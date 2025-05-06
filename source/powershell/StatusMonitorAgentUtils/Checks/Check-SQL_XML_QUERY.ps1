# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SQL_XML_QUERY.ps1
# --- Версия 2.0.2 --- Исправлена зависимость от Get-OrElse
<#
.SYNOPSIS
    Выполняет SQL-запрос, извлекает XML, парсит и извлекает значения ключей. (v2.0.2)
.DESCRIPTION
    Подключается к MS SQL, выполняет запрос, ожидает XML, парсит, извлекает ключи.
    Формирует $Details с полем 'extracted_data'.
    Вызывает Test-SuccessCriteria для определения CheckSuccess.
.NOTES
    Версия: 2.0.2 (Убрана зависимость от Get-OrElse).
    Зависит от New-CheckResultObject, Test-SuccessCriteria.
    Требует модуль 'SqlServer'.
#>
param(
    [Parameter(Mandatory = $true)][string]$TargetIP,
    [Parameter(Mandatory = $false)][hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)][hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)][string]$NodeName = "Unknown Node"
)

# --- Инициализация ---
$isAvailable = $false; $checkSuccess = $null; $errorMessage = $null; $finalResult = $null
$details = @{ server_instance=$TargetIP; database_name=$null; query_executed=$null; xml_source_column=$null; rows_returned=0; extracted_data=@{} }

Write-Verbose "[$NodeName] Check-SQL_XML_QUERY (v2.0.2): Начало выполнения SQL XML на $TargetIP"

