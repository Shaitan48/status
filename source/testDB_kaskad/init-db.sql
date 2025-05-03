CREATE DATABASE kaskad;
GO

USE kaskad;
GO

CREATE TABLE dbo.ReviseData (
    id INT PRIMARY KEY,
    CreationDate DATETIME,
    Revise NVARCHAR(MAX),
    UTCTime DATETIME
);
GO

-- Создание временной таблицы для загрузки данных из CSV
CREATE TABLE #TempReviseData (
    CreationDate NVARCHAR(255),
    Revise NVARCHAR(MAX),
    id INT,
    UTCTime NVARCHAR(255)
);
GO

-- Загрузка данных из CSV-файла
BULK INSERT #TempReviseData
FROM '/var/opt/mssql/data/kaskad_revise.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',', 
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    TABLOCK
);
GO

-- Вставка из временной таблицы в основную таблицу с преобразованием дат
INSERT INTO dbo.ReviseData (id, CreationDate, Revise, UTCTime)
SELECT id,
       CONVERT(DATETIME, CreationDate, 104),
       Revise,
       CONVERT(DATETIME, UTCTime, 104)
FROM #TempReviseData;
GO

DROP TABLE #TempReviseData;
GO
