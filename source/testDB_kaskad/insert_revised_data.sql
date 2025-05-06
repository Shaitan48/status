-- F:\status\source\testDB_kaskad\insert_revised_data.sql (Идемпотентный)
-- Вставляет или обновляет тестовую запись в kaskad.dbo.ReviseData

USE kaskad;
GO

-- Используем MERGE для вставки или обновления
MERGE dbo.ReviseData AS target
USING (
    SELECT
        1115 AS id,
        CONVERT(DATETIME, '2023-05-01 18:00:26', 120) AS CreationDate, -- Используем безопасный формат 120 (ODBC canonical)
        N'<kaskad_properties><VersionStat>20221206</VersionStat><ArrivalStationID>1516</ArrivalStationID><TS_Version>108</TS_Version><PAK_Version>5.8 build 1073742079</PAK_Version></kaskad_properties>' AS Revise,
        CONVERT(DATETIME, '2023-05-01 15:00:26', 120) AS UTCTime
) AS source
ON (target.id = source.id)
WHEN MATCHED THEN
    UPDATE SET
        target.CreationDate = source.CreationDate,
        target.Revise = source.Revise,
        target.UTCTime = source.UTCTime
WHEN NOT MATCHED THEN
    INSERT (id, CreationDate, Revise, UTCTime)
    VALUES (source.id, source.CreationDate, source.Revise, source.UTCTime);
GO

PRINT 'Test data in dbo.ReviseData inserted or updated.';
GO