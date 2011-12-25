-- | Provides a simple, clean monad to write websocket servers in
{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings,
        NoMonomorphismRestriction, Rank2Types, ScopedTypeVariables #-}
module Network.WebSockets.Monad
    ( WebSocketsOptions (..)
    , defaultWebSocketsOptions
    , WebSockets (..)
    , runWebSockets
    , runWebSocketsWith
    , runWebSocketsHandshake
    , runWebSocketsWithHandshake
    , runWebSocketsWith'
    , receive
    , sendWith
    , send
    , Sink
    , sendSink
    , getSink
    , getOptions
    , getProtocol
    , getVersion
    , throwWsError
    , catchWsError
    , spawnPingThread
    ) where

import Control.Applicative (Applicative, (<$>))
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (Exception (..), SomeException, throw)
import Control.Monad (forever)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Control.Monad.Trans (MonadIO, lift, liftIO)

import Blaze.ByteString.Builder (Builder)
import Blaze.ByteString.Builder.Enumerator (builderToByteString)
import Data.ByteString (ByteString)
import Data.Enumerator (Enumerator, Iteratee, ($$), (>>==), (=$))
import qualified Data.Attoparsec.Enumerator as AE
import qualified Data.Enumerator as E
import qualified Data.Enumerator.List as EL

import Network.WebSockets.Handshake
import Network.WebSockets.Handshake.Http
import Network.WebSockets.Handshake.ShyIterParser
import Network.WebSockets.Mask
import Network.WebSockets.Protocol
import Network.WebSockets.Types

-- | Options for the WebSocket program
data WebSocketsOptions = WebSocketsOptions
    { onPong       :: IO ()
    }

-- | Default options
defaultWebSocketsOptions :: WebSocketsOptions
defaultWebSocketsOptions = WebSocketsOptions
    { onPong       = return ()
    }

-- | Environment in which the 'WebSockets' monad actually runs
data WebSocketsEnv p = WebSocketsEnv
    { options     :: WebSocketsOptions
    , sendBuilder :: Builder -> IO ()
    , protocol    :: p
    }

-- | The monad in which you can write WebSocket-capable applications
newtype WebSockets p a = WebSockets
    { unWebSockets :: ReaderT (WebSocketsEnv p) (Iteratee (Message p) IO) a
    } deriving (Applicative, Functor, Monad, MonadIO)

-- | Receives the initial client handshake, then behaves like 'runWebSockets'.
runWebSocketsHandshake :: Protocol p
                       => (Request -> WebSockets p a)
                       -> Iteratee ByteString IO ()
                       -> Iteratee ByteString IO a
runWebSocketsHandshake = runWebSocketsWithHandshake defaultWebSocketsOptions

-- | Receives the initial client handshake, then behaves like
-- 'runWebSocketsWith'.
runWebSocketsWithHandshake :: Protocol p
                           => WebSocketsOptions
                           -> (Request -> WebSockets p a)
                           -> Iteratee ByteString IO ()
                           -> Iteratee ByteString IO a
runWebSocketsWithHandshake opts goWs outIter = do
    httpReq <- receiveIteratee decodeRequest
    runWebSocketsWith opts httpReq goWs outIter

-- | Run a 'WebSockets' application on an 'Enumerator'/'Iteratee' pair, given
-- that you (read: your web server) has already received the HTTP part of the
-- initial request. If not, you might want to use 'runWebSocketsWithHandshake'
-- instead.
--
-- If the handshake failed, throws a 'HandshakeError'. Otherwise, executes the
-- supplied continuation. You should still send a response to the client
-- yourself.
runWebSockets :: Protocol p
              => RequestHttpPart
              -> (Request -> WebSockets p a)
              -> Iteratee ByteString IO ()
              -> Iteratee ByteString IO a
runWebSockets = runWebSocketsWith defaultWebSocketsOptions

-- | Version of 'runWebSockets' which allows you to specify custom options
runWebSocketsWith :: forall p a. Protocol p
                  => WebSocketsOptions
                  -> RequestHttpPart
                  -> (Request -> WebSockets p a)
                  -> Iteratee ByteString IO ()
                  -> Iteratee ByteString IO a
runWebSocketsWith opts httpReq goWs outIter = do
    mreq <- receiveIterateeShy $ tryFinishRequest httpReq
    case mreq of
        (Left err) -> do
            sendIteratee encodeResponse (responseError proto err) outIter
            E.throwError err
        (Right (r, p)) -> runWebSocketsWith' opts p (goWs r) outIter
  where
    proto :: p
    proto = undefined

runWebSocketsWith' :: Protocol p
                   => WebSocketsOptions
                   -> p
                   -> WebSockets p a
                   -> Iteratee ByteString IO ()
                   -> Iteratee ByteString IO a
runWebSocketsWith' opts proto ws outIter = do
    sendLock <- liftIO $ newMVar () 

    let sender = makeSend sendLock
        env    = WebSocketsEnv opts sender proto
        iter   = runReaderT (unWebSockets ws) env

    decodeMessages proto =$ iter
  where
    makeSend sendLock x = withMVar sendLock $ \_ ->
        builderSender outIter x

-- | @spawnPingThread n@ spawns a thread which sends a ping every @n@ seconds
-- (if the protocol supports it). To be called after having sent the response.
spawnPingThread :: BinaryProtocol p => Int -> WebSockets p ()
spawnPingThread i = do
    sink <- getSink
    _ <- liftIO $ forkIO $ forever $ do
        -- An ugly hack here. We first sleep before sending the first
        -- ping, so the ping (hopefully) doesn't interfere with the
        -- intitial request/response.
        threadDelay (i * 1000 * 1000)  -- seconds
        sendSink sink $ ping ("Hi" :: ByteString)
    return ()

-- todo: move some stuff to another module. "Decode"?

-- | Receive arbitrary data.
receiveIteratee :: Decoder p a -> Iteratee ByteString IO a
receiveIteratee parser = do
    eof <- E.isEOF
    if eof
        then E.throwError ConnectionClosed
        else wrappingParseError . AE.iterParser $ parser

-- | Like receiveIteratee, but if the supplied parser is happy with no input,
-- we don't supply any more. This is very, very important when we have parsers
-- that don't necessarily read data, like hybi10's completeRequest.
receiveIterateeShy :: Decoder p a -> Iteratee ByteString IO a
receiveIterateeShy parser = wrappingParseError $ shyIterParser parser

-- | Execute an iteratee, wrapping attoparsec-enumeratee's ParseError into the
-- ParseError constructor (which is a ConnectionError).
wrappingParseError :: (Monad m) => Iteratee a m b -> Iteratee a m b
wrappingParseError = flip E.catchError $ \e -> E.throwError $
    maybe e (toException . ParseError) $ fromException e

-- | Receive a message
receive :: Protocol p => WebSockets p (Message p)
receive = liftIteratee $ do
    mmsg <- EL.head
    case mmsg of
        Nothing  -> E.throwError ConnectionClosed
        Just msg -> return msg

sendIteratee :: Encoder p a -> a
             -> Iteratee ByteString IO ()
             -> Iteratee ByteString IO ()
sendIteratee enc resp outIter = do
    liftIO $ mkSend (builderSender outIter) enc resp

-- | Low-leven sending with an arbitrary 'Encoder'
sendWith :: Encoder p a -> a -> WebSockets p ()
sendWith encoder x = WebSockets $ do
    send' <- sendBuilder <$> ask
    liftIO $ mkSend send' encoder x

-- | Low-level sending with an arbitrary 'T.Message'
send :: Protocol p => Message p -> WebSockets p ()
send msg = getSink >>= \sink -> liftIO $ sendSink sink msg

-- | Used for asynchronous sending.
newtype Sink p = Sink {unSink :: Message p -> IO ()}

-- | Send a message to a sink. Might generate an exception if the underlying
-- connection is closed.
sendSink :: Sink p -> Message p -> IO ()
sendSink = unSink

-- | In case the user of the library wants to do asynchronous sending to the
-- socket, he can extract a 'Sink' and pass this value around, for example,
-- to other threads.
getSink :: Protocol p => WebSockets p (Sink p)
getSink = WebSockets $ do
    proto <- unWebSockets getProtocol
    send' <- sendBuilder <$> ask
    return $ Sink $ mkSend send' $ encodeMessage proto

-- TODO: rename to mkEncodedSender?
mkSend :: (Builder -> IO ()) -> Encoder p a -> a -> IO ()
mkSend send' encoder x = do
    mask <- randomMask
    send' $ encoder mask x

singleton :: Monad m => a -> Enumerator a m b
singleton c = E.checkContinue0 $ \_ f -> f (E.Chunks [c]) >>== E.returnI

builderSender :: MonadIO m => Iteratee ByteString m b -> Builder -> m ()
builderSender outIter x = do
    ok <- E.run $ singleton x $$ builderToByteString $$ outIter
    case ok of
        Left err -> throw err
        Right _  -> return ()

-- | Get the current configuration
getOptions :: WebSockets p WebSocketsOptions
getOptions = WebSockets $ ask >>= return . options

-- | Get the underlying protocol
getProtocol :: WebSockets p p
getProtocol = WebSockets $ protocol <$> ask

-- | Find out the 'WebSockets' version used at runtime
getVersion :: Protocol p => WebSockets p String
getVersion = version <$> getProtocol

-- | Throw an iteratee error in the WebSockets monad
throwWsError :: (Exception e) => e -> WebSockets p a
throwWsError = liftIteratee . E.throwError

-- | Catch an iteratee error in the WebSockets monad
catchWsError :: WebSockets p a
             -> (SomeException -> WebSockets p a)
             -> WebSockets p a
catchWsError act c = WebSockets $ do
    env <- ask
    let it  = peelWebSockets env $ act
        cit = peelWebSockets env . c
    lift $ it `E.catchError` cit
  where
    peelWebSockets env = flip runReaderT env . unWebSockets

-- | Lift an Iteratee computation to WebSockets
liftIteratee :: Iteratee (Message p) IO a -> WebSockets p a
liftIteratee = WebSockets . lift
