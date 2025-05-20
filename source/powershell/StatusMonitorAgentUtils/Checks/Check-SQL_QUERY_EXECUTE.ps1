# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SQL_QUERY_EXECUTE.ps1
# --- Версия 2.1.3 --- Улучшено извлечение scalar value, исправлена обработка ошибок для scalar.

<#
.SYNOPSIS
    Выполняет SQL-запрос к MS SQL Server и возвращает результат в указанном формате. (v2.1.3)
# ... (описание без изменений) ...
.NOTES
    Версия: 2.1.3
    Изменения:
    - Улучшена логика извлечения значения для return_format = 'scalar'.
    - Улучшена обработка ошибок при проверке критериев для scalar, если scalar_value is null.
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria из модуля StatusMonitorAgentUtils.
    Требует наличия модуля 'SqlServer' на машине, где выполняется скрипт.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIP, 
    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node (SQL_QUERY_EXECUTE)"
)

# --- Инициализация ---
$isAvailable = $false; $checkSuccess = $null; $errorMessage = $null; $finalResult = $null
$details = @{ 
    server_instance    = $TargetIP; database_name      = $null; query_executed     = $null; 
    return_format_used = 'first_row'
}
$DatabaseName = "[UnknownDB]"; $SqlQuery = "[UnknownQuery]"; $ReturnFormat = "first_row"

$logTargetDisplay = if (-not [string]::IsNullOrWhiteSpace($TargetIP)) { $TargetIP } else { "[SQL Server не указан]" }
Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE (v2.1.3): Начало. Сервер: $logTargetDisplay"

