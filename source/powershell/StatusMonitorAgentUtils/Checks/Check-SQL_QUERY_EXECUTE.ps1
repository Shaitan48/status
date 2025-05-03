<#
.SYNOPSIS
    Выполняет SQL-запрос и возвращает результат.
.DESCRIPTION
    Подключается к MS SQL Server, выполняет указанный SQL-запрос
    и возвращает результат в заданном формате (первая строка, все строки,
    количество строк, скалярное значение или статус выполнения non-query).
    Поддерживает проверку SuccessCriteria для скалярных результатов.
.PARAMETER TargetIP
    [string] Имя или IP-адрес SQL Server instance. Обязательный.
.PARAMETER Parameters
    [hashtable] Обязательный. Содержит параметры подключения и запроса:
    - sql_database (string):   Имя базы данных. Обязательно.
    - sql_query (string):      SQL-запрос для выполнения. Обязательно.
    - return_format (string):  Формат возвращаемого результата. Необязательный.
                               Значения: 'first_row' (по умолч.), 'all_rows',
                               'row_count', 'scalar', 'non_query'.
    - sql_username (string):   Имя пользователя для SQL Server аутентификации. Необязательный.
    - sql_password (string):   Пароль для SQL Server аутентификации. Необязательный.
                               (Использование не рекомендуется).
    - query_timeout_sec (int): Таймаут выполнения SQL-запроса в секундах. (по умолч. 30).
.PARAMETER SuccessCriteria
    [hashtable] Необязательный. Критерии успеха.
    Для return_format = 'scalar':
    - expected_value (any): Ожидаемое точное значение (сравнивается как строка).
    - value_greater_than (numeric): Числовое значение, которое результат должен превышать.
    - value_less_than (numeric): Числовое значение, которого результат должен быть меньше.
    (Другие форматы пока не поддерживают критерии).
.PARAMETER NodeName
    [string] Необязательный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
                Содержимое Details зависит от 'return_format'.
.NOTES
    Версия: 1.1 (Добавлена обработка SuccessCriteria для scalar)
    Зависит от функции New-CheckResultObject из родительского модуля.
    Требует наличия модуля PowerShell 'SqlServer'.
    Требует прав доступа к SQL Server и базе данных.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP, # ServerInstance

    [Parameter(Mandatory=$true)]
    [hashtable]$Parameters,

    [Parameter(Mandatory=$false)]
    [hashtable]$SuccessCriteria = $null, # Добавлен параметр

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
        Write-Error "Check-SQL_QUERY_EXECUTE: Критическая ошибка: Не удалось загрузить New-CheckResultObject! $($_.Exception.Message)"
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}

# --- Инициализация результата ---
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{ # Пре-инициализируем поля Details
        server_instance = $TargetIP
        database_name = $null
        query_executed = $null
        return_format_used = 'first_row' # Значение по умолчанию
    }
    ErrorMessage = $null
}

Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Начало выполнения SQL на $TargetIP"

