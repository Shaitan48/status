# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SQL_XML_QUERY.ps1
# --- Версия 2.1.1 --- Рефакторинг, PS 5.1 совместимость, улучшенная обработка ошибок и XML
<#
.SYNOPSIS
    Выполняет SQL-запрос, извлекает XML из указанного столбца первой строки,
    парсит XML и извлекает значения по заданному списку ключей. (v2.1.1)
.DESCRIPTION
    Скрипт подключается к SQL Server, выполняет запрос, который должен вернуть
    хотя бы одну строку с XML-данными в указанном столбце. 
    XML парсится, и из него извлекаются значения элементов, имена которых 
    переданы в параметре 'keys_to_extract'.
    
    Формирует $Details с информацией о запросе, именем XML-столбца, 
    количеством возвращенных строк и хэш-таблицей 'extracted_data' с 
    извлеченными парами ключ-значение.
    Вызывает Test-SuccessCriteria для определения CheckSuccess.
    Обрабатывает ошибки подключения, выполнения SQL, отсутствия данных или ошибок парсинга XML.
.PARAMETER TargetIP
    [string] Обязательный. Имя или IP-адрес SQL Server instance.
.PARAMETER Parameters
    [hashtable] Обязательный. Хэш-таблица с параметрами:
                - sql_database ([string], Обязательный): Имя целевой базы данных.
                - sql_query ([string], Обязательный): SQL-запрос, возвращающий XML.
                - xml_column_name ([string], Обязательный): Имя столбца, содержащего XML.
                - keys_to_extract ([string[]], Обязательный): Массив имен XML-элементов для извлечения.
                - sql_username ([string], Опциональный): Имя пользователя для SQL Server аутентификации.
                - sql_password ([string], Опциональный): Пароль.
                - query_timeout_sec ([int], Опциональный, по умолч. 30): Таймаут SQL-запроса.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха, применяемые к $details, особенно к $details.extracted_data.
                Пример: @{ extracted_data = @{ Version = "1.2.3"; Status = @{'!=' = "Error"} } }
.PARAMETER NodeName
    [string] Опциональный. Имя узла (для логирования).
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
.NOTES
    Версия: 2.1.1
    Зависит от New-CheckResultObject, Test-SuccessCriteria.
    Требует модуль 'SqlServer'.
    Предполагается, что извлекаемые ключи являются прямыми потомками корневого элемента XML.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIP,
    [Parameter(Mandatory = $false)] # Проверяем ключи внутри
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node (SQL_XML_QUERY)"
)

# --- Инициализация ---
$isAvailable = $false
$checkSuccess = $null
$errorMessage = $null
$finalResult = $null
$details = @{
    server_instance   = $TargetIP
    database_name     = $null
    query_executed    = $null
    xml_source_column = $null
    rows_returned     = 0
    extracted_data    = @{} # Для извлеченных ключ-значение из XML
    xml_content_sample = $null # Для отладки при ошибках парсинга
}

$logTargetDisplay = if (-not [string]::IsNullOrWhiteSpace($TargetIP)) { $TargetIP } else { "[SQL Server не указан]" }
Write-Verbose "[$NodeName] Check-SQL_XML_QUERY (v2.1.1): Начало извлечения XML. Сервер: $logTargetDisplay"