try {
    # --- 1. Извлечение и валидация параметров ---
    if (-not $Parameters.ContainsKey('sql_database') -or [string]::IsNullOrWhiteSpace($Parameters.sql_database)) { throw "Отсутствует 'sql_database'." }
    $DatabaseName = $Parameters.sql_database.Trim(); $details.database_name = $DatabaseName
    if (-not $Parameters.ContainsKey('sql_query') -or [string]::IsNullOrWhiteSpace($Parameters.sql_query)) { throw "Отсутствует 'sql_query'." }
    $SqlQuery = $Parameters.sql_query.Trim(); $details.query_executed = $SqlQuery
    $SqlUsername = $null; if ($Parameters.ContainsKey('sql_username')) { $SqlUsername = $Parameters.sql_username }
    $SqlPassword = $null; if (-not [string]::IsNullOrWhiteSpace($SqlUsername)) { if (-not $Parameters.ContainsKey('sql_password') -or $Parameters.sql_password -eq $null) { throw "'sql_password' обязателен при 'sql_username'." }; $SqlPassword = $Parameters.sql_password }
    if ($Parameters.ContainsKey('return_format') -and (-not [string]::IsNullOrWhiteSpace($Parameters.return_format))) { $tempFormat = $Parameters.return_format.ToString().ToLower().Trim(); $validFormats = @('first_row', 'all_rows', 'row_count', 'scalar', 'non_query'); if ($tempFormat -in $validFormats) { $ReturnFormat = $tempFormat } else { throw "Недопустимое 'return_format': '$($Parameters.return_format)'." } }
    $details.return_format_used = $ReturnFormat; Write-Verbose "[$NodeName] SQL: return_format: '$ReturnFormat'."
    $QueryTimeoutSec = 30; if ($Parameters.ContainsKey('query_timeout_sec') -and $Parameters.query_timeout_sec -ne $null) { $parsedTimeout = 0; if ([int]::TryParse($Parameters.query_timeout_sec.ToString(), [ref]$parsedTimeout) -and $parsedTimeout -gt 0) { $QueryTimeoutSec = $parsedTimeout } else { Write-Warning "[$NodeName] SQL: Некорректное 'query_timeout_sec'. Исп. $QueryTimeoutSec сек." } }; Write-Verbose "[$NodeName] SQL: query_timeout_sec: $QueryTimeoutSec сек."

    # --- 2. Подготовка параметров для Invoke-Sqlcmd ---
    $invokeSqlParams = @{ ServerInstance = $TargetIP; Database = $DatabaseName; Query = $SqlQuery; QueryTimeout = $QueryTimeoutSec; ErrorAction = 'Stop'; TrustServerCertificate = $true; OutputSqlErrors = $true }
    if (-not [string]::IsNullOrWhiteSpace($SqlUsername)) { $invokeSqlParams.Credential = New-Object System.Management.Automation.PSCredential($SqlUsername, (ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force)); Write-Verbose "[$NodeName] SQL: SQL Auth для '$SqlUsername'." } else { Write-Verbose "[$NodeName] SQL: Windows Auth." }

    # --- 3. Проверка модуля SqlServer ---
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) { Write-Warning "[$NodeName] SQL: Invoke-Sqlcmd не найден. Импорт 'SqlServer'..."; try { Import-Module SqlServer -ErrorAction Stop -Scope Local; Write-Verbose "[$NodeName] SQL: Модуль 'SqlServer' импортирован." } catch { throw "Модуль 'SqlServer' не установлен/импортируется. Ошибка: $($_.Exception.Message)" } }

    # --- 4. Выполнение SQL-запроса ---
    Write-Verbose "[$NodeName] SQL: Выполнение запроса к '$TargetIP/$DatabaseName' (формат: $ReturnFormat)..."
    $queryResultData = $null
    
    if ($ReturnFormat -eq 'non_query') {
        Invoke-Sqlcmd @invokeSqlParams | Out-Null
        $isAvailable = $true; $details.non_query_success = $true
        Write-Verbose "[$NodeName] SQL: non-query запрос успешно выполнен."
    } else {
        $queryResultData = Invoke-Sqlcmd @invokeSqlParams
        $isAvailable = $true; Write-Verbose "[$NodeName] SQL: запрос, возвращающий данные, выполнен."
        
        switch ($ReturnFormat) {
            'first_row' { 
                $firstRowResult = $null; $returnedRowCount = 0
                if ($null -ne $queryResultData) { $queryResultArray = @($queryResultData); $returnedRowCount = $queryResultArray.Count; if ($returnedRowCount -gt 0) { $firstRowResult = @{}; $queryResultArray[0].PSObject.Properties | ForEach-Object { $firstRowResult[$_.Name] = $_.Value } } }
                $details.query_result = $firstRowResult; $details.rows_returned = $returnedRowCount
            }
            'all_rows' { 
                $allRowsResult = [System.Collections.Generic.List[object]]::new(); $returnedRowCount = 0
                if ($null -ne $queryResultData) { foreach($rowItem in @($queryResultData)) { $rowDataHashtable = @{}; $rowItem.PSObject.Properties | ForEach-Object { $rowDataHashtable[$_.Name] = $_.Value }; $allRowsResult.Add($rowDataHashtable) }; $returnedRowCount = $allRowsResult.Count }
                $details.query_result = $allRowsResult; $details.rows_returned = $returnedRowCount
            }
            'row_count' { 
                $returnedRowCount = 0; if ($null -ne $queryResultData) { $returnedRowCount = @($queryResultData).Count }
                $details.row_count = $returnedRowCount
            }
            'scalar' { 
                $scalarResultValue = $null
                if ($null -ne $queryResultData) {
                    $queryResultArray = @($queryResultData)
                    if ($queryResultArray.Count -gt 0) {
                        $firstRowObject = $queryResultArray[0]
                        Write-Host "DEBUG SCALAR: FirstRowObject Type: $($firstRowObject.GetType().FullName)" -ForegroundColor Cyan
                        $firstRowObject.PSObject.Properties | ForEach-Object { Write-Host "  DEBUG SCALAR Prop: Name='$($_.Name)', Value='$($_.Value)', Type='$($_.Value.GetType().FullName)'" -ForegroundColor DarkCyan }
                        
                        # --- УЛУЧШЕННАЯ ЛОГИКА ИЗВЛЕЧЕНИЯ SCALAR ---
                        if ($firstRowObject.PSObject.Properties.Count -gt 0) {
                            # Пытаемся получить значение напрямую, если объект имеет только одно свойство (как результат SELECT COUNT(*))
                            # или если это примитивный тип (Invoke-Sqlcmd может вернуть сразу значение)
                            if (($firstRowObject.PSObject.Properties.Count -eq 1) -or ($firstRowObject -is [ValueType]) -or ($firstRowObject -is [string])) {
                                if ($firstRowObject -is [System.Data.DataRow]) { # Для DataRow всегда берем первый столбец
                                    $scalarResultValue = $firstRowObject.ItemArray[0]
                                } else {
                                    $scalarResultValue = $firstRowObject # Если это уже скаляр
                                    if ($firstRowObject.PSObject.Properties.Count -eq 1) { # Если это объект с одним свойством
                                         $scalarResultValue = $firstRowObject.PSObject.Properties[0].Value
                                    }
                                }
                                Write-Host "DEBUG SCALAR: Extracted Value (direct or single prop): '$scalarResultValue' (Type: $(if($scalarResultValue -ne $null){$scalarResultValue.GetType().FullName} else {'null'}))" -ForegroundColor Green
                            } else {
                                Write-Warning "DEBUG SCALAR: Объект первой строки имеет несколько свойств, не удалось однозначно определить скалярное значение без имени столбца."
                            }
                        } else { Write-Warning "DEBUG SCALAR: Нет свойств у объекта первой строки (возможно, пустой объект)." }
                        # --- КОНЕЦ УЛУЧШЕННОЙ ЛОГИКИ ---
                    } else { Write-Warning "DEBUG SCALAR: Запрос вернул 0 строк."}
                } else { Write-Warning "DEBUG SCALAR: queryResultData is null."}
                $details.scalar_value = $scalarResultValue
            }
        }
        Write-Verbose "[$NodeName] SQL: Результат запроса обработан для формата '$ReturnFormat'."
    }

    # --- 6. Проверка критериев успеха ---
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] SQL: Вызов Test-SuccessCriteria..."
            # --- ИСПРАВЛЕНИЕ: Проверка на $null для scalar_value перед Test-SuccessCriteria, если критерий на него ---
            if ($details.return_format_used -eq 'scalar' -and $null -eq $details.scalar_value -and $SuccessCriteria.ContainsKey('scalar_value')) {
                $checkSuccess = $null # Не можем оценить критерий, если значение null
                $errorMessage = "Не удалось извлечь scalar_value для проверки критерия."
                Write-Warning "[$NodeName] SQL: $errorMessage"
            } else {
                $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
                $checkSuccess = $criteriaProcessingResult.Passed
                $failReasonFromCriteria = $criteriaProcessingResult.FailReason
                if ($checkSuccess -ne $true) {
                    $currentErrorMessage = if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) { $failReasonFromCriteria }
                                             else {
                                                 $checkSuccessDisplay = if ($null -eq $checkSuccess) { '[null]' } else { $checkSuccess.ToString() }
                                                 "Критерии успеха для SQL-запроса не пройдены (CheckSuccess: $checkSuccessDisplay)."
                                             }
                    $errorMessage = if ([string]::IsNullOrEmpty($errorMessage)) { $currentErrorMessage } else { "$errorMessage; $currentErrorMessage" }
                    Write-Verbose "[$NodeName] SQL: SuccessCriteria НЕ пройдены или ошибка. Error: $errorMessage"
                } else { if ($null -eq $details.error) {$errorMessage = $null}; Write-Verbose "[$NodeName] SQL: SuccessCriteria пройдены." }
            }
        } else {
            $checkSuccess = if ($null -eq $details.error) { $true } else { $false }
            if ($checkSuccess -eq $true) { $errorMessage = $null }
            Write-Verbose "[$NodeName] SQL: SuccessCriteria не заданы. CheckSuccess=$checkSuccess."
        }
    } else {
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = "Ошибка SQL (IsAvailable=false), критерии не проверялись." }
    }

    # --- 7. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable -CheckSuccess $checkSuccess -Details $details -ErrorMessage $errorMessage
} catch {
    $isAvailable = $false; $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message; if ($_.Exception.InnerException) { $exceptionMessage += " Внутренняя ошибка SQL: $($_.Exception.InnerException.Message)"}
    # Используем значения переменных $DatabaseName, $SqlQuery, которые были установлены в начале блока try
    $critErrorMessageFromCatch = "Критическая ошибка в Check-SQL_QUERY_EXECUTE для '$($TargetIP)/$($DatabaseName)' (Запрос: '$($SqlQuery.Substring(0, [System.Math]::Min($SqlQuery.Length, 50)))...'): $exceptionMessage"
    Write-Error "[$NodeName] Check-SQL_QUERY_EXECUTE: $critErrorMessageFromCatch ScriptStackTrace: $($_.ScriptStackTrace)"
    if ($null -eq $details) { $details = @{} }; if (-not $details.ContainsKey('server_instance')) { $details.server_instance = $TargetIP }; if (-not $details.ContainsKey('database_name')) { $details.database_name = $DatabaseName }; if (-not $details.ContainsKey('query_executed')) { $details.query_executed = $SqlQuery }
    $details.error = $critErrorMessageFromCatch; $details.ErrorRecord = $_.ToString()
    if ($ReturnFormat -eq 'non_query' -and -not $details.ContainsKey('non_query_success')) { $details.non_query_success = $false }
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable -CheckSuccess $checkSuccess -Details $details -ErrorMessage $critErrorMessageFromCatch
}

