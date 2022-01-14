{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ConstraintKinds #-}

module HasWorkGroup where
import           Control.Carrier.Reader
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Effect.Labelled
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Foldable
import           Data.IntMap                    ( IntMap )
import qualified Data.IntMap                   as IntMap
import           Data.Kind
import           Data.Traversable               ( for )
import           GHC.TypeLits
import           Type
import           Unsafe.Coerce                  ( unsafeCoerce )

type HasWorkGroup (serverName :: Symbol) s ts sig m
    = ( Elems serverName ts (ToList s)
      , HasLabelled serverName (Request s ts) sig m
      )

type Request :: (Type -> Type)
            -> [Type]
            -> (Type -> Type)
            -> Type
            -> Type
data Request s ts m a where
    SendReq ::(ToSig t s) =>Int -> t -> Request s ts m ()

sendReq
    :: forall (serverName :: Symbol) s ts sig m t
     . ( Elem serverName t ts
       , ToSig t s
       , HasLabelled serverName (Request s ts) sig m
       )
    => Int
    -> t
    -> m ()
sendReq i t = sendLabelled @serverName (SendReq i t)

callById
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , MonadIO m
       , HasLabelled (serverName :: Symbol) (Request s ts) sig m
       )
    => Int
    -> (MVar b -> e)
    -> m b
callById i f = do
    mvar <- liftIO newEmptyMVar
    sendReq @serverName i (f mvar)
    liftIO $ takeMVar mvar

mcall
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , MonadIO m
       , HasLabelled (serverName :: Symbol) (Request s ts) sig m
       )
    => [Int]
    -> (MVar b -> e)
    -> m [b]
mcall is f = do
    for is $ \idx -> do
        mvar <- liftIO newEmptyMVar
        v    <- sendReq @serverName idx (f mvar)
        liftIO $ takeMVar mvar

castById
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , MonadIO m
       , HasLabelled (serverName :: Symbol) (Request s ts) sig m
       )
    => Int
    -> e
    -> m ()
castById i f = do
    sendReq @serverName i f


mcast
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , MonadIO m
       , LabelledMember serverName (Request s ts) sig
       , Algebra sig m
       )
    => [Int]
    -> e
    -> m ()
mcast is f = mapM_ (\x -> castById @serverName x f) is

newtype RequestC s ts m a = RequestC { unRequestC :: ReaderC (IntMap (TChan (Sum s ts))) m a }
  deriving (Functor, Applicative, Monad, MonadIO)

instance (Algebra sig m, MonadIO m) => Algebra (Request s ts :+: sig) (RequestC s ts m) where
    alg hdl sig ctx = RequestC $ ReaderC $ \c -> case sig of
        L (SendReq i t) -> do
            case IntMap.lookup i c of
                Nothing -> error "...."
                Just ch -> do
                    liftIO $ atomically $ writeTChan ch (inject t)
                    pure ctx
        R signa -> alg (runReader c . unRequestC . hdl) signa ctx

runWithWorkGroup
    :: forall serverName s ts m a
     . [(Int, TChan (Some s))]
    -> Labelled (serverName :: Symbol) (RequestC s ts) m a
    -> m a
runWithWorkGroup chan f =
    runReader (unsafeCoerce $ IntMap.fromList chan) $ unRequestC $ runLabelled f

type ToWrokMessage f = Reader (TChan (Some f))

workHelper
    :: forall f es sig m
     . (Has (Reader (TChan (Some f))) sig m, MonadIO m)
    => (forall s . f s -> m ())
    -> m ()
    -> m ()
workHelper f w = forever $ do
    tc  <- ask @(TChan (Some f))
    isE <- liftIO $ atomically (isEmptyTChan tc)
    if isE then w else go tc
  where
    go tc = do
        Some v <- liftIO $ atomically $ readTChan tc
        f v
        isE <- liftIO $ atomically (isEmptyTChan tc)
        if isE then pure () else go tc

runWorkerWithChan
    :: forall f m a . TChan (Some f) -> ReaderC (TChan (Some f)) m a -> m a
runWorkerWithChan = runReader

resp :: (MonadIO m) => MVar a -> a -> m ()
resp tmv a = liftIO $ putMVar tmv a