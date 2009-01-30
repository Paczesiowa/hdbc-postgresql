module SpecificDB where
import Database.HDBC
import Database.HDBC.PostgreSQL
import Database.HDBC.PostgreSQL.Parser(convertSQL)
import Test.HUnit

connectDB = 
    handleSqlError (connectPostgreSQL "")

dateTimeTypeOfSqlValue :: SqlValue -> String
dateTimeTypeOfSqlValue (SqlLocalDate _) = "date"
dateTimeTypeOfSqlValue (SqlLocalTimeOfDay _) = "time without time zone"
dateTimeTypeOfSqlValue (SqlLocalTime _) = "timestamp without time zone"
dateTimeTypeOfSqlValue (SqlZonedTime _) = "timestamp with time zone"
dateTimeTypeOfSqlValue (SqlUTCTime _) = "timestamp without time zone"
dateTimeTypeOfSqlValue (SqlDiffTime _) = "interval"
dateTimeTypeOfSqlValue (SqlPOSIXTime _) = "integer"
dateTimeTypeOfSqlValue (SqlEpochTime _) = "integer"
dateTimeTypeOfSqlValue (SqlTimeDiff _) = "interval"
dateTimeTypeOfSqlValue _ = "text"
