{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}
{- |
Description: This module is responsible for letting peers join us.

This module contains the parts responsible for listening for new tcp
connections, as well as joining existing peers in the swarm.
-}
module Haze.Gateway
    ( GatewayInfo
    , makeGatewayInfo
    , GatewayM
    , runGatewayM
    , gatewayLoop
    )
where

import           Relude

import           Control.Concurrent             ( forkIO )
import           Control.Concurrent.STM.TBQueue ( TBQueue
                                                , readTBQueue
                                                )
import           Control.Exception.Safe         ( MonadThrow
                                                , MonadCatch
                                                , MonadMask
                                                , bracket
                                                )
import           Control.Monad.Random           ( MonadRandom )
import qualified Data.Attoparsec.ByteString    as AP
import qualified Data.ByteString               as BS
import qualified Data.HashMap.Strict           as HM
import qualified Network.Simple.TCP            as TCP
import           System.Random.Shuffle          ( shuffleM )

import           Haze.Peer                      ( makePeerMInfo
                                                , runPeerM
                                                , startPeer
                                                )
import           Haze.PeerInfo                  ( PeerInfo(..)
                                                , HasPeerInfo(..)
                                                , addPeer
                                                )
import           Haze.Tracker                   ( AnnounceInfo(..)
                                                , MetaInfo(..)
                                                , PeerID(..)
                                                , Peer(..)
                                                , SHA1(..)
                                                , peerIDBytes
                                                )



{- | Represents the start of a handshake message

The entire handshake message also contains a PeerID, but usually
only the first part of the message is sent, and the PeerID follows
at a later time. Because of this, the message is split into the initial
portion, and then we read the PeerID seperately.
-}
newtype HandshakeStart = HandshakeStart
    { handshakeHash :: SHA1
    }

-- | Serialize a handshake start to a bytestring
handshakeBytes :: HandshakeStart -> ByteString
handshakeBytes (HandshakeStart hash) = mconcat
    [ BS.singleton 19
    , "BitTorrent protocol"
    , BS.pack (replicate 8 0)
    , getSHA1 hash
    ]

-- | A parser for the handshake start
parseHandshake :: AP.Parser HandshakeStart
parseHandshake = do
    void $ AP.word8 19
    void $ AP.string "BitTorrent protocol"
    void $ AP.take 8
    hash <- AP.take 8
    return (HandshakeStart (SHA1 hash))

-- | A parser for the peer id
parsePeerID :: AP.Parser PeerID
parsePeerID = PeerID <$> AP.take 20


-- | Maybe the result and the remaining unparsed bytes
type ParseRes a = Maybe (a, ByteString)

-- | Parse a full result from a socket, returning the leftover bytes
parseRecv
    :: MonadIO m => (ByteString -> AP.Result a) -> TCP.Socket -> m (ParseRes a)
parseRecv cb sock = do
    mBytes <- TCP.recv sock 1024
    case cb <$> mBytes of
        Nothing               -> return Nothing
        Just AP.Fail{}        -> return Nothing
        Just (AP.Partial cb') -> parseRecv cb' sock
        Just (AP.Done left a) -> return (Just (a, left))


-- | The maximum number of connections to initiate
maxActiveConnections :: Int
maxActiveConnections = 30

-- | The maximum number of connections to keep passively
maxPassiveConnections :: Int
maxPassiveConnections = 50


-- | Information the gateway needs
data GatewayInfo = GatewayInfo
    { gatewayPeerInfo :: !PeerInfo -- | General peer information
    -- | A Queue where we receive announce information
    , gatewayAnnounces :: !(TBQueue AnnounceInfo)
    -- | The torrent we're downloading
    , gatewayMeta :: !MetaInfo
    -- | The number of connections we currently have
    , gatewayConnections :: !(TVar Int)
    }

-- | Construct gateway information
makeGatewayInfo
    :: MonadIO m
    => PeerInfo
    -> TBQueue AnnounceInfo
    -> MetaInfo
    -> m GatewayInfo
makeGatewayInfo info q meta = GatewayInfo info q meta <$> newTVarIO 0

-- | A computation with access to gateway information
newtype GatewayM a = GatewayM (ReaderT GatewayInfo IO a)
    deriving (Functor, Applicative, Monad,
              MonadReader GatewayInfo, MonadIO, MonadRandom,
              MonadThrow, MonadCatch, MonadMask)

instance HasPeerInfo GatewayM where
    getPeerInfo = asks gatewayPeerInfo

-- | run a gateway computation given the right information
runGatewayM :: GatewayM a -> GatewayInfo -> IO a
runGatewayM (GatewayM m) = runReaderT m

-- | Start the gateway loop
gatewayLoop :: GatewayM ()
gatewayLoop = forever $ do
    q       <- asks gatewayAnnounces
    annInfo <- atomically $ readTBQueue q
    handleAnnounce annInfo
  where
    handleAnnounce :: AnnounceInfo -> GatewayM ()
    handleAnnounce AnnounceInfo {..} = do
        peerMap <- readTVarIO =<< asks (infoMap . gatewayPeerInfo)
        let newPeers = filter (not . (`HM.member` peerMap)) annPeers
        connections <- asks gatewayConnections
        allowed     <- atomically $ do
            current <- readTVar connections
            let left  = max 0 (maxActiveConnections - current)
                toAdd = min left (length newPeers)
            modifyTVar' connections (+ toAdd)
            return toAdd
        chosen  <- take allowed <$> shuffleM newPeers
        context <- ask
        forM_ chosen $ \peer ->
            liftIO . void . forkIO $ runGatewayM (connect peer) context
    connect :: Peer -> GatewayM ()
    connect peer = bracket (connectToPeer peer) cleanup $ \sock -> do
        hash <- asks (metaInfoHash . gatewayMeta)
        TCP.send sock (handshakeBytes (HandshakeStart hash))
        void . runMaybeT $ do
            (shake, left) <- MaybeT $ parseRecv (AP.parse parseHandshake) sock
            let theirHash = handshakeHash shake
            when (theirHash /= hash) (fail "")
            ourID <- asks (infoPeerID . gatewayPeerInfo)
            TCP.send sock (peerIDBytes ourID)
            theirID <- case AP.parse parsePeerID left of
                AP.Fail{}     -> fail ""
                AP.Partial cb -> fmap fst . MaybeT $ parseRecv cb sock
                AP.Done _ r   -> return r
            when (Just theirID /= peerID peer) (fail "")
            handle    <- MaybeT . fmap Just $ addPeer peer
            peerMInfo <- makePeerMInfo sock handle
            liftIO $ runPeerM startPeer peerMInfo
      where
        cleanup :: TCP.Socket -> GatewayM ()
        cleanup sock = do
            TCP.closeSock sock
            connections <- asks gatewayConnections
            atomically $ modifyTVar' connections (\x -> x - 1)


{- | Initiate a connection to a peer

This just connects to the right TCP socket. This should be combined
with some form of bracketing to ensure proper cleanup.
-}
connectToPeer :: MonadIO m => Peer -> m TCP.Socket
connectToPeer Peer {..} = fst <$> TCP.connectSock peerHost (show peerPort)
