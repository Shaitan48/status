# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SQL_XML_QUERY.ps1
# --- Версия 2.1.4 --- Упрощена очистка XML-строки, усилено логирование.

<#
.SYNOPSIS
    Выполняет SQL-запрос, извлекает XML из указанного столбца первой строки,
    парсит XML и извлекает значения по заданному списку ключей. (v2.1.4)
# ... (описание без изменений) ...
.NOTES
    Версия: 2.1.4
    Изменения:
    - Упрощена логика очистки XML-строки перед парсингом.
      Теперь используется только Trim() и проверка на начальный '<'.
      XmlDocument.LoadXml() должен сам справляться с BOM.
    - Усилено логирование xml_content_sample до и после попытки парсинга.
    Зависит от New-CheckResultObject, Test-SuccessCriteria.
    Требует модуль 'SqlServer'.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIP,
    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node (SQL_XML_QUERY)"
)

# --- Инициализация ---
$isAvailable = $false; $checkSuccess = $null; $errorMessage = $null; $finalResult = $null
$details = @{
    server_instance   = $TargetIP; database_name     = $null; query_executed    = $null;
    xml_source_column = $null; rows_returned     = 0; extracted_data    = @{};
    xml_content_sample = $null
}
$DatabaseName = "[UnknownDB]"; $SqlQuery = "[UnknownQuery]"; $XmlColumnName = "[UnknownXMLColumn]"

$logTargetDisplay = if (-not [string]::IsNullOrWhiteSpace($TargetIP)) { $TargetIP } else { "[SQL Server не указан]" }
Write-Verbose "[$NodeName] Check-SQL_XML_QUERY (v2.1.4): Начало. Сервер: $logTargetDisplay"

