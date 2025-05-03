<#
.SYNOPSIS
    Выполняет SQL-запрос, извлекает XML из указанного столбца
    и парсит значения по ключам.
.DESCRIPTION
    Подключается к MS SQL Server, выполняет SQL-запрос, ожидает XML
    в указанном столбце первой строки результата, парсит XML и извлекает
    текстовые значения элементов по заданному списку ключей.
.PARAMETER TargetIP
    [string] Имя или IP-адрес SQL Server instance (например, "SERVER\SQLEXPRESS").
.PARAMETER Parameters
    [hashtable] Обязательный. Содержит параметры:
    - sql_database (string):   Имя базы данных. Обязательно.
    - sql_query (string):      SQL-запрос. Должен возвращать столбец с XML. Обязательно.
    - xml_column_name (string): Имя столбца с XML. Обязательно.
    - keys_to_extract (string[]): Массив имен XML-элементов (ключей) для извлечения. Обязательно.
    - sql_username (string):   Имя пользователя SQL Server (опционально).
    - sql_password (string):   Пароль пользователя SQL Server (опционально, небезопасно).
    - query_timeout_sec (int): Таймаут запроса в секундах (опционально, по умолч. 30).
.PARAMETER SuccessCriteria
    [hashtable] Необязательный. Критерии успеха (ПОКА НЕ РЕАЛИЗОВАНЫ).
.PARAMETER NodeName
    [string] Необязательный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
                Details содержит хеш-таблицу 'extracted_data'.
.NOTES
    Версия: 1.1 (Добавлен параметр SuccessCriteria, но без реализации логики).
    Зависит от функции New-CheckResultObject и модуля SqlServer.
    Требует прав доступа к SQL Server.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP, # Используется как ServerInstance

    [Parameter(Mandatory=$true)]
    [hashtable]$Parameters,

    [Parameter(Mandatory=$false)] # <<<< ДОБАВЛЕН ПАРАМЕТР
    [hashtable]$SuccessCriteria = $null,

    [Parameter(Mandatory=$false)]
    [string]$NodeName = "Unknown Node"
)

# --- Загрузка вспомогательной функции ---
if (-not (Get-Command New-CheckResultObject -ErrorAction SilentlyContinue)) {
    try {
        $commonFunctionsPath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils.psm1"
        if(Test-Path $commonFunctionsPath) { . $commonFunctionsPath }
        else { throw "Не найден файл общего модуля: $commonFunctionsPath" }
    } catch {
        Write-Error "Check-SQL_XML_QUERY: Критическая ошибка: Не удалось загрузить New-CheckResultObject! $($_.Exception.Message)"
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}

# --- Инициализация результата ---
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{
        extracted_data = @{} # Для извлеченных данных
        query_executed = $null
        xml_source_column = $null
        rows_returned = 0
    }
    ErrorMessage = $null
}

Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Начало выполнения SQL XML запроса на $TargetIP"

