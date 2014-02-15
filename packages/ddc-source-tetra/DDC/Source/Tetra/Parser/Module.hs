
module DDC.Source.Tetra.Parser.Module
        ( -- * Modules
          pModule
        , pTypeSig
        
          -- * Top-level things
        , pTop)
where
import DDC.Source.Tetra.Parser.Exp
import DDC.Source.Tetra.Compounds
import DDC.Source.Tetra.DataDef
import DDC.Source.Tetra.Module
import DDC.Source.Tetra.Exp
import DDC.Core.Parser.Type
import DDC.Core.Parser.Context
import DDC.Core.Parser.Base
import DDC.Core.Lexer.Tokens
import DDC.Base.Pretty
import Control.Monad
import qualified DDC.Base.Parser        as P


-- Module ---------------------------------------------------------------------
-- | Parse a core module.
pModule :: (Ord n, Pretty n) 
        => Context
        -> Parser n (Module P.SourcePos n)
pModule c
 = do   _sp     <- pTokSP KModule
        name    <- pModuleName

        -- exports { VAR;+ }
        tExports 
         <- P.choice
            [do pTok KExports
                pTok KBraceBra
                vars    <- P.sepEndBy1 pVar (pTok KSemiColon)
                pTok KBraceKet
                return vars

            ,   return []]

        -- imports { SIG;+ }
        tImports
         <- liftM concat $ P.many (pImportSpecs c)

        pTok KWhere
        pTok KBraceBra

        -- TOP;+
        tops    <- P.sepEndBy (pTop c) (pTok KSemiColon)

        pTok KBraceKet

        -- ISSUE #295: Check for duplicate exported names in module parser.
        --  The names are added to a unique map, so later ones with the same
        --  name will replace earlier ones.
        return  $ Module
                { moduleName                    = name
                , moduleExportedTypes           = []
                , moduleExportedValues          = tExports
                
                , moduleImportedModules         = []
                
                , moduleImportedTypes
                        = [(n, (s, k)) | ImportType  n s k <- tImports]

                , moduleImportedValues
                        = [(n, (s, t)) | ImportValue n s t <- tImports]
                
                , moduleTops                    = tops }


-- | Parse a type signature.
pTypeSig 
        :: Ord n 
        => Context -> Parser n (n, Type n)        

pTypeSig c
 = do   var     <- pVar
        pTok KColonColon
        t       <- pType c
        return  (var, t)


-------------------------------------------------------------------------------
-- | An imported foreign type or foreign value.
data ImportSpec n
        = ImportType    n (ImportSource n) (Kind n)
        | ImportValue   n (ImportSource n) (Type n)
        

-- | Parse some import specs.
pImportSpecs
        :: (Ord n, Pretty n)
        => Context -> Parser n [ImportSpec n]

pImportSpecs c
 = do   pTok KImports
        pTok KForeign
        src    <- liftM (renderIndent . ppr) pName

        P.choice
         [      -- imports foreign X type (NAME :: TYPE)+ 
          do    pTok KType
                pTok KBraceBra

                sigs <- P.sepEndBy1 (pImportType c src) (pTok KSemiColon)
                pTok KBraceKet
                return sigs

                -- imports foreign X value (NAME :: TYPE)+
         , do   pTok KValue
                pTok KBraceBra

                sigs <- P.sepEndBy1 (pImportValue c src) (pTok KSemiColon)
                pTok KBraceKet
                return sigs
         ]


-- | Parse a type import spec.
pImportType
        :: (Ord n, Pretty n)
        => Context -> String -> Parser n (ImportSpec n)
pImportType c src
        | "abstract"    <- src
        = do    n       <- pName
                pTok KColonColon
                k       <- pType c
                return  (ImportType n ImportSourceAbstract k)

        | otherwise
        = P.unexpected "import mode for foreign type"


-- | Parse a value import spec.
pImportValue 
        :: (Ord n, Pretty n)
        => Context -> String -> Parser n (ImportSpec n)
pImportValue c src
        | "c"           <- src
        = do    n       <- pName
                pTok KColonColon
                k       <- pType c

                -- TODO: allow def of foreign symbol
                let symbol = renderIndent (ppr n)

                return  (ImportValue n (ImportSourceSea symbol) k)

        | otherwise
        = P.unexpected "import mode for foreign value"


-- Top Level -----------------------------------------------------------------
pTop    :: Ord n 
        => Context -> Parser n (Top P.SourcePos n)
pTop c
 = P.choice
 [ do   -- A top-level, possibly recursive binding.
        (b, x)          <- pLetBinding c
        let Just sp     = takeAnnotOfExp x
        return  $ TopBind sp b x
 
        -- A data type declaration
 , do   pData c
 ]


-- Data -----------------------------------------------------------------------
-- | Parse a data type declaration.
pData   :: Ord n
        => Context -> Parser n (Top P.SourcePos n)

pData c
 = do   sp      <- pTokSP KData
        n       <- pName
        ps      <- liftM concat $ P.many (pDataParam c)
             
        P.choice
         [ -- Data declaration with constructors that have explicit types.
           do   pTok KWhere
                pTok KBraceBra
                ctors   <- P.sepEndBy1 (pDataCtor c) (pTok KSemiColon)
                pTok KBraceKet
                return  $ TopData sp (DataDef n ps ctors)
         
           -- Data declaration with no data constructors.
         , do   return  $ TopData sp (DataDef n ps [])
         ]


-- | Parse a type parameter to a data type.
pDataParam :: Ord n => Context -> Parser n [Bind n]
pDataParam c 
 = do   pTok KRoundBra
        ns      <- P.many1 pName
        pTokSP (KOp ":")
        k       <- pType c
        pTok KRoundKet
        return  [BName n k | n <- ns]


-- | Parse a data constructor declaration.
--   TODO: More restructive parsing to reject extra quantifiers
--   on the front of data constructor types.
pDataCtor :: Ord n => Context -> Parser n (DataCtor n)
pDataCtor c
 = do   n       <- pName
        pTokSP (KOp ":")
        t       <- pType c
        let (tsArg, tResult)    
                = takeTFunArgResult t

        return  $ DataCtor
                { dataCtorName          = n
                , dataCtorFieldTypes    = tsArg
                , dataCtorResultType    = tResult }