try {
    # --- 1. Извлечение и валидация параметров ---
    # ... (код валидации параметров тот же) ...
    if (-not $Parameters.ContainsKey('sql_database') -or [string]::IsNullOrWhiteSpace($Parameters.sql_database)) { throw "Отсутствует 'sql_database'." }; $DatabaseName = $Parameters.sql_database.Trim(); $details.database_name = $DatabaseName
    if (-not $Parameters.ContainsKey('sql_query') -or [string]::IsNullOrWhiteSpace($Parameters.sql_query)) { throw "Отсутствует 'sql_query'." }; $SqlQuery = $Parameters.sql_query.Trim(); $details.query_executed = $SqlQuery
    if (-not $Parameters.ContainsKey('xml_column_name') -or [string]::IsNullOrWhiteSpace($Parameters.xml_column_name)) { throw "Отсутствует 'xml_column_name'." }; $XmlColumnName = $Parameters.xml_column_name.Trim(); $details.xml_source_column = $XmlColumnName
    if (-not $Parameters.ContainsKey('keys_to_extract') -or -not ($Parameters.keys_to_extract -is [array]) -or $Parameters.keys_to_extract.Count -eq 0 -or ($Parameters.keys_to_extract | Where-Object {[string]::IsNullOrWhiteSpace($_)})) { throw "'keys_to_extract' должен быть непустым массивом строк." }
    $KeysToExtract = @($Parameters.keys_to_extract | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    $SqlUsername = $null; if ($Parameters.ContainsKey('sql_username')) { $SqlUsername = $Parameters.sql_username }
    $SqlPassword = $null; if (-not [string]::IsNullOrWhiteSpace($SqlUsername)) { if (-not $Parameters.ContainsKey('sql_password') -or $Parameters.sql_password -eq $null) { throw "'sql_password' обязателен при 'sql_username'." }; $SqlPassword = $Parameters.sql_password }
    $QueryTimeoutSec = 30; if ($Parameters.ContainsKey('query_timeout_sec') -and $Parameters.query_timeout_sec -ne $null) { $parsedTimeout = 0; if ([int]::TryParse($Parameters.query_timeout_sec.ToString(), [ref]$parsedTimeout) -and $parsedTimeout -gt 0) { $QueryTimeoutSec = $parsedTimeout } else { Write-Warning "[$NodeName] SQL-XML: Некорректное 'query_timeout_sec'. Исп. $QueryTimeoutSec сек." } }; Write-Verbose "[$NodeName] SQL-XML: query_timeout_sec: $QueryTimeoutSec сек."

    # --- 2. Подготовка параметров для Invoke-Sqlcmd ---
    $invokeSqlParams = @{ ServerInstance = $TargetIP; Database = $DatabaseName; Query = $SqlQuery; QueryTimeout = $QueryTimeoutSec; ErrorAction = 'Stop'; TrustServerCertificate = $true; OutputSqlErrors = $true }
    if (-not [string]::IsNullOrWhiteSpace($SqlUsername)) { $invokeSqlParams.Credential = New-Object System.Management.Automation.PSCredential($SqlUsername, (ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force)); Write-Verbose "[$NodeName] SQL-XML: SQL Auth для '$SqlUsername'." } else { Write-Verbose "[$NodeName] SQL-XML: Windows Auth." }

    # --- 3. Проверка модуля SqlServer ---
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) { Write-Warning "[$NodeName] SQL-XML: Invoke-Sqlcmd не найден. Импорт 'SqlServer'..."; try { Import-Module SqlServer -ErrorAction Stop -Scope Local } catch { throw "Модуль 'SqlServer' не установлен/импортируется. Ошибка: $($_.Exception.Message)" } }

    # --- 4. Выполнение SQL-запроса ---
    Write-Verbose "[$NodeName] SQL-XML: Выполнение запроса к '$TargetIP/$DatabaseName'..."
    $queryResultData = Invoke-Sqlcmd @invokeSqlParams
    $isAvailable = $true; Write-Verbose "[$NodeName] SQL-XML: SQL-запрос выполнен."

    # --- 5. Обработка результата SQL и извлечение XML-строки ---
    $xmlStringContent = $null; $sqlErrorMessage = $null
    if ($null -ne $queryResultData) {
        $queryResultArray = @($queryResultData); $details.rows_returned = $queryResultArray.Count; Write-Verbose "[$NodeName] SQL-XML: Запрос вернул $($details.rows_returned) строк(у)."
        if ($details.rows_returned -gt 0) {
            $firstRow = $queryResultArray[0]
            if ($firstRow.PSObject.Properties.Name -contains $XmlColumnName) {
                $xmlValueFromDb = $firstRow.$XmlColumnName
                if ($null -ne $xmlValueFromDb -and $xmlValueFromDb -ne [System.DBNull]::Value) { $xmlStringContent = $xmlValueFromDb.ToString(); if ([string]::IsNullOrWhiteSpace($xmlStringContent)) { $sqlErrorMessage = "Столбец '$XmlColumnName' пуст."; $xmlStringContent = $null } else { Write-Verbose "[$NodeName] SQL-XML: Получена непустая XML-строка из '$XmlColumnName'." } }
                else { $sqlErrorMessage = "Столбец '$XmlColumnName' содержит DBNull или PowerShell `$null." }
            } else { $sqlErrorMessage = "Столбец '$XmlColumnName' не найден. Доступные: $($firstRow.PSObject.Properties.Name -join ', ')." }
        } else { $details.message = "SQL-запрос не вернул строк, XML отсутствует."; Write-Verbose "[$NodeName] SQL-XML: $($details.message)" }
    } else { $details.message = "SQL-запрос не вернул данных (Invoke-Sqlcmd вернул `$null)."; Write-Verbose "[$NodeName] SQL-XML: $($details.message)" }
    if ($null -ne $sqlErrorMessage) { $errorMessage = $sqlErrorMessage; $details.error = $sqlErrorMessage; Write-Warning "[$NodeName] SQL-XML: $sqlErrorMessage" }

    # --- 6. Парсинг XML и извлечение ключей ---
    if ($isAvailable -and (-not [string]::IsNullOrWhiteSpace($xmlStringContent))) {
        Write-Verbose "[$NodeName] SQL-XML: Попытка парсинга XML из столбца '$XmlColumnName'."
        
        # --- УПРОЩЕННАЯ ОЧИСТКА XML ---
        $cleanXmlString = $xmlStringContent.Trim()
        # $xmlDoc.LoadXml() обычно сам справляется с BOM, если строка в правильной кодировке.
        # Не будем делать сложную ручную очистку BOM, чтобы не отрезать лишнего.
        # --- КОНЕЦ УПРОЩЕННОЙ ОЧИСТКИ ---

        $details.xml_content_sample = if ($cleanXmlString.Length -gt 250) { $cleanXmlString.Substring(0,250) + "..." } else { $cleanXmlString }
        Write-Debug "[$NodeName] SQL-XML: XML-строка для парсинга (начало): $($details.xml_content_sample)"

        $xmlDoc = $null
        try {
            # Проверка на начальный '<' остается, т.к. это базовый признак XML
            if (-not $cleanXmlString.StartsWith("<")) { 
                throw "Содержимое столбца '$XmlColumnName' не является валидным XML (не начинается с '<' после Trim())." 
            }
            
            $xmlDoc = New-Object System.Xml.XmlDocument
            $xmlDoc.LoadXml($cleanXmlString) # Пытаемся загрузить "как есть" после Trim()
            
            if ($null -eq $xmlDoc.DocumentElement) { throw "XML не содержит корневого элемента после парсинга." }
            Write-Verbose "[$NodeName] SQL-XML: XML успешно распарсен."
            
            $extractedKeyValues = @{}; 
            foreach ($keyToExtract in $KeysToExtract) { 
                $nodeValue = $null
                # Ищем элемент как прямой потомок корневого элемента, игнорируя namespace по умолчанию
                $xmlNode = $xmlDoc.DocumentElement.SelectSingleNode("./*[local-name()='$keyToExtract']")
                if ($null -ne $xmlNode) { $nodeValue = $xmlNode.InnerText }
                $extractedKeyValues[$keyToExtract] = $nodeValue
                Write-Verbose "[$NodeName] SQL-XML: Извлечен ключ '$keyToExtract' = '$nodeValue'"
            }
            $details.extracted_data = $extractedKeyValues

        } catch {
            $parsingErrorMessage = "Ошибка парсинга/обработки XML из '$XmlColumnName': $($_.Exception.Message)"
            $errorMessage = if ([string]::IsNullOrEmpty($errorMessage)) { $parsingErrorMessage } else { "$errorMessage; $parsingErrorMessage" }
            # Добавляем ошибку парсинга к существующим ошибкам в $details.error или устанавливаем ее
            $details.error = if ($details.ContainsKey('error') -and -not [string]::IsNullOrEmpty($details.error)) {"$($details.error); $parsingErrorMessage"} else {$parsingErrorMessage}
            $details.ErrorRecord = $_.ToString() # Перезаписываем ErrorRecord последней ошибкой (парсинга)
            Write-Warning "[$NodeName] SQL-XML: $parsingErrorMessage"
            # Если парсинг XML не удался, считаем проверку недоступной в полной мере
            $isAvailable = $false 
        }
    }

    # --- 7. Проверка критериев успеха ---
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] SQL-XML: Вызов Test-SuccessCriteria..."
            $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
            $checkSuccess = $criteriaProcessingResult.Passed
            $failReasonFromCriteria = $criteriaProcessingResult.FailReason
            if ($checkSuccess -ne $true) {
                $currentErrorMessage = if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) { $failReasonFromCriteria }
                                         else { 
                                             $checkSuccessDisplay = if ($null -eq $checkSuccess) { '[null]' } else { $checkSuccess.ToString() }
                                             "Критерии для XML не пройдены (CheckSuccess: $checkSuccessDisplay)."
                                         }
                $errorMessage = if ([string]::IsNullOrEmpty($errorMessage)) { $currentErrorMessage } else { "$errorMessage; $currentErrorMessage" }
                Write-Verbose "[$NodeName] SQL-XML: Критерии НЕ пройдены. Error: $errorMessage"
            } else { 
                # Если критерии пройдены, но ранее была ошибка (например, ключ не найден, но это OK по критериям),
                # то $errorMessage уже будет установлен. Не перезаписываем его на $null, если он содержит информацию.
                if ($null -eq $details.error) {$errorMessage = $null} 
                Write-Verbose "[$NodeName] SQL-XML: Критерии пройдены."
            }
        } else { 
            $checkSuccess = if ($null -eq $details.error) { $true } else { $false }
            if ($checkSuccess -eq $true) { $errorMessage = $null } # Очищаем, если не было ошибок в деталях
            Write-Verbose "[$NodeName] SQL-XML: Критерии не заданы. CheckSuccess=$checkSuccess (на основе $details.error)."
        }
    } else { 
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) { 
            $errorMessage = "Ошибка SQL/XML (IsAvailable=false), критерии не проверялись."
        }
    }

    # --- 8. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable -CheckSuccess $checkSuccess -Details $details -ErrorMessage $errorMessage
} catch {
    $isAvailable = $false; $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message; if ($_.Exception.InnerException) { $exceptionMessage += " Внутренняя ошибка: $($_.Exception.InnerException.Message)"}
    $critErrorMessageFromCatch = "Критическая ошибка в Check-SQL_XML_QUERY для '$($TargetIP)/$($DatabaseName)' (Запрос: '$($SqlQuery.Substring(0, [System.Math]::Min($SqlQuery.Length, 50)))...', XML-столбец: '$XmlColumnName'): $exceptionMessage"
    Write-Error "[$NodeName] Check-SQL_XML_QUERY: $critErrorMessageFromCatch ScriptStackTrace: $($_.ScriptStackTrace)"
    if ($null -eq $details) { $details = @{} }; if (-not $details.ContainsKey('server_instance')) { $details.server_instance = $TargetIP }; if (-not $details.ContainsKey('database_name')) { $details.database_name = $DatabaseName }; if (-not $details.ContainsKey('query_executed')) { $details.query_executed = $SqlQuery }; if (-not $details.ContainsKey('xml_source_column')) { $details.xml_source_column = $XmlColumnName }
    $details.error = if ($details.ContainsKey('error') -and -not [string]::IsNullOrEmpty($details.error)) {"$($details.error); $critErrorMessageFromCatch"} else {$critErrorMessageFromCatch}
    $details.ErrorRecord = $_.ToString()
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable -CheckSuccess $checkSuccess -Details $details -ErrorMessage $critErrorMessageFromCatch
}

