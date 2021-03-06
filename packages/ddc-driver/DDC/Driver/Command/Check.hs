module DDC.Driver.Command.Check
        ( -- * Checking modules. 
          cmdCheckFromFile
        , cmdCheckSourceTetraFromFile
        , cmdCheckSourceTetraFromString
        , cmdCheckCoreFromFile
        , cmdCheckCoreFromString

          -- * Checking types.
        , cmdShowType
        , cmdTypeEquiv
        , cmdParseCheckType

          -- * Checking expressions.
        , Mode(..)
        , ShowSpecMode(..)
        , cmdShowSpec
        , cmdExpRecon
        , cmdParseCheckExp

          -- * Checking witnesses.
        , cmdShowWType)
where
import DDC.Driver.Stage
import DDC.Driver.Output
import DDC.Driver.Config
import DDC.Interface.Source
import DDC.Build.Language
import DDC.Build.Pipeline
import DDC.Core.Fragment
import DDC.Core.Load
import DDC.Core.Parser
import DDC.Core.Lexer
import DDC.Core.Module
import DDC.Core.Exp
import DDC.Core.Pretty
import DDC.Core.Compounds
import DDC.Type.Transform.SpreadT
import DDC.Type.Universe
import DDC.Type.Equiv
import Control.Monad.Trans.Except
import Control.Monad.IO.Class
import qualified DDC.Base.Parser        as BP
import qualified DDC.Type.Check         as T
import qualified DDC.Core.Check         as C
import Control.Monad
import System.FilePath
import System.Directory


-- Module -----------------------------------------------------------------------------------------
-- | Parse and type-check a core module from a file, 
--   printing any errors to @stdout@.
--
--   This function handle fragments of Disciple Core, as well as Source Tetra
--   modules. The language to use is determined by inspecting the file name
--   extension.
--
cmdCheckFromFile
        :: Config               -- ^ Driver config.
        -> FilePath             -- ^ Module file path.
        -> ExceptT String IO ()

cmdCheckFromFile config filePath
 
 -- Check a Disciple Source Tetra module.
 | ".ds"       <- takeExtension filePath
 =      cmdCheckSourceTetraFromFile config filePath

 -- Check a module in some fragment of Disciple Core.
 | Just language <- languageOfExtension (takeExtension filePath)
 =      cmdCheckCoreFromFile config language filePath

 -- Don't know how to check this file.
 | otherwise
 = let  ext     = takeExtension filePath
   in   throwE $ "Cannot check '" ++ ext ++ "'files."


---------------------------------------------------------------------------------------------------
-- | Check a Disciple Source Tetra module from a file.
cmdCheckSourceTetraFromFile
        :: Config               -- ^ Driver config.
        -> FilePath             -- ^ Module file path.
        -> ExceptT String IO ()

cmdCheckSourceTetraFromFile config filePath
 = do
        -- Check that the file exists.
        exists <- liftIO $ doesFileExist filePath
        when (not exists)
         $ throwE $ "No such file " ++ show filePath

        -- Read in the source file.
        src     <- liftIO $ readFile filePath

        cmdCheckSourceTetraFromString config (SourceFile filePath) src


---------------------------------------------------------------------------------------------------
-- | Check a Disciple Source Tetra module from a string.
--   Any errors are thrown in the `ExceptT` monad.
cmdCheckSourceTetraFromString
        :: Config               -- ^ Driver config.
        -> Source               -- ^ Source of the code.
        -> String               -- ^ Program module text.
        -> ExceptT String IO ()

cmdCheckSourceTetraFromString config source str
 = let
        pmode   = prettyModeOfConfig $ configPretty config

        pipeLoad
         = pipeText     (nameOfSource source) (lineStartOfSource source) str
         $ stageSourceTetraLoad config source []
         [ PipeCoreOutput pmode SinkDiscard ]
   in do
        errs    <- liftIO pipeLoad
        case errs of
         [] -> return ()
         es -> throwE $ renderIndent $ vcat $ map ppr es
 

---------------------------------------------------------------------------------------------------
-- | Check some fragment of Disciple core from a file.
cmdCheckCoreFromFile
        :: Config               -- ^ Driver config.
        -> Language             -- ^ Core language definition.
        -> FilePath             -- ^ Module file path.
        -> ExceptT String IO ()

cmdCheckCoreFromFile config language filePath
 | Language bundle      <- language
 , fragment             <- bundleFragment bundle
 = do
        mModule <- liftIO 
                $ loadModuleFromFile fragment filePath 
                $ (if configInferTypes config then C.Synth else C.Recon)
        
        case mModule of
                (Left  err, _ct) -> throwE (renderIndent $ ppr err)
                (Right _,   _ct) -> return ()


