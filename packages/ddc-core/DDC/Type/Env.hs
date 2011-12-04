
-- | Type environments.
--
--      * TODO: Store the current depth separately, to avoid checking the length all the time in `depth`.
--
module DDC.Type.Env
        ( Env(..)
        , empty
        , extend,       fromList
        , combine
        , member,       memberBind
        , lookup,       lookupName
        , depth)
where
import DDC.Type.Exp
import Data.Maybe
import Data.Map                 (Map)
import Prelude                  hiding (lookup)
import qualified Data.Map       as Map
import qualified Prelude        as P

-- | Type environment used when checking.
data Env n
        = Env
        { envMap        :: Map n (Type n)
        , envStack      :: [Type n] }


-- | An empty environment.
empty :: Env n
empty   = Env
        { envMap        = Map.empty
        , envStack      = [] }


-- | Extend an environment with a new binding.
--   TODO: refactor this so the new binding is on the right.
extend :: Ord n => Bind n -> Env n -> Env n
extend bb env
 = case bb of
         BName n k      -> env { envMap   = Map.insert n k (envMap env) }
         BAnon   k      -> env { envStack = k : envStack env }
         BNone{}        -> env

-- | Convert a list of `Bind`s to an environment.
fromList :: Ord n => [Bind n] -> Env n
fromList bs
        = foldr extend empty bs


-- | Combine two environments, 
--   bindings in the second environment take preference.
combine :: Ord n => Env n -> Env n -> Env n
combine env1 env2
        = Env  
        { envMap        = envMap   env1  `Map.union` envMap   env2
        , envStack      = envStack env1  ++          envStack env2 }


-- | Check whether a bound variable is present in an environment.
member :: Ord n => Bound n -> Env n -> Bool
member uu env
        = isJust $ lookup uu env


-- | Check whether a binder is already present in the an environment.
--   This can only return True for named binders, not anonymous ones.
memberBind :: Ord n => Bind n -> Env n -> Bool
memberBind uu env
 = case uu of
        BName n _       -> Map.member n (envMap env)
        _               -> False


-- | Lookup a bound variable from an environment.
lookup :: Ord n => Bound n -> Env n -> Maybe (Type n)
lookup uu env
 = case uu of
        UName n _       -> Map.lookup n (envMap env)
        UIx i _         -> P.lookup i (zip [0..] (envStack env))


-- | Lookup a bound name from an environment.
lookupName :: Ord n => n -> Env n -> Maybe (Type n)
lookupName n env
        = Map.lookup n (envMap env)


-- | Yield the depth of the debruijn stack.
depth :: Env n -> Int
depth env       = length $ envStack env
