{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# OPTIONS_GHC -fno-warn-unused-imports #-}

module Cardano.Wallet.BlockSyncerSpec
    ( spec
    ) where


import Prelude

import Cardano.Wallet.BlockSyncer
    ( BlockHeadersConsumed (..), tickingFunction )
import Cardano.Wallet.Primitive
    ( Block (..), BlockHeader (..), Hash (..) )
import Control.Concurrent
    ( ThreadId, forkIO, killThread, threadDelay )
import Control.Concurrent.MVar
    ( MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, takeMVar )
import Control.Monad
    ( forM_ )
import Control.Monad.IO.Class
    ( liftIO )
import Data.ByteString
    ( ByteString, pack )
import Data.Map.Strict
    ( Map )
import Data.Time.Units
    ( Second, fromMicroseconds )
import Data.Tuple
    ( swap )
import Test.Hspec
    ( Arg, Spec, SpecWith, describe, it )
import Test.Hspec.Expectations
    ( shouldBe )
import Test.QuickCheck
    ( Arbitrary (..)
    , Property
    , elements
    , generate
    , property
    , vector
    , withMaxSuccess
    )
import Test.QuickCheck.Gen
    ( Gen, choose, vectorOf )
import Test.QuickCheck.Monadic
    ( monadicIO )

import qualified Codec.CBOR.Encoding as CBOR
import qualified Codec.CBOR.Write as CBOR
import qualified Data.List as L
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

spec :: Spec
spec = do
    describe "Block syncer downloads blocks properly" $ do
        it "Check ticking function when blocks are sent"
            (withMaxSuccess 10 $ property tickingFunctionTest)
  where
      tickingFunctionTest
          :: (TickingArgs, Blocks)
          -> Property
      tickingFunctionTest (TickingArgs chunkSizesToTest tickTime deliveryMode, Blocks consecutiveBlocks) = monadicIO $ liftIO $ do
          done <- newEmptyMVar
          consumerData <- newMVar []
          producerData <- newMVar $ BlocksToInject (chunkSizesToTest, map snd consecutiveBlocks)
          let reader = mkReader consumerData (Map.fromList $ swap <$> consecutiveBlocks)
          let blockDelivery = pushNextBlocks done producerData deliveryMode
          threadId <- forkIO $ tickingFunction blockDelivery reader tickTime (BlockHeadersConsumed [])
          _ <- takeMVar done
          obtainedData <- takeMVar consumerData
          killThread threadId
          obtainedData `shouldBe` ((map fst . reverse) consecutiveBlocks)


data TickingArgs = TickingArgs
    { _chunkSizes :: [Int]
    , _tickingTime :: Second
    , _deliveryMode :: DeliveryMode
    } deriving (Show)

instance Arbitrary TickingArgs where
    shrink (TickingArgs sizes t m) =
        [ TickingArgs sizes' t m | sizes' <- shrink sizes ]
    arbitrary = do
        sizes <- choose (1, 15) >>= generateBlockChunks
        deliveryMode <- elements [ExactlyOnce, AtLeastOnce]
        tickTime <- fromMicroseconds . (* (1000 * 1000)) <$> choose (1, 3)
        return $ TickingArgs sizes tickTime deliveryMode
      where
        generateBlockChunks
            :: Int
            -> Gen [Int]
        generateBlockChunks n = do
              vectorOf n (choose (0, 15))

newtype Blocks = Blocks [(Hash "BlockHeader", Block)]
    deriving Show

instance Arbitrary Blocks where
    arbitrary = do
        n <- arbitrary
        let h0 = BlockHeader 1 0 (Hash "initial block")
        return $ Blocks $ take n $ iterate next
            ( blockHeaderHash h0
            , Block h0 mempty
            )
      where
        next :: (Hash "BlockHeader", Block) -> (Hash "BlockHeader", Block)
        next (prev, b) =
            let
                epoch = epochIndex (header b)
                slot = slotNumber (header b) + 1
                h = BlockHeader epoch slot prev
            in
                (blockHeaderHash h, Block h mempty)

blockHeaderHash :: BlockHeader -> Hash "BlockHeader"
blockHeaderHash =
    Hash . CBOR.toStrictByteString . encodeBlockHeader
  where
    encodeBlockHeader (BlockHeader epoch slot prev) = mempty
        <> CBOR.encodeListLen 3
        <> CBOR.encodeWord64 epoch
        <> CBOR.encodeWord16 slot
        <> CBOR.encodeBytes (getHash prev)

newtype BlocksToInject = BlocksToInject ([Int], [Block]) deriving (Show, Eq)


data DeliveryMode = ExactlyOnce | AtLeastOnce deriving Show

pushNextBlocks
    :: MVar ()
    -> MVar BlocksToInject
    -> DeliveryMode
    -> IO [Block]
pushNextBlocks done ref mode = do
    BlocksToInject (blocksToTake, blocksRemaining) <- takeMVar ref
    case (blocksToTake, blocksRemaining) of
        (_, []) -> putMVar done () *> return []
        ([], _) -> putMVar done () *> return []
        (num : rest, _) -> do
            let (bOut, bStay) = L.splitAt num blocksRemaining
            putMVar ref $ BlocksToInject (rest, bStay)
            case mode of
                ExactlyOnce ->
                    return bOut
                AtLeastOnce -> do
                    additionalBlocks <- generate $ choose (1,3) :: IO Int
                    return $ bOut ++ take additionalBlocks bStay


mkReader
    :: Ord k
    => MVar [v]
    -> Map k v
    -> k
    -> IO ()
mkReader ref m k = do
    case k `Map.lookup` m of
        Just v ->
            modifyMVar_ ref $ return . (v :)
        Nothing ->
            return ()
