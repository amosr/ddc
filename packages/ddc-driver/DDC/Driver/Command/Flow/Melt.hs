
module DDC.Driver.Command.Flow.Melt
        (cmdFlowMelt)
where
import DDC.Interface.Source
import DDC.Driver.Stage
import DDC.Driver.Config
import DDC.Build.Pipeline
import DDC.Build.Language.Flow
import Control.Monad.Trans.Except
import Control.Monad.IO.Class
import qualified DDC.Core.Check         as C
import qualified DDC.Base.Pretty        as P


-- | Thread a state token through the given flow program.
--     This can't be generic in the language fragment because we
--     need to provide a specific type to use for the world token,
--     and new types for the effectful combinators.
cmdFlowMelt
        :: Config               -- ^ Driver config.
        -> Source               -- ^ Source of the code.
        -> String               -- ^ Program module text.
        -> ExceptT String IO ()

cmdFlowMelt config source sourceText
 = let  pmode   = prettyModeOfConfig $ configPretty config
        
        pipeMelt
         = pipeText (nameOfSource source)
                    (lineStartOfSource source)
                    sourceText
         $ stageFlowLoad  config source 
         [ PipeCoreCheck  fragment C.Recon SinkDiscard
         [ PipeCoreAsFlow 
         [ PipeFlowMelt
         [ PipeCoreCheck  fragment C.Recon SinkDiscard
         [ PipeCoreOutput pmode SinkStdout ]]]]]

   in do
        errs    <- liftIO pipeMelt
        case errs of
         []     -> return ()
         es     -> throwE $ P.renderIndent $ P.vcat $ map P.ppr es



