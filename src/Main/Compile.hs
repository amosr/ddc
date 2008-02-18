module Main.Compile
	( compileFile )

where

-----
import qualified System.IO		as System
import qualified System.Posix		as System
import qualified System.Cmd		as System
import qualified System.Exit		as System
import System.Time

import qualified Control.Exception	as Exception

import qualified Data.Map		as Map
import qualified Data.Set		as Set

import GHC.IOBase

-----
import qualified Shared.Var		as Var
import Shared.Var			(Module(..), NameSpace(..))
import Shared.Error

import qualified Main.Arg		as Arg
import Main.Arg 			(Arg)

import qualified Module.Graph		as M
import qualified Module.Export		as ME
import Module.IO			(munchFileName, chopOffExt)

import Main.IO				as SI
import Main.Source			as SS
import Main.Core			as SC
import Main.Sea				as SE
import Main.Dump			as SD
import Main.Invoke

import Source.Slurp			as S

import qualified Source.Pragma		as Pragma

import Main.Path
import qualified Main.Build		as Build

import qualified Core.Util.Slurp	as C
import qualified Core.Plate.FreeVars	as C

import qualified Type.Plate.FreeVars	as T

import qualified Desugar.Plate.Trans	as D
import qualified Sea.Util		as E

import Debug.Trace

import Util
import Numeric

out 	ss	= putStr $ pprStr ss
outl   ss	= putStr $ pprStr $ ss % "\n"

-----
-----
-- compileFile
--	Top level compilation function.
--	Compiles one source file.
--
--	Returns a list of module names and the paths to their compiled object files.
--	
--
compileFile 
	:: [Arg] 	-- DDC args from the command line
	-> FilePath	-- path to source file
	-> IO ()

compileFile	argsCmd     fileName_
 = do 
	-- Initialisation ------------------------------------------------------
	let  ?verbose	= or $ map (== Arg.Verbose) argsCmd

	-- this is the base of our installation
	--	it should contain the /runtime and /library subdirs.
	let pathBase_	= concat 
			$ [dirs | Arg.PathBase dirs	<- argsCmd]

	-- if no base path is specified then look in the current directory.
	let pathBase 	= if pathBase_ == []
				then ["."]
				else pathBase_

	-- use the pathBase args and see if we can find the base library and the runtime system.
	let pathLibrary_test = map (++ "/library") pathBase
	mPathLibrary	<- liftM (liftM fst)
			$  SI.findFile pathLibrary_test
			$ "Base.di"
	
	let pathRuntime_test = map (++ "/runtime") pathBase
	mPathRuntime	<- liftM (liftM fst)
			$  SI.findFile pathRuntime_test
			$ "ddc-runtime.so"

	-- normalise the source file name
	let fileName
		= case fileName_ of
			('/':_)	-> fileName_
			('~':_)	-> fileName_
			_	-> "./" ++ fileName_

	-- say hello
	when ?verbose 
	 $ do	out	$ "  * Compiling " % fileName % "\n"
			% "    - pathBase    = " % pathBase	% "\n"
			% "    - pathLibrary = " % mPathLibrary	% "\n"
			% "    - pathRuntime = " % mPathRuntime  % "\n\n"

	
	-- if /runtime and /library can't be found then die with an appropriate error
	when (isNothing mPathLibrary)
	 $ dieWithUserError 
	 	[ "Can't find the DDC base library.\n"
		% "    Please supply a '-basedir' option to specify the directory\n"
		% "    containing 'library/Base.di'\n"
		% "\n"
	 	% "    tried:\n" %> ("\n" %!% pathLibrary_test) % "\n\n"
		% "    use 'ddc -help' for more information\n"]
	
	let Just pathLibrary	= mPathLibrary

	when (isNothing mPathRuntime)
	 $ dieWithUserError 
	 	[ "Can't find the DDC runtime system.\n"
		% "    Please supply a '-basedir' option to specify the directory\n"
		% "    containing 'runtime/ddc-runtime.so'\n"
		% "\n"
	 	% "    tried:\n" %> ("\n" %!% pathRuntime_test) % "\n\n"
		% "    use 'ddc -help' for more information\n"]

	let Just pathRuntime	= mPathRuntime
	
	-- Load build files ------------------------------------------------------
	
	-- Break out the file name
 	let Just (fileDir_, fileBase, fileExt)
			= munchFileName fileName

	let fileDir	= if fileDir_ == []
				then "."
				else fileDir_

	let Just pathSourceBase	= chopOffExt fileName

	-- See if there is a build file
	--	For some source file,             ./Thing.ds
	--	the build file should be called   ./Thing.build
	--
	let buildFilePath	= fileDir ++ "/" ++ fileBase ++ ".build"
	when ?verbose
	 (do	putStr $ "  * Checking for build file " ++ buildFilePath ++ "\n")

	mBuild		<- Build.loadBuildFile buildFilePath

	when ?verbose
	 (case mBuild of
	 	Nothing		-> putStr $ "    - none\n\n"
		Just build	-> putStr $ " " ++ show build ++ "\n\n")


	-- Load extra args from the build file
	let argsBuild	= case mBuild of
				Just build	-> Arg.parse $ catInt " " $ Build.buildExtraDDCArgs build
				Nothing		-> []

	let args	= argsCmd ++ argsBuild
	when ?verbose
	 $ do	putStr	$ "  * Compile options are:\n"

		putStr  $ concat 
			$ map (\s -> "    " ++ s ++ "\n") 
			$ map show args

		putStr 	$ "\n"


	-- Decide on module names  ---------------------------------------------

	-- Gather up all the import dirs.
	let importDirs	
		= pathLibrary
		: (concat $ [dirs | Arg.ImportDirs dirs <- args])

	-- Choose a name for this module.
	let Just moduleName	
			= chooseModuleName 
				importDirs
				fileName
	when ?verbose
	 $ do  	putStr	$  "  * Choosing module name\n"
	 	putStr	$  "    - fileName      = " ++ fileName			++ "\n"
			++ "    - fileDir       = " ++ fileDir			++ "\n"
			++ "    - fileBase      = " ++ fileBase			++ "\n"
	 		++ "    - moduleName    = " ++ pprStr moduleName	++ "\n"
			++ "\n"
		
	let filePaths	= makePaths (fileDir ++ "/" ++ fileBase)
	let  ?args	= Arg.ArgPath filePaths : args

	-- Load the source file
	sSource		<- readFile fileName

	compileFile_parse 
		pathLibrary pathRuntime
		fileName pathSourceBase filePaths moduleName importDirs 
		mBuild   sSource


