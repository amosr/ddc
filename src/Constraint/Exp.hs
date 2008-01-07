------
-- Constraint.Exp
--	Functions for source level type constraints.
--
module	Constraint.Exp
	( CTree(..), newCBranch
	, CBind(..) )
	
where

-----
import Util
import Data.Map			(Map)

import Type.Exp
import Shared.Base

-----------------------
-- CTree
--	Data type representing a tree of type constraints.
--
data	CTree
	= -- any empty tree, used as a place holder.
	  CTreeNil				

	-- A branch representing the constraints from a block of code
	--	in the source. If the block binds bariables (eg, a let expression)
	--	then these will be present in the branchBind field.
	| CBranch  
	  { -- vars bound by this branch.
	    branchBind	:: CBind		

	    -- sub constraints
	  , branchSub	:: [CTree] }		


	-- Type definition.
	--	These come from external type definitions and 
	--	interfaces of imported modules.
	| CDef		TypeSource Type Type	

	-- A type signature from the source program.
	--	These give us (partial) information about what this type should be.
	| CSig		TypeSource Type Type	

	-- Type equality constraint.
	--	The LHS should be a TClass or a TVar.
	| CEq		TypeSource Type Type

	-- Type equality constraints, all these types are equal.
	--	These should all be TClass or TVars
	--	Saves having to write a large collection of CEq constraints.
	| CEqs		TypeSource [Type]

	-- A class contraint between types,
	--	eg, Unify, Shape, Inject
	| CClass	TypeSource Var [Type]

	-- A projection constraint
	--	t1 = t2 -(eff clo)> t3
	| CProject	TypeSource TProj Var Type Type Effect Closure

	-- Instantiate a type scheme
	--	var of instance, var of scheme to instantiate.
	| CInst		TypeSource Var Var

	-- Generalise a type scheme
	--	var to generalise
	| CGen		TypeSource Type


	-- dictionaries

	-- Carries data field definitions.
	--	One of these is generated for each data def in the source.
	-- 	type name, type vars, (field name, field type)
	| CDataFields	TypeSource Var [Var] [(Var, Type)]	

	-- Carries a projection dictionary.
	--	Projection type. field var, implementation var.
	| CDictProject	TypeSource Type (Map Var Var)

	-- An instance for a class dictionary. eg, Num (Int (%_))
	| CClassInst	TypeSource Var [Type]

	-- Leave a branch.
	--	The solver uses this to remind itself when all the constraints in a
	--	branch have been added to the graph.
	| CLeave	CBind



	-- Gathers up effect and closure visible at top level.
	--	ie, all effects caused by cafs, and all external vars used by the module.
	--	There should be one of each of these in the constraint list generated
	--	by Desugar.Slurp
	| CTopEffect	Type
	| CTopClosure	Type



	deriving (Show)

newCBranch
	= CBranch
	{ branchBind	= BNil
	, branchSub	= [] }



-- CBind
--	Represents how a variable was bound.

data	CBind

	-- nothing is bound here
	= BNil		
	
	-- delimits the scope of a group of mutually recursive let bindings
	| BLetGroup	[Var]
	
	-- a let bound variable
	| BLet		[Var]
	
	-- a lambda bound variable
	| BLambda	[Var]
	
	-- a decon bound variable
	| BDecon	[Var]
	deriving (Show, Eq, Ord)





