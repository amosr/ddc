
module Type.Util.Quantify
	(quantifyVarsT)
where

import Type.Util.Bits
import Type.Exp
import Util.Graph.Deps
import Util

import qualified Data.Map	as Map
import qualified Data.Set	as Set

import Debug.Trace

-- When quantifying vars we need to arrange that vars free in FMore
--	fetters appear before the bound varaible, else they won't be
--	in scope during type application in the core.
--
-- eg	f :: forall !e2 !e3 !e1
--	  :- ...
--	  ,  !e1 :> !{!e2; !e3 }
--
-- translated to core..
--
--	f = \/ !e2 -> \/ !e3 -> \/ (!e1 :> !{!e2 ; !e3}) -> ...
--                                            ^^^^^^^^^
--	!e2 and !e3 need to have been substituted when the argument
--	for !e1 is applied, else we can't check the effect subsumption.
--

quantifyVarsT :: [(Var, Kind)] -> Type -> Type
quantifyVarsT vks tt@(TFetters fs t)
 = let
	takeVars tt	= [v 	| TVar k v	
				<- flattenTSum tt]

	-- build a map of which vars need to come before others
 	deps		= Map.fromListWith (++) 
			$ concat
			$ [zip (repeat v1) [takeVars ts]
				| FMore (TVar k v1) ts
				<- fs]

	-- sequence the vars according to the dependency map
	vsSequence	= graphSequence deps Set.empty (map fst vks)
	
	-- look the var kinds back up
	vksSequence	= map (\v -> let Just k = lookup v vks
				     in (v, k))
			$ vsSequence
		
   in {- trace (pprStr 	$ "deps       = " % deps % "\n"
   			% "vsSequence = " % vsSequence	% "\n") -}
	-- add the TForall out the front
   	makeTForall vksSequence tt


quantifyVarsT vks tt
	= makeTForall vks tt