compileFile_parse 
	pathLibrary pathRuntime
	fileName pathSourceBase filePaths moduleName importDirs 
	mBuild   sSource

 -- Emit a nice error message if the source file is empty.
 --	If we parse an empty file to happy it will bail with "reading EOF!" which isn't as nice.
 | words sSource == []
 = exitWithUserError ?args [fileName % "\n    Source file is empty.\n"]

 | otherwise
 = do

	-- Chase down imports --------------------------------------------------

	-- Parse the source file.
	sParsed		<- SS.parse 
				fileName
				sSource

	-- Check if we're supposed to import the prelude
	let importPrelude	
			= not $ elem Arg.NoImplicitPrelude ?args

	-- Slurp out the list of modules directly imported by the source file.
	let importsRoot	= S.slurpImportModules
				sParsed
			++ if importPrelude
				then [ModuleAbsolute ["Prelude"]]
				else []
	when ?verbose
	 $ do	out 	$ "  * Chasing imported modules.\n"
	 		% "    - direct imports   = " % importsRoot 	% "\n"
			% "    - import dirs      = " % importDirs	% "\n"


	-- Recursively chase down all modules needed by this one.
	importsExp	<- SI.chaseModules
				importDirs
				importsRoot

	when ?verbose
	 $ do	putStr	$ "    - recursive imports:\n"
	 	mapM_ dumpImportDef $ Map.elems importsExp
		putStr	$ "\n"
	
	-- Dump a nice graph of the module hierarchy.
	let modulesCut	= concat
			$ [ss | Arg.GraphModulesCut ss <- ?args]
			
	SD.dumpDot Arg.GraphModules
		"modules"
		(M.dotModuleHierarchy 
			moduleName
			modulesCut 
			importsRoot
			importsExp)


	-- Slurp out pragmas
	let pragmas	= Pragma.slurpPragmaTree sParsed

	-- Chase down extra C header files to include into source via pragmas.
	let includeFilesHere	= [ str | Pragma.PragmaCCInclude str <- pragmas]
	
	when ?verbose
	 $ do	mapM_ (\path -> putStr $ pprStr $ "  - included file   " % path % "\n")
	 		$ includeFilesHere
	 	

	------------------------------------------------------------------------
	-- Source Stages
	------------------------------------------------------------------------

	-- slurp out name of vars to inline
	inlineVars	<- SS.sourceSlurpInlineVars sParsed


	
	-- Rename variables and add uniqueBinds.
	((_, sRenamed) : modHeaderRenamedTs)
			<- SS.rename
				$ (moduleName, sParsed) 
				:[ (SI.idModule int, SI.idInterface int)
					| int <- Map.elems importsExp ]
	
	let hRenamed	= concat 
			$ [tree	| (mod, tree) <- modHeaderRenamedTs ]
			
	-- Slurp out header information and fixity defs.
	fixTable	<- SS.sourceSlurpFixTable
				(sRenamed ++ hRenamed)
	
	-- Defix the source.
	sDefixed	<- SS.defix
				sRenamed
				fixTable


	-- Slurp out kind table
	hKinds		<- SS.sourceKinds (sDefixed ++ hRenamed)
	
	-- Rename aliased instance functions
	--	and change main() to traumaMain()
	sAliased	<- SS.alias sDefixed

	-- Desugar the source language
	(sDesugared, hDesugared)
			<- SS.desugar
				hKinds
				sAliased
				hRenamed

	-- Snip down dictionaries and add default projections.
	(dProject, projTable)	
			<- SS.desugarProject
				moduleName
				hDesugared
				sDesugared
				

	------------------------------------------------------------------------
	-- Type stages
	------------------------------------------------------------------------

	-- Slurp out type constraints.
	when ?verbose
	 $ do	putStr	$ "  * Desugar: Slurp\n"

	(  sTagged
	 , sConstrs
	 , sigmaTable
	 , vsTypesPlease
	 , vsBound_source)
			<- SS.slurpC 
				dProject
				hDesugared

	let hTagged	= map (D.transformN (\n -> Nothing)) hDesugared

	-- !! Early exit on StopConstraint
	when (elem Arg.StopConstraint ?args)
		compileExit

	when ?verbose
	 $ do	putStr $ "  * Type: Solve\n"

	-- Solve type constraints
	(  typeTable
	 , typeInst
	 , typeQuantVars
	 , vsFree
	 , vsRegionClasses 
	 , vsProjectResolve)
	 		<- runStage "solve"
			$  SS.solveSquid
				sConstrs
				vsTypesPlease
				sigmaTable

	-- !! Early exit on StopType
	when (elem Arg.StopType ?args)
		compileExit

	when ?verbose
	 $ do	putStr $ "  * Desugar: ToCore\n"
		
	-- Convert source tree to core tree
	(  cSource
	 , cHeader )	<- runStage "core"
	 		$ SS.toCore
		 		sTagged
				hTagged
				sigmaTable
				typeTable
				typeInst
				typeQuantVars
				projTable
				vsProjectResolve

	-- Slurp out the list of all the vars defined at top level.
	let topVars	= Set.union 
				(Set.fromList $ concat $ map C.slurpBoundVarsP cSource)
				(Set.fromList $ concat $ map C.slurpBoundVarsP cHeader)	

	-- These are the TREC vars which are free in the type of a top level binding
	let vsFreeTREC	= Set.unions
			$ map (T.freeVars)
			$ [t	| (v, t)	<- Map.toList typeTable
				, Set.member v vsBound_source]

	------------------------------------------------------------------------
	-- Core stages
	------------------------------------------------------------------------	

	-- Convert to normal form
	when ?verbose
	 $ do	putStr $ "  * Core: Normalise Do Exprs\n"

	cNormalise	<- SC.coreNormalDo "core-normaldo" "CN" cSource
				
	-- Create local regions.
	when ?verbose
	 $ do	putStr $ "  * Core: Bind\n"

	-- these regions have global scope
	let rsGlobal	= Set.filter (\v -> Var.nameSpace v == NameRegion) 
			$ vsFreeTREC
	
	cBind		<- SC.coreBind "CB"
				vsRegionClasses
				rsGlobal
				cNormalise

	-- Convert to A-normal form
	cSnip		<- SC.coreSnip "core-snip" "CS" topVars cBind

	-- Thread through witnesses
	cThread		<- SC.coreThread cHeader cSnip

	-- Check type information and add annotations to each stmt.
	when ?verbose
	 $ do	putStr $ "  * Core: Reconstruct\n"

	cReconstruct	<- runStage "reconstruct"
			$ SC.coreReconstruct "core-reconstruct" cHeader cThread

	-- lint: 
	when ?verbose
	 $ do	putStr $ "  * Core: Lint\n"

	SC.coreLint "core-lint-reconstruct" cReconstruct cHeader
	
	
	-- Call class instance functions and add dictionaries.
	when ?verbose
	 $ do	putStr $ "  * Core: Dict\n"

	cDict		<- SC.coreDict 
				cHeader
				cReconstruct

	-- Identify primitive operations
	cPrim		<- SC.corePrim	cDict

	-----------------------
	-- Optimisations
	-- 
	when ?verbose
	 $ do	putStr $ "  * Core: Optimise\n"


	-- Inline forced inline functions
	cInline		<- SC.coreInline
				cPrim
				cHeader
				inlineVars

	-- Perform simplification
	cSimplify	<- if elem Arg.OptSimplify ?args
				then SC.coreSimplify "CI" topVars cInline cHeader
				else return cInline
	
	-- Do the full laziness optimisation.
	cFullLaziness	<- SC.coreFullLaziness 
				moduleName
				cSimplify
				cHeader



	----------------------
	-- 

	-- Check the program one last time
	--	Lambda lifting doesn't currently preserve the typing.
	--
	cReconstruct2	<- runStage "reconstruct2"
			$  SC.coreReconstruct  "core-reconstruct2" cHeader cFullLaziness


	-- Perform lambda lifting.
	when ?verbose
	 $ do	putStr $ "  * Core: Lift\n"

	(  cLambdaLift
	 , vsLambda_new) <- SC.coreLambdaLift
				cReconstruct2
				cHeader