-- | Parse and type-check a core module from a string.
cmdCheckCoreFromString
        :: (Ord n, Show n, Pretty n, Pretty (err (AnTEC BP.SourcePos n)))
        => Fragment n err       -- ^ Language fragment.
        -> Source               -- ^ Source of the program text.
        -> String               -- ^ Program text.
        -> C.Mode n             -- ^ Type checker mode.
        -> ExceptT String IO (Module (AnTEC BP.SourcePos n) n)

cmdCheckCoreFromString fragment source str mode
 = do   
        let mModule = loadModuleFromString fragment
                        (nameOfSource source) (lineStartOfSource source)
                        mode str

        case mModule of
                (Left err, _ct) -> throwE (renderIndent $ ppr err)
                (Right mm, _ct) -> return mm


-- Type -------------------------------------------------------------------------------------------
-- | Parse a core spec, and return its kind.
cmdParseCheckType 
        :: (Ord n, Show n, Pretty n, Pretty (err (AnTEC BP.SourcePos n)))
        => Fragment n err       -- ^ Language fragment.
        -> Universe             -- ^ Universe this type is supposed to be in.
        -> Source               -- ^ Source of the program text.
        -> String               -- ^ Program text.
        -> IO (Maybe (Type n, Kind n))

cmdParseCheckType fragment uni source str
 = let  srcName = nameOfSource source
        srcLine = lineStartOfSource source
        toks    = fragmentLexExp fragment srcName srcLine str
        eTK     = loadTypeFromTokens fragment uni srcName toks
   in   case eTK of
         Left err       
          -> do outDocLn $ ppr err
                return Nothing

         Right (t, k)
          ->    return $ Just (t, k)


-- | Show the type of a type in the given universe.
cmdShowType :: Language -> Universe -> Source -> String -> IO ()
cmdShowType language uni source str
 | Language bundle      <- language
 , fragment             <- bundleFragment  bundle
 = let  srcName = nameOfSource source
        srcLine = lineStartOfSource source
        toks    = fragmentLexExp fragment srcName srcLine str
        eTK     = loadTypeFromTokens fragment uni srcName toks
   in   case eTK of
         Left err       -> outDocLn $ ppr err
         Right (t, k)   -> outDocLn $ ppr t <+> text "::" <+> ppr k


-- tequiv -----------------------------------------------------------------------------------------
-- | Check if two types are equivlant.
cmdTypeEquiv :: Language -> Source -> String -> IO ()
cmdTypeEquiv language source ss
 | Language bundle      <- language
 , fragment             <- bundleFragment  bundle
 , profile              <- fragmentProfile fragment
 = let  srcName = nameOfSource source
        srcLine = lineStartOfSource source
        
        goParse toks
         = case BP.runTokenParser describeTok (nameOfSource source)
                        (do t1 <- pTypeAtom (contextOfProfile profile)
                            t2 <- pTypeAtom (contextOfProfile profile)
                            return (t1, t2))
                        toks
            of Left err -> outDocLn $ text "parse error " <> ppr err
               Right tt -> goEquiv tt
         
        goEquiv (t1, t2)
         = do   b1 <- checkT t1
                b2 <- checkT t2
                if b1 && b2 
                 then outStrLn $ show $ equivT t1 t2    
                 else return ()


        config  = T.configOfProfile profile
        kenv    = profilePrimKinds    profile

        checkT t
         = case T.checkSpec config kenv (spreadT kenv t) of
                Left err 
                 -> do  outDocLn $ ppr err
                        return False

                Right{} 
                 ->     return True

   in goParse (fragmentLexExp fragment srcName srcLine ss)


-- Exp --------------------------------------------------------------------------------------------
-- | Parse the given core expression, 
--   and return it, along with its type, effect and closure.
--
--   If the expression had a parse error, undefined vars, or type error
--   then print this to the console.
--
--   We include a flag to override the language profile to allow partially
--   applied primitives. Although a paticular evaluator (or backend) may not
--   support partially applied primitives, we want to accept them if we are
--   only loading an expression to check its type.
--
cmdParseCheckExp 
        :: (Ord n, Show n, Pretty n, Pretty (err (AnTEC BP.SourcePos n)))
        => Fragment n err       -- ^ The current language fragment.
        -> ModuleMap (AnTEC () n) n -- ^ Current modules
        -> Mode n               -- ^ Type checker mode.
        -> Bool                 -- ^ Print type checker trace.
        -> Bool                 -- ^ Allow partial application of primitives.
        -> Source               -- ^ Where this expression was sourced from.
        -> String               -- ^ Text to parse.
        -> IO ( Maybe (Exp (AnTEC BP.SourcePos n) n)
              , Maybe CheckTrace)