# --- Отладка и возврат ---
if ($MyInvocation.BoundParameters.Debug -or ($DebugPreference -ne 'SilentlyContinue' -and $DebugPreference -ne 'Ignore')) {
    Write-Host "DEBUG (Check-SQL_QUERY_EXECUTE): --- Начало отладки finalResult.Details ---" -ForegroundColor Green
    if ($finalResult -and $finalResult.Details) { Write-Host "DEBUG: Тип: $($finalResult.Details.GetType().FullName), Ключи: $($finalResult.Details.Keys -join ', ')" -FG Green }
    elseif ($finalResult) { Write-Host "DEBUG: finalResult.Details `$null." -FG Yellow } else { Write-Host "DEBUG: finalResult `$null." -FG Red }
    Write-Host "DEBUG (Check-SQL_QUERY_EXECUTE): --- Конец отладки ---" -ForegroundColor Green
}
$isAvailableStrForLog = if ($finalResult) { $finalResult.IsAvailable.ToString() } else { '[N/A]' }
$checkSuccessStrForLog = if ($finalResult) { if ($null -eq $finalResult.CheckSuccess) { '[null]' } else { $finalResult.CheckSuccess.ToString() } } else { '[N/A]' }
Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE (v2.1.3): Завершение. IsAvailable=$isAvailableStrForLog, CheckSuccess=$checkSuccessStrForLog"
return $finalResult