--	Can't lint the code after lifting, lifter doesn't preserve
--	kinds of witness variables.
--  	runStage "lint-lifted" 
--		$ SC.coreLint "core-lint-lifted" cLambdaLift cHeader

	
	-- Slurp out ctor defs
	let mapCtorDefs	= Map.union
				(C.slurpCtorDefs cLambdaLift)
				(C.slurpCtorDefs cHeader)
				
	-- Convert field labels to field indicies
	cLabelIndex	<- SC.coreLabelIndex
				mapCtorDefs
				cLambdaLift
				
	-- Sequence bindings and CAFs
	cSequence	<- SC.coreSequence	
				cLabelIndex
				cHeader
				
				
	-- Resolve partial applications.
	(cCurry, cafVars)
			<- SC.curryCall
				cSequence
				cHeader

	-- Rewrite so atoms are shared.
	cAtomise	<- if elem Arg.OptAtomise ?args
				then SC.coreAtomise cCurry cHeader
				else return cCurry
	
	-- Generate the module interface
	--
	diInterface	<- ME.makeInterface
				moduleName
				sRenamed
				dProject
				cAtomise
				sigmaTable
				typeTable
				vsLambda_new

	writeFile (pathDI filePaths)	diInterface	


	-- !! Early exit on StopCore
	when (elem Arg.StopCore ?args)
		compileExit

	-- Convert to Sea code.
	-- Perform lambda lifting.
	when ?verbose
	 $ do	putStr $ "  * Core: ToSea\n"

	(eSea, eHeader)	<- SC.toSea
				"TE"
				cAtomise
				cHeader
				
	------------------------------------------------------------------------
	-- Sea stages
	------------------------------------------------------------------------
		
	-- Eliminate simple v1 = v2 statements.
	eSub		<- SE.seaSub
				eSea
				
	-- Expand out constructors.
	eCtor		<- SE.seaCtor
				eSub
				
	-- Expand out thunking.
	eThunking	<- SE.seaThunking
				eCtor
				
	-- Add suspension forcing code.
	eForce		<- SE.seaForce
				eThunking
				
	-- Add GC slots and fixup calls to CAFS
	eSlot		<- SE.seaSlot	
				eForce
				eHeader
				cafVars

	-- Flatten out match stmts.
	eFlatten	<- SE.seaFlatten
				"EF"
				eSlot

	-- Generate module initialisation functions.
	eInit		<- SE.seaInit
				moduleName
				eFlatten

	-- Generate C source code
	(  seaHeader
	 , seaSource )	<- SE.outSea
				moduleName
	 			eInit
				fileName
				[ SI.idFileRelPathH e | e <- Map.elems importsExp ]
				includeFilesHere


	-- If this module binds the top level main function
	--	then append RTS initialisation code.
	--
	seaSourceInit	<- if SE.gotMain eInit 
				then do mainCode <- SE.seaMain $ map fst $ Map.toList importsExp
				     	return 	$ seaSource ++ (catInt "\n" $ map pprStr $ E.eraseAnnotsTree mainCode)
				else 	return  $ seaSource
				
	writeFile (pathC filePaths)	seaSourceInit
	writeFile (pathH filePaths)	seaHeader


	------------------------------------------------------------------------
	-- Invoke external compiler / linker
	------------------------------------------------------------------------

	-- !! Early exit on StopSea
	when (elem Arg.StopSea ?args)
		compileExit	
	

	-- Invoke GCC to compile C source.
	invokeSeaCompiler
		pathRuntime
		pathLibrary
		(fromMaybe [] $ liftM Build.buildExtraCCFlags mBuild)


	-- !! Early exit on StopCompile
	when (elem Arg.StopCompile ?args)
		compileExit
			
	-- Invoke GCC to link main binary.
	invokeLinker
		pathRuntime
		(fromMaybe [] $ liftM Build.buildExtraLinkLibs mBuild)
		(fromMaybe [] $ liftM Build.buildExtraLinkLibDirs mBuild)
		(fromMaybe [] $ liftM Build.buildExtraLinkObjs mBuild)
		([pathSourceBase ++ ".o"]
			++ (map    idFilePathO $ Map.elems importsExp))
			-- ++ (catMap idLinkObjs  $ Map.elems importsExp))	

	return ()
		
