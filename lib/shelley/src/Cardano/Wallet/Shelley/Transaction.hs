{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Copyright: © 2020 IOHK
-- License: Apache-2.0
--
-- Working with Shelley transactions.

module Cardano.Wallet.Shelley.Transaction
    ( newTransactionLayer

    -- * Internals
    , _minimumFee
    , _decodeSignedTx
    , _estimateMaxNumberOfInputs
    , mkUnsignedTx
    , mkShelleyWitness
    , mkByronWitness
    , mkTx
    , TxPayload (..)
    , emptyTxPayload
    ) where

import Prelude

import Cardano.Address.Derivation
    ( XPrv, toXPub )
import Cardano.Api.Typed
    ( NetworkId, TxExtraContent (..) )
import Cardano.Binary
    ( serialize' )
import Cardano.Crypto.DSIGN
    ( DSIGNAlgorithm (..), SignedDSIGN (..) )
import Cardano.Wallet.Primitive.AddressDerivation
    ( ChimericAccount (..), Depth (..), Passphrase (..), WalletKey (..) )
import Cardano.Wallet.Primitive.AddressDerivation.Byron
    ( ByronKey )
import Cardano.Wallet.Primitive.AddressDerivation.Icarus
    ( IcarusKey )
import Cardano.Wallet.Primitive.AddressDerivation.Shelley
    ( ShelleyKey, toChimericAccountRaw )
import Cardano.Wallet.Primitive.CoinSelection
    ( CoinSelection (..), feeBalance )
import Cardano.Wallet.Primitive.Fee
    ( Fee (..), FeePolicy (..) )
import Cardano.Wallet.Primitive.Types
    ( Address (..)
    , Coin (..)
    , Hash (..)
    , PoolId (..)
    , SealedTx (..)
    , Tx (..)
    , TxIn (..)
    , TxOut (..)
    )
import Cardano.Wallet.Shelley.Compatibility
    ( Shelley
    , TPraosStandardCrypto
    , sealShelleyTx
    , toCardanoLovelace
    , toCardanoStakeCredential
    , toCardanoTxIn
    , toCardanoTxOut
    , toHDPayloadAddress
    , toStakeKeyDeregCert
    , toStakeKeyRegCert
    , toStakePoolDlgCert
    )
import Cardano.Wallet.Transaction
    ( DelegationAction (..)
    , ErrDecodeSignedTx (..)
    , ErrMkTx (..)
    , ErrValidateSelection
    , TransactionLayer (..)
    )
import Control.Monad
    ( forM )
import Data.ByteString
    ( ByteString )
import Data.Maybe
    ( fromMaybe )
import Data.Proxy
    ( Proxy (..) )
import Data.Quantity
    ( Quantity (..) )
import Data.Word
    ( Word16, Word64, Word8 )
import Ouroboros.Consensus.Shelley.Protocol.Crypto
    ( Crypto (..) )
import Ouroboros.Network.Block
    ( SlotNo )

import qualified Cardano.Api.Typed as Cardano
import qualified Cardano.Chain.Common as Byron
import qualified Cardano.Crypto as CC
import qualified Cardano.Crypto.DSIGN.Class as Crypto
import qualified Cardano.Crypto.Hash.Class as Crypto
import qualified Cardano.Crypto.Signing as Byron
import qualified Cardano.Crypto.Wallet as Crypto.HD
import qualified Cardano.Wallet.Primitive.CoinSelection as CS
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Data.Text as T
import qualified Shelley.Spec.Ledger.Address.Bootstrap as SL
import qualified Shelley.Spec.Ledger.Keys as SL
import qualified Shelley.Spec.Ledger.LedgerState as SL
import qualified Shelley.Spec.Ledger.Tx as SL

-- | Type encapsulating what we need to know to add things -- payloads,
-- certificates -- to a transaction.
--
-- Designed to allow us to have /one/ @mkTx@ which doesn't care whether we
-- include certificates or not.
data TxPayload era = TxPayload
    { _certificates :: [Cardano.Certificate]
      -- ^ Certificates to be included in the transactions.

    , _extraWitnesses :: Cardano.TxBody era -> [Cardano.Witness era]
      -- ^ Create payload-specific witesses given the unsigned transaction body.
      --
      -- Caller has the freedom and responsibility to provide the correct
      -- witnesses for what they're trying to do.
    }

emptyTxPayload :: TxPayload c
emptyTxPayload = TxPayload mempty mempty

data TxWitnessTag
    = TxWitnessByronUTxO
    | TxWitnessShelleyUTxO
    deriving (Show, Eq)

-- | Provide a transaction witness for a given private key. The type of witness
-- is different between types of keys and, with backward-compatible support, we
-- need to support many types for one backend target.
class TxWitnessTagFor (k :: Depth -> * -> *) where
    txWitnessTagFor :: TxWitnessTag

instance TxWitnessTagFor ShelleyKey  where txWitnessTagFor = TxWitnessShelleyUTxO
instance TxWitnessTagFor IcarusKey   where txWitnessTagFor = TxWitnessByronUTxO
instance TxWitnessTagFor ByronKey    where txWitnessTagFor = TxWitnessByronUTxO

mkTx
    :: forall k. (TxWitnessTagFor k, WalletKey k)
    => Cardano.NetworkId
    -> TxPayload Cardano.Shelley
    -> SlotNo
    -- ^ Time to Live
    -> (k 'AddressK XPrv, Passphrase "encryption")
    -- ^ Reward account
    -> (Address -> Maybe (k 'AddressK XPrv, Passphrase "encryption"))
    -> CoinSelection
    -> Either ErrMkTx (Tx, SealedTx)
mkTx networkId (TxPayload certs mkExtraWits) timeToLive (rewardAcnt, pwdAcnt) keyFrom cs = do
    let wdrls = mkWithdrawals
            networkId
            (toChimericAccountRaw . getRawKey . publicKey $ rewardAcnt)
            (withdrawal cs)

    let unsigned = mkUnsignedTx timeToLive cs wdrls certs

    wits <- case (txWitnessTagFor @k) of
        TxWitnessShelleyUTxO -> do
            addrWits <- forM (CS.inputs cs) $ \(_, TxOut addr _) -> do
                (k, pwd) <- lookupPrivateKey keyFrom addr
                pure $ mkShelleyWitness unsigned (getRawKey k, pwd)

            let wdrlsWits
                    | null wdrls = []
                    | otherwise =
                      [mkShelleyWitness unsigned (getRawKey rewardAcnt, pwdAcnt)]

            pure $ mkExtraWits unsigned <> addrWits <> wdrlsWits

        TxWitnessByronUTxO -> do
            bootstrapWits <- forM (CS.inputs cs) $ \(_, TxOut addr _) -> do
                (k, pwd) <- lookupPrivateKey keyFrom addr
                pure $ mkByronWitness unsigned networkId addr (getRawKey k, pwd)
            pure $ bootstrapWits <> mkExtraWits unsigned

    let tx = Cardano.makeSignedTransaction wits unsigned
    return $ sealShelleyTx tx

newTransactionLayer
    :: forall k t.
        ( t ~ IO Shelley
        , TxWitnessTagFor k
        , WalletKey k
        )
    => NetworkId
    -> TransactionLayer t k
newTransactionLayer networkId = TransactionLayer
    { mkStdTx = \acc ks tip ->
        mkTx networkId emptyTxPayload (defaultTTL tip) acc ks
    , initDelegationSelection = _initDelegationSelection
    , mkDelegationJoinTx = _mkDelegationJoinTx
    , mkDelegationQuitTx = _mkDelegationQuitTx
    , decodeSignedTx = _decodeSignedTx
    , minimumFee = _minimumFee @k networkId
    , estimateMaxNumberOfInputs = _estimateMaxNumberOfInputs @k networkId
    , validateSelection = const $ return ()
    , allowUnbalancedTx = True
    }
  where
    _initDelegationSelection
        :: FeePolicy
            -- Current fee policy
        -> DelegationAction
            -- What sort of action is going on
        -> CoinSelection
        -- ^ An initial selection where 'deposit' and/or 'reclaim' have been set
        -- accordingly.
    _initDelegationSelection (LinearFee _ _ (Quantity c)) = \case
        Quit{} -> mempty { reclaim = round c }
        Join{} -> mempty
        RegisterKeyAndJoin{} -> mempty { deposit = round c }

    _mkDelegationJoinTx
        :: PoolId
            -- ^ Pool Id to which we're planning to delegate
        -> (k 'AddressK XPrv, Passphrase "encryption")
            -- ^ Reward account
        -> (Address -> Maybe (k 'AddressK XPrv, Passphrase "encryption"))
            -- ^ Key store
        -> SlotNo
            -- ^ Tip of the chain, for TTL
        -> CoinSelection
            -- ^ A balanced coin selection where all change addresses have been
            -- assigned.
        -> Either ErrMkTx (Tx, SealedTx)
    _mkDelegationJoinTx poolId acc@(accXPrv, pwd') keyFrom tip cs = do
        let accXPub = toXPub $ getRawKey accXPrv
        let certs =
                if deposit cs > 0 then
                    [ toStakeKeyRegCert  accXPub
                    , toStakePoolDlgCert accXPub poolId
                    ]
                else
                    [ toStakePoolDlgCert accXPub poolId ]

        let mkWits unsigned =
                [ mkShelleyWitness unsigned (getRawKey accXPrv, pwd')
                ]

        let payload = TxPayload certs mkWits
        let ttl = defaultTTL tip
        mkTx networkId payload ttl acc keyFrom cs

    _mkDelegationQuitTx
        :: (k 'AddressK XPrv, Passphrase "encryption")
            -- reward account
        -> (Address -> Maybe (k 'AddressK XPrv, Passphrase "encryption"))
            -- Key store
        -> SlotNo
            -- Tip of the chain, for TTL
        -> CoinSelection
            -- A balanced coin selection where all change addresses have been
            -- assigned.
        -> Either ErrMkTx (Tx, SealedTx)
    _mkDelegationQuitTx acc@(accXPrv, pwd') keyFrom tip cs = do
        let accXPub = toXPub $ getRawKey accXPrv
        let certs = [toStakeKeyDeregCert accXPub]
        let mkWits unsigned =
                [ mkShelleyWitness unsigned (getRawKey accXPrv, pwd')
                ]

        let payload = TxPayload certs mkWits
        let ttl = defaultTTL tip
        mkTx networkId payload ttl acc keyFrom cs

_estimateMaxNumberOfInputs
    :: forall k. TxWitnessTagFor k
    => NetworkId
    -> Quantity "byte" Word16
     -- ^ Transaction max size in bytes
    -> Word8
    -- ^ Number of outputs in transaction
    -> Word8
_estimateMaxNumberOfInputs networkId (Quantity maxSize) nOuts =
      fromIntegral $ bisect (lowerBound, upperBound)
  where
    bisect (!inf, !sup)
        | middle == inf && isTooBig sup = inf
        | middle == inf                 = sup
        | isTooBig middle               = bisect (inf, middle)
        | otherwise                     = bisect (middle, sup)
      where
        middle = inf + ((sup - inf) `div` 2)

    growingFactor = 2

    lowerBound = upperBound `div` growingFactor
    upperBound = upperBound_ 1
      where
        upperBound_ !n | isTooBig n = n
                       | otherwise  = upperBound_ (n*growingFactor)

    isTooBig nInps = size > fromIntegral maxSize
      where
        size = computeTxSize networkId (txWitnessTagFor @k) Nothing sel
        sel  = dummyCoinSel nInps (fromIntegral nOuts)

dummyCoinSel :: Int -> Int -> CoinSelection
dummyCoinSel nInps nOuts = mempty
    { CS.inputs = map (\ix -> (dummyTxIn ix, dummyTxOut)) [0..nInps-1]
    , CS.outputs = replicate nOuts dummyTxOut
    , CS.change = replicate nOuts (Coin 1)
    }
  where
    dummyTxIn   = TxIn (Hash $ BS.pack (1:replicate 64 0)) . fromIntegral
    dummyTxOut  = TxOut dummyAddr (Coin 1)
    dummyAddr   = Address $ BS.pack (1:replicate 64 0)

_decodeSignedTx
    :: ByteString
    -> Either ErrDecodeSignedTx (Tx, SealedTx)
_decodeSignedTx bytes = do
    case Cardano.deserialiseFromCBOR Cardano.AsShelleyTx bytes of
        Right txValid ->
            pure $ sealShelleyTx txValid
        Left decodeErr ->
            Left $ ErrDecodeSignedTxWrongPayload (T.pack $ show decodeErr)

_minimumFee
    :: forall k. TxWitnessTagFor k
    => NetworkId
    -> FeePolicy
    -> Maybe DelegationAction
    -> CoinSelection
    -> Fee
_minimumFee networkId policy action cs =
    computeFee $ computeTxSize networkId (txWitnessTagFor @k) action cs
  where
    computeFee :: Integer -> Fee
    computeFee size =
        Fee $ ceiling (a + b*fromIntegral size)
      where
        LinearFee (Quantity a) (Quantity b) _unused = policy

-- TODO: Can this function be re-written by calling @mkTx@ with dummy signing
-- functions?
computeTxSize
    :: Cardano.NetworkId
    -> TxWitnessTag
    -> Maybe DelegationAction
    -> CoinSelection
    -> Integer
computeTxSize networkId witTag action cs =
    withUnderlyingShelleyTx SL.txsize signed
 where

    withUnderlyingShelleyTx
        :: (forall crypto. SL.Tx crypto -> a)
        -> Cardano.Tx Cardano.Shelley
        -> a
    withUnderlyingShelleyTx f (Cardano.ShelleyTx x) = f x

    signed = Cardano.makeSignedTransaction wits unsigned
    unsigned = mkUnsignedTx maxBound cs' wdrls certs
      where
        cs' :: CoinSelection
        cs' = cs
            { CS.outputs = CS.outputs cs <> (dummyOutput <$> change cs)
            , CS.change  = []
            }

        dummyOutput :: Coin -> TxOut
        dummyOutput = TxOut $ Address $ BS.pack (1:replicate 56 0)

        dummyStakeCred = toCardanoStakeCredential
            $ ChimericAccount dummyKeyHashRaw

        dummyPoolId :: Cardano.PoolId
        dummyPoolId = fromMaybe (error "dummyPoolId couldn't be constructed")
            $ Cardano.deserialiseFromRawBytes (Cardano.AsHash Cardano.AsStakePoolKey)
            $ BS.pack $ replicate 32 0

        certs = case action of
            Nothing -> []
            Just RegisterKeyAndJoin{} ->
                [ Cardano.makeStakeAddressRegistrationCertificate dummyStakeCred
                , Cardano.makeStakeAddressDelegationCertificate dummyStakeCred dummyPoolId
                ]
            Just Join{} ->
                [ Cardano.makeStakeAddressDelegationCertificate dummyStakeCred dummyPoolId
                ]
            Just Quit ->
                [ Cardano.makeStakeAddressDeregistrationCertificate dummyStakeCred
                ]

    dummyKeyHashRaw = BA.convert $ BS.pack (replicate 28 0)

    wdrls = mkWithdrawals
        networkId
        (ChimericAccount dummyKeyHashRaw)
        (withdrawal cs)

    (addrWits, certWits) =
        (
            map dummyWitnessUniq (fst <$> CS.inputs cs)
            <> [dummyWitness "0" | null wdrls]
        , case action of
            Nothing -> []
            Just{}  -> [dummyWitness "a"]
        )
      where
        dummyWitness :: BL.ByteString -> Cardano.Witness Cardano.Shelley
        dummyWitness chaff = Cardano.ShelleyKeyWitness $ SL.WitVKey key sig
          where
            key = SL.VKey
                $ fromMaybe (error "error creating dummy witness ver key")
                $ rawDeserialiseVerKeyDSIGN
                $ bloatChaff keyLen chaff

            sig = SignedDSIGN
                $ fromMaybe (error "error creating dummy witness sig")
                $ rawDeserialiseSigDSIGN
                $ bloatChaff sigLen chaff

        dummyWitnessUniq :: TxIn -> Cardano.Witness Cardano.Shelley
        dummyWitnessUniq (TxIn (Hash txid) ix) =
            dummyWitness chaff
          where
            chaff = L8.pack (show ix) <> BL.fromStrict txid


    -- Note that the "byron"/bootstrap witnesses are still shelley era
    -- witnesses.
    byronWits = map dummyWitnessUniq $ CS.inputs cs
      where
        dummyWitness :: BL.ByteString -> Address -> Cardano.Witness Cardano.Shelley
        dummyWitness chaff addr =
            Cardano.ShelleyBootstrapWitness $ SL.BootstrapWitness key sig cc padding
          where
            key = SL.VKey
                $ fromMaybe (error "error creating dummy witness ver key")
                $ rawDeserialiseVerKeyDSIGN
                $ bloatChaff keyLen chaff

            sig = SignedDSIGN
                $ fromMaybe (error "error creating dummy witness sig")
                $ rawDeserialiseSigDSIGN
                $ bloatChaff sigLen chaff

            cc = SL.ChainCode
                $ bloatChaff ccLen "0"

            padding = serialize'
                $ Byron.mkAttributes
                $ Byron.AddrAttributes
                    { Byron.aaVKDerivationPath = toHDPayloadAddress addr
                    , Byron.aaNetworkMagic     = Cardano.toByronNetworkMagic networkId
                    }

        dummyWitnessUniq :: (TxIn, TxOut) -> Cardano.Witness Cardano.Shelley
        dummyWitnessUniq (TxIn (Hash txid) ix, TxOut addr _) =
            dummyWitness chaff addr
          where
            chaff = L8.pack (show ix) <> BL.fromStrict txid

    sigLen = sizeSigDSIGN $ Proxy @(DSIGN TPraosStandardCrypto)

    keyLen = sizeVerKeyDSIGN $ Proxy @(DSIGN TPraosStandardCrypto)

    ccLen =  32

    bloatChaff :: Word -> BL.ByteString -> ByteString
    bloatChaff n = BL.toStrict . BL.take (fromIntegral n) . BL.cycle

    -- TODO: Surely we can allow byron witnesses paying for certificates?
    -- Should be no reason to case here.
    wits = case witTag of
        TxWitnessShelleyUTxO ->
            addrWits <> certWits
        TxWitnessByronUTxO ->
           byronWits

lookupPrivateKey
    :: (Address -> Maybe (k 'AddressK XPrv, Passphrase "encryption"))
    -> Address
    -> Either ErrMkTx (k 'AddressK XPrv, Passphrase "encryption")
lookupPrivateKey keyFrom addr =
    maybe (Left $ ErrKeyNotFoundForAddress addr) Right (keyFrom addr)

mkUnsignedTx
    :: Cardano.SlotNo
    -> CoinSelection
    -> [(Cardano.StakeAddress, Cardano.Lovelace)]
    -> [Cardano.Certificate]
    -> Cardano.TxBody Cardano.Shelley
mkUnsignedTx ttl cs wdrls certs =
        Cardano.makeShelleyTransaction
            TxExtraContent
                { txMetadata = Nothing
                , txWithdrawals = wdrls
                , txCertificates = certs
                , txUpdateProposal = Nothing
                }
            ttl
            (toCardanoLovelace $ Coin $ feeBalance cs)
            (toCardanoTxIn . fst <$> CS.inputs cs)
            (map toCardanoTxOut $ CS.outputs cs)

mkWithdrawals
    :: NetworkId
    -> ChimericAccount
    -> Word64
    -> [(Cardano.StakeAddress, Cardano.Lovelace)]
mkWithdrawals networkId acc amount
    | amount == 0 = mempty
    | otherwise   = [ (stakeAddress, toCardanoLovelace $ Coin amount) ]
  where
    cred = toCardanoStakeCredential acc
    stakeAddress = Cardano.makeStakeAddress networkId cred

-- NOTE: The (+7200) was selected arbitrarily when we were trying to get
-- this working on the FF testnet. Perhaps a better motivated and/or
-- configurable value would be better.
defaultTTL :: SlotNo -> SlotNo
defaultTTL = (+ 7200)

mkShelleyWitness
    :: Cardano.TxBody Cardano.Shelley
    -> (XPrv, Passphrase "encryption")
    -> Cardano.Witness Cardano.Shelley
mkShelleyWitness body key =
    Cardano.makeShelleyKeyWitness body (unencrypt key)
  where
    unencrypt (xprv, pwd) = Cardano.WitnessPaymentExtendedKey
        $ Cardano.PaymentExtendedSigningKey
        $ Crypto.HD.xPrvChangePass pwd BS.empty xprv

mkByronWitness
    :: Cardano.TxBody Cardano.Shelley
    -> Cardano.NetworkId
    -> Address
    -> (XPrv, Passphrase "encryption")
    -> Cardano.Witness Cardano.Shelley
mkByronWitness (Cardano.ShelleyTxBody txbody _) nw addr (prv, Passphrase pwd) =
    Cardano.ShelleyBootstrapWitness $
        -- Byron era witnesses were weird. This reveals all that weirdness.
        SL.BootstrapWitness {
          SL.bwKey        = vk,
          SL.bwSig        = signature,
          SL.bwChainCode  = chainCode,
          SL.bwAttributes = attributes
        }
  where
    sk = CC.SigningKey $ Crypto.HD.xPrvChangePass pwd BS.empty prv

    -- Starting with the easy bits: we /can/ convert the Byron verification key
    -- to a the pair of a Shelley verification key plus the chain code.
    --
    (vk, chainCode) = SL.unpackByronVKey (Byron.toVerification sk)

    -- Now the hairy bits.
    --
    -- Byron era signing keys were all /extended/ ed25519 keys. We have to
    -- produce a signature using this extended signing key directly. They
    -- /cannot/ be converted to a plain (non-extended) signing keys. Since we
    -- now support extended signing keys for the Shelley too, we are able to
    -- reuse that here.
    --
    signature
        :: SL.SignedDSIGN TPraosStandardCrypto
            (SL.Hash TPraosStandardCrypto (SL.TxBody TPraosStandardCrypto))
    signature = fromXSignature $
          Crypto.HD.sign
            BS.empty  -- passphrase for (unused) in-mem encryption
            (Byron.unSigningKey sk)
            (Crypto.hashToBytes txhash)
      where
        fromXSignature :: Crypto.HD.XSignature
                       -> SL.SignedDSIGN TPraosStandardCrypto b
        fromXSignature =
            Crypto.SignedDSIGN
          . fromMaybe impossible
          . rawDeserialiseSigDSIGN
          . Crypto.HD.unXSignature

        impossible =
          error "mkByronWitness: byron and shelley signature sizes do not match"

    txhash :: SL.Hash TPraosStandardCrypto (SL.TxBody TPraosStandardCrypto)
    txhash = Crypto.hashWith serialize' txbody

    -- And finally we need to provide the extra suffix bytes necessary to
    -- reconstruct the mini-Merkel tree that is a Byron address. The suffix
    -- bytes are the serialised address attributes.
    attributes = serialize' $
        Byron.mkAttributes Byron.AddrAttributes {
          Byron.aaVKDerivationPath = toHDPayloadAddress addr,
          Byron.aaNetworkMagic = Cardano.toByronNetworkMagic nw
        }


--------------------------------------------------------------------------------
-- Extra validations on coin selection
--

type instance ErrValidateSelection (IO Shelley) = ()
