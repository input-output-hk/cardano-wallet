{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
module Cardano.Wallet.Primitive.Signing where

import Prelude

import Cardano.Wallet.Binary
    ( TxWitness (..), toByteString )
import Cardano.Wallet.Primitive.AddressDerivation
    ( Depth (RootK), Key (..), XPrv, XPub, publicKey )
import Cardano.Wallet.Primitive.Types
    ( Address, Hash (..), Tx (..), TxIn, TxOut, protocolMagic )
import Control.Monad
    ( forM )
import Data.ByteString
    ( ByteString )
import GHC.Generics
    ( Generic )

import qualified Cardano.Crypto.Wallet as CC
import qualified Codec.CBOR.Encoding as CBOR



newtype PassPhrase = PassPhrase ByteString -- TODO: Was ScrubbedBytes previously
type TxOwnedInputs owner = [(owner, TxIn)]

-- | Build a transaction

-- | Construct a standard transaction
--
-- " Standard " here refers to the fact that we do not deal with redemption,
-- multisignature transactions, etc.
--
-- TODO: re-add shuffle
-- TODO: I removed FakeSigner/SafeSigner. Might be wrong.
mkStdTx :: (Address -> Either e (Key 'RootK XPrv))
        -- ^ Signer for each input of the transaction
        -> [(TxIn, Address)]
        -- ^ Selected inputs
        -> [TxOut]
        -- ^ Selected outputs (including change)
        -> Either e (Tx, [TxWitness])
mkStdTx signer ownedIns outs = do

    let ins = (fmap fst ownedIns)
        tx = Tx ins outs

    txWitness <- forM ownedIns (\(_, ownerAddr) ->
        mkWit <$> signer ownerAddr)

    return (tx, txWitness)

  where
    txSigData = Hash "tx"

    mkWit ss =
        PublicKeyWitness
            (encode $ publicKey ss)
            (Hash $ signRaw signTag ss txSigData)

    encode :: (Key level XPub) -> ByteString
    encode (Key k) = CC.unXPub k




{-------------------------------------------------------------------------------
                              SignTag
-------------------------------------------------------------------------------}

-- | To protect agains replay attacks (i.e. when an attacker intercepts a
-- signed piece of data and later sends it again), we add a tag to all data
-- that we sign. This ensures that even if some bytestring can be
-- deserialized into two different types of messages (A and B), the attacker
-- can't take message A and send it as message B.
--
-- We also automatically add the network tag ('protocolMagic') whenever it
-- makes sense, to ensure that things intended for testnet won't work for
-- mainnet.
--
-- The wallet only cares about the 'SignTx' tag. In 'cardano-sl' there was
-- a whole @SignTag@ data-type
signTag :: ByteString
signTag = signTxTag <> network
  where
    signTxTag = "\x01"
    network = toByteString $ CBOR.encodeInt32 protocolMagic

-- Signatures


-- | Wrapper around 'CC.XSignature'.
newtype Signature a = Signature CC.XSignature
    deriving (Eq, Ord, Show, Generic)

-- | Sign a bytestring.
signRaw
    :: ByteString
    -> Key 'RootK XPrv
    -> Hash "tx"
    -> ByteString -- Previously Raw
signRaw tag (Key k) (Hash x) = CC.unXSignature $ CC.sign emptyPassphrase k (tag <> x)
  where
    emptyPassphrase :: ByteString
    emptyPassphrase = mempty


--
--
-- ProtocolMAgic
--
--

