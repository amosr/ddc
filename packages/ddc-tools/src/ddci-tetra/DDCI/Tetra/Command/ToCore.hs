module DDCI.Tetra.Command.ToCore
        (cmdToCore)
where
import DDCI.Tetra.State
import DDC.Interface.Source
import DDC.Driver.Stage
import DDC.Build.Pipeline   
import DDC.Base.Pretty
import qualified DDC.Driver.Config      as D


-- Convert Disciple Source Tetra text into Disciple Core Tetra.
cmdToCore :: State -> D.Config -> Source -> String -> IO ()
cmdToCore _state config source str
 = let  
        pmode   = D.prettyModeOfConfig $ D.configPretty config

        pipeLoad
         = pipeText (nameOfSource source) (lineStartOfSource source) str
         $ stageSourceTetraLoad config source []
         [ PipeCoreOutput pmode SinkStdout ]

   in do
        errs    <- pipeLoad
        case errs of
         []     -> return ()
         es     -> putStrLn (renderIndent $ ppr es)

