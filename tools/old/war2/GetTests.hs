
module GetTests where
import Config
import Test
import TestNode
import Command
import War
import Util
import System.Exit


-- Get Tests --------------------------------------------------------------------------------------
-- Look for tests in this directory
getTestsInDir :: Config -> DirPath -> War [TestNode]
getTestsInDir config dirPath
 = do	debugLn $ "- Looking for tests in " ++ dirPath

	-- See what files are here
	filesAll	<- lsFilesIn dirPath

	-- DDC dump files also end with .ds but we don't want to try and build them.
	--	Also skip over anything with the word "-skip" or "skip-" in it.
	let files	= filter 
				(\name -> (not $ isInfixOf ".dump-" name) 
				       && (not $ isInfixOf "-skip"  name)
				       && (not $ isInfixOf "skip-"  name))
				filesAll

	let gotMainStdoutCheck	= any (isSuffixOf "/Main.stdout.check") files


	-- | If we have a Main.hs, then compile and run that.
	--
	let gotMainHS		 = any (isSuffixOf "/Main.hs") files
	let testsHaskellBuildRun
		= listWhen gotMainHS
		$ chainTests	[ TestHsBuild	(dirPath ++ "/Main.hs")
				, TestRun	(dirPath ++ "/Main.bin") 
						(NoShow (\c -> case c of 
							ExitSuccess   -> True
							ExitFailure _ -> False))]

	let testsStdout
		| gotMainStdoutCheck
		, gotMainHS
		, Just nodeLast		<- takeLast testsHaskellBuildRun
		, tLast			<- testOfNode nodeLast
		= [node1 (TestDiff	(dirPath ++ "/Main.stdout.check")
					(dirPath ++ "/Main.stdout"))
			[tLast]]
		  
		| otherwise
		= []


	-- | If we have a Main.sh, then run that
	--	If we have a Main.error.check, we're expecing the script to fail.
	--
	let gotMainSH		 = any (isSuffixOf "/Main.sh") files
	let gotMainErrorCheck	 = any (isSuffixOf "/Main.error.check") files
	let testsShell
		= listWhen (gotMainSH && not gotMainErrorCheck)
		$ chainTests	[ TestShell	(dirPath ++ "/Main.sh") ]
	
	let testsShellError
		= listWhen (gotMainSH && gotMainErrorCheck)
		$ chainTests	[ TestShellError (dirPath ++ "/Main.sh")
				, TestDiff	(dirPath ++ "/Main.error.check") 
						(dirPath ++ "/Main.execute.stderr") ]


	-- Build and run executables if we have a Main.ds, but no Main.sh
	--	If we have an error.check    file 
	--		then we're expecting the build to fail.
	--	If we have an runerror.check file 
	--		then we're expecting the build to succeed, but the executable to fail at runtime.
	--
	let gotMainDS		 = any (isSuffixOf "/Main.ds") files
	let gotMainRunErrorCheck = any (isSuffixOf "/Main.runerror.check") files
	let gotCompileWarnCheck	 = any (isSuffixOf ".warn.check") files

	let testsBuildRunSuccess
		= listWhen (not gotMainSH && gotMainDS && not gotMainErrorCheck && not gotMainRunErrorCheck)
		$ chainTests	[ TestBuild	(dirPath ++ "/Main.ds")
				, TestRun	(dirPath ++ "/Main.bin") 
						(NoShow (\c -> case c of 
							ExitSuccess   -> True
							ExitFailure _ -> False))]

	let testsBuildRunError
		= listWhen (not gotMainSH && gotMainDS && not gotMainErrorCheck && gotMainRunErrorCheck)
		$ chainTests	[ TestBuild	(dirPath ++ "/Main.ds")
				, TestRun	(dirPath ++ "/Main.bin") 
						(NoShow (\c -> case c of 
							ExitFailure _ -> True
							ExitSuccess   -> False))]

	let testsBuildRun
		=  testsBuildRunSuccess 
		++ testsBuildRunError


	-- If we ran an executable, and we have a stdout check file
	--	then check the executable's output against it
	let testsStdout2
		| gotMainStdoutCheck
		, Just nodeLast		<- takeLast testsBuildRun
		, tLast			<- testOfNode nodeLast
		= [node1 (TestDiff	(dirPath ++ "/Main.stdout.check")
					(dirPath ++ "/Main.stdout"))
			[tLast]]
		  
		| otherwise
		= []

	let testsBuildError
		= listWhen (gotMainDS && gotMainErrorCheck && not gotMainSH)
		$ chainTests	[ TestBuildError (dirPath ++ "/Main.ds")
				, TestDiff 	 (dirPath ++ "/Main.error.check") 
						 (dirPath ++ "/Main.compile.stderr") ]


	-- If there is no Main.ds then expect every source file that hasn't got an 
	--	associated error.check file to compile successfully.
	let testsCompile
		= listWhen (not gotMainDS && not gotMainSH)
		$ [ node1 (TestCompile file) []
				| file	<- filter (isSuffixOf ".ds") files 
				, let errorCheckFile	
					= (take (length file - length ".ds") file) ++ ".error.check"
				, not (elem errorCheckFile files)]

	let testsCompileWarn
		= listWhen (gotCompileWarnCheck)
		$ chainTests
		$ concat [	[ TestCompile	file, TestDiff warnCheckFile compileStderr]
				| file	<- filter (isSuffixOf ".ds") files
				, let fileRoot = take (length file - length ".ds") file
				, let warnCheckFile = fileRoot  ++ ".warn.check"
                                , let compileStderr = fileRoot  ++ ".compile.stderr"
				, elem warnCheckFile files]


	-- If there is not Main.ds file then expect source files with an 
	--	associate error.check file to fail during compilation.
	let testsCompileError
		= listWhen (not gotMainDS && not gotMainSH)
		$ concat
		$ [ chainTests 
			[ TestCompileError file
			, TestDiff	   errorCheckFile compileStderr]
			
			| file	<- filter (isSuffixOf ".ds") files 
			, let fileRoot		= take (length file - length ".ds") file
			, let errorCheckFile	= fileRoot ++ ".error.check"
			, let compileStderr	= fileRoot ++ ".compile.stderr"
			, elem errorCheckFile files  ]


	-- These tests are can be run in all ways
	--	So run them all ways that were specified
	let testsAllWays
		= concat 
			[ testsBuildRun,	testsBuildError
			, testsShell,		testsShellError
			, testsCompile,		testsCompileError
			, testsCompileWarn
			, testsStdout
			, testsStdout2
			, testsHaskellBuildRun]

	let testsHereExpanded
		= expandWays (configWays config) testsAllWays


	-- Cleanup after each set of tests if asked 
	let testsFinal
		| configClean config
		, Just n1	<- takeLast $ testsHereExpanded
		= testsHereExpanded 
			++ [TestNode (TestClean dirPath, WayNil) [testIdOfNode n1]]

		| otherwise
		= testsHereExpanded


	debugLn 
		$  " Expandable tests " ++ dirPath ++ "\n"
		++ (unlines $ map show $ testsAllWays)
		++ " -- expanded --\n"
		++ (unlines $ map show $ testsHereExpanded)
		++ "\n"
		++ " -- final -- \n"
		++ (unlines $ map show $ testsFinal)
		++ "\n"
		++ " -- compile error -- \n"
		++ (unlines $ map show $ testsCompileError)
		++ "\n"


	-- See what dirs we can recurse into
	dirsAll		<- lsDirsIn dirPath

	-- Skip over boring dirs
	let dirs	= filter
				(\name -> (not $ isInfixOf "-skip" name)
				       && (not $ isInfixOf "skip-" name))
				dirsAll

	-- Recurse into directories
	moreTests 
		<- liftM concat
		$  mapM (getTestsInDir config) dirs

	return	$ testsFinal ++ moreTests



listWhen :: Bool -> [a] -> [a]
listWhen True xs	= xs
listWhen False xs	= []


justWhen :: Bool -> a -> Maybe a
justWhen True  x	= Just x
justWhen False _	= Nothing