# --- Отладка и возврат ---
if ($MyInvocation.BoundParameters.Debug -or ($DebugPreference -ne 'SilentlyContinue' -and $DebugPreference -ne 'Ignore')) {
    Write-Host "DEBUG (Check-SQL_XML_QUERY): --- Начало отладки finalResult.Details ---" -ForegroundColor Green
    if ($finalResult -and $finalResult.Details) { 
        Write-Host "DEBUG: Тип: $($finalResult.Details.GetType().FullName), Ключи: $($finalResult.Details.Keys -join ', ')" -FG Green
        Write-Host "DEBUG: XML Sample в Details: '$($finalResult.Details.xml_content_sample)'" -FG DarkCyan
        Write-Host "DEBUG: Extracted Data: $($finalResult.Details.extracted_data | ConvertTo-Json -Compress -Depth 2)" -FG DarkCyan
    }
    elseif ($finalResult) { Write-Host "DEBUG: finalResult.Details `$null." -FG Yellow } 
    else { Write-Host "DEBUG: finalResult `$null." -FG Red }
    Write-Host "DEBUG (Check-SQL_XML_QUERY): --- Конец отладки ---" -ForegroundColor Green
}
$isAvailableStrForLog = if ($finalResult) { $finalResult.IsAvailable.ToString() } else { '[N/A]' }
$checkSuccessStrForLog = if ($finalResult) { if ($null -eq $finalResult.CheckSuccess) { '[null]' } else { $finalResult.CheckSuccess.ToString() } } else { '[N/A]' }
Write-Verbose "[$NodeName] Check-SQL_XML_QUERY (v2.1.4): Завершение. IsAvailable=$isAvailableStrForLog, CheckSuccess=$checkSuccessStrForLog"
return $finalResult