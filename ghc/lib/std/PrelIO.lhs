%
% (c) The GRAP/AQUA Project, Glasgow University, 1992-1996
%
\section[PrelIO]{Module @PrelIO@}

This module defines all basic IO operations.
These are needed for the IO operations exported by Prelude,
but as it happens they also do everything required by library
module IO.


\begin{code}
{-# OPTIONS -fno-implicit-prelude -#include "cbits/stgio.h" #-}

module PrelIO where

import PrelBase

import PrelIOBase
import PrelHandle	-- much of the real stuff is in here

import PrelRead         ( readParen, Read(..), reads, lex,
			  readIO 
			)
import PrelShow
import PrelMaybe	( Either(..), Maybe(..) )
import PrelAddr		( Addr(..), nullAddr )
import PrelByteArr	( ByteArray )
import PrelPack		( unpackNBytesAccST )
import PrelException    ( ioError, catch )
import PrelConc
\end{code}



%*********************************************************
%*							 *
\subsection{Standard IO}
%*							 *
%*********************************************************

The Prelude has from Day 1 provided a collection of common
IO functions. We define these here, but let the Prelude
export them.

\begin{code}
putChar         :: Char -> IO ()
putChar c       =  hPutChar stdout c

putStr          :: String -> IO ()
putStr s        =  hPutStr stdout s

putStrLn        :: String -> IO ()
putStrLn s      =  do putStr s
                      putChar '\n'

print           :: Show a => a -> IO ()
print x         =  putStrLn (show x)

getChar         :: IO Char
getChar         =  hGetChar stdin

getLine         :: IO String
getLine         =  hGetLine stdin
            
getContents     :: IO String
getContents     =  hGetContents stdin

interact        ::  (String -> String) -> IO ()
interact f      =   do s <- getContents
                       putStr (f s)

readFile        :: FilePath -> IO String
readFile name	=  openFile name ReadMode >>= hGetContents

writeFile       :: FilePath -> String -> IO ()
writeFile name str = do
    hdl <- openFile name WriteMode
    hPutStr hdl str
    hClose hdl

appendFile      :: FilePath -> String -> IO ()
appendFile name str = do
    hdl <- openFile name AppendMode
    hPutStr hdl str
    hClose hdl

readLn          :: Read a => IO a
readLn          =  do l <- getLine
                      r <- readIO l
                      return r
\end{code}


%*********************************************************
%*							*
\subsection{Simple input operations}
%*							*
%*********************************************************

Computation @hReady hdl@ indicates whether at least
one item is available for input from handle {\em hdl}.

@hWaitForInput@ is the generalisation, wait for \tr{n} milliseconds
before deciding whether the Handle has run dry or not.

If @hWaitForInput@ finds anything in the Handle's buffer, it immediately returns.
If not, it tries to read from the underlying OS handle. Notice that
for buffered Handles connected to terminals this means waiting until a complete
line is available.

\begin{code}
hReady :: Handle -> IO Bool
hReady h = hWaitForInput h 0

hWaitForInput :: Handle -> Int -> IO Bool 
hWaitForInput handle msecs =
    wantReadableHandle "hWaitForInput" handle $ \ handle_ -> do
    rc       <- inputReady (haFO__ handle_) (msecs::Int)     -- ConcHask: SAFE, won't block
    case (rc::Int) of
      0 -> return False
      1 -> return True
      _ -> constructErrorAndFail "hWaitForInput"
\end{code}

@hGetChar hdl@ reads the next character from handle @hdl@,
blocking until a character is available.

\begin{code}
hGetChar :: Handle -> IO Char
hGetChar handle = do
  c <- mayBlockRead "hGetChar" handle fileGetc
  return (chr c)

{-
  If EOF is reached before EOL is encountered, ignore the
  EOF and return the partial line. Next attempt at calling
  hGetLine on the handle will yield an EOF IO exception though.
-}
hGetLine :: Handle -> IO String
hGetLine h = do
  c <- hGetChar h
  if c == '\n' then
     return ""
   else do
    l <- getRest
    return (c:l)
 where
  getRest = do
    c <- 
      catch 
        (hGetChar h)
        (\ err -> do
          if isEOFError err then
	     return '\n'
	   else
	     ioError err)
    if c == '\n' then
       return ""
     else do
       s <- getRest
       return (c:s)

\end{code}

@hLookahead hdl@ returns the next character from handle @hdl@
without removing it from the input buffer, blocking until a
character is available.

\begin{code}
hLookAhead :: Handle -> IO Char
hLookAhead handle = do
  rc <- mayBlockRead "hLookAhead" handle fileLookAhead
  return (chr rc)
\end{code}


%*********************************************************
%*							*
\subsection{Getting the entire contents of a handle}
%*							*
%*********************************************************

@hGetContents hdl@ returns the list of characters corresponding
to the unread portion of the channel or file managed by @hdl@,
which is made semi-closed.

\begin{code}
hGetContents :: Handle -> IO String
hGetContents handle = 
	-- can't use wantReadableHandle here, because we want to side effect
	-- the handle.
    withHandle handle $ \ handle_ -> do
    case haType__ handle_ of 
      ErrorHandle theError -> ioError theError
      ClosedHandle 	   -> ioe_closedHandle "hGetContents" handle
      SemiClosedHandle 	   -> ioe_closedHandle "hGetContents" handle
      AppendHandle 	   -> ioError not_readable_error
      WriteHandle 	   -> ioError not_readable_error
      _ -> do
    	  {- 
    	    To avoid introducing an extra layer of buffering here,
    	    we provide three lazy read methods, based on character,
    	    line, and block buffering.
    	  -}
   	let handle_' = handle_{ haType__ = SemiClosedHandle }
    	case (haBufferMode__ handle_) of
    	 LineBuffering    -> do
    	    str <- unsafeInterleaveIO (lazyReadLine handle (haFO__ handle_))
    	    return (handle_', str)
    	 BlockBuffering _ -> do
    	    str <- unsafeInterleaveIO (lazyReadBlock handle (haFO__ handle_))
    	    return (handle_', str)
    	 NoBuffering      -> do
    	    str <- unsafeInterleaveIO (lazyReadChar handle (haFO__ handle_))
    	    return (handle_', str)
  where
   not_readable_error = 
	   IOError (Just handle) IllegalOperation "hGetContents"
		   ("handle is not open for reading")
\end{code}

Note that someone may close the semi-closed handle (or change its buffering), 
so each these lazy read functions are pulled on, they have to check whether
the handle has indeed been closed.

\begin{code}
#ifndef __PARALLEL_HASKELL__
lazyReadBlock :: Handle -> ForeignObj -> IO String
lazyReadLine  :: Handle -> ForeignObj -> IO String
lazyReadChar  :: Handle -> ForeignObj -> IO String
#else
lazyReadBlock :: Handle -> Addr -> IO String
lazyReadLine  :: Handle -> Addr -> IO String
lazyReadChar  :: Handle -> Addr -> IO String
#endif

lazyReadBlock handle fo = do
   buf   <- getBufStart fo 0
   bytes <- mayBlock fo (readBlock fo) -- ConcHask: UNSAFE, may block.
   case (bytes::Int) of
     -3 -> -- buffering has been turned off, use lazyReadChar instead
           lazyReadChar handle fo
     -2 -> return ""
     -1 -> -- an error occurred, close the handle
	  withHandle handle $ \ handle_ -> do
          closeFile (haFO__ handle_) 0{-don't bother flushing-}  -- ConcHask: SAFE, won't block.
	  return (handle_ { haType__    = ClosedHandle,
			    haFO__      = nullFile__ }, 
		  "")
     _ -> do
      more <- unsafeInterleaveIO (lazyReadBlock handle fo)
      stToIO (unpackNBytesAccST buf bytes more)

lazyReadLine handle fo = do
     bytes <- mayBlock fo (readLine fo)   -- ConcHask: UNSAFE, may block.
     case (bytes::Int) of
       -3 -> -- buffering has been turned off, use lazyReadChar instead
             lazyReadChar handle fo
       -2 -> return "" -- handle closed by someone else, stop reading.
       -1 -> -- an error occurred, close the handle
  	     withHandle handle $ \ handle_ -> do
             closeFile (haFO__ handle_) 0{- don't bother flushing-}  -- ConcHask: SAFE, won't block
	     return (handle_ { haType__    = ClosedHandle,
			       haFO__      = nullFile__ },
		     "")
       _ -> do
          more <- unsafeInterleaveIO (lazyReadLine handle fo)
          buf  <- getBufStart fo bytes  -- ConcHask: won't block
	  stToIO (unpackNBytesAccST buf bytes more)

lazyReadChar handle fo = do
    char <- mayBlock fo (readChar fo)   -- ConcHask: UNSAFE, may block.
    case (char::Int) of
      -4 -> -- buffering is now block-buffered, use lazyReadBlock instead
	    lazyReadBlock handle fo
	    
      -3 -> -- buffering is now line-buffered, use lazyReadLine instead
	    lazyReadLine handle fo
      -2 -> return ""
      -1 -> -- error, silently close handle.
 	 withHandle handle $ \ handle_ -> do
         closeFile (haFO__ handle_) 0{-don't bother flusing-}  -- ConcHask: SAFE, won't block
	 return (handle_{ haType__  = ClosedHandle,
			  haFO__    = nullFile__ },
		 "")
      _ -> do
	 more <- unsafeInterleaveIO (lazyReadChar handle fo)
         return (chr char : more)

\end{code}


%*********************************************************
%*							*
\subsection{Simple output functions}
%*							*
%*********************************************************

@hPutChar hdl ch@ writes the character @ch@ to the file
or channel managed by @hdl@.  Characters may be buffered if
buffering is enabled for @hdl@

\begin{code}
hPutChar :: Handle -> Char -> IO ()
hPutChar handle c = 
    wantWriteableHandle "hPutChar" handle $ \ handle_  -> do
    let fo = haFO__ handle_
    flushConnectedBuf fo
    rc       <- mayBlock fo (filePutc fo c)   -- ConcHask: UNSAFE, may block.
    if rc == 0
     then return ()
     else constructErrorAndFail "hPutChar"

\end{code}

@hPutStr hdl s@ writes the string @s@ to the file or
channel managed by @hdl@, buffering the output if needs be.

\begin{code}
hPutStr :: Handle -> String -> IO ()
hPutStr handle str = 
    wantWriteableHandle "hPutStr" handle $ \ handle_ -> do
    let fo = haFO__ handle_
    flushConnectedBuf fo
    case haBufferMode__ handle_ of
       LineBuffering -> do
	    buf <- getWriteableBuf fo
	    pos <- getBufWPtr fo
	    bsz <- getBufSize fo
	    writeLines fo buf bsz pos str
       BlockBuffering _ -> do
	    buf <- getWriteableBuf fo
	    pos <- getBufWPtr fo
	    bsz <- getBufSize fo
            writeBlocks fo buf bsz pos str
       NoBuffering -> do
	    writeChars fo str
\end{code}

Going across the border between Haskell and C is relatively costly,
so for block writes we pack the character strings on the Haskell-side
before passing the external write routine a pointer to the buffer.

\begin{code}
#ifdef __HUGS__

#ifdef __CONCURRENT_HASKELL__
/* See comment in shoveString below for explanation */
#warning delayed update of buffer disnae work with killThread
#endif

#ifndef __PARALLEL_HASKELL__
writeLines :: ForeignObj -> Addr -> Int -> Int -> String -> IO ()
#else
writeLines :: Addr -> Addr -> Int -> Int -> String -> IO ()
#endif
writeLines obj buf bufLen initPos s =
  let
   shoveString :: Int -> [Char] -> IO ()
   shoveString n ls = 
     case ls of
      [] ->   
	  {-
	    At the end of a buffer write, update the buffer position
	    in the underlying file object, so that if the handle
	    is subsequently dropped by the program, the whole
	    buffer will be properly flushed.

	    There's one case where this delayed up-date of the buffer
	    position can go wrong: if a thread is killed, it might be
	    in the middle of filling up a buffer, with the result that
	    the partial buffer update is lost upon finalisation. Not
	    that killing of threads is supported at the moment.

	  -}
	  setBufWPtr obj n

      (x:xs) -> do
        primWriteCharOffAddr buf n x
          {- Flushing on buffer exhaustion or newlines (even if it isn't the last one) -}
	if n == bufLen || x == '\n'
	 then do
	   rc <-  mayBlock obj (writeFileObject obj (n + 1))  -- ConcHask: UNSAFE, may block.
	   if rc == 0 
	    then shoveString 0 xs
	    else constructErrorAndFail "writeLines"
         else
	   shoveString (n + 1) xs
  in
  shoveString initPos s
#else /* ndef __HUGS__ */
#ifndef __PARALLEL_HASKELL__
writeLines :: ForeignObj -> Addr -> Int -> Int -> String -> IO ()
#else
writeLines :: Addr -> Addr -> Int -> Int -> String -> IO ()
#endif
writeLines obj buf (I# bufLen) (I# initPos#) s =
  let
   write_char :: Addr -> Int# -> Char# -> IO ()
   write_char (A# buf#) n# c# =
      IO $ \ s# ->
      case (writeCharOffAddr# buf# n# c# s#) of s2# -> (# s2#, () #)

   shoveString :: Int# -> [Char] -> IO ()
   shoveString n ls = 
     case ls of
      [] ->   
	  {-
	    At the end of a buffer write, update the buffer position
	    in the underlying file object, so that if the handle
	    is subsequently dropped by the program, the whole
	    buffer will be properly flushed.

	    There's one case where this delayed up-date of the buffer
	    position can go wrong: if a thread is killed, it might be
	    in the middle of filling up a buffer, with the result that
	    the partial buffer update is lost upon finalisation. Not
	    that killing of threads is supported at the moment.

	  -}
	  setBufWPtr obj (I# n)

      ((C# x):xs) -> do
        write_char buf n x
          {- Flushing on buffer exhaustion or newlines (even if it isn't the last one) -}
	if n ==# bufLen || x `eqChar#` '\n'#
	 then do
	   rc <-  mayBlock obj (writeFileObject obj (I# (n +# 1#)))  -- ConcHask: UNSAFE, may block.
	   if rc == 0 
	    then shoveString 0# xs
	    else constructErrorAndFail "writeLines"
         else
	   shoveString (n +# 1#) xs
  in
  shoveString initPos# s
#endif /* ndef __HUGS__ */

#ifdef __HUGS__
#ifndef __PARALLEL_HASKELL__
writeBlocks :: ForeignObj -> Addr -> Int -> Int -> String -> IO ()
#else
writeBlocks :: Addr -> Addr -> Int -> Int -> String -> IO ()
#endif
writeBlocks obj buf bufLen initPos s =
  let
   shoveString :: Int -> [Char] -> IO ()
   shoveString n ls = 
     case ls of
      [] ->   
	  {-
	    At the end of a buffer write, update the buffer position
	    in the underlying file object, so that if the handle
	    is subsequently dropped by the program, the whole
	    buffer will be properly flushed.

	    There's one case where this delayed up-date of the buffer
	    position can go wrong: if a thread is killed, it might be
	    in the middle of filling up a buffer, with the result that
	    the partial buffer update is lost upon finalisation. However,
	    by the time killThread is supported, Haskell finalisers are also
	    likely to be in, which means the 'IOFileObject' hack can go
	    alltogether.

	  -}
	  setBufWPtr obj n

      (x:xs) -> do
        primWriteCharOffAddr buf n x
	if n == bufLen
	 then do
	   rc <-  mayBlock obj (writeFileObject obj (n + 1))   -- ConcHask: UNSAFE, may block.
	   if rc == 0 
            then shoveString 0 xs
	    else constructErrorAndFail "writeChunks"
         else
	   shoveString (n + 1) xs
  in
  shoveString initPos s
#else /* ndef __HUGS__ */
#ifndef __PARALLEL_HASKELL__
writeBlocks :: ForeignObj -> Addr -> Int -> Int -> String -> IO ()
#else
writeBlocks :: Addr -> Addr -> Int -> Int -> String -> IO ()
#endif
writeBlocks obj buf (I# bufLen) (I# initPos#) s =
  let
   write_char :: Addr -> Int# -> Char# -> IO ()
   write_char (A# buf#) n# c# =
      IO $ \ s# ->
      case (writeCharOffAddr# buf# n# c# s#) of s2# -> (# s2#, () #)

   shoveString :: Int# -> [Char] -> IO ()
   shoveString n ls = 
     case ls of
      [] ->   
	  {-
	    At the end of a buffer write, update the buffer position
	    in the underlying file object, so that if the handle
	    is subsequently dropped by the program, the whole
	    buffer will be properly flushed.

	    There's one case where this delayed up-date of the buffer
	    position can go wrong: if a thread is killed, it might be
	    in the middle of filling up a buffer, with the result that
	    the partial buffer update is lost upon finalisation. However,
	    by the time killThread is supported, Haskell finalisers are also
	    likely to be in, which means the 'IOFileObject' hack can go
	    alltogether.

	  -}
	  setBufWPtr obj (I# n)

      ((C# x):xs) -> do
        write_char buf n x
	if n ==# bufLen
	 then do
	   rc <-  mayBlock obj (writeFileObject obj (I# (n +# 1#)))   -- ConcHask: UNSAFE, may block.
	   if rc == 0 
	    then shoveString 0# xs
	    else constructErrorAndFail "writeChunks"
         else
	   shoveString (n +# 1#) xs
  in
  shoveString initPos# s
#endif /* ndef __HUGS__ */

#ifndef __PARALLEL_HASKELL__
writeChars :: ForeignObj -> String -> IO ()
#else
writeChars :: Addr -> String -> IO ()
#endif
writeChars _fo ""    = return ()
writeChars fo (c:cs) = do
  rc <- mayBlock fo (filePutc fo c)   -- ConcHask: UNSAFE, may block.
  if rc == 0 
   then writeChars fo cs
   else constructErrorAndFail "writeChars"

\end{code}

Computation @hPrint hdl t@ writes the string representation of {\em t}
given by the @shows@ function to the file or channel managed by {\em
hdl}.

[ Seem to have disappeared from the 1.4 interface  - SOF 2/97 ]

\begin{code}
hPrint :: Show a => Handle -> a -> IO ()
hPrint hdl = hPutStrLn hdl . show
\end{code}

Derived action @hPutStrLn hdl str@ writes the string \tr{str} to
the handle \tr{hdl}, adding a newline at the end.

\begin{code}
hPutStrLn :: Handle -> String -> IO ()
hPutStrLn hndl str = do
 hPutStr  hndl str
 hPutChar hndl '\n'
\end{code}
