-- | Compiler stages.
--
--   A compiler 'stage' is a compound pipeline that depends on DDCI specific
--   configuration information. 
--
--   This is where we select optimisation passes based on command line
--   flags, and dump the intermediate representation after the various transforms.
--
--   These stages are then invoked by the DDCI commands.
--
module DDCI.Core.Stage
        ( stageLiteToSalt
        , stageSaltToLLVM
        , stageCompileLLVM)
where
import DDCI.Core.State
import DDC.Build.Builder
import DDC.Build.Pipeline
import DDC.Build.Language
import System.FilePath
import Data.Monoid
import Data.Maybe
import DDC.Core.Simplifier.Recipie      as Simpl
import qualified DDC.Core.Lite.Name     as Lite
import qualified DDC.Core.Salt.Name     as Salt
import qualified DDC.Core.Check         as C


-- | Convert Lite to Salt.
stageLiteToSalt 
        :: State -> Builder 
        -> [PipeCore (C.AnTEC () Salt.Name) Salt.Name] 
        -> PipeCore  (C.AnTEC () Lite.Name) Lite.Name

stageLiteToSalt _state builder pipesSalt
 = PipeCoreAsLite 
   [ PipeLiteOutput       (SinkFile "ddc.lite-loaded.dcl")
   , PipeLiteToSalt       (buildSpec builder)
     [ PipeCoreOutput     (SinkFile "ddc.lite-to-salt.dce")
     , PipeCoreSimplify   fragmentSalt Simpl.anormalize
       [ PipeCoreOutput   (SinkFile "ddc.salt-normalized.dce")
       , PipeCoreCheck    fragmentSalt
         pipesSalt]]]


-- | Convert Salt to LLVM.
stageSaltToLLVM
        :: State -> Builder -> Bool
        -> [PipeLlvm]
        -> PipeCore a Salt.Name

stageSaltToLLVM state builder doTransfer pipesLLVM
 = PipeCoreSimplify       fragmentSalt
                          (stateSimplifier state <> Simpl.anormalize)
   [ PipeCoreOutput       (SinkFile "ddc.salt-simplified.dce")
   , PipeCoreCheck        fragmentSalt
     [ PipeCoreAsSalt
       [ (if doTransfer then PipeSaltTransfer else PipeSaltId)
         [ PipeSaltOutput (SinkFile "ddc.salt-transfer.dce")
         , PipeSaltToLlvm (buildSpec builder) pipesLLVM]]]]


-- | Compile LLVM code.
stageCompileLLVM 
        :: State -> Builder -> FilePath
        -> PipeLlvm

stageCompileLLVM state builder filePath
 = let  -- Decide where to place the build products.
        outputDir      = fromMaybe (takeDirectory filePath) (stateOutputDir state)
        outputDirBase  = dropExtension (replaceDirectory filePath outputDir)
        llPath         = outputDirBase ++ ".ddc.ll"
        sPath          = outputDirBase ++ ".ddc.s"
        oPath          = outputDirBase ++ ".o"
        exePathDefault = outputDirBase
        exePath        = fromMaybe exePathDefault (stateOutputFile state)
   in   -- Make the pipeline for the final compilation.
        PipeLlvmCompile
          { pipeBuilder           = builder
          , pipeFileLlvm          = llPath
          , pipeFileAsm           = sPath
          , pipeFileObject        = oPath
          , pipeFileExe           = Just exePath }

