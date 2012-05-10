
module DDC.Core.Salt.Lite.Convert.Type
        ( convertT
        , convertPrimT
        , convertB
        , convertU)
where
import DDC.Core.Salt.Lite.Convert.Base
import DDC.Core.Exp
import DDC.Type.Compounds
import DDC.Type.Predicates
import DDC.Type.Check.Monad                     (throw)
import qualified DDC.Core.Salt.Lite.Name        as L
import qualified DDC.Core.Salt.Output.Name      as O
import qualified DDC.Core.Salt.Output.Env       as O
import Control.Monad


-- Type -----------------------------------------------------------------------
-- | Convert the type of a user-defined function or argument.
convertT     :: Type L.Name -> ConvertM a (Type O.Name)
convertT        = convertT' True

-- | Convert the type of a primop.
--   With primop types we need to keep quantifiers.
convertPrimT :: Type L.Name -> ConvertM a (Type O.Name)
convertPrimT    = convertT' False

-- TODO: It would be better to decide what type arguments to erase 
--       at the binding point of the function, and pass this information down
--       into the tree while we're doing the main conversion.
convertT' :: Bool -> Type L.Name -> ConvertM a (Type O.Name)
convertT' stripForalls tt
 = case tt of
        -- Convert type variables an constructors.
        TVar u          -> liftM TVar (convertU u)
        TCon tc         -> convertTyCon tc

        -- Strip off foralls, as the Brine fragment doesn't care about quantifiers.
        TForall b t     
         | stripForalls -> convertT t
         | otherwise    -> liftM2 TForall (convertB b) (convertPrimT t)

        TApp{}  
         -- Strip off effect and closure information.
         |  Just (t1, _, _, t2)  <- takeTFun tt
         -> liftM2 tFunPE (convertT t1) (convertT t2)

         -- Boxed data values are represented in generic form.
         | otherwise
         -> return $ O.tPtr O.tObj

        -- We shouldn't find any TSums.
        TSum{}          
         | isBot tt     -> throw $ ErrorBotAnnot
         | otherwise    -> throw $ ErrorUnexpectedSum


-- | Convert a simple type constructor to a Brine type.
convertTyCon :: TyCon L.Name -> ConvertM a (Type O.Name)
convertTyCon tc
 = case tc of
        -- Higher universe constructors are passed through unharmed.
        TyConSort    c           -> return $ TCon $ TyConSort    c 
        TyConKind    c           -> return $ TCon $ TyConKind    c 
        TyConWitness c           -> return $ TCon $ TyConWitness c 
        TyConSpec    c           -> return $ TCon $ TyConSpec    c 

        -- Convert primitive TyCons to Brine form.
        TyConBound   (UPrim n _) -> convertTyConPrim n

        -- Boxed data values are represented in generic form.
        TyConBound   _           -> return $ O.tPtr O.tObj


-- | Convert a primitive type constructor to Salt form.
convertTyConPrim :: L.Name -> ConvertM a (Type O.Name)
convertTyConPrim n
 = case n of
        L.NamePrimTyCon pc      
          -> return $ TCon $ TyConBound (UPrim (O.NamePrimTyCon pc) kData)
        _ -> error "toSaltX: unknown prim"


-- Names ----------------------------------------------------------------------
convertB :: Bind L.Name -> ConvertM a (Bind O.Name)
convertB bb
  = case bb of
        BNone t         -> liftM  BNone (convertT t)        
        BAnon t         -> liftM  BAnon (convertT t)
        BName n t       -> liftM2 BName (convertBindNameM n) (convertT t)


convertU :: Bound L.Name -> ConvertM a (Bound O.Name)
convertU uu
  = case uu of
        UIx i t         -> liftM2 UIx   (return i) (convertT t)
        UName n t       -> liftM2 UName (convertBoundNameM n) (convertT t)
        UPrim n t       -> liftM2 UPrim (convertBoundNameM n) (convertPrimT t)
        UHole   t       -> liftM  UHole (convertT t)


convertBindNameM :: L.Name -> ConvertM a O.Name
convertBindNameM nn
 = case nn of
        L.NameVar str   -> return $ O.NameVar str
        _               -> throw $ ErrorInvalidBinder nn


convertBoundNameM :: L.Name -> ConvertM a O.Name
convertBoundNameM nn
 = case nn of
        L.NameVar str           -> return $ O.NameVar str
        L.NamePrimOp op         -> return $ O.NamePrim (O.PrimOp op)
        _               -> error "toSaltX: convertBoundName"