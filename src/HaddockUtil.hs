--
-- Haddock - A Haskell Documentation Tool
--
-- (c) The University of Glasgow 2001-2002
-- (c) Simon Marlow 2002
--

module HaddockUtil (

  -- * Misc utilities
  nameOfQName, collectNames, declBinders, declMainBinder, splitTyConApp,
  restrictTo, declDoc, parseModuleHeader, freeTyCons,

  -- * Filename utilities
  basename, dirname, splitFilename3, 
  isPathSeparator, pathSeparator,

  -- * Miscellaneous utilities
  die, dieMsg, mapSnd, mapMaybeM

 ) where

import HsSyn

import List	( intersect )
import IO	( hPutStr, stderr )
import System
import RegexString

-- -----------------------------------------------------------------------------
-- Some Utilities

nameOfQName (Qual _ n) = n
nameOfQName (UnQual n) = n

collectNames :: [HsDecl] -> [HsName]
collectNames ds = concat (map declBinders ds)

declMainBinder :: HsDecl -> Maybe HsName
declMainBinder d = 
   case d of
     HsTypeDecl _ n _ _ _          -> Just n
     HsDataDecl _ _ n _ cons _ _   -> Just n
     HsNewTypeDecl _ _ n _ _ _  _  -> Just n
     HsClassDecl _ qt _ decls _    -> Just (exQtNm qt)
     HsTypeSig _ [n] _ _           -> Just n
     HsTypeSig _ ns _ _            -> error "declMainBinder"
     HsForeignImport _ _ _ _ n _ _ -> Just n
     _                             -> Nothing

declBinders :: HsDecl -> [HsName]
declBinders d =
   case d of
     HsTypeDecl _ n _ _ _          -> [n]
     HsDataDecl _ _ n _ cons _ _   -> n : concat (map conDeclBinders cons)
     HsNewTypeDecl _ _ n _ con _ _ -> n : conDeclBinders con
     HsClassDecl _ qt _ decls _    -> exQtNm qt : collectNames decls
     HsTypeSig _ ns _ _            -> ns
     HsForeignImport _ _ _ _ n _ _ -> [n]
     _                             -> []

conDeclBinders (HsConDecl _ n _ _ _ _) = [n]
conDeclBinders (HsRecDecl _ n _ _ fields _) = 
  n : concat (map fieldDeclBinders fields)

fieldDeclBinders (HsFieldDecl ns _ _) = ns

exQtNm (HsForAllType _ _ t) = nameOfQName (fst (splitTyConApp t))
exQtNm t = nameOfQName (fst (splitTyConApp t))

splitTyConApp :: HsType -> (HsQName, [HsType])
splitTyConApp t = split t []
 where
	split :: HsType -> [HsType] -> (HsQName,[HsType])
	split (HsTyApp t u) ts = split t (u:ts)
	split (HsTyCon t)   ts = (t,ts)
	split _ _ = error "splitTyConApp"

freeTyCons :: HsType -> [HsQName]
freeTyCons ty = go ty []
  where go (HsForAllType _ _ t) r = go t r
	go (HsTyApp t u) r = go t (go u r)
	go (HsTyCon c) r = c : r
	go (HsTyFun f a) r = go f (go a r)
	go (HsTyTuple b ts) r = foldr go r ts
	go (HsTyVar v) r = r
	go (HsTyDoc t _) r = go t r

-- ---------------------------------------------------------------------------
-- Making abstract declarations

restrictTo :: [HsName] -> HsDecl -> HsDecl
restrictTo names decl = case decl of
     HsDataDecl loc ctxt n xs cons drv doc -> 
	HsDataDecl loc ctxt n xs (restrictCons names cons) drv doc
     HsNewTypeDecl loc ctxt n xs con drv doc ->
	HsDataDecl loc ctxt n xs (restrictCons names [con]) drv	doc
     HsClassDecl loc qt fds decls doc ->
	HsClassDecl loc qt fds (restrictDecls names decls) doc
     _ -> decl
   
restrictCons :: [HsName] -> [HsConDecl] -> [HsConDecl]
restrictCons names decls = filter keep decls
  where keep (HsConDecl _ n _ _ _ _) = n `elem` names
	keep (HsRecDecl _ n _ _ _ _) = n `elem` names
	-- ToDo: records not right

