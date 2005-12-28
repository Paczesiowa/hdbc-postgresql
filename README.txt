Welcome to HDBC, Haskell Database Connectivity.

This package provides a database backend driver for PostgreSQL.

Please see HDBC itself for documentation on use.  If you don't already
have it, you can browse this documentation at
http://darcs.complete.org/hdbc/doc/index.html.

This package provides one function in module Database.HDBC.PostgreSQL:

{- | Connect to a PostgreSQL server.

See <http://www.postgresql.org/docs/8.1/static/libpq.html#LIBPQ-CONNECT> for the meaning
of the connection string. -}
connectPostgreSQL :: String -> IO Connection

An example would be:
dbh <- connectPostgreSQL "host=localhost dbname=testdb user=foo"

DIFFERENCES FROM HDBC STANDARD
------------------------------

None known at this time.

PREREQUISITES
-------------

Before installing this package, you'll need to have HDBC 0.99.0 or
above installed.  You can download HDBC from http://quux.org/devel/hdbc.

INSTALLATION
------------

The steps to install are:

1) ghc --make -o setup Setup.lhs

2) ./setup configure

3) ./setup build

4) ./setup install   (as root)

If you're on Windows, you can omit the leading "./".

USAGE
-----

To use with hugs, you'll want to use hugs -98.

To use with GHC, you'll want to use:

 -package HDBC -package HDBC-postgresql

Or, with Cabal, use:

  Build-Depends: HDBC>=0.99.0, HDBC-postgresql

-- John Goerzen
   December 2005