-- F:\status\source\testDB_kaskad\init-db.sql (Упрощенный)
-- Создает БД и таблицу для тестов Kaskad

-- Создаем базу данных, если она еще не существует
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

-- Создаем таблицу, если она еще не существует
IF OBJECT_ID('dbo.ReviseData', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReviseData (
        id INT PRIMARY KEY,
        CreationDate DATETIME,
        Revise NVARCHAR(MAX), -- Используем NVARCHAR(MAX) для XML
        UTCTime DATETIME
    );
    PRINT 'Table "dbo.ReviseData" created.';
END
ELSE
BEGIN
    PRINT 'Table "dbo.ReviseData" already exists.';
END
GO