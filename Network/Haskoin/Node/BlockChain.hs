{-# LANGUAGE TemplateHaskell #-}
module Network.Haskoin.Node.BlockChain
( withBlockChain
) where

import Control.Monad ( when, unless, forM_, forever, liftM)
import Control.Monad.Trans (MonadIO, liftIO, lift)
import Control.Monad.State (StateT, evalStateT, gets, modify)
import Control.Monad.Logger (MonadLogger, logInfo, logWarn, logDebug, logError)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.Async.Lifted (withAsync, link)
import Control.Monad.Trans.Control (MonadBaseControl)

import Data.Text (Text, pack)
import Data.Maybe (isJust, isNothing, fromJust)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Clock (UTCTime, getCurrentTime, addUTCTime)
import Data.Unique (newUnique, hashUnique)
import Data.Conduit (Sink, awaitForever, ($$))
import Data.Conduit.TMChan (TBMChan, writeTBMChan, newTBMChan, sourceTBMChan)
import qualified Data.Map as M 
    ( Map, keys , empty, insert, lookup
    , assocs, partition, size, null, delete
    )

import Network.Haskoin.Block
import Network.Haskoin.Crypto
import Network.Haskoin.Constants
import Network.Haskoin.Node.Bloom
import Network.Haskoin.Node.PeerManager
import Network.Haskoin.Node.Chan

data SpvSession = SpvSession
    { -- Peer manager message channel
      mngrChan :: !(TBMChan ManagerMessage)
      -- Mempool message channel
    , mempChan :: !(TBMChan MempoolMessage)
      -- Peer that is currently syncing the headers
    , syncResource :: !(Maybe JobResource)
      -- Timeout to detect a stalled header sync
    , syncTimeout :: !UTCTime
      -- Block hashes that a peer advertised to us but we haven't linked them
      -- yet to our chain. We use this map to update the peer height once
      -- those blocks are linked. Only the last tickle of any peer is stored.
    , peerTickles :: !(M.Map PeerId BlockHash)
      -- This value will be True if the wallet has sent us a non-empty 
      -- bloom filter.
    , validBloom :: !Bool
      -- Continue downloading blocks from this point on. The merkle download
      -- process will be paused as long as this value is Nothing.
    , windowEnd :: !(Maybe BlockHash)
      -- Do not request merkle blocks with a timestamp before the
      -- fast catchup time.
    , fastCatchup :: !(Maybe Timestamp)
      -- True if we are downloading merkles. False for full blocks.
    , downloadMerkles :: !Bool
      -- Merkle download batch which we are currently waiting for
    , merkleId :: !(Maybe (DwnMerkleId, BlockChainAction))
      -- Block window. Every element in the window corresponds to a block
      -- download job. Completed jobs in the window are sent to the mempool in
      -- order.
    , blockWindow :: !(M.Map DwnBlockId (BlockChainAction, [Block]))
      -- Estimated height of the best chain on the bitcoin network
    , networkHeight :: !BlockHeight
    }

data LocatorType
    = FullLocator
    | PartialLocator
    | LastLocator
    deriving (Eq, Read, Show)

-- | Start the SpvBlockChain. This function will spin up a new thread and
-- return the BlockChain message channel to communicate with it.
withBlockChain 
    :: (HeaderTree m, MonadLogger m, MonadIO m, MonadBaseControl IO m)
    => TBMChan MempoolMessage
    -> (TBMChan BlockChainMessage -> TBMChan ManagerMessage -> m ())
    -> m ()
withBlockChain mempChan f = do
    bkchChan <- liftIO $ atomically $ newTBMChan 10000
    withPeerManager bkchChan mempChan $ \mngrChan -> do
        now <- liftIO getCurrentTime
        let syncResource    = Nothing
            syncTimeout     = now -- dummy value
            peerTickles     = M.empty
            windowEnd       = Nothing
            fastCatchup     = Nothing
            downloadMerkles = False
            merkleId        = Nothing
            blockWindow     = M.empty
            validBloom      = False
            networkHeight   = 0
            session         = SpvSession{..}

            -- Run the main blockchain message processing loop
            run = do
                $(logDebug) $ format "SPV Blockchain thread started"
                -- Initialize Header Tree
                runDB initHeaderTree
                -- Trigger the header download
                height <- runDB bestBlockHeaderHeight
                $(logInfo) $ format 
                    "Running a full block locator. This can take some time."
                headerSync (AnyPeer height) FullLocator Nothing
                -- Process messages
                sourceTBMChan bkchChan $$ processBlockChainMessage

            -- Monitoring hearbeat
            heartbeat = do
                $(logDebug) $ format "Blockchain heartbeat thread started"
                forever $ do
                    liftIO $ threadDelay $ 1000000 * 120 -- Sleep for 2 minutes
                    liftIO . atomically $ writeTBMChan bkchChan BkchHeartbeat

        withAsync (evalStateT run session) $ \a1 -> do
            withAsync (evalStateT heartbeat session) $ \a2 -> do
                link a1 >> link a2 >> f bkchChan mngrChan

processBlockChainMessage :: (HeaderTree m, MonadLogger m, MonadIO m) 
                         => Sink BlockChainMessage (StateT SpvSession m) ()
processBlockChainMessage = awaitForever $ \req -> lift $ case req of
    BlockTickle pid bid      -> processBlockTickle pid bid
    IncHeaders pid bhs       -> processBlockHeaders pid bhs
    IncBlocks did blocks     -> processBlocks did blocks
    IncMerkleBlocks did dmbs -> processMerkleBlocks did dmbs
    StartMerkleDownload valE -> processStartMerkleDownload valE
    StartBlockDownload valE  -> processStartBlockDownload valE
    SetBloomFilter bloom     -> processBloomFilter bloom
    NetworkHeight h          -> processNetworkHeight h
    BkchHeartbeat            -> processHeartbeat
    _ -> return () -- Ignore block invs (except tickles) and full blocks

-- | Handle block tickles from a peer. A peer can only send us one tickle
-- at a time. If we are syncing the tickle of a peer, we ignore other
-- tickles form the same peer.
processBlockTickle :: (HeaderTree m, MonadLogger m, MonadIO m) 
                   => PeerId -> BlockHash -> StateT SpvSession m ()
processBlockTickle pid bid = do
    $(logInfo) $ format $ unwords
        [ "Received block tickle", encodeBlockHashLE bid
        , "from peer", show $ hashUnique pid
        ]
    nodeM <- runDB $ getBlockHeaderNode bid
    case nodeM of
        Just node -> do
            $(logDebug) $ format "We already have this block hash."
            -- Update the height of the peer who sent us this tickle
            sendManager $ PeerHeight pid $ nodeHeaderHeight node
        Nothing -> do
            $(logDebug) $ format $ unwords
                [ "Buffering block hash tickle to update peer height when"
                , "we can connect it."
                ]
            -- Save the PeerId/BlockHash so we can update the PeerId height
            -- when we can connect the block.
            -- TODO: We could have a DoS leak here
            setPeerTickle pid bid
            --Request headers so we can connect this block
            headerSync (ThisPeer pid) PartialLocator $ Just bid

processBlockHeaders :: (HeaderTree m, MonadLogger m, MonadIO m) 
                    => PeerId -> [BlockHeader] -> StateT SpvSession m ()

processBlockHeaders pid [] = canProcessHeaders pid >>= \valid -> when valid $ do
    $(logInfo) $ format $ unwords 
        [ "Finished downloading headers from peer", show $ hashUnique pid ]
    continueDownload
    -- Check if block downloads have reached the headers
    checkSynced

processBlockHeaders pid hs = canProcessHeaders pid >>= \valid -> when valid $ do
    $(logDebug) $ format $ unwords
        [ "Received", show $ length hs, "headers" 
        , "from peer", show $ hashUnique pid
        ]
    now <- liftM round $ liftIO getPOSIXTime
    -- Connect block headers and commit them
    actionE <- runDB $ connectHeaders hs now True
    case actionE of
        Left err -> sendManager $ PeerMisbehaving pid severeDoS err
        Right action -> case action of
            -- Ignore SideChain/duplicate headers
            SideChain _ -> do
                $(logDebug) $ format $ unwords
                    [ "Ignoring side chain headers from peer"
                    , show $ hashUnique pid
                    ]
            -- Headers extend our current best head
            _ -> do
                let nodes  = actionNewNodes action
                    height = nodeHeaderHeight $ last nodes
                $(logInfo) $ format $ unwords 
                    [ "Headers from peer", show $ hashUnique pid
                    , "connected successfully."
                    , "New best header height:", show height
                    ]
                -- Adjust height of peers that sent us a tickle for
                -- these blocks
                forM_ nodes adjustPeerHeight
                -- Adjust height of the node that sent us these headers
                sendManager $ PeerHeight pid height
                -- Continue syncing headers from the same peer
                headerSync (ThisPeer pid) LastLocator Nothing
                -- Try to download more blocks
                continueDownload

-- If the resource is a specific peer, only allow that peer to connect more
-- headers. If that peer stalls, we will detect it with the monitoring.
canProcessHeaders :: MonadLogger m => PeerId -> StateT SpvSession m Bool
canProcessHeaders pid = do
    valid <- liftM f $ gets syncResource
    -- If the peer is allowed to process the headers, we reset the resource
    -- so that a new header sync can happen.
    when valid $ modify $ \s -> s{ syncResource = Nothing }
    return valid
  where
    f (Just (ThisPeer pid')) = pid == pid'
    f _ = True

-- | Request a header download job for the given peer resource
headerSync :: (HeaderTree m, MonadLogger m, MonadIO m)
           => JobResource -> LocatorType -> Maybe BlockHash
           -> StateT SpvSession m ()
headerSync resource locType hStopM = do
    -- Only download more headers if a header request is not already sent
    gets syncResource >>= \resM -> when (isNothing resM) $ do
        $(logDebug) $ format $ unwords 
            [ "Requesting more headers with block locator type", show locType ]
        -- Save the deadline for this job (2 minutes). If we don't get a
        -- response within the given time, we continue the header download.
        deadline <- liftM (addUTCTime 120) $ liftIO getCurrentTime
        modify $ \s -> s{ syncResource = Just resource
                        , syncTimeout  = deadline
                        }
        -- Build the block locator object
        loc <- runDB $ case locType of
            FullLocator    -> blockLocator 
            PartialLocator -> partialLocator 20
            LastLocator    -> liftM ((:[]) . nodeBlockHash) getBestBlockHeader
        -- Send a job that can only run on the given PeerId. Priority = 2 to
        -- give priority to BloomFilters (0) and Tx broadcasts (1)
        sendManager $ PublishJob (JobHeaderSync loc hStopM) resource 2

-- | When we get a block, check if we are awaiting this specific
-- batch ID and dispatch it to the mempool. If we had no transactions, 
-- continue the merkle download.
processBlocks :: (HeaderTree m, MonadLogger m, MonadIO m)
              => DwnBlockId -> [Block] -> StateT SpvSession m ()
processBlocks did [] = do
    $(logError) $ format $ "Got a completed block job with an empty block list"
    modify $ \s -> s{ blockWindow = M.delete did $ blockWindow s }
    continueBlockDownload
processBlocks did blocks = do
    $(logDebug) $ format $ unwords
        [ "Received block batch id", show $ hashUnique did
        , "containing", show $ length blocks, "blocks."
        ]
    win <- gets blockWindow
    -- Find this specific job in the window
    case M.lookup did win of
        Just (action, []) -> do
            $(logDebug) $ format $ unwords
                [ "Saving block batch id", show $ hashUnique did
                , "in block window."
                ]
            -- Add the blocks to the window
            modify $ \s -> s{ blockWindow = M.insert did (action, blocks) win }
            -- Try to send blocks to the mempool
            dispatchBlocks 
        -- This can happen if we had pending jobs when issuing a rescan. We
        -- simply ignore jobs from before the rescan.
        _ -> $(logDebug) $ format $ unwords
            [ "Ignoring block batch id", show $ hashUnique did ] 
  where
    dispatchBlocks = do
        win <- gets blockWindow
        case M.assocs win of
            -- If the first batch in the window is ready, send it to the mempool
            ((doneId, (action, doneBlocks@(_:_))):_) -> do
                $(logDebug) $ format $ unwords
                    [ "Dispatching block batch id", show $ hashUnique doneId
                    , "to the mempool."
                    ]
                sendMempool $ MempoolBlocks action doneBlocks
                modify $ \s -> s{ blockWindow = M.delete doneId win }
                dispatchBlocks
            -- Try to download more blocks if there is space in the window
            _ -> do
                continueBlockDownload
                checkSynced

-- | When we get a merkle block, check if we are awaiting this specific
-- batch ID and dispatch it to the mempool. If we had no transactions, 
-- continue the merkle download.
processMerkleBlocks :: (HeaderTree m, MonadLogger m, MonadIO m)
                    => DwnMerkleId 
                    -> [DecodedMerkleBlock] -> StateT SpvSession m ()
processMerkleBlocks did [] = gets merkleId >>= \mid -> case mid of
    Just (expId, _) -> if did == expId
        then do
            $(logError) $ format $ 
                "Got a completed merkle job with an empty merkle list"
            modify $ \s -> s{ merkleId = Nothing }
            -- We continue the merkle download because we didn't have any
            -- transactions
            continueMerkleDownload
            checkSynced
        else $(logDebug) $ format $ unwords
            [ "Ignoring merkle batch id", show $ hashUnique did ] 
    _ -> $(logDebug) $ format $ unwords
        [ "Ignoring empty merkle batch id", show $ hashUnique did ] 

processMerkleBlocks did dmbs = gets merkleId >>= \mid -> case mid of
    Just (expId, action) -> if did == expId
        then do
            $(logDebug) $ format $ unwords
                [ "Received merkle batch id", show $ hashUnique did
                , "containing", show $ length dmbs, "merkle blocks."
                , "Dispatching it to the mempool"
                ]
            -- Clear the inflight merkle
            modify $ \s -> s{ merkleId = Nothing }
            -- Try to send the merkle block to the mempool
            sendMempool $ MempoolMerkles action dmbs
            -- Continue the merkle download only if no transactions
            -- are in the batch. Otherwise, we wait for the wallets 
            -- instructions. The wallet might want to set a new bloom filter.
            if (null $ concat $ map merkleTxs dmbs) 
                then do
                    $(logDebug) $ format $ unwords
                        [ "No transactions in the merkle batch."
                        , "Continuing merkle block download"
                        ]
                    continueMerkleDownload
                -- Set the windowEnd to False to block the merkle download.
                -- Only the wallet can continue it.
                else do
                    $(logDebug) $ format $ unwords
                        [ "Got transactions in the merkle batch."
                        , "Blocking merkle block download and awaiting"
                        , "instructions from the wallet."
                        ]
                    modify $ \s -> s{ windowEnd = Nothing }
            checkSynced
        else $(logDebug) $ format $ unwords
            [ "Ignoring merkle batch id", show $ hashUnique did ] 
    -- This can happen if we had pending jobs when issuing a rescan. We
    -- simply ignore jobs from before the rescan.
    _ -> $(logDebug) $ format $ unwords
        [ "Ignoring merkle batch id", show $ hashUnique did ] 

-- Call the right download function depending on what the user requested
continueDownload :: (HeaderTree m, MonadLogger m, MonadIO m) 
                 => StateT SpvSession m ()
continueDownload = do
    merkles <- gets downloadMerkles
    if merkles then continueMerkleDownload else continueBlockDownload

-- | If we are not already downloading a merkle batch, request a new merkle
-- batch download job.
continueMerkleDownload :: (HeaderTree m, MonadLogger m, MonadIO m) 
                       => StateT SpvSession m ()
continueMerkleDownload = do
    dwnM   <- gets windowEnd
    mid    <- gets merkleId
    -- Merkle block downloads require a valid bloom filter
    vBloom <- gets validBloom
    -- Download merkle blocks if the wallet asked us to start, if we are
    -- not already downloading a merkle batch and we got a valid bloom filter.
    when (vBloom && isJust dwnM && isNothing mid) $ do
        let dwn = fromJust dwnM
        -- Get a batch of blocks to download
        -- TODO: Add this value to a configuration (10)
        actionM <- runDB $ getNodeWindow dwn 10
        case actionM of
            -- Nothing to download
            Nothing -> $(logDebug) $ format 
                "No more block headers available to download."
            -- A batch of merkle blocks is available for download
            Just action -> do
                -- Update the windowEnd pointer
                let nodes  = actionNewNodes action
                    winEnd = Just $ nodeBlockHash $ last nodes
                modify $ \s -> s{ windowEnd = winEnd }
                fcM <- gets fastCatchup 
                let fc = fromJust fcM
                    ts = map (blockTimestamp . nodeHeader) nodes
                    height = nodeHeaderHeight $ last nodes
                -- Check if the batch is after the fast catchup time
                if isNothing fcM || any (>= fc) ts
                    then do
                        did <- liftIO newUnique
                        let job = JobDwnMerkles did $ map nodeBlockHash nodes
                        $(logDebug) $ format $ unwords
                            [ "Requesting download of merkle batch id"
                            , show $ hashUnique did
                            , "of length", show $ length nodes
                            , "up to height", show height
                            ]
                        -- Publish the job with low priority 10
                        sendManager $ PublishJob job (AnyPeer height) 10
                        -- Extend the window
                        modify $ \s -> 
                            s{ merkleId   = Just (did, action)
                            -- We reached the fast catchup. Set to Nothing.
                            , fastCatchup = Nothing
                            }
                    else do
                        $(logDebug) $ format $ unwords
                            [ "Not downloading pre-catchup merkle block of"
                            , "length", show $ length nodes
                            , "up to height", show height
                            ]
                        -- Recurse with the windowEnd pointer updated
                        continueMerkleDownload

-- | If space is available in the block block download window, request
-- more block download jobs and add them to the window.
continueBlockDownload :: (HeaderTree m, MonadLogger m, MonadIO m) 
                      => StateT SpvSession m ()
continueBlockDownload = do
    dwnM      <- gets windowEnd
    win       <- gets blockWindow
    -- Download merkle blocks if the wallet asked us to start and if there
    -- is space left in the window and the bloom filter is valid.
    when (isJust dwnM && M.size win < 10) $ do
        let dwn = fromJust dwnM
        -- Get a batch of blocks to download
        -- TODO: Add this value to a configuration (100)
        actionM <- runDB $ getNodeWindow dwn 100
        case actionM of
            -- Nothing to download
            Nothing -> $(logDebug) $ format 
                "No more block headers available to download."
            -- A batch of merkle blocks is available for download
            Just action -> do
                -- Update the windowEnd pointer
                let nodes  = actionNewNodes action
                    winEnd = Just $ nodeBlockHash $ last nodes
                modify $ \s -> s{ windowEnd = winEnd }
                fcM <- gets fastCatchup 
                let fc = fromJust fcM
                    ts = map (blockTimestamp . nodeHeader) nodes
                    height = nodeHeaderHeight $ last nodes
                -- Check if the batch is after the fast catchup time
                if isNothing fcM || any (>= fc) ts
                    then do
                        did <- liftIO newUnique
                        let job = JobDwnBlocks did $ map nodeBlockHash nodes
                        $(logDebug) $ format $ unwords
                            [ "Requesting download of block batch id"
                            , show $ hashUnique did
                            , "of length", show $ length nodes
                            , "up to height", show height
                            ]
                        -- Publish the job with low priority 10
                        sendManager $ PublishJob job (AnyPeer height) 10
                        -- Extend the window
                        modify $ \s -> 
                            s{ blockWindow = M.insert did (action, []) win 
                            -- We reached the fast catchup. Set to Nothing.
                            , fastCatchup  = Nothing
                            }
                    else $(logDebug) $ format $ unwords
                        [ "Not downloading pre-catchup merkle block of length"
                        , show $ length nodes
                        , "up to height", show height
                        ]
                -- Recurse with the windowEnd pointer updated until we reach
                -- the stop condition (we fill up the window)
                continueBlockDownload

processStartMerkleDownload 
    :: (HeaderTree m, MonadLogger m, MonadIO m) 
    => Either Timestamp BlockHash -> StateT SpvSession m ()
processStartMerkleDownload = flip processStartDownloadG True

processStartBlockDownload 
    :: (HeaderTree m, MonadLogger m, MonadIO m) 
    => Either Timestamp BlockHash -> StateT SpvSession m ()
processStartBlockDownload = flip processStartDownloadG False

processStartDownloadG :: (HeaderTree m, MonadLogger m, MonadIO m) 
                      => Either Timestamp BlockHash 
                      -> Bool -- True for merkle blocks
                      -> StateT SpvSession m ()
processStartDownloadG valE merkle = do
    resM <- case valE of
        -- Set a fast catchup time and search from the genesis
        Left ts -> do
            $(logInfo) $ format $ unwords
                [ "Rescanning merkle blocks from timestamp", show ts ]
            return $ Just (Just ts, Just $ headerHash genesisHeader)
        -- No fast catchup time. Just download from the given block.
        Right h -> do
            runDB (getBlockHeaderNode h) >>= \nodeM -> case nodeM of
                -- The block hash exists
                Just _ -> do
                    $(logDebug) $ format $ unwords
                        [ "Continuing merkle block download from block"
                        , encodeBlockHashLE h
                        ]
                    return $ Just (Nothing, Just h)
                -- Unknown block hash
                _ -> do
                    $(logError) $ format $ unwords
                        [ "Cannot start download. Unknown block hash"
                        , encodeBlockHashLE h
                        ]
                    return Nothing

    case resM of
        Just (fc, we) -> do
            modify $ \s -> 
                s{ fastCatchup     = fc
                 , windowEnd       = we
                 -- Empty the window to ignore any old pending jobs
                 , merkleId        = Nothing
                 , blockWindow     = M.empty
                 -- Save whether we are download blocks or merkles
                 , downloadMerkles = merkle
                 }
            -- Notify the peer manager
            sendManager $ MngrStartDownload valE
            -- Notify the mempool
            sendMempool $ MempoolStartDownload valE
            -- Trigger merkle block downloads
            continueDownload
        _ -> return ()

processBloomFilter :: (HeaderTree m, MonadLogger m, MonadIO m)
                   => BloomFilter -> StateT SpvSession m ()
processBloomFilter bloom 
    | isBloomEmpty bloom =
        $(logWarn) $ format "Trying to load an empty bloom filter"
    | otherwise = do
        $(logDebug) $ format "Received a new bloom filter."
        -- Send the bloom filter to the manager
        sendManager $ MngrBloomFilter bloom
        valid <- gets validBloom
        unless valid $ do
            modify $ \s -> s{ validBloom = True }
            $(logDebug) $ format 
                "Attempting to start the block download."
            -- We got a valid bloom filter form the wallet. We can try to
            -- continue the merkle block download.
            continueDownload

processNetworkHeight :: MonadLogger m => BlockHeight -> StateT SpvSession m ()
processNetworkHeight height = do
    $(logDebug) $ format $ unwords
        [ "Network best chain height:", show height ]
    modify $ \s -> s{ networkHeight = height }

-- Check if merkle blocks are in sync with block headers.
checkSynced :: (HeaderTree m, MonadLogger m, MonadIO m)
            => StateT SpvSession m ()
checkSynced = do
    merkles   <- gets downloadMerkles
    mid       <- gets merkleId
    win       <- gets blockWindow
    winEnd    <- gets windowEnd
    netHeight <- gets networkHeight
    bestNode  <- runDB getBestBlockHeader
        -- We have reached at least the height of the network which must be
        -- greater than 0.
    let netSynced = netHeight > 0 && nodeHeaderHeight bestNode >= netHeight
        -- We are not awaiting any merkle blocks and the merkle pointer
        -- is equal to our best header
        merkleSynced = 
            merkles && isNothing mid && 
            winEnd == Just (nodeBlockHash bestNode)
        blockSynced = 
            (not merkles) && M.null win && 
            winEnd == Just (nodeBlockHash bestNode)
    when (netSynced && (merkleSynced || blockSynced)) $ do
        $(logDebug) $ format "Blocks are synchronized with the network."
        sendMempool MempoolSynced

processHeartbeat :: (HeaderTree m, MonadLogger m, MonadIO m) 
                 => StateT SpvSession m ()
processHeartbeat = do
    $(logDebug) $ format "Sync resource monitoring heartbeat"
    gets syncResource >>= \resM -> case resM of
        Just (ThisPeer pid) -> do
            now <- liftIO getCurrentTime
            deadline <- gets syncTimeout
            when (now > deadline) $ do
                $(logWarn) $ format $ unwords
                    [ "Sync peer", show $ hashUnique pid
                    , "is stalling the header download."
                    ]
                modify $ \s -> s{ syncResource = Nothing }
                height <- runDB bestBlockHeaderHeight
                -- Issue a new header sync with any peer at the right height
                headerSync (AnyPeer height) PartialLocator Nothing
        _ -> return ()
    -- Continue the merkle block download in case it gets stuck
    continueDownload
    
{- Helpers -}

-- Add a BlockHash to the PeerId tickle map
setPeerTickle :: Monad m => PeerId -> BlockHash -> StateT SpvSession m ()
setPeerTickle pid bid = modify $ \s ->
    s{ peerTickles = M.insert pid bid $ peerTickles s }

-- Adjust height of peers that sent us a tickle for these blocks
adjustPeerHeight :: (MonadLogger m, MonadIO m) 
                 => BlockHeaderNode -> StateT SpvSession m ()
adjustPeerHeight node = do
    -- Find peers that have this block as a tickle
    (m, r) <- liftM (M.partition (== bid)) $ gets peerTickles 
    forM_ (M.keys m) $ \pid -> do
        $(logDebug) $ format $ unwords
            [ "Removing buffered tickle from peer", show $ hashUnique pid ]
        -- Update the height of the peer
        sendManager $ PeerHeight pid height
    -- Update the peer tickles
    modify $ \s -> s{ peerTickles = r }
  where
    bid    = nodeBlockHash node
    height = nodeHeaderHeight node

-- Send a message to the PeerManager
sendManager :: MonadIO m => ManagerMessage -> StateT SpvSession m ()
sendManager msg = do
    chan <- gets mngrChan
    liftIO . atomically $ writeTBMChan chan msg

-- Send a message to the mempool
sendMempool :: MonadIO m => MempoolMessage -> StateT SpvSession m ()
sendMempool msg = do
    chan <- gets mempChan
    liftIO . atomically $ writeTBMChan chan msg

runDB :: HeaderTree m => m a -> StateT SpvSession m a
runDB = lift

format :: String -> Text
format str = pack $ unwords [ "[Blockchain]", str ]

