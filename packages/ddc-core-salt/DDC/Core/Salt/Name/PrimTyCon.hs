
module DDC.Core.Salt.Name.PrimTyCon
        ( PrimTyCon     (..)
        , readPrimTyCon
        , primTyConIsIntegral
        , primTyConIsFloating
        , primTyConIsUnsigned
        , primTyConIsSigned
        , primTyConWidth)
where
import DDC.Base.Pretty
import DDC.Core.Salt.Platform
import Data.Char
import Data.List
import Control.DeepSeq


-- PrimTyCon -----------------------------------------------------------------
-- | Primitive type constructors.
data PrimTyCon
        -- | @Void#@ the Void type has no values.
        = PrimTyConVoid

        -- | @Bool#@ unboxed booleans.
        | PrimTyConBool

        -- | @Nat#@ natural numbers.
        --   Enough precision to count every object in the heap,
        --   but NOT enough precision to count every byte of memory.
        | PrimTyConNat

        -- | @Int#@ signed integers.
        --   Enough precision to count every object in the heap,
        --   but NOT enough precision to count every byte of memory.
        --   If N is the total number of objects that can exist in the heap,
        --   then the range of @Int#@ is at least (-N .. +N) inclusive.
        | PrimTyConInt

        -- | @WordN#@ machine words of the given width.
        | PrimTyConWord   Int

        -- | @FloatN#@ floating point numbers of the given width.
        | PrimTyConFloat  Int

        -- | @VecN#@ a packed vector of N values.
        --   This is intended to have kind (Data -> Data), 
        --   so we use concrete vector types like @Vec4# Word32#@.
        | PrimTyConVec    Int

        -- | @Addr#@ a relative or absolute machine address.
        --   Enough precision to count every byte of memory.
        --   Unlike pointers below, an absolute @Addr#@ need not refer to 
        --   memory owned by the current process.
        | PrimTyConAddr

        -- | @Ptr#@ should point to a well-formed object owned by the
        --   current process.
        | PrimTyConPtr

        -- | @Tag#@ data constructor tags.
        --   Enough precision to count every possible alternative of an 
        --   enumerated type.
        | PrimTyConTag

        -- | @String#@ of UTF8 characters.
        -- 
        --   These are primitive until we can define our own unboxed types.
        | PrimTyConString 
        deriving (Eq, Ord, Show)


instance NFData PrimTyCon where
 rnf tc
  = case tc of
        PrimTyConWord i         -> rnf i
        PrimTyConFloat i        -> rnf i
        _                       -> ()


instance Pretty PrimTyCon where
 ppr tc
  = case tc of
        PrimTyConVoid           -> text "Void#"
        PrimTyConBool           -> text "Bool#"
        PrimTyConNat            -> text "Nat#"
        PrimTyConInt            -> text "Int#"
        PrimTyConWord   bits    -> text "Word"  <> int bits  <> text "#"
        PrimTyConFloat  bits    -> text "Float" <> int bits  <> text "#"
        PrimTyConVec    arity   -> text "Vec"   <> int arity <> text "#"
        PrimTyConTag            -> text "Tag#"
        PrimTyConAddr           -> text "Addr#"
        PrimTyConPtr            -> text "Ptr#"
        PrimTyConString         -> text "String#"


-- | Read a primitive type constructor.
--  
--   Words are limited to 8, 16, 32, or 64 bits.
--  
--   Floats are limited to 32 or 64 bits.
readPrimTyCon :: String -> Maybe PrimTyCon
readPrimTyCon str
        | str == "Void#"   = Just $ PrimTyConVoid
        | str == "Bool#"   = Just $ PrimTyConBool
        | str == "Nat#"    = Just $ PrimTyConNat
        | str == "Int#"    = Just $ PrimTyConInt
        | str == "Tag#"    = Just $ PrimTyConTag
        | str == "Addr#"   = Just $ PrimTyConAddr
        | str == "Ptr#"    = Just $ PrimTyConPtr
        | str == "String#" = Just $ PrimTyConString

        -- WordN#
        | Just rest     <- stripPrefix "Word" str
        , (ds, "#")     <- span isDigit rest
        , not $ null ds
        , n             <- read ds
        , elem n [8, 16, 32, 64]
        = Just $ PrimTyConWord n

        -- FloatN#
        | Just rest     <- stripPrefix "Float" str
        , (ds, "#")     <- span isDigit rest
        , not $ null ds
        , n             <- read ds
        , elem n [32, 64]
        = Just $ PrimTyConFloat n

        -- VecN#
        | Just rest     <- stripPrefix "Vec" str
        , (ds, "#")     <- span isDigit rest
        , not $ null ds
        , n             <- read ds
        , elem n [2, 4, 8, 16]        
        = Just $ PrimTyConVec n

        | otherwise
        = Nothing


-- | Integral constructors are the ones that we can reasonably
--   convert from integers of the same size. 
--  
--   These are @Bool#@ @Nat#@ @Int#@ @WordN#@ and @Tag#@.
--
primTyConIsIntegral :: PrimTyCon -> Bool
primTyConIsIntegral tc
 = case tc of
        PrimTyConBool           -> True
        PrimTyConNat            -> True
        PrimTyConInt            -> True
        PrimTyConWord{}         -> True
        PrimTyConTag            -> True
        _                       -> False


-- | Floating point constructors.
-- 
--   These are @FloatN@.
primTyConIsFloating :: PrimTyCon -> Bool
primTyConIsFloating tc
 = case tc of
        PrimTyConFloat{}        -> True
        _                       -> False


-- | Unsigned integral constructors.
--
--   These are @Bool@ @Nat@ @WordN@ @Tag@.
primTyConIsUnsigned :: PrimTyCon -> Bool
primTyConIsUnsigned tc
 = case tc of
        PrimTyConBool           -> True
        PrimTyConNat            -> True
        PrimTyConWord{}         -> True
        PrimTyConTag            -> True
        _                       -> False

-- | Signed integral constructors.
-- 
--   This is just @Int@.
primTyConIsSigned :: PrimTyCon -> Bool
primTyConIsSigned tc
 = case tc of
        PrimTyConInt            -> True
        PrimTyConFloat{}        -> True
        _                       -> False


-- | Get the representation width of a primitive type constructor, 
--   in bits. This is how much space it takes up in an object payload.
--
--   Bools are representable with a single bit, but we unpack
--   them into a whole word.
--
--   The constructors @Void@ and @VecN#@ and @String@ have no width.
--
primTyConWidth :: Platform -> PrimTyCon -> Maybe Integer
primTyConWidth pp tc
 = case tc of
        PrimTyConVoid           -> Nothing
        PrimTyConBool           -> Just $ 8 * platformNatBytes pp 
        PrimTyConNat            -> Just $ 8 * platformNatBytes  pp
        PrimTyConInt            -> Just $ 8 * platformNatBytes  pp
        PrimTyConWord  bits     -> Just $ fromIntegral bits
        PrimTyConFloat bits     -> Just $ fromIntegral bits
        PrimTyConTag            -> Just $ 8 * platformTagBytes  pp
        PrimTyConAddr           -> Just $ 8 * platformAddrBytes pp
        PrimTyConPtr            -> Just $ 8 * platformAddrBytes pp
        PrimTyConVec   _        -> Nothing
        PrimTyConString         -> Nothing

