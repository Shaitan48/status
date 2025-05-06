# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SQL_QUERY_EXECUTE.ps1
# --- Версия 2.0.2 --- Исправлена зависимость от Get-OrElse
<#
.SYNOPSIS
    Выполняет SQL-запрос к MS SQL Server и возвращает результат. (v2.0.2)
.DESCRIPTION
    Подключается к SQL Server, выполняет запрос, обрабатывает результат
    согласно 'return_format'.
    Формирует $Details с результатом запроса (scalar_value, row_count, query_result).
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
$details = @{ server_instance=$TargetIP; database_name=$null; query_executed=$null; return_format_used='first_row' }

Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE (v2.0.2): Начало выполнения SQL на $TargetIP"

try { # <<< Основной TRY >>>
    # 1. Параметры
    $SqlServerInstance = $TargetIP; $DatabaseName = $Parameters.sql_database; $SqlQuery = $Parameters.sql_query; $SqlUsername = $Parameters.sql_username; $SqlPassword = $Parameters.sql_password
    if (-not $DatabaseName) { throw "Отсутствует 'sql_database'." }
    if (-not $SqlQuery) { throw "Отсутствует 'sql_query'." }
    if ($SqlUsername -and (-not $SqlPassword)) { throw "'sql_password' обязателен при 'sql_username'." }
    $details.database_name = $DatabaseName; $details.query_executed = $SqlQuery

    # --- ИСПРАВЛЕНО: Получение return_format без Get-OrElse ---
    $ReturnFormat = 'first_row' # Значение по умолчанию
    if ($Parameters.ContainsKey('return_format') -and (-not [string]::IsNullOrWhiteSpace($Parameters.return_format))) {
        $tempFormat = $Parameters.return_format.ToLower()
        $validFormats = @('first_row', 'all_rows', 'row_count', 'scalar', 'non_query')
        if ($tempFormat -in $validFormats) { $ReturnFormat = $tempFormat }
        else { throw "Недопустимое значение 'return_format': '$($Parameters.return_format)'." }
    }
    $details.return_format_used = $ReturnFormat
    Write-Verbose "... Используется return_format: $ReturnFormat"

    # --- ИСПРАВЛЕНО: Получение query_timeout_sec без Get-OrElse ---
    $QueryTimeoutSec = 30 # Значение по умолчанию
    if ($Parameters.ContainsKey('query_timeout_sec') -and $Parameters.query_timeout_sec -ne $null) {
        $parsedTimeout = 0
        if ([int]::TryParse($Parameters.query_timeout_sec, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
            $QueryTimeoutSec = $parsedTimeout
        } else { Write-Warning "[$NodeName] ... Некорректное 'query_timeout_sec', используется $QueryTimeoutSec сек." }
    }
    Write-Verbose "... Используется query_timeout_sec: $QueryTimeoutSec сек."

    # 2. Параметры Invoke-Sqlcmd
    $invokeSqlParams = @{ ServerInstance=$SqlServerInstance; Database=$DatabaseName; Query=$SqlQuery; QueryTimeout=$QueryTimeoutSec; ErrorAction='Stop'; TrustServerCertificate=$true }
    if ($SqlUsername) { $securePassword = ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force; $invokeSqlParams.Credential = New-Object System.Management.Automation.PSCredential($SqlUsername, $securePassword) }

    # 3. Проверка модуля SqlServer (без изменений)
    if (-not (Get-Command Invoke-Sqlcmd -EA SilentlyContinue)) { if (-not (Get-Module -ListAvailable -Name SqlServer)) { throw "Модуль 'SqlServer' не найден." }; try { Import-Module SqlServer -EA Stop } catch { throw "Не удалось загрузить модуль 'SqlServer'." } }

    # 4. Выполнение SQL-запроса
    Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Выполнение запроса (формат: $ReturnFormat)..."
    $queryResultData = $null; $nonQuerySuccess = $null
    if ($ReturnFormat -eq 'non_query') {
        try { Invoke-Sqlcmd @invokeSqlParams | Out-Null; $isAvailable = $true; $nonQuerySuccess = $true; $details.non_query_success = $true; Write-Verbose "... non-query успешно." }
        catch { $isAvailable = $false; $errorMessage = "Ошибка non-query SQL: $($_.Exception.Message)"; $details.error = $errorMessage; $details.ErrorRecord = $_.ToString(); $details.non_query_success = $false; Write-Warning "... $errorMessage" }
    } else {
        $queryResultData = Invoke-Sqlcmd @invokeSqlParams
        $isAvailable = $true
        Write-Verbose "... запрос с данными выполнен."
        # 5. Обработка результата (пересоздаем $details)
        $details = @{ server_instance=$SqlServerInstance; database_name=$DatabaseName; query_executed=$SqlQuery; return_format_used=$ReturnFormat }
        switch ($ReturnFormat) {
            'first_row' { $res=@{};$count=0; if($queryResultData){$arr=@($queryResultData);$count=$arr.Length;if($count -gt 0){$first=$arr[0];$first.PSObject.Properties|%{$res[$_.Name]=$_.Value}}}; $details.query_result=$res;$details.rows_returned=$count }
            'all_rows' { $res=[System.Collections.Generic.List[object]]::new();$count=0; if($queryResultData){foreach($r in @($queryResultData)){$h=@{};$r.PSObject.Properties|%{$h[$_.Name]=$_.Value};$res.Add($h)};$count=$res.Count}; $details.query_result=$res;$details.rows_returned=$count }
            'row_count' { $count=0; if($queryResultData){$count=@($queryResultData).Length}; $details.row_count=$count }
            'scalar' { $val=$null; if($queryResultData){$first=@($queryResultData)[0];if($first){$pName=($first.PSObject.Properties|select -f 1).Name;if($pName){$val=$first.$pName}}}; $details.scalar_value=$val }
        }
        Write-Verbose ("... результат обработан (формат: {0})." -f $ReturnFormat)
    }

    # 6. Проверка критериев успеха
    $failReason = $null
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.PSObject.Properties.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Вызов Test-SuccessCriteria..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason
            if ($checkSuccess -ne $true) {
                # --- ИСПРАВЛЕНО: Используем if или $() вместо Get-OrElse ---
                $errorMessage = if ([string]::IsNullOrWhiteSpace($failReason)) { "Критерии успеха SQL запроса не пройдены." } else { $failReason }
                Write-Verbose "[$NodeName] ... SuccessCriteria НЕ пройдены/ошибка: $errorMessage"
            } else { $errorMessage = $null; Write-Verbose "[$NodeName] ... SuccessCriteria пройдены." }
        } else {
            $checkSuccess = $true; $errorMessage = $null
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = "Ошибка выполнения SQL запроса (IsAvailable=false)." }
    }

    # 7. Формирование результата
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable -CheckSuccess $checkSuccess -Details $details -ErrorMessage $errorMessage

} catch { # <<< Основной CATCH >>>
    $isAvailable = $false; $checkSuccess = $null; $critErrorMessage = "Критическая ошибка Check-SQL_QUERY_EXECUTE: $($_.Exception.Message)"
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString(); server_instance=$TargetIP; database_name=$Parameters?.sql_database; query_executed=$Parameters?.sql_query }
    $finalResult = @{ IsAvailable=$isAvailable; CheckSuccess=$checkSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$detailsError; ErrorMessage=$critErrorMessage }
    Write-Error "[$NodeName] Check-SQL_QUERY_EXECUTE: Критическая ошибка: $critErrorMessage"
}

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[null]' }; $checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[null]' }
Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE (v2.0.2): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"
return $finalResult