# --- Основной блок Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>

    # --- 1. Извлечение и валидация параметров из $Parameters ---
    $SqlServerInstance = $TargetIP

    if (-not $Parameters.ContainsKey('sql_database') -or [string]::IsNullOrWhiteSpace($Parameters.sql_database)) {
        throw "Отсутствует или пуст обязательный параметр 'sql_database'."
    }
    $DatabaseName = $Parameters.sql_database.Trim()
    $details.database_name = $DatabaseName

    if (-not $Parameters.ContainsKey('sql_query') -or [string]::IsNullOrWhiteSpace($Parameters.sql_query)) {
        throw "Отсутствует или пуст обязательный параметр 'sql_query'."
    }
    $SqlQuery = $Parameters.sql_query.Trim()
    $details.query_executed = $SqlQuery

    if (-not $Parameters.ContainsKey('xml_column_name') -or [string]::IsNullOrWhiteSpace($Parameters.xml_column_name)) {
        throw "Отсутствует или пуст обязательный параметр 'xml_column_name'."
    }
    $XmlColumnName = $Parameters.xml_column_name.Trim()
    $details.xml_source_column = $XmlColumnName

    if (-not $Parameters.ContainsKey('keys_to_extract') -or `
        -not ($Parameters.keys_to_extract -is [array]) -or `
        $Parameters.keys_to_extract.Count -eq 0 -or `
        ($Parameters.keys_to_extract | Where-Object {[string]::IsNullOrWhiteSpace($_)})) {
        throw "Параметр 'keys_to_extract' должен быть непустым массивом строк без пустых элементов."
    }
    $KeysToExtract = @($Parameters.keys_to_extract | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})


    $SqlUsername = $null
    if ($Parameters.ContainsKey('sql_username')) { $SqlUsername = $Parameters.sql_username }
    $SqlPassword = $null
    if (-not [string]::IsNullOrWhiteSpace($SqlUsername)) {
        if (-not $Parameters.ContainsKey('sql_password') -or $Parameters.sql_password -eq $null) {
            throw "Параметр 'sql_password' обязателен, если указан 'sql_username'."
        }
        $SqlPassword = $Parameters.sql_password
    }

    $QueryTimeoutSec = 30
    if ($Parameters.ContainsKey('query_timeout_sec') -and $Parameters.query_timeout_sec -ne $null) {
        $parsedTimeout = 0
        if ([int]::TryParse($Parameters.query_timeout_sec.ToString(), [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
            $QueryTimeoutSec = $parsedTimeout
        } else {
            Write-Warning "[$NodeName] SQL-XML: Некорректное 'query_timeout_sec': '$($Parameters.query_timeout_sec)'. Используется $QueryTimeoutSec сек."
        }
    }
    Write-Verbose "[$NodeName] SQL-XML: Используется query_timeout_sec: $QueryTimeoutSec сек."

    # --- 2. Подготовка параметров для Invoke-Sqlcmd ---
    $invokeSqlParams = @{
        ServerInstance       = $SqlServerInstance
        Database             = $DatabaseName
        Query                = $SqlQuery
        QueryTimeout         = $QueryTimeoutSec
        ErrorAction          = 'Stop'
        TrustServerCertificate = $true
        OutputSqlErrors      = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($SqlUsername)) {
        $invokeSqlParams.Credential = New-Object System.Management.Automation.PSCredential($SqlUsername, (ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force))
        Write-Verbose "[$NodeName] SQL-XML: Используется SQL аутентификация для '$SqlUsername'."
    } else {
        Write-Verbose "[$NodeName] SQL-XML: Используется Windows аутентификация."
    }

    # --- 3. Проверка модуля SqlServer ---
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
        Write-Warning "[$NodeName] SQL-XML: Командлет Invoke-Sqlcmd не найден. Попытка импорта 'SqlServer'..."
        try { Import-Module SqlServer -ErrorAction Stop -Scope Local }
        catch { throw "Модуль 'SqlServer' не установлен или не импортируется. Ошибка: $($_.Exception.Message)" }
    }

    # --- 4. Выполнение SQL-запроса ---
    Write-Verbose "[$NodeName] SQL-XML: Выполнение запроса к '$SqlServerInstance/$DatabaseName'..."
    $queryResultData = Invoke-Sqlcmd @invokeSqlParams
    
    # Если Invoke-Sqlcmd не вызвал исключение, считаем, что SQL-часть доступна
    $isAvailable = $true 
    Write-Verbose "[$NodeName] SQL-XML: SQL-запрос выполнен."

    # --- 5. Обработка результата SQL и извлечение XML-строки ---
    $xmlStringContent = $null
    $sqlErrorMessage = $null # Локальная ошибка, если столбец не найден или пуст

    if ($null -ne $queryResultData) {
        $queryResultArray = @($queryResultData) # Гарантируем массив
        $details.rows_returned = $queryResultArray.Count
        Write-Verbose "[$NodeName] SQL-XML: Запрос вернул $($details.rows_returned) строк(у)."

        if ($details.rows_returned -gt 0) {
            $firstRow = $queryResultArray[0]
            if ($firstRow.PSObject.Properties.Name -contains $XmlColumnName) {
                $xmlValueFromDb = $firstRow.$XmlColumnName
                if ($null -ne $xmlValueFromDb -and $xmlValueFromDb -ne [System.DBNull]::Value) {
                    $xmlStringContent = $xmlValueFromDb.ToString()
                    if ([string]::IsNullOrWhiteSpace($xmlStringContent)) {
                        $sqlErrorMessage = "Столбец '$XmlColumnName' в первой строке результата SQL пуст."
                        $xmlStringContent = $null # Убедимся, что не пытаемся парсить пустую строку
                    } else {
                        Write-Verbose "[$NodeName] SQL-XML: Получена непустая XML-строка из столбца '$XmlColumnName'."
                    }
                } else {
                    $sqlErrorMessage = "Столбец '$XmlColumnName' в первой строке результата SQL содержит DBNull или PowerShell `$null."
                }
            } else {
                $sqlErrorMessage = "Столбец '$XmlColumnName' не найден в первой строке результата SQL-запроса. Доступные столбцы: $($firstRow.PSObject.Properties.Name -join ', ')."
            }
        } else { # Запрос не вернул строк
            $details.message = "SQL-запрос не вернул строк, XML для анализа отсутствует."
            Write-Verbose "[$NodeName] SQL-XML: $($details.message)"
            # $isAvailable остается true, но $checkSuccess будет зависеть от критериев (если есть)
            # Если критерии есть, они, вероятно, не пройдут, так как extracted_data будет пуст.
        }
    } else { # Invoke-Sqlcmd вернул $null (например, для некоторых типов запросов или если нет результатов)
        $details.message = "SQL-запрос не вернул данных (результат Invoke-Sqlcmd равен `$null)."
        Write-Verbose "[$NodeName] SQL-XML: $($details.message)"
    }

    if ($null -ne $sqlErrorMessage) {
        # Эта ошибка не критична для $isAvailable (SQL запрос выполнился), но важна для $checkSuccess и $errorMessage
        $errorMessage = $sqlErrorMessage
        $details.error = $sqlErrorMessage # Добавляем в детали
        Write-Warning "[$NodeName] SQL-XML: $sqlErrorMessage"
        # Дальнейший парсинг XML невозможен
    }

    # --- 6. Парсинг XML и извлечение ключей (только если есть $xmlStringContent) ---
    if ($isAvailable -and (-not [string]::IsNullOrWhiteSpace($xmlStringContent))) {
        Write-Verbose "[$NodeName] SQL-XML: Попытка парсинга XML из столбца '$XmlColumnName'..."
        $xmlDoc = $null
        try {
            # Удаляем BOM, если есть, и лишние пробелы
            $cleanXmlString = $xmlStringContent.Trim()
            if ($cleanXmlString.StartsWith($([char]0xFEFF))) { $cleanXmlString = $cleanXmlString.Substring(1) } # UTF-16 BOM
            if ($cleanXmlString.StartsWith($([char]0xEFBBBF))) { $cleanXmlString = $cleanXmlString.Substring(3) } # UTF-8 BOM

            if (-not $cleanXmlString.StartsWith("<")) {
                 throw "Содержимое столбца '$XmlColumnName' не является валидным XML (не начинается с '<')."
            }
            $details.xml_content_sample = if ($cleanXmlString.Length -gt 200) { $cleanXmlString.Substring(0,200) + "..." } else { $cleanXmlString }
            
            $xmlDoc = New-Object System.Xml.XmlDocument
            $xmlDoc.LoadXml($cleanXmlString) # Загружаем очищенную строку
            
            if ($null -eq $xmlDoc.DocumentElement) {
                throw "XML не содержит корневого элемента после парсинга."
            }
            Write-Verbose "[$NodeName] SQL-XML: XML успешно распарсен."

            # Извлечение значений по ключам
            $extractedKeyValues = @{}
            foreach ($keyToExtract in $KeysToExtract) {
                $nodeValue = $null
                # Ищем элемент как прямой потомок корневого элемента
                $xmlNode = $xmlDoc.DocumentElement.SelectSingleNode("./*[local-name()='$keyToExtract']") # local-name() для игнорирования namespace
                if ($null -ne $xmlNode) {
                    $nodeValue = $xmlNode.InnerText # Получаем текстовое содержимое
                }
                $extractedKeyValues[$keyToExtract] = $nodeValue # Добавляем ключ, даже если значение $null (ключ не найден)
                Write-Verbose "[$NodeName] SQL-XML: Извлечен ключ '$keyToExtract' = '$nodeValue'"
            }
            $details.extracted_data = $extractedKeyValues

        } catch {
            # Ошибка парсинга XML или извлечения ключей - это провал проверки, но $isAvailable может оставаться true, если SQL запрос прошел
            $parsingErrorMessage = "Ошибка парсинга/обработки XML из '$XmlColumnName': $($_.Exception.Message)"
            $errorMessage = if ([string]::IsNullOrEmpty($errorMessage)) { $parsingErrorMessage } else { "$errorMessage; $parsingErrorMessage" }
            $details.error = $errorMessage # Дополняем или устанавливаем ошибку
            $details.ErrorRecord = $_.ToString()
            Write-Warning "[$NodeName] SQL-XML: $parsingErrorMessage"
            $isAvailable = $false # Считаем, что если XML не распарсился, то проверка недоступна в полной мере
        }
    }

    # --- 7. Проверка критериев успеха ---
    # Критерии проверяются, даже если были некритические ошибки (например, ключ не найден в XML, но XML распарсился)
    # $isAvailable может быть $false из-за ошибки парсинга XML, тогда $checkSuccess будет $null
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] SQL-XML: Вызов Test-SuccessCriteria..."
            # Критерии обычно будут нацелены на $details.extracted_data
            $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
            
            $checkSuccess = $criteriaProcessingResult.Passed
            $failReasonFromCriteria = $criteriaProcessingResult.FailReason

            if ($checkSuccess -ne $true) {
                $currentErrorMessage = if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) { $failReasonFromCriteria }
                                 else { "Критерии успеха для XML-данных не пройдены (CheckSuccess: $($checkSuccess | ForEach-Object {$_ -eq $null ? '[null]' : $_}))." }
                $errorMessage = if ([string]::IsNullOrEmpty($errorMessage)) { $currentErrorMessage } else { "$errorMessage; $currentErrorMessage" }
                Write-Verbose "[$NodeName] SQL-XML: SuccessCriteria НЕ пройдены или ошибка оценки. ErrorMessage: $errorMessage"
            } else {
                # Если критерии пройдены, но ранее была ошибка (например, ключ не найден, но это OK по критериям),
                # то $errorMessage может уже быть установлен. Не перезаписываем его на $null.
                if ($null -eq $details.error) { $errorMessage = $null } # Сбрасываем только если не было ошибок в $details
                Write-Verbose "[$NodeName] SQL-XML: SuccessCriteria пройдены."
            }
        } else {
            # Критерии не заданы. Успех, если $isAvailable и нет ошибок в $details.error
            $checkSuccess = if ($null -eq $details.error) { $true } else { $false }
            # $errorMessage уже должен содержать $details.error, если он есть
            Write-Verbose "[$NodeName] SQL-XML: SuccessCriteria не заданы. CheckSuccess установлен на $checkSuccess (на основе $details.error)."
        }
    } else { # $isAvailable = $false (критическая ошибка SQL или парсинга XML)
        $checkSuccess = $null # Критерии не оценивались
        if ([string]::IsNullOrEmpty($errorMessage)) { 
            $errorMessage = "Ошибка выполнения SQL XML запроса или парсинга XML (IsAvailable=false), критерии не проверялись."
        }
    }

    # --- 8. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch { # <<< Основной CATCH для критических ошибок скрипта >>>
    $isAvailable = $false 
    $checkSuccess = $null   
    
    $exceptionMessage = $_.Exception.Message
    if ($_.Exception.InnerException) { $exceptionMessage += " Внутренняя ошибка: $($_.Exception.InnerException.Message)"}
    $critErrorMessageFromCatch = "Критическая ошибка в Check-SQL_XML_QUERY для '$($TargetIP)/$($details.database_name)': $exceptionMessage"
    Write-Error "[$NodeName] Check-SQL_XML_QUERY: $critErrorMessageFromCatch ScriptStackTrace: $($_.ScriptStackTrace)"
    
    if ($null -eq $details) { $details = @{} }
    if (-not $details.ContainsKey('server_instance')) { $details.server_instance = $TargetIP }
    # Заполняем поля из параметров, если они были установлены до ошибки
    if (-not $details.ContainsKey('database_name') -and $DatabaseName) { $details.database_name = $DatabaseName }
    if (-not $details.ContainsKey('query_executed') -and $SqlQuery) { $details.query_executed = $SqlQuery }
    if (-not $details.ContainsKey('xml_source_column') -and $XmlColumnName) { $details.xml_source_column = $XmlColumnName }

    $details.error = $critErrorMessageFromCatch
    $details.ErrorRecord = $_.ToString()
        
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $critErrorMessageFromCatch
} # <<< КОНЕЦ ОСНОВНОГО CATCH >>>