cmdParseCheckExp 
        fragment modules 
        mode printTrace permitPartialPrims 
        source str
 = goLex
 where
        -- Override profile to allow partially applied primitives if we were
        -- told to do so.
        profile   = fragmentProfile fragment
        features  = profileFeatures profile
        features' = features { featuresPartialPrims 
                             = featuresPartialPrims features || permitPartialPrims}
        profile'  = profile  { profileFeatures  = features' }
        fragment' = fragment     { fragmentProfile  = profile'  }

        goLex 
         = goLoad (fragmentLexExp fragment'
                        (nameOfSource source) 
                        (lineStartOfSource source) 
                        str)

        -- Parse and type check the expression.
        goLoad toks
         = case loadExpFromTokens fragment' modules 
                        (nameOfSource source) mode toks of
              (Left err, mct)
               -> do    outDocLn $ ppr err
                        
                        case mct of
                         Just ct 
                          | printTrace  -> outDocLn $ ppr ct
                         _              -> return ()
                        
                        return (Nothing, mct)

              (Right result, mct)
               -> return (Just result, mct)


---------------------------------------------------------------------------------------------------
-- | What components of the checked type to display.
data ShowSpecMode
        = ShowSpecAll
        | ShowSpecData
        | ShowSpecEffect
        | ShowSpecClosure
        deriving (Eq, Show)


-- | Show the spec of an expression.
cmdShowSpec
        :: Language     -- ^ Language fragment.
        -> ShowSpecMode -- ^ What part of the type to show.
        -> Bool         -- ^ Type checker mode, Synth(True) or Recon(False)
        -> Bool         -- ^ Whether to display type checker trace.
        -> Source       -- ^ Source of the program text.
        -> String       -- ^ Program text.
        -> IO ()

cmdShowSpec language showMode checkMode shouldPrintTrace source ss
 | Language bundle      <- language
 , fragment             <- bundleFragment  bundle
 , modules              <- bundleModules   bundle
 =   cmdParseCheckExp fragment modules mode shouldPrintTrace True source ss 
 >>= goResult fragment
 where
        -- Determine the checker mode based on the flag we're given.
        -- We don't pass the mode directly because the Mode type is
        -- also parameterised over the type of names.
        mode    = case checkMode of
                        True    -> Synth
                        False   -> Recon

        goResult fragment (Just x, Just ct)
         = let  annot    = annotOfExp x
                t        = annotType annot
                eff      = annotEffect annot
                clo      = annotClosure annot
                features = profileFeatures $ fragmentProfile fragment

           in case showMode of
                ShowSpecAll
                 -> do  outDocLn $ ppr x
                        outDocLn $ text ":*:" <+> ppr t
                        
                        when (featuresTrackedEffects  features)
                         $ outDocLn $ text ":!:" <+> ppr eff

                        when (featuresTrackedClosures features)
                         $ outDocLn $ text ":$:" <+> ppr clo

                        when shouldPrintTrace 
                         $ do   outDocLn $ checkTraceDoc ct
                                outDoc (text "\n")

                ShowSpecData
                 ->     outDocLn $ ppr x <+> text "::" <+> ppr t
        
                ShowSpecEffect
                 ->     outDocLn $ ppr x <+> text ":!:" <+> ppr eff

                ShowSpecClosure
                 ->     outDocLn $ ppr x <+> text ":$:" <+> ppr clo

        goResult _ _
         = return ()


-- Recon ------------------------------------------------------------------------------------------
-- | Check expression and reconstruct type annotations on binders.
cmdExpRecon :: Language -> Source -> String -> IO ()
cmdExpRecon language source ss
 | Language bundle      <- language
 , fragment             <- bundleFragment  bundle
 , modules              <- bundleModules   bundle
 =   cmdParseCheckExp fragment modules Recon False True source ss 
 >>= goResult
 where
        goResult (Nothing, _ct)
         = return ()

        goResult (Just x,  _ct)
         = outDocLn $ ppr x


-- wtype ------------------------------------------------------------------------------------------
-- | Show the type of a witness.
cmdShowWType :: Language -> Source -> String -> IO ()
cmdShowWType language source str
 | Language bundle      <- language
 , fragment             <- bundleFragment  bundle
 = let  srcName = nameOfSource source
        srcLine = lineStartOfSource source
        toks    = fragmentLexExp fragment srcName srcLine str
        eTK     = loadWitnessFromTokens fragment srcName toks
   in   case eTK of
         Left err       -> outDocLn $ ppr err
         Right (t, k)   -> outDocLn $ ppr t <+> text "::" <+> ppr k

