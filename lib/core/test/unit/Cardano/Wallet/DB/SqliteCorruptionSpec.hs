{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Wallet.DB.SqliteCorruptionSpec
    ( spec
    ) where

import Prelude

import Cardano.Wallet
    ( unsafeRunExceptT )
import Cardano.Wallet.DB
    ( DBLayer (..), ErrWalletAlreadyExists (..), PrimaryKey (..) )
import Cardano.Wallet.DB.Sqlite
    ( newDBLayer, newDBLayer' )
import Cardano.Wallet.DBSpec
    ( DummyTarget, KeyValPairs (..), cleanDB, withDB )
import Cardano.Wallet.Primitive.AddressDerivation
    ( Passphrase (..)
    , encryptPassphrase
    , generateKeyFromSeed
    , unsafeGenerateKeyFromSeed
    )
import Cardano.Wallet.Primitive.AddressDiscovery
    ( SeqState (..), defaultAddressPoolGap, mkSeqState )
import Cardano.Wallet.Primitive.Mnemonic
    ( EntropySize, entropyToBytes, genEntropy )
import Cardano.Wallet.Primitive.Model
    ( Wallet, initWallet )
import Cardano.Wallet.Primitive.Types
    ( Address (..)
    , Coin (..)
    , Direction (..)
    , Hash (..)
    , SlotId (..)
    , Tx (..)
    , TxIn (..)
    , TxMeta (TxMeta)
    , TxOut (..)
    , TxStatus (..)
    , WalletDelegation (..)
    , WalletId (..)
    , WalletMetadata (..)
    , WalletName (..)
    , WalletPassphraseInfo (..)
    , WalletState (..)
    )
import Control.Monad
    ( forM_, replicateM_ )
import Control.Monad.IO.Class
    ( liftIO )
import Control.Monad.Trans.Except
    ( runExceptT )
import Crypto.Hash
    ( hash )
import Data.ByteString
    ( ByteString )
import Data.Coerce
    ( coerce )
import Data.Functor
    ( ($>) )
import Data.Quantity
    ( Quantity (..) )
import Data.Text.Class
    ( FromText (..) )
import Data.Time.Clock
    ( getCurrentTime )
import Database.Sqlite
    ( Connection, close )
import System.Directory
    ( doesFileExist, removeFile )
import System.IO.Temp
    ( emptySystemTempFile )
import System.IO.Unsafe
    ( unsafePerformIO )
import Test.Hspec
    ( Expectation
    , Spec
    , SpecWith
    , beforeAll
    , beforeWith
    , describe
    , it
    , shouldReturn
    )
import Test.QuickCheck
    ( Property, choose, generate, property, (==>) )
import Test.QuickCheck.Monadic
    ( monadicIO )

import qualified Data.List as L
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

spec :: Spec
spec = do
    withFileDBLayer $ describe "Check db opening/closing" $ do
        it "opening and closing of db works" $ \(FileDB db conn f) -> do
            cleanDB db
            unsafeRunExceptT $ createWallet db testPk testCp testMetadata
            listWallets db `shouldReturn` [testPk]
            close conn
            replicateM_ 25 (openCloseDB f)

    withFileDBLayer $ describe "Check db reading/writing from/to file and cleaning" $ do

        it "create and list wallet works" $ \(FileDB db conn f) -> do
            unsafeRunExceptT $ createWallet db testPk testCp testMetadata
            listWallets db `shouldReturn` [testPk]
            db1 <- newDBLayer (Just f)
            runExceptT (createWallet db1 testPk testCp testMetadata)
                `shouldReturn` (Left (ErrWalletAlreadyExists testWid))
            ( testOpeningCleaning f
                listWallets
                [testPk]
                [] )

        it "create and get meta works" $ \(FileDB db conn f) -> do
            now <- getCurrentTime
            let md = testMetadata { passphraseInfo = Just $ WalletPassphraseInfo now }
            unsafeRunExceptT $ createWallet db testPk testCp md
            readWalletMeta db testPk `shouldReturn` Just md
            ( testOpeningCleaning f
                (`readWalletMeta` testPk)
                (Just md)
                Nothing )

        it "create and get private key" $ \(FileDB db conn f) -> do
            unsafeRunExceptT $ createWallet db testPk testCp testMetadata
            readPrivateKey db testPk `shouldReturn` Nothing
            let Right phr = fromText "simplephrase"
                k = unsafeGenerateKeyFromSeed (coerce phr, coerce phr) phr
            h <- encryptPassphrase phr
            unsafeRunExceptT (putPrivateKey db testPk (k, h))
            readPrivateKey db testPk `shouldReturn` Just (k, h)
            ( testOpeningCleaning f
                (`readPrivateKey` testPk)
                (Just (k, h))
                Nothing )

        it "put and read tx history" $ \(FileDB db conn f) -> do
            unsafeRunExceptT $ createWallet db testPk testCp testMetadata
            runExceptT (putTxHistory db testPk testTxs) `shouldReturn` Right ()
            readTxHistory db testPk `shouldReturn` testTxs
            ( testOpeningCleaning f
                (`readTxHistory` testPk)
                testTxs
                Map.empty )

        it "put and read checkpoint" $ \(FileDB db conn f) -> do
            unsafeRunExceptT $ createWallet db testPk testCp testMetadata
            runExceptT (putCheckpoint db testPk testCp) `shouldReturn` Right ()
            readCheckpoint db testPk `shouldReturn` Just testCp
            ( testOpeningCleaning f
                (`readCheckpoint` testPk)
                (Just testCp)
                Nothing )

    withDB inMemoryDBLayer $
        describe "random operation chunks property when writing to/reading from file" $ do
        it "realize a random batch of operations upon one db open"
            (property . prop_randomOpChunks)

    where
        testOpeningCleaning
            :: (Show s, Eq s)
            => FilePath
            -> (DBLayer IO (SeqState DummyTarget) DummyTarget -> IO s)
            -> s
            -> s
            -> Expectation
        testOpeningCleaning f call expectedAfterOpen expectedAfterClean = do
            db1 <- newDBLayer (Just f)
            call db1 `shouldReturn` expectedAfterOpen
            cleanDB db1
            call db1 `shouldReturn` expectedAfterClean
            db2 <- newDBLayer (Just f)
            call db2 `shouldReturn` expectedAfterClean

        openCloseDB :: FilePath -> IO ()
        openCloseDB f = do
            (conn, db) <- newDBLayer' (Just f) :: IO (Connection, DBLayer IO (SeqState DummyTarget) DummyTarget)
            listWallets db `shouldReturn` [testPk]
            close conn


prop_randomOpChunks
    :: DBLayer IO (SeqState DummyTarget) DummyTarget
    -> KeyValPairs (PrimaryKey WalletId) (Wallet (SeqState DummyTarget) DummyTarget , WalletMetadata)
    -> Property
prop_randomOpChunks inMemoryDB (KeyValPairs pairs) =
    not (null pairs) ==> monadicIO (prop inMemoryDB)
  where
    prop dbM = liftIO $ do
        -- fixme: withSystemTempFile
        dbF <- newDBLayer (Just "prop_randomOpChunks.db")
        cleanDB dbF
        cleanDB inMemoryDB

        forM_ pairs (updateDB dbM)
        chunks <- cutRandomly [] pairs
        forM_ chunks handleChunks

        verify dbM dbF

    cutRandomly :: [[a]] -> [a] -> IO [[a]]
    cutRandomly acc rest =
        if L.length rest > 1 then do
            chunksNum <- generate $ choose (1, L.length rest)
            let chunk = L.take chunksNum rest
            cutRandomly (chunk:acc) (L.drop chunksNum rest)
        else
            pure $ L.reverse (rest:acc)
    handleChunks chunk = do
        db <- newDBLayer (Just "prop_randomOpChunks.db")
        forM_ chunk (updateDB db)
    updateDB
        :: DBLayer IO s t
        -> (PrimaryKey WalletId, (Wallet s t, WalletMetadata))
        -> IO ()
    updateDB db (k, (cp, meta)) = do
        keys <- listWallets db
        if k `elem` keys then do
            runExceptT (putCheckpoint db k cp) `shouldReturn` Right ()
            runExceptT (putWalletMeta db k meta) `shouldReturn` Right ()
        else do
            unsafeRunExceptT $ createWallet db k cp meta
            Set.fromList <$> listWallets db `shouldReturn` Set.fromList (k:keys)
    verify :: (Eq s) => DBLayer IO s t -> DBLayer IO s t -> IO ()
    verify db1 db2 = do
        expectedWalIds <- Set.fromList <$> listWallets db1
        Set.fromList <$> listWallets db2
            `shouldReturn` expectedWalIds
        forM_ expectedWalIds $ \walId -> do
            expectedCps <- readCheckpoint db1 walId
            readCheckpoint db2 walId
                `shouldReturn` expectedCps
        forM_ expectedWalIds $ \walId -> do
            expectedMetas <- readWalletMeta db1 walId
            readWalletMeta db2 walId
                `shouldReturn` expectedMetas

data FileDB = FileDB
    { dbLayer :: DBLayer IO (SeqState DummyTarget) DummyTarget
    , dbConn :: Connection
    , dbFileName :: FilePath
    }

withFileDBLayer :: SpecWith FileDB -> Spec
withFileDBLayer = beforeAll fileDBLayer . beforeWith clean
  where clean dbf = cleanDB (dbLayer dbf) $> dbf

fileDBLayer :: IO FileDB
fileDBLayer = do
    f <- emptySystemTempFile "unit.db"
    (c, db) <- newDBLayer' (Just f)
    pure $ FileDB db c f

removeDB :: FilePath -> IO ()
removeDB f = mapM_ remove [f, f <> "-shm", f <> "-wal"]
  where
    remove f = doesFileExist f >>= \case
        True -> removeFile f
        False -> pure ()

inMemoryDBLayer :: IO (DBLayer IO (SeqState DummyTarget) DummyTarget)
inMemoryDBLayer = newDBLayer Nothing

testCp :: Wallet (SeqState DummyTarget) DummyTarget
testCp = initWallet initDummyState

initDummyState :: SeqState DummyTarget
initDummyState = mkSeqState (xprv, mempty) defaultAddressPoolGap
  where
      bytes = entropyToBytes <$> unsafePerformIO $ genEntropy @(EntropySize 15)
      xprv = generateKeyFromSeed (Passphrase bytes, mempty) mempty

testMetadata :: WalletMetadata
testMetadata = WalletMetadata
    { name = WalletName "test wallet"
    , creationTime = unsafePerformIO getCurrentTime
    , passphraseInfo = Nothing
    , status = Ready
    , delegation = NotDelegating
    }

testWid :: WalletId
testWid = WalletId (hash ("test" :: ByteString))

testPk :: PrimaryKey WalletId
testPk = PrimaryKey testWid

testTxs :: Map.Map (Hash "Tx") (Tx, TxMeta)
testTxs = Map.fromList
    [ (Hash "tx2"
      , (Tx [TxIn (Hash "tx1") 0] [TxOut (Address "addr") (Coin 1)]
        , TxMeta InLedger Incoming (SlotId 14 0) (Quantity 1337144))) ]
