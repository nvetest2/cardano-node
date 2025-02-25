{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

-- | Metadata embedded in transactions
--
module Cardano.Api.TxMetadata (

    -- * Types
    TxMetadata (TxMetadata),

    -- * Class
    AsTxMetadata (..),

    -- * Constructing metadata
    TxMetadataValue(..),
    makeTransactionMetadata,
    mergeTransactionMetadata,
    metaTextChunks,
    metaBytesChunks,

    -- * Validating metadata
    validateTxMetadata,
    TxMetadataRangeError (..),

    -- * Conversion to\/from JSON
    TxMetadataJsonSchema (..),
    metadataFromJson,
    metadataToJson,
    metadataValueToJsonNoSchema,
    TxMetadataJsonError (..),
    TxMetadataJsonSchemaError (..),

    -- * Internal conversion functions
    toShelleyMetadata,
    fromShelleyMetadata,
    toShelleyMetadatum,
    fromShelleyMetadatum,

    -- * Shared parsing utils
    parseAll,
    pUnsigned,
    pSigned,
    pBytes,

    -- * Data family instances
    AsType(..)
  ) where

import           Cardano.Api.Eras
import           Cardano.Api.Error
import           Cardano.Api.HasTypeProxy
import           Cardano.Api.SerialiseCBOR (SerialiseAsCBOR (..))
import qualified Cardano.Ledger.Binary as CBOR
import qualified Cardano.Ledger.Shelley.TxAuxData as Shelley
import           Control.Applicative (Alternative (..))
import           Control.Monad (guard, when)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Aeson.Text as Aeson.Text
import qualified Data.Attoparsec.ByteString.Char8 as Atto
import           Data.Bifunctor (bimap, first)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.List as List
import qualified Data.Map.Lazy as Map.Lazy
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import qualified Data.Scientific as Scientific
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Lazy as Text.Lazy
import qualified Data.Text.Lazy.Builder as Text.Builder
import qualified Data.Vector as Vector
import           Data.Word

{- HLINT ignore "Use lambda-case" -}

-- ----------------------------------------------------------------------------
-- TxMetadata types
--

newtype TxMetadata = TxMetadata (Map Word64 TxMetadataValue)
    deriving (Eq, Show)

data TxMetadataValue = TxMetaMap    [(TxMetadataValue, TxMetadataValue)]
                     | TxMetaList   [TxMetadataValue]
                     | TxMetaNumber Integer -- -2^64 .. 2^64-1
                     | TxMetaBytes  ByteString
                     | TxMetaText   Text
    deriving (Eq, Ord, Show)
  -- Note the order of constructors is the same as the ledger definitions
  -- so that the Ord instance is consistent with the ledger one.
  -- This is checked by prop_ord_distributive_TxMetadata

-- | Merge metadata maps. When there are clashing entries the left hand side
-- takes precedence.
--
instance Semigroup TxMetadata where
    TxMetadata m1 <> TxMetadata m2 = TxMetadata (m1 <> m2)

instance Monoid TxMetadata where
    mempty = TxMetadata mempty

instance HasTypeProxy TxMetadata where
    data AsType TxMetadata = AsTxMetadata
    proxyToAsType _ = AsTxMetadata

instance SerialiseAsCBOR TxMetadata where
    serialiseToCBOR =
          -- This is a workaround. There is a tiny chance that serialization could change
          -- for Metadata in the future, depending on the era it is being used in. For now
          -- we can pretend like it is the same for all eras starting with Shelley
          --
          -- Versioned cbor works only when we have protocol version available during
          -- [de]serialization. The only two ways to fix this:
          --
          -- - Paramterize TxMetadata with era. This would allow us to get protocol version
          --   from the type level
          --
          -- - Change SerialiseAsCBOR interface in such a way that it allows major
          --   protocol version be supplied as an argument.
          CBOR.serialize' CBOR.shelleyProtVer
        . toShelleyMetadata
        . (\(TxMetadata m) -> m)

    deserialiseFromCBOR AsTxMetadata bs =
          TxMetadata
        . fromShelleyMetadata
      <$> (CBOR.decodeFullDecoder' CBOR.shelleyProtVer "TxMetadata" CBOR.decCBOR bs
           :: Either CBOR.DecoderError (Map Word64 Shelley.Metadatum))

makeTransactionMetadata :: Map Word64 TxMetadataValue -> TxMetadata
makeTransactionMetadata = TxMetadata

mergeTransactionMetadata
  :: (TxMetadataValue -> TxMetadataValue -> TxMetadataValue)
  -> TxMetadata
  -> TxMetadata
  -> TxMetadata
mergeTransactionMetadata merge (TxMetadata m1) (TxMetadata m2) =
  TxMetadata $ Map.unionWith merge m1 m2

-- | Create a 'TxMetadataValue' from a 'Text' as a list of chunks of an
-- acceptable size.
metaTextChunks :: Text -> TxMetadataValue
metaTextChunks =
  TxMetaList . chunks
    txMetadataTextStringMaxByteLength
    TxMetaText
    (BS.length . Text.encodeUtf8)
    utf8SplitAt
 where
  fromBuilder = Text.Lazy.toStrict . Text.Builder.toLazyText

  -- 'Text.splitAt' is no good here, because our measurement is on UTF-8
  -- encoded text strings; So a char of size 1 in a text string may be
  -- encoded over multiple UTF-8 bytes.
  --
  -- Thus, no choice than folding over each char and manually implementing
  -- splitAt that counts utf8 bytes. Using builders for slightly more
  -- efficiency.
  utf8SplitAt n =
    bimap fromBuilder fromBuilder . snd . Text.foldl
      (\(len, (left, right)) char ->
        -- NOTE:
        -- Starting from text >= 2.0.0.0, one can use:
        --
        --   Data.Text.Internal.Encoding.Utf8#utf8Length
        --
        let sz = BS.length (Text.encodeUtf8 (Text.singleton char)) in
        if len + sz > n then
          ( n + 1 -- Higher than 'n' to always trigger the predicate
          , ( left
            , right <> Text.Builder.singleton char
            )
          )
        else
          ( len + sz
          , ( left <> Text.Builder.singleton char
            , right
            )
          )
      )
      (0, (mempty, mempty))

-- | Create a 'TxMetadataValue' from a 'ByteString' as a list of chunks of an
-- accaptable size.
metaBytesChunks :: ByteString -> TxMetadataValue
metaBytesChunks =
  TxMetaList . chunks
    txMetadataByteStringMaxLength
    TxMetaBytes
    BS.length
    BS.splitAt

-- ----------------------------------------------------------------------------
-- TxMetadata class
--

class AsTxMetadata a where
  asTxMetadata :: a -> TxMetadata

-- ----------------------------------------------------------------------------
-- Internal conversion functions
--

toShelleyMetadata :: Map Word64 TxMetadataValue -> Map Word64 Shelley.Metadatum
toShelleyMetadata = Map.map toShelleyMetadatum

toShelleyMetadatum :: TxMetadataValue -> Shelley.Metadatum
toShelleyMetadatum (TxMetaNumber x) = Shelley.I x
toShelleyMetadatum (TxMetaBytes  x) = Shelley.B x
toShelleyMetadatum (TxMetaText   x) = Shelley.S x
toShelleyMetadatum (TxMetaList  xs) = Shelley.List
                                        [ toShelleyMetadatum x | x <- xs ]
toShelleyMetadatum (TxMetaMap   xs) = Shelley.Map
                                        [ (toShelleyMetadatum k,
                                           toShelleyMetadatum v)
                                        | (k,v) <- xs ]

fromShelleyMetadata :: Map Word64 Shelley.Metadatum -> Map Word64 TxMetadataValue
fromShelleyMetadata = Map.Lazy.map fromShelleyMetadatum

fromShelleyMetadatum :: Shelley.Metadatum -> TxMetadataValue
fromShelleyMetadatum (Shelley.I     x) = TxMetaNumber x
fromShelleyMetadatum (Shelley.B     x) = TxMetaBytes  x
fromShelleyMetadatum (Shelley.S     x) = TxMetaText   x
fromShelleyMetadatum (Shelley.List xs) = TxMetaList
                                           [ fromShelleyMetadatum x | x <- xs ]
fromShelleyMetadatum (Shelley.Map  xs) = TxMetaMap
                                           [ (fromShelleyMetadatum k,
                                              fromShelleyMetadatum v)
                                           | (k,v) <- xs ]

-- | Transform a string-like structure into chunks with a maximum size; Chunks
-- are filled from left to right.
chunks
  :: Int
    -- ^ Chunk max size (inclusive)
  -> (str -> chunk)
    -- ^ Hoisting
  -> (str -> Int)
    -- ^ Measuring
  -> (Int -> str -> (str, str))
    -- ^ Splitting
  -> str
    -- ^ String
  -> [chunk]
chunks maxLength strHoist strLength strSplitAt str
  | strLength str > maxLength =
    let (h, t) = strSplitAt maxLength str
     in strHoist h : chunks maxLength strHoist strLength strSplitAt t
  | otherwise =
    [strHoist str | strLength str > 0]

-- ----------------------------------------------------------------------------
-- Validate tx metadata
--

-- | Validate transaction metadata. This is for use with existing constructed
-- metadata values, e.g. constructed manually or decoded from CBOR directly.
--
validateTxMetadata :: TxMetadata -> Either [(Word64, TxMetadataRangeError)] ()
validateTxMetadata (TxMetadata m) =
    -- Collect all errors and do a top-level check to see if there are any.
    case [ (k, err)
         | (k, v) <- Map.toList m
         , err <- validateTxMetadataValue v ] of
      []   -> Right ()
      errs -> Left errs

-- collect all errors in a monoidal fold style
validateTxMetadataValue :: TxMetadataValue -> [TxMetadataRangeError]
validateTxMetadataValue (TxMetaNumber n) =
    [ TxMetadataNumberOutOfRange n
    |    n >         fromIntegral (maxBound :: Word64)
      || n < negate (fromIntegral (maxBound :: Word64))
    ]
validateTxMetadataValue (TxMetaBytes bs) =
    [ TxMetadataBytesTooLong len
    | let len = BS.length bs
    , len > txMetadataByteStringMaxLength
    ]
validateTxMetadataValue (TxMetaText txt) =
    [ TxMetadataTextTooLong len
    | let len = BS.length (Text.encodeUtf8 txt)
    , len > txMetadataTextStringMaxByteLength
    ]
validateTxMetadataValue (TxMetaList xs) =
    foldMap validateTxMetadataValue xs

validateTxMetadataValue (TxMetaMap kvs) =
    foldMap (\(k, v) -> validateTxMetadataValue k
                     <> validateTxMetadataValue v)
            kvs

-- | The maximum byte length of a transaction metadata text string value.
txMetadataTextStringMaxByteLength :: Int
txMetadataTextStringMaxByteLength = 64

-- | The maximum length of a transaction metadata byte string value.
txMetadataByteStringMaxLength :: Int
txMetadataByteStringMaxLength = 64


-- | An error in transaction metadata due to an out-of-range value.
--
data TxMetadataRangeError =

    -- | The number is outside the maximum range of @-2^64-1 .. 2^64-1@.
    --
    TxMetadataNumberOutOfRange !Integer

    -- | The length of a text string metadatum value exceeds the maximum of
    -- 64 bytes as UTF8.
    --
  | TxMetadataTextTooLong !Int

    -- | The length of a byte string metadatum value exceeds the maximum of
    -- 64 bytes.
    --
  | TxMetadataBytesTooLong !Int
  deriving (Eq, Show)

instance Error TxMetadataRangeError where
  displayError (TxMetadataNumberOutOfRange n) =
      "Numeric metadata value "
        <> show n
        <> " is outside the range -(2^64-1) .. 2^64-1."
  displayError (TxMetadataTextTooLong actualLen) =
      "Text string metadata value must consist of at most "
        <> show txMetadataTextStringMaxByteLength
        <> " UTF8 bytes, but it consists of "
        <> show actualLen
        <> " bytes."
  displayError (TxMetadataBytesTooLong actualLen) =
      "Byte string metadata value must consist of at most "
        <> show txMetadataByteStringMaxLength
        <> " bytes, but it consists of "
        <> show actualLen
        <> " bytes."


-- ----------------------------------------------------------------------------
-- JSON conversion
--

-- | Tx metadata is similar to JSON but not exactly the same. It has some
-- deliberate limitations such as no support for floating point numbers or
-- special forms for null or boolean values. It also has limitations on the
-- length of strings. On the other hand, unlike JSON, it distinguishes between
-- byte strings and text strings. It also supports any value as map keys rather
-- than just string.
--
-- We provide two different mappings between tx metadata and JSON, useful
-- for different purposes:
--
-- 1. A mapping that allows almost any JSON value to be converted into
--    tx metadata. This does not require a specific JSON schema for the
--    input. It does not expose the full representation capability of tx
--    metadata.
--
-- 2. A mapping that exposes the full representation capability of tx
--    metadata, but relies on a specific JSON schema for the input JSON.
--
-- In the \"no schema"\ mapping, the idea is that (almost) any JSON can be
-- turned into tx metadata and then converted back, without loss. That is, we
-- can round-trip the JSON.
--
-- The subset of JSON supported is all JSON except:
-- * No null or bool values
-- * No floating point, only integers in the range of a 64bit signed integer
-- * A limitation on string lengths
--
-- The approach for this mapping is to use whichever representation as tx
-- metadata is most compact. In particular:
--
-- * JSON lists and maps represented as CBOR lists and maps
-- * JSON strings represented as CBOR strings
-- * JSON hex strings with \"0x\" prefix represented as CBOR byte strings
-- * JSON integer numbers represented as CBOR signed or unsigned numbers
-- * JSON maps with string keys that parse as numbers or hex byte strings,
--   represented as CBOR map keys that are actually numbers or byte strings.
--
-- The string length limit depends on whether the hex string representation
-- is used or not. For text strings the limit is 64 bytes for the UTF8
-- representation of the text string. For byte strings the limit is 64 bytes
-- for the raw byte form (ie not the input hex, but after hex decoding).
--
-- In the \"detailed schema\" mapping, the idea is that we expose the full
-- representation capability of the tx metadata in the form of a JSON schema.
-- This means the full representation is available and can be controlled
-- precisely. It also means any tx metadata can be converted into the JSON and
-- back without loss. That is we can round-trip the tx metadata via the JSON and
-- also round-trip schema-compliant JSON via tx metadata.
--
data TxMetadataJsonSchema =

       -- | Use the \"no schema\" mapping between JSON and tx metadata as
       -- described above.
       TxMetadataJsonNoSchema

       -- | Use the \"detailed schema\" mapping between JSON and tx metadata as
       -- described above.
     | TxMetadataJsonDetailedSchema
  deriving (Eq, Show)


-- | Convert a value from JSON into tx metadata, using the given choice of
-- mapping between JSON and tx metadata.
--
-- This may fail with a conversion error if the JSON is outside the supported
-- subset for the chosen mapping. See 'TxMetadataJsonSchema' for the details.
--
metadataFromJson :: TxMetadataJsonSchema
                 -> Aeson.Value
                 -> Either TxMetadataJsonError TxMetadata
metadataFromJson schema =
    \vtop -> case vtop of
      -- The top level has to be an object
      -- with unsigned integer (decimal or hex) keys
      Aeson.Object m ->
          fmap (TxMetadata . Map.fromList)
        . mapM (uncurry metadataKeyPairFromJson)
        $ KeyMap.toList m

      _ -> Left TxMetadataJsonToplevelNotMap
  where
    metadataKeyPairFromJson :: Aeson.Key
                            -> Aeson.Value
                            -> Either TxMetadataJsonError
                                      (Word64, TxMetadataValue)
    metadataKeyPairFromJson k v = do
      k' <- convTopLevelKey k
      v' <- first (TxMetadataJsonSchemaError k' v)
                  (metadataValueFromJson v)
      first (TxMetadataRangeError k' v)
            (validateMetadataValue v')
      return (k', v')

    convTopLevelKey :: Aeson.Key -> Either TxMetadataJsonError Word64
    convTopLevelKey (Aeson.toText -> k) =
      case parseAll (pUnsigned <* Atto.endOfInput) k of
        Just n | n <= fromIntegral (maxBound :: Word64)
          -> Right (fromIntegral n)
        _ -> Left (TxMetadataJsonToplevelBadKey k)

    validateMetadataValue :: TxMetadataValue -> Either TxMetadataRangeError ()
    validateMetadataValue v =
      case validateTxMetadataValue v of
        []      -> Right ()
        err : _ -> Left err

    metadataValueFromJson :: Aeson.Value
                          -> Either TxMetadataJsonSchemaError TxMetadataValue
    metadataValueFromJson =
      case schema of
        TxMetadataJsonNoSchema       -> metadataValueFromJsonNoSchema
        TxMetadataJsonDetailedSchema -> metadataValueFromJsonDetailedSchema


-- | Convert a tx metadata value into JSON , using the given choice of mapping
-- between JSON and tx metadata.
--
-- This conversion is total but is not necessarily invertible.
-- See 'TxMetadataJsonSchema' for the details.
--
metadataToJson :: TxMetadataJsonSchema
               -> TxMetadata
               -> Aeson.Value
metadataToJson schema =
    \(TxMetadata mdMap) ->
    Aeson.object
      [ (Aeson.fromString (show k), metadataValueToJson v)
      | (k, v) <- Map.toList mdMap ]
  where
    metadataValueToJson :: TxMetadataValue -> Aeson.Value
    metadataValueToJson =
      case schema of
        TxMetadataJsonNoSchema       -> metadataValueToJsonNoSchema
        TxMetadataJsonDetailedSchema -> metadataValueToJsonDetailedSchema


-- ----------------------------------------------------------------------------
-- JSON conversion using the the "no schema" style
--

metadataValueToJsonNoSchema :: TxMetadataValue -> Aeson.Value
metadataValueToJsonNoSchema = conv
  where
    conv :: TxMetadataValue -> Aeson.Value
    conv (TxMetaNumber n) = Aeson.Number (fromInteger n)
    conv (TxMetaBytes bs) = Aeson.String (bytesPrefix
                                       <> Text.decodeLatin1 (Base16.encode bs))

    conv (TxMetaText txt) = Aeson.String txt
    conv (TxMetaList  vs) = Aeson.Array (Vector.fromList (map conv vs))
    conv (TxMetaMap  kvs) = Aeson.object
                              [ (convKey k, conv v)
                              | (k, v) <- kvs ]

    -- Metadata allows any value as a key, not just string as JSON does.
    -- For simple types we just convert them to string directly.
    -- For structured keys we render them as JSON and use that as the string.
    convKey :: TxMetadataValue -> Aeson.Key
    convKey (TxMetaNumber n) = Aeson.fromString (show n)
    convKey (TxMetaBytes bs) = Aeson.fromText $ bytesPrefix
                            <> Text.decodeLatin1 (Base16.encode bs)
    convKey (TxMetaText txt) = Aeson.fromText txt
    convKey v                = Aeson.fromText
                             . Text.Lazy.toStrict
                             . Aeson.Text.encodeToLazyText
                             . conv
                             $ v

metadataValueFromJsonNoSchema :: Aeson.Value
                              -> Either TxMetadataJsonSchemaError
                                        TxMetadataValue
metadataValueFromJsonNoSchema = conv
  where
    conv :: Aeson.Value
         -> Either TxMetadataJsonSchemaError TxMetadataValue
    conv Aeson.Null   = Left TxMetadataJsonNullNotAllowed
    conv Aeson.Bool{} = Left TxMetadataJsonBoolNotAllowed

    conv (Aeson.Number d) =
      case Scientific.floatingOrInteger d :: Either Double Integer of
        Left  n -> Left (TxMetadataJsonNumberNotInteger n)
        Right n -> Right (TxMetaNumber n)

    conv (Aeson.String s)
      | Just s' <- Text.stripPrefix bytesPrefix s
      , let bs' = Text.encodeUtf8 s'
      , Right bs <- Base16.decode bs'
      , not (BSC.any (\c -> c >= 'A' && c <= 'F') bs')
      = Right (TxMetaBytes bs)

    conv (Aeson.String s) = Right (TxMetaText s)

    conv (Aeson.Array vs) =
        fmap TxMetaList
      . traverse conv
      $ Vector.toList vs

    conv (Aeson.Object kvs) =
        fmap TxMetaMap
      . traverse (\(k,v) -> (,) (convKey k) <$> conv v)
      . List.sortOn fst
      . fmap (first Aeson.toText)
      $ KeyMap.toList kvs

    convKey :: Text -> TxMetadataValue
    convKey s =
      fromMaybe (TxMetaText s) $
      parseAll ((fmap TxMetaNumber pSigned <* Atto.endOfInput)
            <|> (fmap TxMetaBytes  pBytes  <* Atto.endOfInput)) s

-- | JSON strings that are base16 encoded and prefixed with 'bytesPrefix' will
-- be encoded as CBOR bytestrings.
bytesPrefix :: Text
bytesPrefix = "0x"


-- ----------------------------------------------------------------------------
-- JSON conversion using the "detailed schema" style
--

metadataValueToJsonDetailedSchema :: TxMetadataValue -> Aeson.Value
metadataValueToJsonDetailedSchema  = conv
  where
    conv :: TxMetadataValue -> Aeson.Value
    conv (TxMetaNumber n) = singleFieldObject "int"
                          . Aeson.Number
                          $ fromInteger n
    conv (TxMetaBytes bs) = singleFieldObject "bytes"
                          . Aeson.String
                          $ Text.decodeLatin1 (Base16.encode bs)
    conv (TxMetaText txt) = singleFieldObject "string"
                          . Aeson.String
                          $ txt
    conv (TxMetaList  vs) = singleFieldObject "list"
                          . Aeson.Array
                          $ Vector.fromList (map conv vs)
    conv (TxMetaMap  kvs) = singleFieldObject "map"
                          . Aeson.Array
                          $ Vector.fromList
                              [ Aeson.object [ ("k", conv k), ("v", conv v) ]
                              | (k, v) <- kvs ]

    singleFieldObject name v = Aeson.object [(name, v)]

metadataValueFromJsonDetailedSchema :: Aeson.Value
                                    -> Either TxMetadataJsonSchemaError
                                              TxMetadataValue
metadataValueFromJsonDetailedSchema = conv
  where
    conv :: Aeson.Value
         -> Either TxMetadataJsonSchemaError TxMetadataValue
    conv (Aeson.Object m) =
      case KeyMap.toList m of
        [("int", Aeson.Number d)] ->
          case Scientific.floatingOrInteger d :: Either Double Integer of
            Left  n -> Left (TxMetadataJsonNumberNotInteger n)
            Right n -> Right (TxMetaNumber n)

        [("bytes", Aeson.String s)]
          | Right bs <- Base16.decode (Text.encodeUtf8 s)
          -> Right (TxMetaBytes bs)

        [("string", Aeson.String s)] -> Right (TxMetaText s)

        [("list", Aeson.Array vs)] ->
            fmap TxMetaList
          . traverse conv
          $ Vector.toList vs

        [("map", Aeson.Array kvs)] ->
            fmap TxMetaMap
          . traverse convKeyValuePair
          $ Vector.toList kvs

        [(key, v)] | key `elem` ["int", "bytes", "string", "list", "map"] ->
            Left (TxMetadataJsonTypeMismatch (Aeson.toText key) v)

        kvs -> Left (TxMetadataJsonBadObject (first Aeson.toText <$> kvs))

    conv v = Left (TxMetadataJsonNotObject v)

    convKeyValuePair :: Aeson.Value
                     -> Either TxMetadataJsonSchemaError
                               (TxMetadataValue, TxMetadataValue)
    convKeyValuePair (Aeson.Object m)
      | KeyMap.size m == 2
      , Just k <- KeyMap.lookup "k" m
      , Just v <- KeyMap.lookup "v" m
      = (,) <$> conv k <*> conv v

    convKeyValuePair v = Left (TxMetadataJsonBadMapPair v)


-- ----------------------------------------------------------------------------
-- Shared JSON conversion error types
--

data TxMetadataJsonError =
       TxMetadataJsonToplevelNotMap
     | TxMetadataJsonToplevelBadKey !Text
     | TxMetadataJsonSchemaError !Word64 !Aeson.Value !TxMetadataJsonSchemaError
     | TxMetadataRangeError      !Word64 !Aeson.Value !TxMetadataRangeError
  deriving (Eq, Show)

data TxMetadataJsonSchemaError =
       -- Only used for 'TxMetadataJsonNoSchema'
       TxMetadataJsonNullNotAllowed
     | TxMetadataJsonBoolNotAllowed

       -- Used by both mappings
     | TxMetadataJsonNumberNotInteger !Double

       -- Only used for 'TxMetadataJsonDetailedSchema'
     | TxMetadataJsonNotObject !Aeson.Value
     | TxMetadataJsonBadObject ![(Text, Aeson.Value)]
     | TxMetadataJsonBadMapPair !Aeson.Value
     | TxMetadataJsonTypeMismatch !Text !Aeson.Value
  deriving (Eq, Show)

instance Error TxMetadataJsonError where
    displayError TxMetadataJsonToplevelNotMap =
        "The JSON metadata top level must be a map (JSON object) from word to "
     ++ "value."
    displayError (TxMetadataJsonToplevelBadKey k) =
        "The JSON metadata top level must be a map (JSON object) with unsigned "
     ++ "integer keys.\nInvalid key: " ++ show k
    displayError (TxMetadataJsonSchemaError k v detail) =
        "JSON schema error within the metadata item " ++ show k ++ ": "
     ++ LBS.unpack (Aeson.encode v) ++ "\n" ++ displayError detail
    displayError (TxMetadataRangeError k v detail) =
        "Value out of range within the metadata item " ++ show k ++ ": "
     ++ LBS.unpack (Aeson.encode v) ++ "\n" ++ displayError detail

instance Error TxMetadataJsonSchemaError where
    displayError TxMetadataJsonNullNotAllowed =
        "JSON null values are not supported."
    displayError TxMetadataJsonBoolNotAllowed =
        "JSON bool values are not supported."
    displayError (TxMetadataJsonNumberNotInteger d) =
        "JSON numbers must be integers. Unexpected value: " ++ show d
    displayError (TxMetadataJsonNotObject v) =
        "JSON object expected. Unexpected value: "
     ++ LBS.unpack (Aeson.encode v)
    displayError (TxMetadataJsonBadObject v) =
        "JSON object does not match the schema.\nExpected a single field named "
     ++ "\"int\", \"bytes\", \"string\", \"list\" or \"map\".\n"
     ++ "Unexpected object field(s): "
     ++ LBS.unpack (Aeson.encode (Aeson.object $ first Aeson.fromText <$> v))
    displayError (TxMetadataJsonBadMapPair v) =
        "Expected a list of key/value pair { \"k\": ..., \"v\": ... } objects."
     ++ "\nUnexpected value: " ++ LBS.unpack (Aeson.encode v)
    displayError (TxMetadataJsonTypeMismatch k v) =
        "The value in the field " ++ show k ++ " does not have the type "
     ++ "required by the schema.\nUnexpected value: "
     ++ LBS.unpack (Aeson.encode v)


-- ----------------------------------------------------------------------------
-- Shared parsing utils
--

parseAll :: Atto.Parser a -> Text -> Maybe a
parseAll p = either (const Nothing) Just
           . Atto.parseOnly p
           . Text.encodeUtf8

pUnsigned :: Atto.Parser Integer
pUnsigned = do
    bs <- Atto.takeWhile1 Atto.isDigit
    -- no redundant leading 0s allowed, or we cannot round-trip properly
    guard (not (BS.length bs > 1 && BSC.head bs == '0'))
    return $! BS.foldl' step 0 bs
  where
    step a w = a * 10 + fromIntegral (w - 48)

pSigned :: Atto.Parser Integer
pSigned = Atto.signed pUnsigned

pBytes :: Atto.Parser ByteString
pBytes = do
  _ <- Atto.string "0x"
  remaining <- Atto.takeByteString
  when (BSC.any hexUpper remaining) $ fail ("Unexpected uppercase hex characters in " <> show remaining)
  case Base16.decode remaining of
    Right bs -> return bs
    _ -> fail ("Expecting base16 encoded string, found: " <> show remaining)
  where
    hexUpper c = c >= 'A' && c <= 'F'
