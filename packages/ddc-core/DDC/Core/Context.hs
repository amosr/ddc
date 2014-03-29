
module DDC.Core.Context
        ( Context (..)
        , enterLAM
        , enterLam
        , enterAppLeft
        , enterAppRight
        , enterLetBody
        , enterCaseScrut)
where
import DDC.Core.Exp.Annot
import DDC.Core.Exp.AnnotCtx
import DDC.Core.Compounds
import DDC.Type.Env             (KindEnv, TypeEnv)
import qualified DDC.Type.Env   as Env


data Context a n
        = Context
        { contextKindEnv        :: KindEnv n
        , contextTypeEnv        :: TypeEnv n 
        , contextCtx            :: Ctx a n }


-- | Enter the body of a type lambda.
enterLAM 
        :: Ord n => Context a n
        -> a -> Bind n -> Exp a n
        -> (Context a n -> Exp a n -> b) -> b

enterLAM c a b x f
 = let  c' = c  { contextKindEnv = Env.extend b (contextKindEnv c)
                , contextCtx     = CtxLAM (contextCtx c) a b }
   in   f c' x


-- | Enter the body of a value lambda.
enterLam
        :: Ord n => Context a n
        -> a -> Bind n -> Exp a n
        -> (Context a n -> Exp a n -> b) -> b

enterLam c a b x f
 = let  c' = c  { contextTypeEnv = Env.extend b (contextTypeEnv c) 
                , contextCtx     = CtxLam (contextCtx c) a b }
   in   f c' x


-- | Enter the left of an application.
enterAppLeft   
        :: Context a n
        -> a -> Exp a n -> Exp a n
        -> (Context a n -> Exp a n -> b) -> b

enterAppLeft c a x1 x2 f
 = let  c' = c  { contextCtx     = CtxAppLeft (contextCtx c) a x2 }

   in   f c' x1


-- | Enter the right of an application.
enterAppRight
        :: Context a n
        -> a -> Exp a n -> Exp a n
        -> (Context a n -> Exp a n -> b) -> b

enterAppRight c a x1 x2 f
 = let  c' = c  { contextCtx    = CtxAppRight (contextCtx c) a x1 }
   in   f c' x2


-- | Enter the body of a let-expression.
enterLetBody
        :: Ord n => Context a n 
        -> a -> Lets a n -> Exp a n
        -> (Context a n -> Exp a n -> b) -> b

enterLetBody c a lts x f
 = let  (bs1, bs0) = bindsOfLets lts
        c' = c  { contextKindEnv  = Env.extends bs1 (contextKindEnv c)
                , contextTypeEnv  = Env.extends bs0 (contextTypeEnv c)
                , contextCtx      = CtxLetBody (contextCtx c) a lts }
   in   f c' x


-- | Enter the scrutinee of a case-expression.
enterCaseScrut
        :: Context a n
        -> a -> Exp a n -> [Alt a n]
        -> (Context a n -> Exp a n -> b) -> b

enterCaseScrut c a x alts f
 = let  c' = c  { contextCtx     = CtxCaseScrut (contextCtx c) a alts }
   in   f c' x



