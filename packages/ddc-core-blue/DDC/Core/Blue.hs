
module DDC.Core.Blue
        ( -- * Language profile
          profile

          -- * Names
        , Name          (..)
        , TyConPrim     (..)
        , OpPrimArith   (..)
        , OpPrimRef     (..)

          -- * Name Parsing
        , readName

          -- * Program Lexing
        , lexModuleString
        , lexExpString)

where
import DDC.Core.Blue.Prim
import DDC.Core.Blue.Profile