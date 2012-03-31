
module DDC.Core.Llvm.Convert.Prim
        (convPrimCallM)
where
import DDC.Llvm.Instr
import DDC.Core.Llvm.Convert.Atom
import DDC.Core.Llvm.Convert.Type
import DDC.Core.Llvm.Platform
import DDC.Core.Llvm.LlvmM
import DDC.Type.Compounds
import Data.Sequence                            (Seq)
import qualified DDC.Core.Exp                   as C
import qualified DDC.Core.Sea.Output.Name       as E
import qualified Data.Sequence                  as Seq


-- Prim call ------------------------------------------------------------------
-- | Convert a primitive call to LLVM.
convPrimCallM 
        :: Show a 
        => Platform             -- ^ Current platform.
        -> Maybe Var            -- ^ Assign result to this var.
        -> E.Prim               -- ^ Prim to call.
        -> C.Type E.Name        -- ^ Type of prim.
        -> [C.Exp a E.Name]     -- ^ Arguments to prim.
        -> LlvmM (Seq Instr)

convPrimCallM pp mdst p tPrim xs
 = case p of
        -- Binary operations ----------
        E.PrimOp op
         | [C.XType t, x1, x2] <- xs
         , Just x1'     <- mconvAtom   pp x1
         , Just x2'     <- mconvAtom   pp x2
         , Just dst     <- mdst
         -> let result
                 | Just op'     <- convPrimOp2 op t
                 = IOp dst op' x1' x2'

                 | Just icond'  <- convPrimICond op t
                 = IICmp dst icond' x1' x2'

                 | Just fcond'  <- convPrimFCond op t
                 = IFCmp dst fcond' x1' x2'

                 | otherwise
                 = IComment ["convPrimCallM: cannot convert " ++ show (p, xs)]

           in   return $ Seq.singleton result

        -- Cast primops ---------------
        E.PrimCast E.PrimCastPromote
         | [C.XType tDst, C.XType tSrc, xSrc] <- xs
         , Just vDst    <- mdst
         , Just xSrc'   <- mconvAtom pp xSrc
         , minstr       <- convPrimPromote pp tDst vDst tSrc xSrc'
         -> case minstr of
                Just instr      -> return $ Seq.singleton instr
                Nothing         -> error $ "convPrimCallM: invalid promotion " ++ show (tSrc, tDst)


        -- Store primops --------------
        E.PrimStore E.PrimStoreAlloc
         | [xBytes]     <- xs
         , Just xBytes' <- mconvAtom pp xBytes
         -> return      $ Seq.singleton
                        $ ICall mdst CallTypeStd
                                (tAddr pp) (NameGlobal "malloc") 
                                [xBytes'] []

        E.PrimStore E.PrimStoreRead
         | [C.XType t, xAddr, xOffset] <- xs
         , _t'                         <- convType pp t
         , Just xAddr'                 <- mconvAtom pp xAddr
         , Just xOffset'               <- mconvAtom pp xOffset
         , Just vDst@(Var nDst tDst)   <- mdst
         -> let vOff    = Var (bumpName nDst "off") (tAddr pp)
                vPtr    = Var (bumpName nDst "ptr") (tPtr tDst)
            in  return  $ Seq.fromList
                        [ IOp   vOff OpAdd xAddr' xOffset'
                        , IConv vPtr ConvInttoptr (XVar vOff)
                        , ILoad vDst (XVar vPtr) ]

        E.PrimStore E.PrimStoreWrite
         | [C.XType _t, xAddr, xOffset, xVal] <- xs
         , Just xAddr'   <- mconvAtom pp xAddr
         , Just xOffset' <- mconvAtom pp xOffset
         , Just xVal'    <- mconvAtom pp xVal
         -> do  vOff     <- newUniqueNamedVar "off" (tAddr pp)
                vPtr     <- newUniqueNamedVar "ptr" (tPtr $ typeOfExp xVal')
                return  $ Seq.fromList
                        [ IOp    vOff OpAdd xAddr' xOffset'
                        , IConv  vPtr ConvInttoptr (XVar vOff)
                        , IStore (XVar vPtr) xVal' ]

        E.PrimStore E.PrimStoreMakePtr
         | [C.XType _t, xAddr]          <- xs
         , Just xAddr'  <- mconvAtom pp xAddr
         , Just vDst    <- mdst
         ->     return  $ Seq.singleton
                        $ IConv vDst ConvInttoptr xAddr'

        E.PrimStore E.PrimStoreTakePtr
         | [C.XType _t, xPtr]          <- xs
         , Just xPtr'   <- mconvAtom pp xPtr
         , Just vDst    <- mdst
         ->     return  $ Seq.singleton
                        $ IConv vDst ConvPtrtoint xPtr'

        -- External Primops -----------
        E.PrimExternal prim
         |  Just xs'     <- sequence $ map (mconvAtom pp) xs
         ,  (_, tResult) <- takeTFunArgResult tPrim
         ,  tResult'     <- convType pp tResult
         ,  Just name'   <- convPrimExtern prim tPrim
         -> return      $ Seq.singleton
                        $ ICall mdst CallTypeStd tResult'
                                name' xs' []

        _ -> return $ Seq.singleton 
           $ IComment ["convPrimCallM: cannot convert " ++ show (p, xs)]


bumpName :: Name -> String -> Name
bumpName nn s
 = case nn of
        NameLocal str   -> NameLocal  (str ++ "." ++ s)
        NameGlobal str  -> NameGlobal (str ++ "." ++ s)


-- Op -------------------------------------------------------------------------
-- | Convert a binary primop from Core Sea to LLVM form.
convPrimOp2 :: E.PrimOp -> C.Type E.Name -> Maybe Op
convPrimOp2 op t
 = case op of
        E.PrimOpAdd     
         | isIntegralT t                -> Just OpAdd
         | isFloatingT t                -> Just OpFAdd 

        E.PrimOpSub      
         | isIntegralT t                -> Just OpSub
         | isFloatingT t                -> Just OpFSub

        E.PrimOpMul 
         | isIntegralT t                -> Just OpMul
         | isFloatingT t                -> Just OpFMul

        E.PrimOpDiv
         | isIntegralT t, isUnsignedT t -> Just OpUDiv
         | isIntegralT t, isSignedT t   -> Just OpSDiv
         | isFloatingT t                -> Just OpFDiv

        E.PrimOpRem
         | isIntegralT t, isUnsignedT t -> Just OpURem
         | isIntegralT t, isSignedT t   -> Just OpSRem
         | isFloatingT t                -> Just OpFRem

        E.PrimOpShl
         | isIntegralT t                -> Just OpShl

        E.PrimOpShr
         | isIntegralT t, isUnsignedT t -> Just OpLShr
         | isIntegralT t, isSignedT t   -> Just OpAShr

        E.PrimOpBAnd
         | isIntegralT t                -> Just OpAnd

        E.PrimOpBOr
         | isIntegralT t                -> Just OpOr

        E.PrimOpBXOr
         | isIntegralT t                -> Just OpXor

        _                               -> Nothing


-- Cast -----------------------------------------------------------------------
convPrimPromote 
        :: Platform 
        -> C.Type E.Name -> Var
        -> C.Type E.Name -> Exp
        -> Maybe Instr

convPrimPromote pp tDst vDst tSrc xSrc
 = let  tDst'   = convType pp tDst
        tSrc'   = convType pp tSrc
        
        -- TODO: add Float and Int -> Float promotions
        result
         -- Same sized integers
         | TInt bitsDst <- tDst'
         , TInt bitsSrc <- tSrc'
         , bitsDst == bitsSrc
         = Just $ ISet vDst xSrc

         -- Both Unsigned
         | TInt bitsDst <- tDst'
         , TInt bitsSrc <- tSrc'
         , isUnsignedT tSrc
         , isUnsignedT tDst
         , bitsDst > bitsSrc
         = Just $ IConv vDst ConvZext xSrc

         -- Both Signed
         | TInt bitsDst <- tDst'
         , TInt bitsSrc <- tSrc'
         , isSignedT tSrc
         , isSignedT tDst
         , bitsDst > bitsSrc
         = Just $ IConv vDst ConvSext xSrc

         -- Unsigned to Signed
         | TInt bitsDst <- tDst'
         , TInt bitsSrc <- tSrc'
         , isUnsignedT tSrc
         , isSignedT   tDst
         , bitsDst > bitsSrc
         = Just $ IConv vDst ConvZext xSrc

         | otherwise
         = Nothing

   in   result


-- Cond -----------------------------------------------------------------------
-- | Convert an integer comparison from Core Sea to LLVM form.
convPrimICond :: E.PrimOp -> C.Type E.Name -> Maybe ICond
convPrimICond op t
 | isIntegralT t
 = case op of
        E.PrimOpEq      -> Just ICondEq
        E.PrimOpNeq     -> Just ICondNe
        E.PrimOpGt      -> Just ICondUgt
        E.PrimOpGe      -> Just ICondUge
        E.PrimOpLt      -> Just ICondUlt
        E.PrimOpLe      -> Just ICondUle
        _               -> Nothing

 | otherwise            =  Nothing


-- | Convert a floating point comparison from Core Sea to LLVM form.
convPrimFCond :: E.PrimOp -> C.Type E.Name -> Maybe FCond
convPrimFCond op t
 | isIntegralT t
 = case op of
        E.PrimOpEq      -> Just FCondOeq
        E.PrimOpNeq     -> Just FCondOne
        E.PrimOpGt      -> Just FCondOgt
        E.PrimOpGe      -> Just FCondOge
        E.PrimOpLt      -> Just FCondOlt
        E.PrimOpLe      -> Just FCondOle
        _               -> Nothing

 | otherwise            =  Nothing


-- Extern ---------------------------------------------------------------------
-- | Get the symbol name of an external primitive.
convPrimExtern :: E.PrimExternal -> C.Type E.Name -> Maybe Name
convPrimExtern p _t
 = case p of
        E.PrimExternalShowInt bits      
         -> Just $ NameGlobal ("showInt" ++ show bits)

        E.PrimExternalPutStr
         -> Just $ NameGlobal "putStr"

        E.PrimExternalPutStrLn
         -> Just $ NameGlobal "putStrLn"
