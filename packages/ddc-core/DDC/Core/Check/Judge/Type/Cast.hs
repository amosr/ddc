
module DDC.Core.Check.Judge.Type.Cast
        (checkCast)
where
import DDC.Core.Check.Judge.Type.Sub
import DDC.Core.Check.Judge.Type.Base
import qualified DDC.Type.Sum   as Sum
import qualified Data.Set       as Set


checkCast :: Checker a n

-- WeakenEffect ---------------------------------------------------------------
-- Weaken the effect of an expression.
checkCast !table !ctx0 xx@(XCast a (CastWeakenEffect eff) x1) mode
 = do   let config      = tableConfig  table
        let kenv        = tableKindEnv table

        -- Check the effect term.
        (eff', kEff, ctx1) 
         <- checkTypeM config kenv ctx0 UniverseSpec eff 
          $ case mode of
                Recon   -> Recon
                Synth   -> Check kEffect
                Check _ -> Check kEffect

        -- Check the body.
        (x1', t1, effs, clo, ctx2)
         <- tableCheckExp table table ctx1 x1 mode

        -- The effect term must have Effect kind.
        when (not $ isEffectKind kEff)
         $ throw $ ErrorWeakEffNotEff a xx eff' kEff

        let c'     = CastWeakenEffect eff'
        let effs'  = Sum.insert eff' effs

        returnX a (\z -> XCast z c' x1')
                t1 effs' clo ctx2
                

-- WeakenClosure --------------------------------------------------------------
-- Weaken the closure of an expression.
--
-- DEPRECATED: Closures are being removed in the next version,
--             so we don't bother doing proper type inference for closure
--             weakenings.
--
checkCast !table !ctx (XCast a (CastWeakenClosure xs) x1) mode
 = do   
        -- Check the contained expressions.
        --  Just ditch the resulting contexts because they shouldn't
        --  contain expression that need types infered.
        (xs', closs, _ctx)
                <- liftM unzip3
                $   mapM (\x -> checkArgM table ctx x Recon) xs

        -- Check the body.
        (x1', t1, effs, clos, ctx1)
                <- tableCheckExp table table ctx x1 mode
        
        let c'     = CastWeakenClosure xs'
        let closs' = Set.unions (clos : closs)

        returnX a (\z -> XCast z c' x1')
                t1 effs closs' ctx1


-- Purify ---------------------------------------------------------------------
-- Purify the effect of an expression.
-- 
-- EXPERIMENTAL: The Tetra language doesn't have purification casts yet,
--               so proper type inference isn't implemented.
-- 
checkCast !table !ctx xx@(XCast a (CastPurify w) x1) mode
 = do   let config      = tableConfig table
        let kenv        = tableKindEnv table
        let tenv        = tableTypeEnv table

        -- Check the witness.
        (w', tW)  <- checkWitnessM config kenv tenv ctx w
        let wTEC  = reannotate fromAnT w'

        -- Check the body.
        (x1', t1, effs, clo, ctx1)
         <- tableCheckExp table table ctx x1 mode

        -- The witness must have type (Pure e), for some effect e.
        effs' <- case tW of
                  TApp (TCon (TyConWitness TwConPure)) effMask
                    -> return $ Sum.delete effMask effs
                  _ -> throw  $ ErrorWitnessNotPurity a xx w tW

        let c'  = CastPurify wTEC
        returnX a (\z -> XCast z c' x1')
                t1 effs' clo ctx1


-- Forget ---------------------------------------------------------------------
-- Forget the closure of an expression.
--
-- DEPRECATED: Closures are being removed in the next version,
--             so we don't bother doing proper type inference for forget casts.
-- 
checkCast !table !ctx xx@(XCast a (CastForget w) x1) mode
 = do   let config      = tableConfig table
        let kenv        = tableKindEnv table
        let tenv        = tableTypeEnv table

        -- Check the witness.
        (w', tW)  <- checkWitnessM config kenv tenv ctx w
        let wTEC  = reannotate fromAnT w'

        -- Check the body.
        (x1', t1, effs, clos, ctx1)  
         <- tableCheckExp table table ctx x1 mode

        -- The witness must have type (Empty c), for some closure c.
        clos' <- case tW of
                  TApp (TCon (TyConWitness TwConEmpty)) cloMask
                    -> return $ maskFromTaggedSet 
                                        (Sum.singleton kClosure cloMask)
                                        clos

                  _ -> throw $ ErrorWitnessNotEmpty a xx w tW

        let c'  = CastForget wTEC
        returnX a (\z -> XCast z c' x1')
                t1 effs clos' ctx1


-- Box ------------------------------------------------------------------------
-- Box a computation,
-- capturing its effects in a computation type.
checkCast !table ctx0 xx@(XCast a CastBox x1) mode
 = case mode of
    Check tExpected
     -> do      
        let config      = tableConfig table

        -- Check the body.
        (x1', tBody, effs, clos, ctx1)     
         <- tableCheckExp table table ctx0 x1 Synth

        -- The actual type is (S eff tBody).
        let tBody'      = applyContext ctx1 tBody
        let tActual     = tApps (TCon (TyConSpec TcConSusp)) [TSum effs, tBody']

        -- The actual type needs to match the expected type.
        -- We're treating the S constructor as invariant in both positions,
        --  so we use 'makeEq' here instead of 'makeSub'
        let tExpected'  = applyContext ctx1 tExpected
        ctx2    <- makeEq config a ctx1 tActual tExpected'
                $  ErrorMismatch a      tActual tExpected' xx

        returnX a (\z -> XCast z CastBox x1')
                tExpected (Sum.empty kEffect) clos ctx2

    -- Recon and Synth mode.
    _
     -> do
        -- Check the body.
        (x1', t1, effs, clos, ctx1) 
         <- tableCheckExp table table ctx0 x1 mode

        -- The result type is (S effs a).
        let tS  = tApps (TCon (TyConSpec TcConSusp))
                        [TSum effs, t1]

        returnX a (\z -> XCast z CastBox x1')
                tS (Sum.empty kEffect) clos ctx1


-- Run ------------------------------------------------------------------------
-- Run a suspended computation,
-- releasing its effects into the environment.
checkCast !table !ctx0 xx@(XCast a CastRun xBody) mode
 = case mode of
    Recon
     -> do
        -- Check the body.
        (xBody', tBody, effs, clos, ctx1)
         <- tableCheckExp table table ctx0 xBody Recon

        -- The body must have type (S eff a),
        --  and the result has type 'a' while unleashing effect 'eff'.
        case tBody of
         TApp (TApp (TCon (TyConSpec TcConSusp)) eff2) tResult
          -> do
                -- Check that the context has the capability to support 
                -- this effect.
                let config      = tableConfig table
                checkEffectSupported config a xx ctx0 eff2

                returnX a
                        (\z -> XCast z CastRun xBody')
                        tResult 
                        (Sum.union effs (Sum.singleton kEffect eff2))
                        clos ctx1

         _ -> throw $ ErrorRunNotSuspension a xx tBody

    Synth
     -> do
        -- Synthesize a type for the body.
        (xBody', tBody, effs, clos, ctx1)
         <- tableCheckExp table table ctx0 xBody Synth

        -- Run the body,
        -- which needs to have been resolved to a computation type.
        let tBody'      = applyContext ctx1 tBody
        (tResult, effsSusp, ctx2)
         <- synthRunSusp table a xx ctx1 tBody'

        returnX a 
                (\z -> XCast z CastRun xBody')
                tResult
                (Sum.union effs (Sum.singleton kEffect effsSusp))
                clos ctx2

    Check tExpected
     -> checkSub table a ctx0 xx tExpected

checkCast _ _ _ _
        = error "ddc-core.checkCast: no match"


-------------------------------------------------------------------------------
-- | Synthesize the type of a run computation.
synthRunSusp
        :: (Show n, Ord n, Pretty n)
        => Table a n
        -> a                    -- Annot for error messages.
        -> Exp a n              -- Cast expression for error messages.
        -> Context n            -- Current context.
        -> Type n               -- Type of suspended computation.
        -> CheckM a n
                ( Type n        -- Type of result value.
                , Effect n      -- Effects unleashed by running the computation.
                , Context n)    -- Result context.

synthRunSusp table a xx ctx0 tt 
 
 -- Rule (Run Synth exists)
 -- If the type of the suspension has not been resolved then we don't know
 -- what effects it has, and thus cannot check if running them is supported
 -- by the context.
 | Just _iFn     <- takeExists tt
 =      throw $ ErrorRunCannotInfer a xx

 -- Rule (Run Synth Susp)
 | TApp (TApp (TCon (TyConSpec TcConSusp)) eff) tResult <- tt
 = do
        -- Check that the context has the capability to support this effect.
        let config      = tableConfig table
        checkEffectSupported config a xx ctx0 eff

        return (tResult, eff, ctx0)

 -- Run expression is not a suspension.
 | otherwise
 =      throw $ ErrorRunNotSuspension a xx tt
 

-- Arg ------------------------------------------------------------------------
-- | Like `checkExp` but we allow naked types and witnesses.
checkArgM 
        :: (Show n, Pretty n, Ord n)
        => Table a n            -- ^ Static config.
        -> Context n            -- ^ Input context.
        -> Exp a n              -- ^ Expression to check.
        -> Mode n               -- ^ Checking mode.
        -> CheckM a n 
                ( Exp (AnTEC a n) n
                , Set (TaggedClosure n)
                , Context n)

checkArgM !table !ctx0 !xx !mode
 = let  config  = tableConfig  table
        tenv    = tableTypeEnv table
        kenv    = tableKindEnv table
   in case xx of
        XType a t
         -> do  (t', k, ctx1) <- checkTypeM config kenv ctx0 UniverseSpec t Recon
                let Just clo = taggedClosureOfTyArg kenv ctx1 t
                let a'   = AnTEC k (tBot kEffect) (tBot kClosure) a
                return  ( XType a' t'
                        , clo
                        , ctx1)

        XWitness a w
         -> do  (w', t) <- checkWitnessM config kenv tenv ctx0 w
                let a'   = AnTEC t (tBot kEffect) (tBot kClosure) a
                return  ( XWitness a' (reannotate fromAnT w')
                        , Set.empty
                        , ctx0)

        _ -> do
                (xx', _, _, clos, ctx1) 
                        <- tableCheckExp table table ctx0 xx mode
                return  (xx', clos, ctx1)
                        

-- Support --------------------------------------------------------------------
-- | Check if the provided effect is supported by the context, 
--   if not then throw an error.
checkEffectSupported 
        :: Ord n 
        => Config n             -- ^ Static config.
        -> a                    -- ^ Annotation for error messages.
        -> Exp a n              -- ^ Expression for error messages.
        -> Context n            -- ^ Input context.
        -> Effect n             -- ^ Effect to check
        -> CheckM a n ()

checkEffectSupported _config a xx ctx eff
 = case effectSupported eff ctx of
        Nothing         -> return ()
        Just effBad     -> throw $ ErrorRunNotSupported a xx effBad
 
