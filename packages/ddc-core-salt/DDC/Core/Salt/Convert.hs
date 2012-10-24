
-- | Convert the Disciple Core Salt into to real C code.
--
--   The input module needs to be:
--      well typed,
--      fully named with no deBruijn indices,
--      have all functions defined at top-level,
--      a-normalised,
--      have a control-transfer primop at the end of every function body
--        (these are added by DDC.Core.Salt.Convert.Transfer)
--      
module DDC.Core.Salt.Convert
        ( Error (..)
        , convertModule)
where
import DDC.Core.Salt.Convert.Prim
import DDC.Core.Salt.Convert.Base
import DDC.Core.Salt.Name
import DDC.Core.Compounds
import DDC.Type.Compounds
import DDC.Type.Predicates
import DDC.Type.Env                     (KindEnv, TypeEnv)
import DDC.Core.Module                  as C
import DDC.Core.Exp
import DDC.Base.Pretty
import DDC.Type.Check.Monad             (throw, result)
import qualified DDC.Type.Env           as Env
import qualified Data.Map               as Map


-- | Convert a Disciple Core Salt module to C-source text.
convertModule 
        :: Show a 
        => Bool                 -- ^ Whether to include top-level include macros.
        -> Module a Name        -- ^ Module to convert.
        -> Either (Error a) Doc

convertModule withPrelude mm
 = result $ convModuleM withPrelude mm


-- Module ---------------------------------------------------------------------
-- | Convert a Salt module to C source text.
convModuleM :: Show a => Bool -> Module a Name -> ConvertM a Doc
convModuleM withPrelude mm@(ModuleCore{})
 | ([LRec bxs], _) <- splitXLets $ moduleBody mm
 = do   
        -- Top-level includes ---------
        let cIncludes
                | not withPrelude
                = []

                | otherwise
                = [ text "#include \"Runtime.h\""
                  , text "#include \"Primitive.h\""
                  , empty ]

        -- Import external symbols ----
        let nts = Map.elems $ C.moduleImportTypes mm
        docs    <- mapM (uncurry $ convFunctionType Env.empty) nts
        let cExterns
                |  not withPrelude
                = []

                | otherwise
                =  [ text "extern " <> doc <> semi | doc <- docs ]

        -- RTS def --------------------
        -- If this is the main module then we need to declare
        -- the global RTS state.
        let cGlobals
                | not withPrelude
                = []

                | isMainModule mm
                = [ text "addr_t _DDC_Runtime_heapTop = 0;"
                  , text "addr_t _DDC_Runtime_heapMax = 0;"
                  , empty ]

                | otherwise
                = [ text "extern addr_t _DDC_Runtime_heapTop;"
                  , text "extern addr_t _DDC_Runtime_heapMax;"
                  , empty ]

        -- Super-combinator definitions.
        cSupers <- mapM (uncurry (convSuperM Env.empty Env.empty)) bxs

        -- Pase everything together
        return  $  vcat 
                $  cIncludes 
                ++ cExterns
                ++ cGlobals 
                ++ cSupers

 | otherwise
 = throw $ ErrorNoTopLevelLetrec mm


-- Type -----------------------------------------------------------------------
-- | Convert a Salt type to C source text.
--   This only handles non-function types.
convTypeM :: KindEnv Name -> Type Name -> ConvertM a Doc
convTypeM kenv tt
 = case tt of
        TVar u
         -> case Env.lookup u kenv of
             Nothing            -> error $ "Type variable not in kind environment." ++ show u
             Just k
              | isDataKind k    -> return $ text "Obj*"
              | otherwise       -> error "Invalid type variable."

        TCon{}
         | TCon (TyConBound (UPrim (NamePrimTyCon tc) _) _)      <- tt
         , Just doc     <- convPrimTyCon tc
         -> return doc

         | TCon (TyConBound (UPrim NameObjTyCon _) _)   <- tt
         -> return  $ text "Obj"


        TApp{}
         | Just (NamePrimTyCon PrimTyConPtr, [_, t2])   <- takePrimTyConApps tt
         -> do  t2'     <- convTypeM kenv t2
                return  $ t2' <> text "*"

        TForall b t
          -> convTypeM (Env.extend b kenv) t

        _ -> throw $ ErrorTypeInvalid tt


-- | Convert a Salt function type to a C source prototype.
convFunctionType 
        :: KindEnv  Name
        -> QualName Name        -- ^ Function name.
        -> Type     Name        -- ^ Function type.
        -> ConvertM a Doc

