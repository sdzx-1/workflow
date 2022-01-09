{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes, ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeOperators #-}
module Metrics where

import           Control.Carrier.Reader
import           Control.Effect.Labelled
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Data
import           Data.Default.Class
import           Data.Kind
import           Data.Maybe
import           Data.Vector.Mutable
import           GHC.TypeLits
import           Prelude                 hiding ( replicate )
import           Text.Read                      ( readMaybe )

type K :: Symbol  -> Type
data K s where
    K ::K s

toi :: forall s . (KnownSymbol s) => K s -> Int
toi _ = fromJust $ readMaybe $ symbolVal (Proxy :: Proxy s)

get :: (KnownSymbol s, Default a) => (a -> K s) -> Int
get v1 = toi . v1 $ def

class Vlength a where
    vlength :: a -> Int

fun
    :: (KnownSymbol s, Default a)
    => IOVector Int
    -> (a -> K s)
    -> (Int -> Int)
    -> IO ()
fun v idx f = unsafeModify v f (get idx)

gv :: (KnownSymbol s, Default a) => IOVector Int -> (a -> K s) -> IO Int
gv v idx = unsafeRead v (get idx)

pv :: (KnownSymbol s, Default a) => IOVector Int -> (a -> K s) -> Int -> IO ()
pv v idx = unsafeWrite v (get idx)

addOne1 :: (KnownSymbol s, Default a) => IOVector Int -> (a -> K s) -> IO ()
addOne1 v idx = fun v idx (+ 1)

subOne1 :: (KnownSymbol s, Default a) => IOVector Int -> (a -> K s) -> IO ()
subOne1 v idx = fun v idx (\x -> x - 1)

type Metric :: Type -> (Type -> Type) -> Type -> Type
data Metric v m a where
    AddOne ::KnownSymbol s => (v -> K s) -> Metric v m ()
    SubOne ::KnownSymbol s => (v -> K s) -> Metric v m ()
    GetVal ::KnownSymbol s => (v -> K s) -> Metric v m Int
    PutVal ::KnownSymbol s => (v -> K s) -> Int -> Metric v m ()

addOne :: (Has (Metric v) sig m, KnownSymbol s) => (v -> K s) -> m ()
addOne g = send (AddOne g)

subOne :: (Has (Metric v) sig m, KnownSymbol s) => (v -> K s) -> m ()
subOne g = send (SubOne g)

getVal :: (Has (Metric v) sig m, KnownSymbol s) => (v -> K s) -> m Int
getVal g = send (GetVal g)

putVal :: (Has (Metric v) sig m, KnownSymbol s) => (v -> K s) -> Int -> m ()
putVal g v = send (PutVal g v)

newtype MetriC v m a= MetriC { unMetric :: ReaderC (IOVector Int) m a }
  deriving (Functor, Applicative, Monad, MonadIO)

instance (Algebra sig m, MonadIO m, Default v) => Algebra (Metric v :+: sig ) (MetriC v m) where
    alg hdl sig ctx = MetriC $ ReaderC $ \iov -> case sig of
        L (AddOne g) -> do
            liftIO $ addOne1 iov g
            pure ctx
        L (SubOne g) -> do
            liftIO $ subOne1 iov g
            pure ctx
        L (GetVal g) -> do
            v <- liftIO $ gv iov g
            pure (v <$ ctx)
        L (PutVal g v) -> do
            liftIO $ pv iov g v
            pure ctx
        R signa -> alg (runReader iov . unMetric . hdl) signa ctx

runMetric :: forall v m a . (MonadIO m, Default v) => MetriC v m a -> m a
runMetric f = do
    v <- liftIO creatVec
    runMetricWith v f

data Vec v = Vec v (IOVector Int)

creatVec :: forall v . (Vlength v, Default v) => IO (Vec v)
creatVec = do
    iov <- liftIO $ replicate (vlength @v undefined) 0
    pure (Vec def iov)

runMetricWith :: forall v m a . (MonadIO m) => Vec v -> MetriC v m a -> m a
runMetricWith (Vec v iov) f = runReader iov $ unMetric f

data V = V
    { timer   :: K "0"
    , sleeper :: K "1"
    , counter :: K "2"
    }

instance Default V where
    def = V K K K

instance Vlength a where
    vlength _ = 3

v1 :: (Has (Metric V) sig m, MonadIO m) => m Int
v1 = do
    replicateM_ 31 $ do
        addOne timer
    getVal sleeper

-- >>> r1
-- 0
r1 :: IO Int
r1 = runMetric @V v1