try { # <<< Основной TRY >>>
    # 1. Параметры
    $SqlServerInstance = $TargetIP; $DatabaseName = $Parameters.sql_database; $SqlQuery = $Parameters.sql_query; $XmlColumnName = $Parameters.xml_column_name; $KeysToExtract = $Parameters.keys_to_extract; $SqlUsername = $Parameters.sql_username; $SqlPassword = $Parameters.sql_password
    $details.database_name = $DatabaseName; $details.query_executed = $SqlQuery; $details.xml_source_column = $XmlColumnName
    if (-not $DatabaseName) { throw "Отсутствует 'sql_database'." }
    if (-not $SqlQuery) { throw "Отсутствует 'sql_query'." }
    if (-not $XmlColumnName) { throw "Отсутствует 'xml_column_name'." }
    if (-not ($KeysToExtract -is [array]) -or $KeysToExtract.Count -eq 0) { throw "'keys_to_extract' должен быть непустым массивом." }
    if ($SqlUsername -and (-not $SqlPassword)) { throw "'sql_password' обязателен при 'sql_username'." }
    # --- ИСПРАВЛЕНО: Получение query_timeout_sec без Get-OrElse ---
    $QueryTimeoutSec = 30; if ($Parameters.ContainsKey('query_timeout_sec')) { $parsedTimeout=0; if([int]::TryParse($Parameters.query_timeout_sec,[ref]$parsedTimeout) -and $parsedTimeout -gt 0){$QueryTimeoutSec=$parsedTimeout} }
    Write-Verbose "... Используется query_timeout_sec: $QueryTimeoutSec сек."

    # 2. Параметры Invoke-Sqlcmd (без изменений)
    $invokeSqlParams = @{ ServerInstance=$SqlServerInstance; Database=$DatabaseName; Query=$SqlQuery; QueryTimeout=$QueryTimeoutSec; ErrorAction='Stop'; TrustServerCertificate=$true }
    if ($SqlUsername) { $securePassword = ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force; $invokeSqlParams.Credential = New-Object System.Management.Automation.PSCredential($SqlUsername, $securePassword) }

    # 3. Проверка модуля SqlServer (без изменений)
    if (-not (Get-Command Invoke-Sqlcmd -EA SilentlyContinue)) { if (-not (Get-Module -ListAvailable -Name SqlServer)) { throw "Модуль 'SqlServer' не найден." }; try { Import-Module SqlServer -EA Stop } catch { throw "Не удалось загрузить модуль 'SqlServer'." } }

    # 4. Выполнение SQL-запроса
    Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Выполнение запроса..."
    $queryResult = Invoke-Sqlcmd @invokeSqlParams
    $isAvailable = $true

    # 5. Обработка результата и извлечение XML
    $xmlString = $null; $parseXml = $false; $errorMessageFromSqlOrXml = $null
    if ($queryResult -ne $null) {
        if ($queryResult -isnot [array]) { $queryResult = @($queryResult) }
        $details.rows_returned = $queryResult.Count
        if ($queryResult.Count -gt 0) {
            $firstRow = $queryResult[0]; Write-Verbose "... запрос вернул $($queryResult.Count) строк."
            if ($firstRow.PSObject.Properties.Name -contains $XmlColumnName) {
                $xmlValue = $firstRow.$XmlColumnName
                if ($xmlValue -ne $null -and $xmlValue -ne [System.DBNull]::Value) {
                    $xmlString = [string]$xmlValue; if (-not [string]::IsNullOrWhiteSpace($xmlString)) { $parseXml = $true; Write-Verbose "... получен непустой XML." } else { $errorMessageFromSqlOrXml = "Столбец '$XmlColumnName' пуст." }
                } else { $errorMessageFromSqlOrXml = "Столбец '$XmlColumnName' NULL." }
            } else { $errorMessageFromSqlOrXml = "Столбец '$XmlColumnName' не найден." }
        } else { $details.message = "SQL-запрос не вернул строк."; Write-Verbose $details.message }
    } else { $details.message = "SQL-запрос не вернул данных."; Write-Verbose $details.message }
    if ($errorMessageFromSqlOrXml) { $isAvailable = $false; $errorMessage = $errorMessageFromSqlOrXml; $details.error = $errorMessage; Write-Warning "... $errorMessage" }

    # 6. Парсинг XML и извлечение ключей
    if ($isAvailable -and $parseXml) {
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Попытка парсинга XML..."
        $xmlContentSample = $null; $xmlDoc = $null
        try {
            $xmlStringForParsing = $xmlString.Trim(); if ($xmlStringForParsing.StartsWith([char]0xFEFF)) { $xmlStringForParsing = $xmlStringForParsing.Substring(1) }
            if (-not $xmlStringForParsing.StartsWith('<')) { throw "Строка не начинается с '<'." }
            if ($xmlStringForParsing.Length > 500) { $xmlContentSample = $xmlStringForParsing.Substring(0, 500) + "..." } else { $xmlContentSample = $xmlStringForParsing }
            $xmlDoc = New-Object System.Xml.XmlDocument; $xmlDoc.LoadXml($xmlStringForParsing)
            if ($null -eq $xmlDoc.DocumentElement) { throw "Корневой элемент не найден." }
            Write-Verbose "... XML распарсен."
            $extractedData = @{}; foreach ($key in $KeysToExtract) { $value = $null; $el = $xmlDoc.DocumentElement.SelectSingleNode("./*[local-name()='$key']"); if ($el) { $value = $el.InnerText }; $extractedData[$key] = $value; Write-Verbose "... ключ '$key' = '$value'" }; $details.extracted_data = $extractedData
        } catch {
            $isAvailable = $false; $errorMessage = "Ошибка парсинга/обработки XML из '$XmlColumnName': $($_.Exception.Message)"; if ($errorMessage.Length > 500) { $errorMessage = $errorMessage.Substring(0, 500) + "..." }
            $details.error = $errorMessage; $details.ErrorRecord = $_.ToString(); if ($xmlContentSample) { $details.xml_content_sample = $xmlContentSample }; Write-Warning "... $errorMessage"
        }
    }

    # 7. Проверка критериев успеха
    $failReason = $null
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.PSObject.Properties.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Вызов Test-SuccessCriteria..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason
            if ($checkSuccess -ne $true) {
                 # --- ИСПРАВЛЕНО: Используем if вместо Get-OrElse ---
                 $errorMessage = if ([string]::IsNullOrWhiteSpace($failReason)) { "Критерии успеха для XML данных не пройдены." } else { $failReason }
                 Write-Verbose "[$NodeName] ... SuccessCriteria НЕ пройдены/ошибка: $errorMessage"
            } else { $errorMessage = $null; Write-Verbose "[$NodeName] ... SuccessCriteria пройдены." }
        } else {
            $checkSuccess = $true; $errorMessage = $null
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = "Ошибка выполнения SQL XML запроса (IsAvailable=false)." }
    }

    # 8. Формирование результата
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable -CheckSuccess $checkSuccess -Details $details -ErrorMessage $errorMessage

} catch { # <<< Основной CATCH >>>
    $isAvailable = $false; $checkSuccess = $null; $critErrorMessage = "Критическая ошибка Check-SQL_XML_QUERY: $($_.Exception.Message)"
    $detailsError = @{ error=$critErrorMessage; ErrorRecord=$_.ToString(); server_instance=$TargetIP; database_name=$Parameters?.sql_database; query_executed=$Parameters?.sql_query; xml_source_column=$Parameters?.xml_column_name }
    $finalResult = @{ IsAvailable=$isAvailable; CheckSuccess=$checkSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$detailsError; ErrorMessage=$critErrorMessage }
    Write-Error "[$NodeName] Check-SQL_XML_QUERY: Критическая ошибка: $critErrorMessage"
}

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[null]' }; $checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[null]' }
Write-Verbose "[$NodeName] Check-SQL_XML_QUERY (v2.0.2): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"
return $finalResult