-----
compileExit
 = do
 	System.exitWith System.ExitSuccess



runStage :: String -> IO a -> IO a
runStage name stage
 =	Exception.catch stage (handleStage name)
		
 
handleStage :: String -> Exception -> IO a
handleStage name ex
 = case ex of
 	ErrorCall string	
	 -> do	putStr $ "DDC: error in stage " ++ name ++ "\n"
	 	putStr $ string ++ "\n"
		
		error "failed."
		
	_ ->	throwIO ex





putStrF s
 = do
 	System.hFlush System.stdout
	putStr s
 	System.hFlush System.stdout
	

getTimeF :: IO Double
getTimeF 
 = do
 	clock		<- getClockTime
	calTime		<- toCalendarTime clock
	
	let secs	= (ctMin calTime) * 60
			+ (ctSec calTime)
			
	let frac 	= ((fromIntegral $ ctPicosec calTime) / 1000000000000.0 :: Double)
			
	return (fromIntegral secs + frac)
		
showF :: Double -> String
showF	f	= (showFFloat (Just 6) f "") ++ "s"



-----
runPragmaShell fileName fileDir c
 = do
	when ?verbose
	 $ 	putStr $ pprStr $ "  - pragma Shell \"" % c % "\"\n"

	-- Change to the same dir as the source file.
	oldDir	<- System.getWorkingDirectory
	System.changeWorkingDirectory fileDir	 

	-- Run the command.
	ret	<- System.system c

	-- Change back to original dir.
	System.changeWorkingDirectory oldDir
	
	case ret of
	 System.ExitSuccess	-> return ()
	 System.ExitFailure _
	  -> do	System.hPutStr System.stderr 
		  	$  pprStr
			$ "* DDC ERROR - embedded pragma shell command failed.\n"
			% "    source file = '" % fileName % "'\n"
			% "    command     = '" % c % "'\n"
			% "\n"
	
		System.exitWith (System.ExitFailure 1)
	 	 
-----
dumpImportDef def
	= putStr	
	$ pprStr
 	$ "        " % (padR 30 $ pprStr $ idModule def) % " " % idFilePathDI def % "\n"
{-
 | otherwise
 = putStr
 	$ pprStr
 	$ "        " % (padR 30 $ pprStr $ idModule def) % " " % idFilePathDI def % "\n"
	% "          linkObjs:\n" 
	% "\n" %!% (map (\p -> "             " % p) $ idLinkObjs def)
	% "\n"
-}




