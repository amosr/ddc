
module DDC.Source.Tetra.Module
        ( -- * Modules
          Module        (..)
        , isMainModule
        , ExportSource  (..)
        , ImportSource  (..)

          -- * Module Names
        , QualName      (..)
        , ModuleName    (..)
        , isMainModuleName

          -- * Top-level things
        , Top           (..)

          -- * Data type definitions
        , DataDef       (..))
where
import DDC.Source.Tetra.Exp
import DDC.Source.Tetra.DataDef
import Control.DeepSeq

import DDC.Core.Module          
        ( QualName      (..)
        , ModuleName    (..)
        , isMainModuleName
        , ExportSource  (..)
        , ImportSource  (..))
        

-- Module ---------------------------------------------------------------------
data Module a n
        = Module
        { -- | Name of this module
          moduleName            :: !ModuleName

          -- Exports ----------------------------
          -- | Names of exported types  (level-1).
        , moduleExportTypes     :: [n]

          -- | Names of exported values (level-0).
        , moduleExportValues    :: [n]

          -- Imports ----------------------------
          -- | Imported modules.
        , moduleImportModules   :: [ModuleName]

          -- | Kinds of imported foreign types.
        , moduleImportTypes     :: [(n, ImportSource n)]

          -- | Types of imported foreign values.
        , moduleImportValues    :: [(n, ImportSource n)]

          -- Local ------------------------------
          -- | Top-level things
        , moduleTops            :: [Top a n] }
        deriving Show


instance (NFData a, NFData n) => NFData (Module a n) where
 rnf !mm
        =     rnf (moduleName mm)
        `seq` rnf (moduleExportTypes   mm)
        `seq` rnf (moduleExportValues  mm)
        `seq` rnf (moduleImportModules mm)
        `seq` rnf (moduleImportTypes   mm)
        `seq` rnf (moduleImportValues  mm)
        `seq` rnf (moduleTops          mm)
        

-- | Check if this is the `Main` module.
isMainModule :: Module a n -> Bool
isMainModule mm
        = isMainModuleName
        $ moduleName mm


-- Top Level Thing ------------------------------------------------------------
data Top a n
        -- | Top-level, possibly recursive binding.
        = TopBind a (Bind n) (Exp a n)

        -- | Data type definition.
        | TopData 
        { topAnnot      :: a
        , topDataDef    :: DataDef n }
        deriving Show


instance (NFData a, NFData n) => NFData (Top a n) where
 rnf !top
  = case top of
        TopBind a b x   
         -> rnf a `seq` rnf b  `seq` rnf x
                 
        TopData a def
         -> rnf a `seq` rnf def 

