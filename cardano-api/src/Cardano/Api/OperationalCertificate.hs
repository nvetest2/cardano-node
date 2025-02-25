{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}

-- | Operational certificates
--
module Cardano.Api.OperationalCertificate (
    OperationalCertificate(..),
    OperationalCertificateIssueCounter(..),
    Shelley.KESPeriod(..),
    OperationalCertIssueError(..),
    getHotKey,
    getKesPeriod,
    getOpCertCount,
    issueOperationalCertificate,

    -- * Data family instances
    AsType(..)
  ) where

import           Data.Word

import           Cardano.Ledger.Crypto (StandardCrypto)
import qualified Cardano.Ledger.Keys as Shelley

import           Cardano.Api.Address
import           Cardano.Api.Certificate
import           Cardano.Api.Error
import           Cardano.Api.HasTypeProxy
import           Cardano.Api.Keys.Byron
import           Cardano.Api.Keys.Class
import           Cardano.Api.Keys.Praos
import           Cardano.Api.Keys.Shelley
import           Cardano.Api.ProtocolParameters
import           Cardano.Api.SerialiseCBOR
import           Cardano.Api.SerialiseTextEnvelope
import           Cardano.Api.Tx

import qualified Cardano.Protocol.TPraos.OCert as Shelley

-- ----------------------------------------------------------------------------
-- Operational certificates
--

data OperationalCertificate =
     OperationalCertificate
       !(Shelley.OCert StandardCrypto)
       !(VerificationKey StakePoolKey)
  deriving (Eq, Show)
  deriving anyclass SerialiseAsCBOR

data OperationalCertificateIssueCounter =
     OperationalCertificateIssueCounter
       { opCertIssueCount :: !Word64
       , opCertIssueColdKey :: !(VerificationKey StakePoolKey) -- For consistency checking
       }
  deriving (Eq, Show)
  deriving anyclass SerialiseAsCBOR

instance ToCBOR OperationalCertificate where
    toCBOR (OperationalCertificate ocert vkey) =
      toCBOR (ocert, vkey)

instance FromCBOR OperationalCertificate where
    fromCBOR = do
      (ocert, vkey) <- fromCBOR
      return (OperationalCertificate ocert vkey)

instance ToCBOR OperationalCertificateIssueCounter where
    toCBOR (OperationalCertificateIssueCounter counter vkey) =
      toCBOR (counter, vkey)

instance FromCBOR OperationalCertificateIssueCounter where
    fromCBOR = do
      (counter, vkey) <- fromCBOR
      return (OperationalCertificateIssueCounter counter vkey)

instance HasTypeProxy OperationalCertificate where
    data AsType OperationalCertificate = AsOperationalCertificate
    proxyToAsType _ = AsOperationalCertificate

instance HasTypeProxy OperationalCertificateIssueCounter where
    data AsType OperationalCertificateIssueCounter = AsOperationalCertificateIssueCounter
    proxyToAsType _ = AsOperationalCertificateIssueCounter

instance HasTextEnvelope OperationalCertificate where
    textEnvelopeType _ = "NodeOperationalCertificate"

instance HasTextEnvelope OperationalCertificateIssueCounter where
    textEnvelopeType _ = "NodeOperationalCertificateIssueCounter"

data OperationalCertIssueError =
       -- | The stake pool verification key expected for the
       -- 'OperationalCertificateIssueCounter' does not match the signing key
       -- supplied for signing.
       --
       -- Order: pool vkey expected, pool skey supplied
       --
       OperationalCertKeyMismatch (VerificationKey StakePoolKey)
                                  (VerificationKey StakePoolKey)
  deriving Show

instance Error OperationalCertIssueError where
    displayError (OperationalCertKeyMismatch _counterKey _signingKey) =
      "Key mismatch: the signing key does not match the one that goes with the counter"
      --TODO: include key ids

issueOperationalCertificate :: VerificationKey KesKey
                            -> Either (SigningKey StakePoolKey)
                                      (SigningKey GenesisDelegateExtendedKey)
                               --TODO: this may be better with a type that
                               -- captured the three (four?) choices, stake pool
                               -- or genesis delegate, extended or normal.
                            -> Shelley.KESPeriod
                            -> OperationalCertificateIssueCounter
                            -> Either OperationalCertIssueError
                                      (OperationalCertificate,
                                      OperationalCertificateIssueCounter)
issueOperationalCertificate (KesVerificationKey kesVKey)
                            skey
                            kesPeriod
                            (OperationalCertificateIssueCounter counter poolVKey)
    | poolVKey /= poolVKey'
    = Left (OperationalCertKeyMismatch poolVKey poolVKey')

    | otherwise
    = Right (OperationalCertificate ocert poolVKey,
            OperationalCertificateIssueCounter (succ counter) poolVKey)
  where
    poolVKey' :: VerificationKey StakePoolKey
    poolVKey' = either getVerificationKey (convert . getVerificationKey) skey
      where
        convert :: VerificationKey GenesisDelegateExtendedKey
                -> VerificationKey StakePoolKey
        convert = (castVerificationKey :: VerificationKey GenesisDelegateKey
                                       -> VerificationKey StakePoolKey)
                . (castVerificationKey :: VerificationKey GenesisDelegateExtendedKey
                                       -> VerificationKey GenesisDelegateKey)

    ocert     :: Shelley.OCert StandardCrypto
    ocert     = Shelley.OCert kesVKey counter kesPeriod signature

    signature :: Shelley.SignedDSIGN
                   StandardCrypto
                   (Shelley.OCertSignable StandardCrypto)
    signature = makeShelleySignature
                  (Shelley.OCertSignable kesVKey counter kesPeriod)
                  skey'
      where
        skey' :: ShelleySigningKey
        skey' = case skey of
                  Left (StakePoolSigningKey poolSKey) ->
                    ShelleyNormalSigningKey poolSKey
                  Right (GenesisDelegateExtendedSigningKey delegSKey) ->
                    ShelleyExtendedSigningKey delegSKey

getHotKey :: OperationalCertificate -> VerificationKey KesKey
getHotKey (OperationalCertificate cert _) = KesVerificationKey $ Shelley.ocertVkHot cert

getKesPeriod :: OperationalCertificate -> Word
getKesPeriod (OperationalCertificate cert _) = Shelley.unKESPeriod $ Shelley.ocertKESPeriod cert

getOpCertCount :: OperationalCertificate -> Word64
getOpCertCount (OperationalCertificate cert _) = Shelley.ocertN cert
