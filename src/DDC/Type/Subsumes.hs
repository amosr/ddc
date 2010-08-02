{-# OPTIONS -fwarn-incomplete-patterns -fwarn-unused-matches -fwarn-name-shadowing #-}
module DDC.Type.Subsumes
	( Subsumes(..)
	, isSubsumes
	, joinSubsumes
	, subsumesTT)
where
import DDC.Type.Exp
import DDC.Type.Equiv
import DDC.Type.Kind
import DDC.Type.Compounds

-- Subsumes ---------------------------------------------------------------------------------------
data Subsumes
	= Subsumes
	| NoSubsumes Type Type
	deriving (Show, Eq)

isSubsumes :: Subsumes -> Bool
isSubsumes eq
 = case eq of
	Subsumes	-> True
	_		-> False

joinSubsumes :: Subsumes -> Subsumes -> Subsumes
joinSubsumes e1 e2
 = case e1 of
	Subsumes	-> e2
	NoSubsumes{}	-> e1


-- Type Subsumption -------------------------------------------------------------------------------

-- | t1 <: t2
subsumesTT :: Type -> Type -> Subsumes
subsumesTT t1 t2
	| TNil		<- t1
	, TNil		<- t2
	= Subsumes

	-- These might contain more-than constraints that we'll need to check
	-- the subsumption, but they'll also be directly attached to the variables.
	| TConstrain t1' _ <- t1
	= subsumesTT t1' t2
	
	| TConstrain t2' _ <- t2
	= subsumesTT t1 t2'

	| TVar _ b1	<- t1
	, TVar _ b2	<- t2
	, takeVarOfBound b1 == takeVarOfBound b2
	= Subsumes

	| TVar _ (UMore _ t2')	<- t2
	= subsumesTT t1 t2'
	
	| TApp t11 t12	<- t1
	, TApp t21 t22	<- t2
	= joinSubsumes (subsumesTT t11 t21) (subsumesTT t12 t22)

	-- Constructors ---------------
	-- Ignore tag variables when checking whether closure constructors are equivalent.
	| TCon (TyConClosure tcc1 _)	<- t1
	, TCon (TyConClosure tcc2 _)	<- t2
	= case (tcc1, tcc2) of
		(TyConClosureFreeType   _, TyConClosureFreeType _)	-> Subsumes
		(TyConClosureFreeRegion _, TyConClosureFreeRegion _)	-> Subsumes
		(TyConClosureFree _,	   TyConClosureFree _)		-> Subsumes
		_							-> NoSubsumes t1 t2

	| TCon tc1	<- t1
	, TCon tc2	<- t2
	, tc1 == tc2
	= Subsumes

	-- Sums -----------------------
	| TSum k1 []		<- t1
	, TSum k2 []		<- t2
	, isRegionKind k1 || isEffectKind k1 || isClosureKind k1
	, isEquiv (equivKK k1 k2)
	= Subsumes

	| TSum k1 _		<- t1
	, TSum _  _		<- t2
	, isRegionKind k1 || isEffectKind k1 || isClosureKind k1
	, isEquiv (equivTT t1 t2)
	= Subsumes
		
	| TSum k2 ts2		<- t2
	, isRegionKind k2 || isEffectKind k2 || isClosureKind k2
	, or $ map (\t2i -> isSubsumes $ subsumesTT t1  t2i) ts2
	= Subsumes

	| TSum k1 ts1		<- t1
	, isRegionKind k1 || isEffectKind k1 || isClosureKind k1
	, and $ map (\t1i -> isSubsumes $ subsumesTT t1i t2)  ts1
	= Subsumes

	-- No dice.
	| otherwise
	= NoSubsumes t1 t2









