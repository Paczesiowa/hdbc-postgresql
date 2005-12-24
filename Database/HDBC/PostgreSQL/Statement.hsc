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
             nextrowmv :: MVar (Int), -- -1 for no next row (empty); otherwise, next row to read.
             dbo :: Conn,
             squery :: String}

-- FIXME: we currently do no prepare optimization whatsoever.

newSth :: CConn -> String -> IO Statement               
newSth indbo query = 
    do newstomv <- newMVar Nothing
       newnextrowmv <- newMVar (-1)
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
    do public_ffinish sstate    -- Sets nextrowmv to -1
       resptr <- pqexecParams (dbo sstate) (squery sstate)
                 (genericLength args) nullPtr csargs nullPtr nullPtr 0
       status <- pqresultStatus resptr
       case status of
         #{const PGRES_EMPTY_QUERY} ->
             do pqclear resptr
                return (-1)
         #{const PGRES_COMMAND_OK} ->
             do rowscs <- pqcmdTuples resptr
                rows <- peekCString rowscs
                pqclear resptr
                return $ case rows of
                                   "" -> (-1)
                                   x -> read x
         #{const PGRES_TUPLES_OK} -> 
             do numrows <- pqntuples resptr
                if numrows < 1
                   then do pqclear resptr
                           return numrows
                   else do fresptr <- newForeignPtr resptr pqclearptr
                           swapMVar (nextrowmv sstate) 0
                           swapMVar (stomv sstate) fresptr
                           return (-1)
         _ -> do csstatusmsg <- pqresStatus status
                 cserrormsg <- pqresultErrorMessage resptr
                 statusmsg <- peekCString csstatusmsg
                 errormsg <- peekCString cserrormsg
                 pqclear resptr
                 throwDyn $ 
                          SqlError {seState = "",
                                    seNativeError = fromIntegral status,
                                    seErrorMsg = "execute: " ++ statusmsg ++
                                                 ": " ++ errormsg}
{- General algorithm: find out how many columns we have, check the type
of each to see if it's NULL.  If it's not, fetch it as text and return that.
-}

ffetchrow :: SState -> IO (Maybe [SqlValue])
ffetchrow sstate = modifyMVar (nextrowmv sstate) dofetchrow
    where dofetchrow (-1) = return ((-1), Nothing)
          dofetchrow nextrow = withMVar (stomv sstate) $ \stmt -> 
                               withStmt stmt $ \cstmt ->
             do numrows <- pqntuples cstmt
                if nextrow >= numrows
                   then do public_ffinish sstate
                           return ((-1), Nothing)
                   else do ncols <- pqnfields cstmt
                           res <- mapM (getCol nextrow cstmt) [0..(ncols - 1)]
                           return (nextrow + 1, Just res)
          getCol p row icol = 
             do isnull <- pqgetisnull p row icol
                if isnull /= 0
                   then return SqlNull
                   else do text <- pqgetvalue p row icol
                           s <- peekCString text
                           return (SqlString s)

-- FIXME: needs a faster algorithm.
fexecutemany sstate arglist =
    mapM_ (fexecute sstate) arglist >> return ()

-- Finish and change state
public_ffinish sstate = 
    do swapMVar (nextrowmv sstate) (-1)
       modifyMVar_ (stomv sstate) (\sth -> ffinish sth >> return Nothing)

ffinish :: Stmt -> IO ()
ffinish = finalizeForeignPtr

foreign import ccall unsafe "libpq-fe.h PQresultStatus"
  pqresultStatus :: (Ptr CStmt) -> IO #{type ExecStatusType}

foreign import ccall unsafe "libpq-fe.h PQexecParams"
  pqexecParams :: (Ptr CConn) -> CString -> CInt ->
                  (Ptr #{type Oid}) ->
                  (Ptr CString) ->
                  (Ptr CInt) ->
                  (Ptr CInt) ->
                  CInt ->
                  Ptr CStmt

foreign import ccall unsafe "libpq-fe.h &PQclear"
  pqclearptr :: FunPtr ((Ptr CStmt) -> IO ())

foreign import ccall unsafe "libpq-fe.h PQclear"
  pqclear :: Ptr CStmt -> IO ()

foreign import ccall unsafe "libpq-fe.h PQcmdTuples"
  pqcmdTuples :: Ptr CStmt -> IO CString
foreign import ccall unsafe "libpq-fe.h PQresStatus"
  pqresStatus :: #{type ExecStatusType} -> IO CString

foreign import ccall unsafe "libpq-fe.h PQresultErrorMessage"
  pqresultErrorMessage :: (Ptr CStmt) -> IO CString

foreign import ccall unsafe "libpq-fe.h PQntuples"
  pqntuples :: Ptr CStmt -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQnfields"
  pqnfields :: Ptr CStmt -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQgetisnull"
  pqgetisnull :: Ptr CStmt -> CInt -> CInt -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQgetvalue"
  pqgetvalue :: Ptr CStmt -> CInt -> CInt -> IO CString