restrictDecls :: [HsName] -> [HsDecl] -> [HsDecl]
restrictDecls names decls = filter keep decls
  where keep d = not (null (declBinders d `intersect` names))
	-- ToDo: not really correct

-- -----------------------------------------------------------------------------
-- Extract documentation from a declaration

declDoc (HsTypeDecl _ _ _ _ d)          = d
declDoc (HsDataDecl _ _ _ _ _ _ d)      = d
declDoc (HsNewTypeDecl _ _ _ _ _ _ d)   = d
declDoc (HsClassDecl _ _ _ _ d)         = d
declDoc (HsTypeSig _ _ _ d)             = d
declDoc (HsForeignImport _ _ _ _ _ _ d) = d
declDoc _ = Nothing

-- -----------------------------------------------------------------------------
-- Parsing module headers

parseModuleHeader :: String -> (String, Maybe ModuleInfo)
parseModuleHeader str =
  case matchRegexAll moduleHeaderRE str of
	Just (before, match, after, _, (_:_:_:s1:s2:s3:_)) -> 
	   (after, Just (ModuleInfo { 
				 portability = s3,
				 stability   = s2,
				 maintainer  = s1 }))
	_other -> (str, Nothing)

moduleHeaderRE = mkRegexWithOpts
			 "^([ \t\n]*Module[ \t]*:.*\n)?\ 
			  \([ \t\n]*Copyright[ \t]*:.*\n)?\ 
			  \([ \t\n]*License[ \t]*:.*\n)?\ 
			  \[ \t\n]*Maintainer[ \t]*:(.*)\n\ 
			  \[ \t\n]*Stability[ \t]*:(.*)\n\ 
			  \[ \t\n]*Portability[ \t]*:([^\n]*)\n"
		True -- match "\n" with "."
		False -- not case sensitive
	-- All fields except the last (Portability) may be multi-line.
	-- This is so that the portability field doesn't swallow up the
	-- rest of the module documentation - we might want to revist
	-- this at some point (perhaps have a separator between the 
	-- portability field and the module documentation?).

#if __GLASGOW_HASKELL__ < 500
mkRegexWithOpts :: String -> Bool -> Bool -> Regex
mkRegexWithOpts s single_line case_sensitive
      = unsafePerformIO (re_compile_pattern (packString s) 
                              single_line case_sensitive)
#endif

-- -----------------------------------------------------------------------------
-- Filename mangling functions stolen from GHC's main/DriverUtil.lhs.

type Suffix = String

splitFilename :: String -> (String,Suffix)
splitFilename f = split_longest_prefix f (=='.')

basename :: String -> String
basename f = base where (_dir, base, _suff) = splitFilename3 f

dirname :: String -> String
dirname f = dir where (dir, _base, _suff) = splitFilename3 f

-- "foo/bar/xyzzy.ext" -> ("foo/bar", "xyzzy", ".ext")
splitFilename3 :: String -> (String,String,Suffix)
splitFilename3 str
   = let (dir, rest) = split_longest_prefix str isPathSeparator
	 (name, ext) = splitFilename rest
	 real_dir | null dir  = "."
		  | otherwise = dir
     in  (real_dir, name, ext)

split_longest_prefix :: String -> (Char -> Bool) -> (String,String)
split_longest_prefix s pred
  = case pre of
	[]      -> ([], reverse suf)
	(_:pre) -> (reverse pre, reverse suf)
  where (suf,pre) = break pred (reverse s)

pathSeparator :: Char
#ifdef __WIN32__
pathSeparator = '\\'
#else
pathSeparator = '/'
#endif

isPathSeparator :: Char -> Bool
isPathSeparator ch =
#ifdef mingw32_TARGET_OS
  ch == '/' || ch == '\\'
#else
  ch == '/'
#endif

-----------------------------------------------------------------------------
-- misc.

die :: String -> IO a
die s = hPutStr stderr s >> exitWith (ExitFailure 1)

dieMsg :: String -> IO a
dieMsg s = getProgName >>= \prog -> die (prog ++ ": " ++ s)

mapSnd f [] = []
mapSnd f ((x,y):xs) = (x,f y) : mapSnd f xs

mapMaybeM :: Monad m => (a -> m b) -> Maybe a -> m (Maybe b)
mapMaybeM f Nothing = return Nothing
mapMaybeM f (Just a) = f a >>= return . Just