try {
    # 1. Валидация и извлечение параметров
    $SqlServerInstance = $TargetIP
    $DatabaseName = $Parameters.sql_database
    $SqlQuery = $Parameters.sql_query
    $ReturnFormat = ($Parameters.return_format | Get-OrElse 'first_row').ToLower()
    $SqlUsername = $Parameters.sql_username
    $SqlPassword = $Parameters.sql_password
    $QueryTimeoutSec = $Parameters.query_timeout_sec | Get-OrElse 30

    # Заполняем Details
    $resultData.Details.database_name = $DatabaseName
    $resultData.Details.query_executed = $SqlQuery
    $resultData.Details.return_format_used = $ReturnFormat

    # Проверка обязательных параметров
    if (-not $DatabaseName) { throw "Отсутствует обязательный параметр 'sql_database'." }
    if (-not $SqlQuery) { throw "Отсутствует обязательный параметр 'sql_query'." }
    if ($ReturnFormat -notin @('first_row', 'all_rows', 'row_count', 'scalar', 'non_query')) {
        throw "Недопустимое значение 'return_format': '$ReturnFormat'."
    }
    if ($SqlUsername -and (-not $SqlPassword)) { throw "Параметр 'sql_password' обязателен при указании 'sql_username'." }
    if (-not ([int]::TryParse($QueryTimeoutSec, [ref]$null)) -or $QueryTimeoutSec -le 0) {
         Write-Warning "[$NodeName] Некорректное значение query_timeout_sec ('$($Parameters.query_timeout_sec)'). Используется 30 сек."; $QueryTimeoutSec = 30
    }


    # 2. Формирование параметров для Invoke-Sqlcmd
    $invokeSqlParams = @{
        ServerInstance = $SqlServerInstance
        Database       = $DatabaseName
        Query          = $SqlQuery
        QueryTimeout   = $QueryTimeoutSec
        ErrorAction    = 'Stop' # Важно для перехвата ошибок
    }
    if ($SqlUsername) {
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Используется SQL Server аутентификация для '$SqlUsername'."
        $securePassword = ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($SqlUsername, $securePassword)
        $invokeSqlParams.Credential = $credential
    } else {
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Используется Windows аутентификация."
    }

    # 3. Проверка и загрузка модуля SqlServer
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
         if (-not (Get-Module -ListAvailable -Name SqlServer)) {
              throw "Модуль PowerShell 'SqlServer' не найден. Установите его: Install-Module SqlServer -Scope CurrentUser -Force"
         }
         try {
             Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Загрузка модуля SqlServer..."
             Import-Module SqlServer -ErrorAction Stop
         } catch {
              throw "Не удалось загрузить модуль 'SqlServer'. Ошибка: $($_.Exception.Message)"
         }
    }

    # 4. Выполнение SQL-запроса
    Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Выполнение запроса к '$SqlServerInstance/$DatabaseName'..."
    $queryResultData = Invoke-Sqlcmd @invokeSqlParams

    # Запрос выполнен успешно (без ошибок)
    $resultData.IsAvailable = $true
    $resultData.CheckSuccess = $true # По умолчанию считаем успешным, если не было ошибок И критерии прошли

    # 5. Обработка результата в зависимости от return_format
    Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Обработка результата (формат: $ReturnFormat)"
    $scalarValueForCriteria = $null # Для проверки критериев

    switch ($ReturnFormat) {
        'first_row' {
            if ($queryResultData -ne $null) {
                 $firstRow = $queryResultData | Select-Object -First 1
                 $resultHashTable = @{}
                 if ($firstRow) {
                     $firstRow.PSObject.Properties | ForEach-Object { $resultHashTable[$_.Name] = $_.Value }
                 }
                 $resultData.Details.query_result = $resultHashTable
                 $resultData.Details.rows_returned = if ($queryResultData -is [array]) { $queryResultData.Length } elseif($firstRow) { 1 } else { 0 }
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Возвращена первая строка."
            } else {
                 $resultData.Details.query_result = $null; $resultData.Details.rows_returned = 0
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Запрос не вернул строк."
            }
        }
        'all_rows' {
            $allRowsList = [System.Collections.Generic.List[object]]::new()
            if ($queryResultData -ne $null) {
                 foreach($row in $queryResultData) {
                      $rowHashTable = @{}
                      $row.PSObject.Properties | ForEach-Object { $rowHashTable[$_.Name] = $_.Value }
                      $allRowsList.Add($rowHashTable)
                 }
                 $resultData.Details.rows_returned = $allRowsList.Count
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Возвращено строк: $($allRowsList.Count)"
            } else {
                $resultData.Details.rows_returned = 0
                Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Запрос не вернул строк."
            }
             $resultData.Details.query_result = $allRowsList # Массив хеш-таблиц
        }
        'row_count' {
            if ($queryResultData -ne $null) {
                 $rowCount = if ($queryResultData -is [array]) { $queryResultData.Length } else { 1 }
                 $resultData.Details.row_count = $rowCount
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Количество строк: $rowCount"
            } else {
                 $resultData.Details.row_count = 0
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Запрос не вернул строк."
            }
        }
        'scalar' {
             if ($queryResultData -ne $null) {
                 $firstRow = $queryResultData | Select-Object -First 1
                 if ($firstRow) {
                     $firstColumnName = ($firstRow.PSObject.Properties | Select-Object -First 1).Name
                     $scalarValue = $firstRow.$firstColumnName
                     $resultData.Details.scalar_value = $scalarValue
                     $scalarValueForCriteria = $scalarValue # Сохраняем для проверки критериев
                     Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Скалярное значение: '$scalarValue'"
                 } else { $resultData.Details.scalar_value = $null; Write-Verbose "[...] Запрос не вернул строк для скаляра." }
             } else { $resultData.Details.scalar_value = $null; Write-Verbose "[...] Запрос не вернул строк для скаляра." }
        }
        'non_query' {
            # Ошибки ловятся через ErrorAction=Stop, сам результат null для non-query
            $resultData.Details.non_query_success = $true
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Non-query запрос выполнен успешно."
        }
    }

    # 6. Обработка SuccessCriteria (ПОКА ТОЛЬКО ДЛЯ SCALAR)
    if ($resultData.IsAvailable -and $ReturnFormat -eq 'scalar' -and $SuccessCriteria -ne $null) {
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Применение SuccessCriteria для скалярного значения..."
        $checkSuccessResult = $true # Локальная переменная для результата проверки критериев
        $failReason = $null

        # Проверка на точное совпадение
        if ($SuccessCriteria.ContainsKey('expected_value')) {
            $expected = $SuccessCriteria.expected_value
            # Сравниваем как строки, чтобы избежать проблем с типами
            if ("$scalarValueForCriteria" -ne "$expected") {
                $checkSuccessResult = $false
                $failReason = "Значение '$scalarValueForCriteria' не равно ожидаемому '$expected'."
            }
        }
        # Проверка "больше чем"
        if ($checkSuccessResult -and $SuccessCriteria.ContainsKey('value_greater_than')) {
            try {
                $threshold = [double]$SuccessCriteria.value_greater_than
                $currentValue = [double]$scalarValueForCriteria
                if ($currentValue -le $threshold) {
                    $checkSuccessResult = $false
                    $failReason = "Значение $currentValue не больше $threshold."
                }
            } catch {
                 $checkSuccessResult = $null # Ошибка сравнения -> CheckSuccess = null
                 $failReason = "Ошибка сравнения: значение '$scalarValueForCriteria' или критерий '$($SuccessCriteria.value_greater_than)' не является числом."
            }
        }
        # Проверка "меньше чем"
        if ($checkSuccessResult -and $SuccessCriteria.ContainsKey('value_less_than')) {
            try {
                $threshold = [double]$SuccessCriteria.value_less_than
                $currentValue = [double]$scalarValueForCriteria
                if ($currentValue -ge $threshold) {
                    $checkSuccessResult = $false
                    $failReason = "Значение $currentValue не меньше $threshold."
                }
            } catch {
                 $checkSuccessResult = $null # Ошибка сравнения -> CheckSuccess = null
                 $failReason = "Ошибка сравнения: значение '$scalarValueForCriteria' или критерий '$($SuccessCriteria.value_less_than)' не является числом."
            }
        }
        # ... можно добавить другие критерии (contains, not_contains, etc.)

        # Обновляем итоговый результат
        if ($failReason -ne $null) {
            $resultData.ErrorMessage = $failReason
            $resultData.CheckSuccess = if ($checkSuccessResult -eq $null) { $null } else { $false }
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Критерий не пройден: $failReason"
        } else {
            $resultData.CheckSuccess = $true # Все критерии пройдены
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Все критерии для скаляра пройдены."
        }
    } elseif ($SuccessCriteria -ne $null) {
         Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: SuccessCriteria переданы, но для формата '$ReturnFormat' их обработка пока не реализована."
    }


} catch {
    # Перехват ошибок Invoke-Sqlcmd или других (валидация, модуль)
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "Ошибка выполнения SQL-запроса: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    # Добавляем детали ошибки
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    # Логируем ошибку
    Write-Error "[$NodeName] Check-SQL_QUERY_EXECUTE: Критическая ошибка: $errorMessage"
}

# Вызов New-CheckResultObject для финальной стандартизации
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Завершение. IsAvailable=$($finalResult.IsAvailable), CheckSuccess=$($finalResult.CheckSuccess)"
return $finalResult