-- F:\status\source\testDB_kaskad\init-db.sql
IF DB_ID('kaskad') IS NULL
BEGIN
    CREATE DATABASE kaskad;
    PRINT 'Database "kaskad" created.';
END
ELSE
BEGIN
    PRINT 'Database "kaskad" already exists.';
END
GO

USE kaskad;
GO

IF OBJECT_ID('dbo.ReviseData', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReviseData (
        id INT PRIMARY KEY,
        CreationDate DATETIME,
        Revise NVARCHAR(MAX),
        UTCTime DATETIME
    );
    PRINT 'Table "dbo.ReviseData" created.';
END
ELSE
BEGIN
    PRINT 'Table "dbo.ReviseData" already exists.';
END
GO