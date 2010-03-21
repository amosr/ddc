
module Util.Misc
	( (=@=)
	, orf
	, (<:)
	, (<::)
	, (>::)
	, getTime
	, toRectangular
	, buildRun
	, interpolate
	, choose )
where
import System.Time
import Data.IORef
import GHC.Base


-- | Compare tags of constructors in these two values
(=@=) :: a -> a -> Bool
(=@=) a b = getTag a ==# getTag b


----
orf :: 	a -> [a -> Bool] -> Bool
orf	x fs
 = 	foldl (\a f -> a || f x) False fs
	
----
updateRefIO :: IORef a -> (a -> IO a) -> IO ()
updateRefIO    ref    f =
 do
 	a	<- readIORef ref
	a'	<- f a
	writeIORef ref a'

(<:)	= modifyIORef
(<::)	= updateRefIO

(>::)	:: IORef a -> (a -> IO ()) -> IO ()
(>::) 	   ref f 
 = do
 	a	<- readIORef ref
	f a


-- | Get time in picoseconds.
getTime :: IO Integer
getTime = 
 do
 	TOD sec psec 	<- getClockTime
	return ((sec * 1000000000000) + psec)


------
toRectangular :: (Float, Float) -> (Float, Float)
toRectangular 	 (mag,   angle)	=  (x, y)
 where
 	x	= mag * cos angle
	y	= mag * sin angle


-----
buildRun :: (Ord a, Num a) => a -> a -> a -> [a]
buildRun first last step
	= buildRun' first last step 0 first

buildRun' :: (Ord a, Num a) => a -> a -> a -> Int -> a -> [a]
buildRun' first last step count x
	| x >= last	= []
	| otherwise	= x' : buildRun' first last step (count+1) x'	
	   where
	   	x'	= step * fromIntegral count

interpolate      :: (Float, Float) -> Float -> Float
interpolate         (min, max)        x     = min + (max - min) * x


choose :: Bool -> a -> a -> a
choose 	b x y
 = if b then x else y
 