# --- Отладка перед возвратом ---
Write-Host "DEBUG (Check-SQL_XML_QUERY): --- Начало отладки finalResult.Details ---" -ForegroundColor Green
# ... (ваш отладочный блок) ...
if ($finalResult -and $finalResult.Details) {
    Write-Host "DEBUG (Check-SQL_XML_QUERY): Тип finalResult.Details: $($finalResult.Details.GetType().FullName)" -ForegroundColor Green
    Write-Host "DEBUG (Check-SQL_XML_QUERY): Ключи в finalResult.Details: $($finalResult.Details.Keys -join ', ')" -ForegroundColor Green
    # Закомментировано, чтобы не перегружать вывод
    # Write-Host "DEBUG (Check-SQL_XML_QUERY): Полное содержимое finalResult.Details (JSON): $($finalResult.Details | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue)" -ForegroundColor DarkGreen
} elseif ($finalResult) { Write-Host "DEBUG (Check-SQL_XML_QUERY): finalResult.Details является $null или отсутствует." -ForegroundColor Yellow}
else { Write-Host "DEBUG (Check-SQL_XML_QUERY): finalResult сам по себе $null." -ForegroundColor Red }
Write-Host "DEBUG (Check-SQL_XML_QUERY): --- Конец отладки finalResult.Details ---" -ForegroundColor Green

# --- Возврат результата ---
$isAvailableStrForLog = '[N/A]'
if ($finalResult) { $isAvailableStrForLog = $finalResult.IsAvailable.ToString() }
$checkSuccessStrForLog = '[N/A]'
if ($finalResult) {
    if ($null -eq $finalResult.CheckSuccess) { $checkSuccessStrForLog = '[null]' }
    else { $checkSuccessStrForLog = $finalResult.CheckSuccess.ToString() }
}
Write-Verbose "[$NodeName] Check-SQL_XML_QUERY (v2.1.1): Завершение. IsAvailable=$isAvailableStrForLog, CheckSuccess=$checkSuccessStrForLog"

return $finalResult