try {
    # 1. Валидация и извлечение параметров
    $SqlServerInstance = $TargetIP
    $DatabaseName = $Parameters.sql_database
    $SqlQuery = $Parameters.sql_query
    $XmlColumnName = $Parameters.xml_column_name
    $KeysToExtract = $Parameters.keys_to_extract
    $SqlUsername = $Parameters.sql_username
    $SqlPassword = $Parameters.sql_password
    $QueryTimeoutSec = $Parameters.query_timeout_sec | Get-OrElse 30

    # Запись в Details для логгирования/отладки
    $resultData.Details.query_executed = $SqlQuery
    $resultData.Details.xml_source_column = $XmlColumnName

    # Проверка обязательных параметров
    if (-not $DatabaseName) { throw "Отсутствует обязательный параметр 'sql_database'." }
    if (-not $SqlQuery) { throw "Отсутствует обязательный параметр 'sql_query'." }
    if (-not $XmlColumnName) { throw "Отсутствует обязательный параметр 'xml_column_name'." }
    if (-not ($KeysToExtract -is [array]) -or $KeysToExtract.Count -eq 0) {
        throw "Параметр 'keys_to_extract' должен быть непустым массивом строк."
    }
    if ($SqlUsername -and (-not $SqlPassword)) { throw "Параметр 'sql_password' обязателен при указании 'sql_username'." }
    if (-not ([int]::TryParse($QueryTimeoutSec, [ref]$null)) -or $QueryTimeoutSec -le 0) {
         Write-Warning "[$NodeName] Некорректное значение query_timeout_sec ('$($Parameters.query_timeout_sec)'). Используется 30 сек."; $QueryTimeoutSec = 30
    }

    # 2. Формирование параметров для Invoke-Sqlcmd
    $invokeSqlParams = @{ ServerInstance = $SqlServerInstance; Database = $DatabaseName; Query = $SqlQuery; QueryTimeout = $QueryTimeoutSec; ErrorAction = 'Stop' }
    if ($SqlUsername) {
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Используется SQL аутентификация для '$SqlUsername'."
        $securePassword = ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force
        $invokeSqlParams.Credential = New-Object System.Management.Automation.PSCredential($SqlUsername, $securePassword)
    } else { Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Используется Windows аутентификация." }

    # 3. Проверка модуля SqlServer
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -ListAvailable -Name SqlServer)) { throw "Модуль 'SqlServer' не найден. Установите его." }
        try { Import-Module SqlServer -ErrorAction Stop } catch { throw "Не удалось загрузить модуль 'SqlServer'. Ошибка: $($_.Exception.Message)" }
    }

    # 4. Выполнение SQL-запроса
    Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Выполнение запроса к '$SqlServerInstance/$DatabaseName'..."
    $queryResult = Invoke-Sqlcmd @invokeSqlParams
    $resultData.IsAvailable = $true # Если нет ошибки, запрос прошел

    # 5. Обработка результата
    $xmlString = $null
    if ($queryResult -ne $null) {
        if ($queryResult -isnot [array]) { $queryResult = @($queryResult) }
        $resultData.Details.rows_returned = $queryResult.Count

        if ($queryResult.Count -gt 0) {
            $firstRow = $queryResult[0]
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Запрос вернул строк: $($queryResult.Count). Обработка первой строки."
            if ($firstRow.PSObject.Properties.Name -contains $XmlColumnName) {
                $xmlValue = $firstRow.$XmlColumnName
                if ($xmlValue -ne $null -and $xmlValue -ne [System.DBNull]::Value) {
                    $xmlString = $xmlValue.ToString()
                    Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Получен XML из столбца '$XmlColumnName'."
                } else { $resultData.ErrorMessage = "Столбец '$XmlColumnName' в первой строке пуст (NULL)."; $resultData.CheckSuccess = $false }
            } else { $resultData.ErrorMessage = "Столбец '$XmlColumnName' не найден в результате запроса."; $resultData.CheckSuccess = $false }
        } else { $resultData.Details.message = "Запрос не вернул строк."; $resultData.CheckSuccess = $true }
    } else { $resultData.Details.message = "Запрос не вернул данных (возможно, non-query?)."; $resultData.CheckSuccess = $true }

    # 6. Парсинг XML и извлечение ключей
    if ($xmlString -and $resultData.CheckSuccess -ne $false) { # Парсим только если есть XML и не было ошибки ранее
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Парсинг XML..."
        try {
            [xml]$xmlDoc = $xmlString
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: XML успешно распарсен."
            if ($null -eq $xmlDoc.DocumentElement) { throw "Корневой элемент в XML не найден." }

            $extractedData = @{}
            foreach ($key in $KeysToExtract) {
                $value = $null
                # Ищем элемент с таким именем среди дочерних корневого
                $xmlElement = $xmlDoc.DocumentElement.SelectSingleNode("./*[local-name()='$key']") # Устойчивость к namespace
                if ($xmlElement -ne $null) {
                    $value = $xmlElement.InnerText # Получаем текстовое содержимое
                }
                $extractedData[$key] = $value # Сохраняем значение (или null)
                Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Ключ '$key', Значение: '$value'"
            }
            $resultData.Details.extracted_data = $extractedData
            $resultData.CheckSuccess = $true # Если дошли сюда, парсинг успешен

        } catch {
            # Ошибка парсинга XML
            $errorMessage = "Ошибка парсинга XML из столбца '$XmlColumnName': $($_.Exception.Message)"
            if ($errorMessage.Length -gt 500) { $errorMessage = $errorMessage.Substring(0, 500) + "..." }
            $resultData.ErrorMessage = $errorMessage
            $resultData.Details.error = $errorMessage
            $resultData.Details.xml_content_sample = $xmlString.Substring(0, [math]::Min($xmlString.Length, 200)) + "..."
            $resultData.CheckSuccess = $false # Парсинг не удался
        }
    }

    # 7. Обработка SuccessCriteria (ПОКА НЕ РЕАЛИЗОВАНА)
    if ($resultData.IsAvailable -and $resultData.CheckSuccess -and $SuccessCriteria -ne $null) {
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: SuccessCriteria переданы, но их обработка пока не реализована."
        # Здесь можно сравнивать значения из $resultData.Details.extracted_data с $SuccessCriteria
        # if ($resultData.Details.extracted_data.VersionStat -ne $SuccessCriteria.expected_version) {
        #     $resultData.CheckSuccess = $false
        #     $resultData.ErrorMessage = "Значение VersionStat не совпадает с ожидаемым."
        # }
    }


} catch {
    # Обработка ошибок Invoke-Sqlcmd или других
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "Ошибка выполнения SQL XML запроса: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    Write-Error "[$NodeName] Check-SQL_XML_QUERY: Критическая ошибка: $errorMessage"
}

# Финальная установка CheckSuccess, если ошибка сделала его null
if ($resultData.IsAvailable -eq $false) { $resultData.CheckSuccess = $null }
elseif ($resultData.CheckSuccess -eq $null) { $resultData.CheckSuccess = $true } # Если IsAvailable=true и не было ошибок -> успех

# Вызов New-CheckResultObject
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Завершение. IsAvailable=$($finalResult.IsAvailable), CheckSuccess=$($finalResult.CheckSuccess)"
return $finalResult