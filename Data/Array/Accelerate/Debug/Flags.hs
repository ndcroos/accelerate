{-# LANGUAGE CPP                      #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# LANGUAGE TypeOperators            #-}
#ifdef ACCELERATE_DEBUG
#if __GLASGOW_HASKELL >= 800
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
#endif
#else
{-# OPTIONS_GHC -fno-warn-unused-binds   #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}
#endif
-- |
-- Module      : Data.Array.Accelerate.Debug.Flags
-- Copyright   : [2008..2017] Manuel M T Chakravarty, Gabriele Keller
--               [2009..2017] Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Option parsing for debug flags
--

module Data.Array.Accelerate.Debug.Flags (

  Flags, Mode,
  acc_sharing, exp_sharing, fusion, simplify, flush_cache, fast_math, verbose,
  dump_phases, dump_sharing, dump_simpl_stats, dump_simpl_iterations, dump_vectorisation,
  dump_dot, dump_simpl_dot, dump_gc, dump_gc_stats, debug_cc, dump_cc, dump_ld, dump_asm,
  dump_exec, dump_sched,

  accInit,
  queryFlag, setFlag, setFlags, clearFlag, clearFlags,
  when, unless,

) where

import Control.Monad.IO.Class
import Data.IORef
import Data.Label
import Data.Label.Derive
import Data.List
import System.Environment
import System.IO.Unsafe
import Text.PrettyPrint                         hiding ( Mode )
import qualified Control.Monad                  as M ( when, unless )

import Foreign.C
import Foreign.Marshal
import Foreign.Ptr
import GHC.Foreign                              as GHC
import GHC.IO.Encoding                          ( getFileSystemEncoding )

import Debug.Trace


data FlagSpec flag = Option String              -- external form
                            flag                -- internal form

-- The runtime debug and control options supported by Accelerate. This is a bit
-- awkward, as we process both frontend as well as backend option flags, but
-- gives some control over error messages and overlapping options.
--
data Flags = Flags
  {
    -- Functionality and phase control
    -- -------------------------------
    --
    -- These are Maybe types because they will only override the backend
    -- options if the user specifies a value
    --
    _acc_sharing              :: !(Maybe Bool)        -- recover sharing of array computations
  , _exp_sharing              :: !(Maybe Bool)        -- recover sharing of scalar expressions
  , _fusion                   :: !(Maybe Bool)        -- fuse array expressions
  , _simplify                 :: !(Maybe Bool)        -- simplify scalar expressions
  -- , _unfolding_use_threshold  :: !(Maybe Int)         -- the magic cut-off figure for inlining
  , _flush_cache              :: !(Maybe Bool)        -- delete persistent compilation cache(s)
  , _fast_math                :: !(Maybe Bool)        -- use faster, less precise math library operations

    -- Debug trace
    -- -----------
  , _verbose                  :: !Bool                -- be very chatty

    -- optimisation and simplification
  , _dump_phases              :: !Bool                -- print information about each phase of the compiler
  , _dump_sharing             :: !Bool                -- sharing recovery phase
  , _dump_simpl_stats         :: !Bool                -- statistics form fusion/simplification
  , _dump_simpl_iterations    :: !Bool                -- output from each simplifier iteration
  , _dump_vectorisation       :: !Bool                -- output from the vectoriser
  , _dump_dot                 :: !Bool                -- generate dot output of the program
  , _dump_simpl_dot           :: !Bool                -- generate simplified dot output

    -- garbage collection
  , _dump_gc                  :: !Bool                -- trace garbage collector
  , _dump_gc_stats            :: !Bool                -- print final GC statistics

    -- code generation / compilation
  , _debug_cc                 :: !Bool                -- compile with debug symbols
  , _dump_cc                  :: !Bool                -- trace code generation & compilation
  , _dump_ld                  :: !Bool                -- trace runtime linker
  , _dump_asm                 :: !Bool                -- trace assembler

    -- execution
  , _dump_exec                :: !Bool                -- trace execution
  , _dump_sched               :: !Bool                -- trace scheduler
  }

-- Generate labels with INLINE pragmas
$(mkLabelsWith defaultNaming True False False True ''Flags)


allFlags :: [FlagSpec (Flags -> Flags)]
allFlags
  =  map (enable  'd') dflags
  ++ map (enable  'f') fflags ++ map (disable 'f') fflags
  where
    enable  p (Option f go) = Option ('-':p:f)        (go True)
    disable p (Option f go) = Option ('-':p:"no-"++f) (go False)


-- These @-f\<blah\>@ phase control flags can be reversed with @-fno-\<blah\>@
--
fflags :: [FlagSpec (Bool -> Flags -> Flags)]
fflags =
  [ Option "acc-sharing"                (set' acc_sharing)
  , Option "exp-sharing"                (set' exp_sharing)
  , Option "fusion"                     (set' fusion)
  , Option "simplify"                   (set' simplify)
  , Option "flush-cache"                (set' flush_cache)
  , Option "fast-math"                  (set' fast_math)
  ]
  where
    set' f v = set f (Just v)

-- These debugging flags default to off and can be enable with @-d\<blah\>@
--
dflags :: [FlagSpec (Bool -> Flags -> Flags)]
dflags =
  [ Option "verbose"                    (set verbose)
  , Option "dump-phases"                (set dump_phases)
  , Option "dump-sharing"               (set dump_sharing)
  , Option "dump-simpl-stats"           (set dump_simpl_stats)
  , Option "dump-simpl-iterations"      (set dump_simpl_iterations)
  , Option "dump-vectorisation"         (set dump_vectorisation)
  , Option "dump-dot"                   (set dump_dot)
  , Option "dump-simpl-dot"             (set dump_simpl_dot)
  , Option "dump-gc"                    (set dump_gc)
  , Option "dump-gc-stats"              (set dump_gc_stats)
  , Option "debug-cc"                   (set debug_cc)
  , Option "dump-cc"                    (set dump_cc)
  , Option "dump-ld"                    (set dump_ld)
  , Option "dump-asm"                   (set dump_asm)
  , Option "dump-exec"                  (set dump_exec)
  , Option "dump-sched"                 (set dump_sched)
  ]


class DebugFlag a where
  def :: a

instance DebugFlag Bool where
  {-# INLINE def #-}
  def = False

instance DebugFlag (Maybe a) where
  {-# INLINE def #-}
  def = Nothing


-- | A bit of a hack to get the command line options processing out of the way.
--
-- We would like to have this automatically called once during program
-- initialisation, so that our command-line debug flags between +ACC .. [-ACC]
-- don't interfere with other programs.
--
-- Hacks beget hacks beget hacks...
--
accInit :: IO ()
#ifdef ACCELERATE_DEBUG
accInit = _flags `seq` return ()
#else
accInit = getUpdateArgs >> return ()
#endif

-- Initialise the debugging flags structure. This reads from both the command
-- line arguments as well as the environment variable "ACCELERATE_FLAGS".
-- Where applicable, options on the command line take precedence.
--
-- This is only available when compiled with debugging mode, because trying to
-- access it at any other time is an error.
--
#ifdef ACCELERATE_DEBUG
initialiseFlags :: IO Flags
initialiseFlags = do
  argv  <- getUpdateArgs
  env   <- maybe [] words `fmap` lookupEnv "ACCELERATE_FLAGS"
  return $ parse (env ++ argv)
  where
    defaults            = Flags def def def def def def def def def def def def def def def def def def def def def def

    parse               = foldl parse1 defaults
    parse1 opts this    =
      case filter (\(Option flag _) -> this `isPrefixOf` flag) allFlags of
        [Option _ go]   -> go opts
        []              -> trace unknown opts
        alts            -> case find (\(Option flag _) -> flag == this) alts of
                             Just (Option _ go) -> go opts
                             Nothing            -> trace (ambiguous alts) opts
      where
        unknown         = render $ text "Unknown option:" <+> quotes (text this)
        ambiguous alts  = render $
          vcat [ text "Ambiguous option:" <+> quotes (text this)
               , text ""
               , text "Did you mean one of these?"
               , nest 4 $ vcat (map (\(Option s _) -> text s) alts)
               ]
#endif


-- If the command line arguments include a section "+ACC ... [-ACC]" then return
-- that section, and update the command line arguments to not include that part.
--
getUpdateArgs :: IO [String]
getUpdateArgs = do
  argv <- getArgs
  --
  let (before, r1)      = span (/= "+ACC") argv
      (flags,  r2)      = span (/= "-ACC") $ dropWhile (== "+ACC") r1
      after             = dropWhile (== "-ACC") r2
  --
#ifdef ACCELERATE_DEBUG
  prog <- getProgName
  setProgArgv (prog : before ++ after)
#else
  M.unless (null flags)
    $ error "Data.Array.Accelerate: Debugging options are disabled. Reinstall package 'accelerate' with '-fdebug' to enable them."
#endif
  return flags


-- This is only defined in debug mode because to access it at any other time
-- should be an error.
--
#ifdef ACCELERATE_DEBUG
{-# NOINLINE _flags #-}
_flags :: IORef Flags
_flags = unsafePerformIO $ newIORef =<< initialiseFlags
#endif

{-# INLINE queryFlag #-}
queryFlag :: DebugFlag a => (Flags :-> a) -> IO a
#ifdef ACCELERATE_DEBUG
queryFlag f = get f `fmap` readIORef _flags
#else
queryFlag _ = return def
#endif


type Mode = Flags :-> Bool

setFlag, clearFlag :: Mode -> IO ()
setFlag f   = setFlags [f]
clearFlag f = clearFlags [f]

setFlags, clearFlags :: [Mode] -> IO ()
#ifdef ACCELERATE_DEBUG
setFlags f   = modifyIORef _flags (\opt -> foldr (flip set True)  opt f)
clearFlags f = modifyIORef _flags (\opt -> foldr (flip set False) opt f)
#else
setFlags _   = return ()
clearFlags _ = return ()
#endif


-- | Conditional execution of a monadic debugging expression
--
{-# INLINEABLE when #-}
when :: MonadIO m => Mode -> m () -> m ()
when f s = do
  yes <- liftIO $ queryFlag f
  M.when yes s

-- | The opposite of 'when'
--
{-# INLINEABLE unless #-}
unless :: MonadIO m => Mode -> m () -> m ()
unless f s = do
  yes <- liftIO $ queryFlag f
  M.unless yes s


#ifdef ACCELERATE_DEBUG
-- Stolen from System.Environment
--
setProgArgv :: [String] -> IO ()
setProgArgv argv = do
  enc <- getFileSystemEncoding
  vs  <- mapM (GHC.newCString enc) argv >>= newArray0 nullPtr
  c_setProgArgv (genericLength argv) vs

foreign import ccall unsafe "setProgArgv"
  c_setProgArgv  :: CInt -> Ptr CString -> IO ()
#endif