convFunctionType kenv nFunc tFunc
 | TForall b t' <- tFunc
 = convFunctionType (Env.extend b kenv) nFunc t'

 | otherwise
 = do   -- TODO: print the qualifier when we start using them.
        let QualName _ n = nFunc        
        let nFun'        = text $ sanitizeName (renderPlain $ ppr n)

        let (tsArgs, tResult) = takeTFunArgResult tFunc

        tsArgs'          <- mapM (convTypeM kenv) tsArgs
        tResult'         <- convTypeM kenv tResult

        return $ tResult' <+> nFun' <+> parenss tsArgs'


-- Super definition -----------------------------------------------------------
-- | Convert a super to C source text.
convSuperM 
        :: Show a 
        => KindEnv Name 
        -> TypeEnv Name
        -> Bind Name 
        -> Exp a Name 
        -> ConvertM a Doc

convSuperM     kenv0 tenv0 bTop xx
 = convSuperM' kenv0 tenv0 bTop [] xx

convSuperM' kenv tenv bTop bsParam xx
 -- Enter into type abstractions,
 --  adding the bound name to the environment.
 | XLAM _ b x   <- xx
 = convSuperM' (Env.extend b kenv) tenv bTop bsParam x

 -- Enter into value abstractions,
 --  remembering that we're now in a function that has this parameter.
 | XLam _ b x   <- xx
 = convSuperM' kenv (Env.extend b tenv) bTop (bsParam ++ [b]) x

 -- Convert the function body.
 | BName (NameVar nTop) tTop <- bTop
 = do   
        let nTop'        = text $ sanitizeName nTop
        let (_, tResult) = takeTFunArgResult $ eraseTForalls tTop 
        bsParam'        <- mapM (convBind kenv tenv) $ filter keepBind bsParam
        tResult'        <- convTypeM kenv $ eraseWitArg tResult
        xBody'          <- convBodyM kenv tenv xx

        return  $ vcat
                [ tResult'
                         <+> nTop'
                         <+> parenss bsParam'
                , lbrace <> line
                         <> indent 8 (xBody' <> semi) <> line
                         <> rbrace
                         <> line ]
        
 | otherwise    
 = throw $ ErrorFunctionInvalid xx


-- | Remove witness arguments from the return type
eraseWitArg :: Type Name -> Type Name
eraseWitArg tt
 = case tt of 
        -- Distinguish between application of witnesses and ptr
        TApp _ t2
         | Just (NamePrimTyCon PrimTyConPtr, _) <- takePrimTyConApps tt -> tt
         | otherwise -> eraseWitArg t2

        -- Pass through all other types
        _ -> tt


-- | Ditch witness bindings
keepBind :: Bind Name -> Bool
keepBind bb
 = case bb of        
        BName _ t
         |  tc : _ <- takeTApps t
         ,  isWitnessType tc
         -> False
         
        BNone{} -> False         
        _       -> True


-- | Convert a function parameter binding to C source text.
convBind :: KindEnv Name -> TypeEnv Name -> Bind Name -> ConvertM a Doc
convBind kenv _tenv b
 = case b of 
   
        -- Named variables binders.
        BName (NameVar str) t
         -> do   t'      <- convTypeM kenv t
                 return  $ t' <+> (text $ sanitizeName str)
                 
        _       -> throw $ ErrorParameterInvalid b


-- Super body -----------------------------------------------------------------
-- | Convert a super body to C source text.
convBodyM 
        :: Show a 
        => KindEnv Name
        -> TypeEnv Name
        -> Exp a Name
        -> ConvertM a Doc

convBodyM kenv tenv xx
 = case xx of

        -- End of function body must explicitly pass control.
        XApp{}
         -> case takeXPrimApps xx of
             Just (NamePrim p, xs)
              | isControlPrim p -> convPrimCallM kenv tenv p xs
             _                  -> throw $ ErrorBodyMustPassControl xx

        -- Variable assignment.
        XLet _ (LLet LetStrict (BName (NameVar n) t) x1) x2
         -> do  t'      <- convTypeM   kenv t
                x1'     <- convRValueM kenv tenv x1
                x2'     <- convBodyM   kenv tenv x2
                let n'  = text $ sanitizeName n

                return  $ vcat
                        [ fill 16 (t' <+> n') <+> equals <+> x1' <> semi
                        , x2' ]

        -- Non-binding statement.
        --  We just drop any returned value on the floor.
        XLet _ (LLet LetStrict (BNone _) x1) x2
         -> do  x1'     <- convStmtM kenv tenv x1
                x2'     <- convBodyM kenv tenv x2

                return  $ vcat
                        [ x1' <> semi
                        , x2' ]

        -- Throw out letregion expressions.
        XLet _ (LLetRegions _ _) x
         -> convBodyM kenv tenv x

        -- Case-expression.
        --   Prettier printing for case-expression that just checks for failure.
        XCase _ x [ AAlt (PData dc []) x1
                  , AAlt PDefault     xFail]
         | isFailX xFail
         , Just n       <- takeNameOfDaCon dc
         , Just n'      <- convDaConName n
         -> do  
                x'      <- convRValueM kenv tenv x
                x1'     <- convBodyM   kenv tenv x1
                xFail'  <- convBodyM   kenv tenv xFail

                return  $ vcat
                        [ text "if"
                                <+> parens (x' <+> text "!=" <+> n')
                                <+> xFail' <> semi
                        , x1' ]

        -- Case-expression.
        --   Prettier printing for if-then-else.
        XCase _ x [ AAlt (PData dc1 []) x1
                  , AAlt (PData dc2 []) x2 ]
         | Just (NameBool True)  <- takeNameOfDaCon dc1
         , Just (NameBool False) <- takeNameOfDaCon dc2
         -> do  x'      <- convRValueM kenv tenv x
                x1'     <- convBodyM   kenv tenv x1
                x2'     <- convBodyM   kenv tenv x2

                return  $ vcat
                        [ text "if" <> parens x'
                        , lbrace <> indent 7 x1' <> semi <> line <> rbrace
                        , lbrace <> indent 7 x2' <> semi <> line <> rbrace ]

        -- Case-expression.
        --   In the general case we use the C-switch statement.
        XCase _ x alts
         -> do  x'      <- convRValueM kenv tenv x
                alts'   <- mapM (convAltM kenv tenv) alts

                return  $ vcat
                        [ text "switch" <+> parens x'
                        , lbrace <> indent 1 (vcat alts')
                        , rbrace ]

        _ -> throw $ ErrorBodyInvalid xx


-- | Check whether this primop passes control.
isControlPrim :: Prim -> Bool
isControlPrim pp
 = case pp of
        PrimControl _   -> True
        _               -> False


-- | Check whether this an application of the fail# primop.
isFailX  :: Exp a Name -> Bool
isFailX (XApp _ (XVar _ (UPrim (NamePrim (PrimControl PrimControlFail)) _)) _) = True
isFailX _ = False


-- Alt ------------------------------------------------------------------------
-- | Convert a case alternative to C source text.
convAltM 
        :: Show a 
        => KindEnv Name
        -> TypeEnv Name
        -> Alt a Name 
        -> ConvertM a Doc

convAltM kenv tenv aa
 = case aa of
        AAlt PDefault x1 
         -> do  x1'     <- convBodyM kenv tenv x1
                return  $ vcat
                        [ text "default:" 
                        , lbrace <> indent 5 (x1' <> semi)
                                 <> line
                                 <> rbrace]

        AAlt (PData dc []) x1
         | Just n       <- takeNameOfDaCon dc
         , Just n'      <- convDaConName n
         -> do  x1'     <- convBodyM kenv tenv x1
                return  $ vcat
                        [ text "case" <+> n' <> colon
                        , lbrace <> indent 5 (x1' <> semi)
                                 <> line
                                 <> rbrace]

        AAlt{} -> throw $ ErrorAltInvalid aa


convDaConName :: Name -> Maybe Doc
convDaConName nn
 = case nn of
        NameBool True   -> Just $ int 1
        NameBool False  -> Just $ int 0

        NameNat  i      -> Just $ integer i

        NameInt  i      -> Just $ integer i

        NameWord i bits
         |  elem bits [8, 16, 32, 64]
         -> Just $ integer i

        NameTag i       -> Just $ integer i

        _               -> Nothing


-- RValue ---------------------------------------------------------------------
-- | Convert an r-value to C source text.
convRValueM 
        :: Show a 
        => KindEnv Name 
        -> TypeEnv Name 
        -> Exp a Name 
        -> ConvertM a Doc

convRValueM kenv tenv xx
 = case xx of

        -- Plain variable.
        XVar _ (UName n)
         | NameVar str  <- n
         -> return $ text $ sanitizeName str

        -- Literals
        XCon _ dc
         | DaConNamed n         <- daConName dc
         -> case n of
                NameNat  i      -> return $ integer i
                NameInt  i      -> return $ integer i
                NameWord i _    -> return $ integer i
                NameTag  i      -> return $ integer i
                NameVoid        -> return $ text "void"
                _               -> throw $ ErrorRValueInvalid xx

        -- Primop application.
        XApp{}
         |  Just (NamePrim p, args)        <- takeXPrimApps xx
         -> convPrimCallM kenv tenv p args

        -- Super application.
        XApp{}
         |  Just (XVar _ (UName n), args)  <- takeXApps xx
         ,  NameVar nTop <- n
         -> do  let nTop' = sanitizeName nTop

                -- Ditch type and witness arguments
                args'   <- mapM (convRValueM kenv tenv) 
                        $  filter keepFunArgX args

                return  $ text nTop' <> parenss args'

        -- Type argument.
        XType t
         -> do  t'      <- convTypeM kenv t
                return  $ t'

        _ -> throw $ ErrorRValueInvalid xx


-- | We don't need to pass types and witnesses to top-level supers.
keepFunArgX :: Exp a n -> Bool
keepFunArgX xx
 = case xx of
        XType{}         -> False
        XWitness{}      -> False
        _               -> True


-- Stmt -----------------------------------------------------------------------
-- | Convert an effectful statement to C source text.
convStmtM 
        :: Show a 
        => KindEnv Name
        -> TypeEnv Name 
        -> Exp a Name 
        -> ConvertM a Doc

convStmtM kenv tenv xx
 = case xx of
        -- Primop application.
        XApp{}
          |  Just (NamePrim p, xs) <- takeXPrimApps xx
          -> convPrimCallM kenv tenv p xs

        -- Super application.
        XApp{}
         |  Just (XVar _ (UName n), args)  <- takeXApps xx
         ,  NameVar nTop <- n
         -> do  let nTop'       = sanitizeName nTop

                args'           <- mapM (convRValueM kenv tenv)
                                $  filter keepFunArgX args

                return  $ text nTop' <+> parenss args'

        _ -> throw $ ErrorStmtInvalid xx


-- PrimCalls ------------------------------------------------------------------
-- | Convert a call to a primitive operator to C source text.
convPrimCallM 
        :: Show a 
        => KindEnv Name
        -> TypeEnv Name
        -> Prim 
        -> [Exp a Name] -> ConvertM a Doc

convPrimCallM kenv tenv p xs
 = case p of

        -- Binary arithmetic primops.
        PrimOp op
         | [XType _t, x1, x2]   <- xs
         , Just op'             <- convPrimOp2 op
         -> do  x1'     <- convRValueM kenv tenv x1
                x2'     <- convRValueM kenv tenv x2
                return  $ parens (x1' <+> op' <+> x2')


        -- Cast primops.
        -- TODO: check for valid promotion
        PrimCast PrimCastPromote
         | [XType tTo, XType _tFrom, x1] <- xs
         -> do  tTo'    <- convTypeM   kenv tTo
                x1'     <- convRValueM kenv tenv x1
                return  $  parens tTo' <> parens x1'

        -- TODO: check for valid truncate
        PrimCast PrimCastTruncate
         | [XType tTo, XType _tFrom, x1] <- xs
         -> do  tTo'    <- convTypeM   kenv tTo
                x1'     <- convRValueM kenv tenv x1
                return  $  parens tTo' <> parens x1'


        -- Control primops.
        PrimControl PrimControlReturn
         | [XType _t, x1]       <- xs
         -> do  x1'     <- convRValueM kenv tenv x1
                return  $ text "return" <+> x1'

        PrimControl PrimControlFail
         | [XType _t]           <- xs
         -> do  return  $ text "_fail()"


        -- Store primops.
        PrimStore op
         -> do  let op'  = convPrimStore op
                xs'     <- mapM (convRValueM kenv tenv)
                        $  filter keepArgX xs
                return  $ op' <> parenss xs'


        -- External primops.
        PrimExternal op 
         -> do  let op' = convPrimExternal op
                xs'     <- mapM (convRValueM kenv tenv) 
                        $  filter keepArgX xs
                return  $ op' <> parenss xs'

        _ -> throw $ ErrorPrimCallInvalid p xs


-- | Throw away region arguments.
keepArgX :: Exp a n -> Bool
keepArgX xx
 = case xx of
        XType (TVar _)  -> False
        _               -> True


parenss :: [Doc] -> Doc
parenss xs = encloseSep lparen rparen (comma <> space) xs

