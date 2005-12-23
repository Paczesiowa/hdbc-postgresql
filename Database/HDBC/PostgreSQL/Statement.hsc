{- -*- mode:haskell; -*-
Copyright (C) 2005 John Goerzen <jgoerzen@complete.org>

This program is free software; you can redistribute it and\/or modify
it under the terms of the GNU Lesser General Public License as published by
the Free Software Foundation; either version 2.1 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

-}
module Database.HDBC.PostgreSQL.Statement where
import Database.HDBC.Types
import Database.HDBC
import Database.HDBC.PostgreSQL.Types
import Database.HDBC.PostgreSQL.Utils
import Foreign.C.Types
import Foreign.ForeignPtr
import Foreign.Ptr
import Control.Concurrent.MVar
import Foreign.C.String
import Foreign.Marshal
import Foreign.Storable
import Control.Monad
import Data.List
import Control.Exception

#include <libpq-fe.h>

data SState = 
    SState { stomv :: MVar (Maybe Stmt),
             nextrowmv :: MVar (Int),
             dbo :: Conn,
             squery :: String}

-- FIXME: we currently do no prepare optimization whatsoever.

newSth :: CConn -> String -> IO Statement               
newSth indbo query = 
    do newstomv <- newMVar Nothing
       newnextrowmv <- newMVar 0
       let sstate = SState {stomv = newstomv, nextrowmv = newnextrowmv,
                            dbo = indbo, squery = query}
       return $ Statement {execute = fexecute sstate query,
                           executeMany = fexecutemany sstate query,
                           finish = public_ffinish sstate,
                           fetchRow = ffetchrow sstate,
                           originalQuery = query}

{- For now, we try to just  handle things as simply as possible.
FIXME lots of room for improvement here (types, etc). -}
fexecute sstate args = 
    do public_ffinish sstate
       
       resptr <- pqexecParams (dbo sstate) (squery sstate)
                 (genericLength args) nullPtr csargs nullPtr nullPtr 0
                 


{- General algorithm: find out how many columns we have, check the type
of each to see if it's NULL.  If it's not, fetch it as text and return that.

Note that execute() will have already loaded up the first row -- and we
do that each time.  so this function returns the row that is already in sqlite,
then loads the next row. -}
ffetchrow :: SState -> IO (Maybe [SqlValue])
ffetchrow sstate = modifyMVar (stomv sstate) dofetchrow
    where dofetchrow Empty = return (Empty, Nothing)
          dofetchrow (Prepared _) = 
              throwDyn $ SqlError {seState = "HDBC Sqlite3 fetchrow",
                                   seNativeError = 0,
                                   seErrorMsg = "Attempt to fetch row from Statement that has not been executed.  Query was: " ++ (query sstate)}
          dofetchrow (Executed sto) = withStmt sto (\p ->
              do ccount <- sqlite3_column_count p
                 -- fetch the data
                 res <- mapM (getCol p) [0..(ccount - 1)]
                 r <- fstep (dbo sstate) p
                 if r
                    then return (Executed sto, Just res)
                    else do ffinish (dbo sstate) sto
                            return (Empty, Just res)
                                                         )
 
          getCol p icol = 
             do t <- sqlite3_column_type p icol
                if t == #{const SQLITE_NULL}
                   then return SqlNull
                   else do text <- sqlite3_column_text p icol
                           len <- sqlite3_column_bytes p icol
                           s <- peekCStringLen (text, fromIntegral len)
                           return (SqlString s)

fstep :: Sqlite3 -> Ptr CStmt -> IO Bool
fstep dbo p =
    do r <- sqlite3_step p
       case r of
         #{const SQLITE_ROW} -> return True
         #{const SQLITE_DONE} -> return False
         #{const SQLITE_ERROR} -> checkError "step" dbo #{const SQLITE_ERROR}
                                   >> (throwDyn $ SqlError 
                                          {seState = "",
                                           seNativeError = 0,
                                           seErrorMsg = "In HDBC step, internal processing error (got SQLITE_ERROR with no error)"})
         x -> throwDyn $ SqlError {seState = "",
                                   seNativeError = fromIntegral x,
                                   seErrorMsg = "In HDBC step, unexpected result from sqlite3_step"}

fexecute sstate args = modifyMVar (stomv sstate) doexecute
    where doexecute (Executed sto) = ffinish (dbo sstate) sto >> doexecute Empty
          doexecute Empty =     -- already cleaned up from last time
              do sto <- fprepare sstate
                 doexecute (Prepared sto)
          doexecute (Prepared sto) = withStmt sto (\p -> 
              do c <- sqlite3_bind_parameter_count p
                 when (c /= genericLength args)
                   (throwDyn $ SqlError {seState = "",
                                         seNativeError = (-1),
                                         seErrorMsg = "In HDBC execute, received " ++ (show args) ++ " but expected " ++ (show c) ++ " args."})
                 sqlite3_reset p >>= checkError "execute (reset)" (dbo sstate)
                 zipWithM_ (bindArgs p) [1..c] args
                 r <- fstep (dbo sstate) p
                 if r
                    then return (Executed sto, (-1))
                    else do ffinish (dbo sstate) sto
                            return (Empty, 0)
                                                        )
          bindArgs p i SqlNull =
              sqlite3_bind_null p i >>= 
                checkError ("execute (binding NULL column " ++ (show i) ++ ")")
                           (dbo sstate)
          bindArgs p i arg = withCStringLen (fromSql arg) 
             (\(cs, len) -> do r <- sqlite3_bind_text2 p i cs 
                                    (fromIntegral len)
                               checkError ("execute (binding column " ++ 
                                           (show i) ++ ")") (dbo sstate) r
             )

-- FIXME: needs a faster algorithm.
fexecutemany sstate arglist =
    mapM (fexecute sstate) arglist >>= return . genericLength

--ffinish o = withForeignPtr o (\p -> sqlite3_finalize p >>= checkError "finish")
-- Finish and change state
public_ffinish sstate = modifyMVar_ (stomv sstate) worker
    where worker (Empty) = return Empty
          worker (Prepared sto) = ffinish (dbo sstate) sto >> return Empty
          worker (Executed sto) = ffinish (dbo sstate) sto >> return Empty
    
ffinish dbo o = withRawStmt o (\p -> do r <- sqlite3_finalize p
                                        checkError "finish" dbo r)

foreign import ccall unsafe "hdbc-sqlite3-helper.h &sqlite3_finalize_finalizer"
  sqlite3_finalizeptr :: FunPtr ((Ptr CStmt) -> IO ())

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_finalize_app"
  sqlite3_finalize :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_prepare2"
  sqlite3_prepare :: (Ptr CSqlite3) -> CString -> CInt -> Ptr (Ptr CStmt) -> Ptr (Ptr CString) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_bind_parameter_count"
  sqlite3_bind_parameter_count :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_step"
  sqlite3_step :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_reset"
  sqlite3_reset :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_column_count"
  sqlite3_column_count :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_column_type"
  sqlite3_column_type :: (Ptr CStmt) -> CInt -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_column_text"
  sqlite3_column_text :: (Ptr CStmt) -> CInt -> IO CString

foreign import ccall unsafe "sqlite3.h sqlite3_column_bytes"
  sqlite3_column_bytes :: (Ptr CStmt) -> CInt -> IO CInt

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_bind_text2"
  sqlite3_bind_text2 :: (Ptr CStmt) -> CInt -> CString -> CInt -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_bind_null"
  sqlite3_bind_null :: (Ptr CStmt) -> CInt -> IO CInt