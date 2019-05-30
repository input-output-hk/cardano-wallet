{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
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
    ( newDBLayer )
import Cardano.Wallet.DBSpec
    ( DummyTarget, cleanDB )
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
import Control.Monad.Trans.Except
    ( runExceptT )
import Crypto.Hash
    ( hash )
import Data.ByteString
    ( ByteString )
import Data.Coerce
    ( coerce )
import Data.Quantity
    ( Quantity (..) )
import Data.Text.Class
    ( FromText (..) )
import Data.Time.Clock
    ( getCurrentTime )
import System.IO.Unsafe
    ( unsafePerformIO )
import Test.Hspec
    ( Expectation, Spec, before, describe, it, shouldReturn )

import qualified Data.Map as Map

spec :: Spec
spec = before (readDBLayer >>= cleanDB) $ do
    describe "Check db reading/writing from/to file and cleaning" $ do
        it "create and list wallet works" $ \db -> do
            unsafeRunExceptT $ createWallet db testPk testCp testMetadata
            listWallets db `shouldReturn` [testPk]
            db1 <- readDBLayer
            runExceptT (createWallet db1 testPk testCp testMetadata)
                `shouldReturn` (Left (ErrWalletAlreadyExists testWid))
            ( testOpeningCleaning
                listWallets
                [testPk]
                [] )

        it "create and get meta works" $ \db -> do
            now <- getCurrentTime
            let md = testMetadata { passphraseInfo = Just $ WalletPassphraseInfo now }
            unsafeRunExceptT $ createWallet db testPk testCp md
            readWalletMeta db testPk `shouldReturn` Just md
            ( testOpeningCleaning
                (`readWalletMeta` testPk)
                (Just md)
                Nothing )

        it "create and get private key" $ \db -> do
            unsafeRunExceptT $ createWallet db testPk testCp testMetadata
            readPrivateKey db testPk `shouldReturn` Nothing
            let Right phr = fromText "simplephrase"
                k = unsafeGenerateKeyFromSeed (coerce phr, coerce phr) phr
            h <- encryptPassphrase phr
            unsafeRunExceptT (putPrivateKey db testPk (k, h))
            readPrivateKey db testPk `shouldReturn` Just (k, h)
            ( testOpeningCleaning
                (`readPrivateKey` testPk)
                (Just (k, h))
                Nothing )

        it "put and read tx history" $ \db -> do
            unsafeRunExceptT $ createWallet db testPk testCp testMetadata
            runExceptT (putTxHistory db testPk testTxs) `shouldReturn` Right ()
            readTxHistory db testPk `shouldReturn` testTxs
            ( testOpeningCleaning
                (`readTxHistory` testPk)
                testTxs
                Map.empty )

        it "put and read checkpoint" $ \db -> do
            unsafeRunExceptT $ createWallet db testPk testCp testMetadata
            runExceptT (putCheckpoint db testPk testCp) `shouldReturn` Right ()
            readCheckpoint db testPk `shouldReturn` Just testCp
            ( testOpeningCleaning
                (`readCheckpoint` testPk)
                (Just testCp)
                Nothing )

    where
        testOpeningCleaning
            :: (Show s, Eq s)
            => (DBLayer IO (SeqState DummyTarget) DummyTarget -> IO s)
            -> s
            -> s
            -> Expectation
        testOpeningCleaning call expectedAfterOpen expectedAfterClean = do
            db1 <- readDBLayer
            call db1 `shouldReturn` expectedAfterOpen
            _ <- cleanDB db1
            call db1 `shouldReturn` expectedAfterClean
            db2 <- readDBLayer
            call db2 `shouldReturn` expectedAfterClean


readDBLayer :: IO (DBLayer IO (SeqState DummyTarget) DummyTarget)
readDBLayer = newDBLayer (Just "backup/test.db")

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
