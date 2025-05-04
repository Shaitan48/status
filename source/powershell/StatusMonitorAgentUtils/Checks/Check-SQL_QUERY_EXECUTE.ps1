# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SQL_QUERY_EXECUTE.ps1
# --- Версия 2.0 ---
# Изменения:
# - Логика проверки SuccessCriteria вынесена в универсальную функцию Test-SuccessCriteria.
# - Стандартизирован формат $Details для каждого return_format.
# - Убран прямой расчет CheckSuccess на основе скалярных сравнений.
# - Добавлен вызов Test-SuccessCriteria.

<#
.SYNOPSIS
    Выполняет SQL-запрос к MS SQL Server и возвращает результат. (v2.0)
.DESCRIPTION
    Подключается к SQL Server, выполняет запрос и обрабатывает результат
    в соответствии с параметром 'return_format'.
    Формирует стандартизированный объект $Details с результатом запроса.
    Для определения итогового CheckSuccess использует универсальную функцию
    Test-SuccessCriteria, сравнивающую $Details с переданным $SuccessCriteria.
.PARAMETER TargetIP
    [string] Обязательный. Имя или IP-адрес экземпляра SQL Server.
.PARAMETER Parameters
    [hashtable] Обязательный. Параметры подключения и запроса:
    - sql_database (string): Имя БД. Обязательно.
    - sql_query (string): Текст SQL-запроса. Обязательно.
    - return_format (string): Формат возврата ('first_row', 'all_rows', 'row_count', 'scalar', 'non_query', default: 'first_row').
    - sql_username (string): Имя пользователя SQL (опционально).
    - sql_password (string): Пароль SQL (опционально, небезопасно).
    - query_timeout_sec (int): Таймаут запроса (default: 30).
.PARAMETER SuccessCriteria
    [hashtable] Необязательный. Критерии успеха для сравнения с полями в $Details.
                Формат зависит от return_format. Примеры:
                - scalar: @{ scalar_value = @{ '>=' = 10 } }
                - row_count: @{ row_count = @{ '==' = 0 } }
                - non_query: @{ non_query_success = $true } # Проверка успешности выполнения
                - first_row/all_rows: Критерии для полей внутри строки/массива (требует доработки Test-SuccessCriteria).
                Обрабатывается функцией Test-SuccessCriteria.
.PARAMETER NodeName
    [string] Необязательный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
                Поле Details (hashtable) содержит:
                - server_instance, database_name, query_executed, return_format_used
                - И ОДНО из следующих полей в зависимости от return_format:
                  - query_result (hashtable или List<object>) и rows_returned (int)
                  - row_count (int)
                  - scalar_value (any)
                  - non_query_success (bool)
                А также (при ошибке):
                - error (string)
                - ErrorRecord (string)
.NOTES
    Версия: 2.0.1 (Добавлены комментарии, форматирование, проверка модуля).
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria.
    Требует наличия модуля PowerShell 'SqlServer'.
    Требует прав доступа к SQL Server.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIP, # ServerInstance

    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},

    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,

    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node"
)

# --- Инициализация переменных ---
$isAvailable = $false
$checkSuccess = $null
$errorMessage = $null
$finalResult = $null

# Инициализируем $Details базовой информацией
$details = @{
    server_instance    = $TargetIP
    database_name      = $null
    query_executed     = $null
    return_format_used = 'first_row' # Значение по умолчанию
    # Поле с результатом будет добавлено позже
}

Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE (v2.0.1): Начало выполнения SQL на $TargetIP"

# --- Основной блок Try/Catch ---
try {
    # --- 1. Валидация и извлечение параметров ---
    Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Обработка параметров..."
    $SqlServerInstance = $TargetIP
    $DatabaseName = $Parameters.sql_database
    $SqlQuery = $Parameters.sql_query
    $SqlUsername = $Parameters.sql_username
    $SqlPassword = $Parameters.sql_password

    # Проверка обязательных параметров
    if (-not $DatabaseName) { throw "Отсутствует обязательный параметр 'sql_database'." }
    if (-not $SqlQuery) { throw "Отсутствует обязательный параметр 'sql_query'." }
    if ($SqlUsername -and (-not $SqlPassword)) { throw "Параметр 'sql_password' обязателен при указании 'sql_username'." }

    # Обновляем детали
    $details.database_name = $DatabaseName
    $details.query_executed = $SqlQuery

    # Формат возврата результата
    $ReturnFormat = 'first_row' # По умолчанию
    if ($Parameters.ContainsKey('return_format') -and -not [string]::IsNullOrWhiteSpace($Parameters.return_format)) {
        $tempFormat = $Parameters.return_format.ToLower()
        $validFormats = @('first_row', 'all_rows', 'row_count', 'scalar', 'non_query')
        if ($tempFormat -in $validFormats) { $ReturnFormat = $tempFormat }
        else { throw "Недопустимое значение 'return_format': '$($Parameters.return_format)'." }
    }
    $details.return_format_used = $ReturnFormat
    Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Используется return_format: $ReturnFormat"

    # Таймаут запроса
    $QueryTimeoutSec = 30
    if ($Parameters.ContainsKey('query_timeout_sec') -and $Parameters.query_timeout_sec -ne $null) {
        $parsedTimeout = 0
        if ([int]::TryParse($Parameters.query_timeout_sec, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
            $QueryTimeoutSec = $parsedTimeout
        } else {
            Write-Warning "[$NodeName] Check-SQL_QUERY_EXECUTE: Некорректное 'query_timeout_sec', используется $QueryTimeoutSec сек."
        }
    }
    Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Используется query_timeout_sec: $QueryTimeoutSec сек."

    # --- 2. Формирование параметров для Invoke-Sqlcmd ---
    $invokeSqlParams = @{
        ServerInstance          = $SqlServerInstance
        Database                = $DatabaseName
        Query                   = $SqlQuery
        QueryTimeout            = $QueryTimeoutSec
        ErrorAction             = 'Stop' # Перехватываем ошибки SQL
        TrustServerCertificate  = $true
    }
    if ($SqlUsername) {
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Используется SQL Server аутентификация для '$SqlUsername'."
        $securePassword = ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force
        $invokeSqlParams.Credential = New-Object System.Management.Automation.PSCredential($SqlUsername, $securePassword)
    } else {
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Используется Windows аутентификация."
    }

    # --- 3. Проверка и загрузка модуля SqlServer ---
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -ListAvailable -Name SqlServer)) {
            throw "Модуль PowerShell 'SqlServer' не найден. Установите его: Install-Module SqlServer"
        }
        try {
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Загрузка модуля SqlServer..."
            Import-Module SqlServer -ErrorAction Stop
        } catch {
            throw "Не удалось загрузить модуль 'SqlServer'. Ошибка: $($_.Exception.Message)"
        }
    }

    # --- 4. Выполнение SQL-запроса ---
    Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Выполнение запроса к '$SqlServerInstance/$DatabaseName'..."
    $queryResultData = $null # Результат выполнения команды

    # Для non_query нужно перехватывать ошибку, чтобы понять, был ли успех
    if ($ReturnFormat -eq 'non_query') {
        try {
            Invoke-Sqlcmd @invokeSqlParams | Out-Null # Игнорируем вывод, если он есть
            $isAvailable = $true
            $details.non_query_success = $true # Запрос выполнен без ошибок
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Non-query запрос выполнен успешно."
        } catch {
            # Ошибка при выполнении non-query
            $isAvailable = $false # Считаем проверку неуспешной
            $exceptionMessage = $_.Exception.Message
            if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
            $errorMessage = "Ошибка выполнения non-query SQL: $exceptionMessage"
            $details.error = $errorMessage
            $details.ErrorRecord = $_.ToString()
            $details.non_query_success = $false
            Write-Warning "[$NodeName] Check-SQL_QUERY_EXECUTE: $errorMessage"
        }
    } else {
        # Для запросов, возвращающих данные
        $queryResultData = Invoke-Sqlcmd @invokeSqlParams
        $isAvailable = $true # Если нет исключения, запрос выполнен
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Запрос, возвращающий данные, выполнен."
    }

    # --- 5. Обработка результата (если это не non_query и запрос был успешен) ---
    if ($isAvailable -and $ReturnFormat -ne 'non_query') {
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Обработка результата (формат: $ReturnFormat)..."

        # --- СОЗДАЕМ ДЕТАЛИ ЗАПРОСА ЗАНОВО ВНУТРИ БЛОКА ---
        $details = @{
            server_instance    = $SqlServerInstance
            database_name      = $DatabaseName
            query_executed     = $SqlQuery
            return_format_used = $ReturnFormat
            # Добавляем сюда поля, специфичные для формата
        }

        switch ($ReturnFormat) {
            'first_row' {
                $resultHashTable = $null
                $rowCount = 0
                if ($queryResultData -ne $null) {
                    $resultArray = @($queryResultData)
                    if ($resultArray.Length -gt 0) {
                        $firstRow = $resultArray[0]
                        $resultHashTable = @{}
                        $firstRow.PSObject.Properties | ForEach-Object { $resultHashTable[$_.Name] = $_.Value }
                        $rowCount = $resultArray.Length
                    }
                }
                $details.Add('query_result', $resultHashTable) # Добавляем поле
                $details.Add('rows_returned', $rowCount)     # Добавляем поле
                Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: first_row результат обработан. Строк: $rowCount."
            }
            'all_rows' {
                $allRowsList = [System.Collections.Generic.List[object]]::new()
                $rowCount = 0
                if ($queryResultData -ne $null) {
                    foreach ($row in @($queryResultData)) {
                        $rowHashTable = @{}
                        $row.PSObject.Properties | ForEach-Object { $rowHashTable[$_.Name] = $_.Value }
                        $allRowsList.Add($rowHashTable)
                    }
                    $rowCount = $allRowsList.Count
                }
                $details.Add('query_result', $allRowsList) # Добавляем поле
                $details.Add('rows_returned', $rowCount)  # Добавляем поле
                Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: all_rows результат обработан. Строк: $rowCount."
            }
            'row_count' {
                $rowCount = 0
                if ($queryResultData -ne $null) { $rowCount = @($queryResultData).Length }
                $details.Add('row_count', $rowCount) # Добавляем поле
                Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: row_count результат обработан. Строк: $rowCount."
            }
            'scalar' {
                $scalarValue = $null
                if ($queryResultData -ne $null) {
                    $firstRow = @($queryResultData)[0]
                    if ($firstRow) {
                        $firstColumnName = ($firstRow.PSObject.Properties | Select-Object -First 1).Name
                        if ($firstColumnName) { $scalarValue = $firstRow.$firstColumnName }
                    }
                }
                $details.Add('scalar_value', $scalarValue) # Добавляем поле
                Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: scalar результат обработан. Значение: '$scalarValue'."
            }
        } # Конец switch

        # --- 6. Вызов универсальной функции проверки критериев (ИСПОЛЬЗУЕМ ЗАПОЛНЕННЫЙ $details) ---
        $failReason = $null
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Вызов Test-SuccessCriteria..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason
            if ($checkSuccess -eq $null) {
                $errorMessage = "Ошибка при обработке SuccessCriteria: $failReason"
                Write-Warning "[$NodeName] $errorMessage"
            } elseif ($checkSuccess -eq $false) {
                $errorMessage = $failReason
                Write-Verbose "[$NodeName] ... SuccessCriteria НЕ пройдены: $failReason"
            } else {
                $errorMessage = $null
                Write-Verbose "[$NodeName] ... SuccessCriteria пройдены."
            }
        } else {
            $checkSuccess = $true
            $errorMessage = $null
            Write-Verbose "[$NodeName] ... SuccessCriteria не заданы, CheckSuccess=true."
        }

    } elseif ($ReturnFormat -eq 'non_query' -and $isAvailable) {
        # Для non_query, который прошел без SQL ошибки
        $checkSuccess = $true # Считаем успешным, если нет критериев
        $errorMessage = $null
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Вызов Test-SuccessCriteria для non_query..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            if ($checkSuccess -ne $true) { $errorMessage = $criteriaResult.FailReason }
        }
    } else {
        # Если IsAvailable = $false (ошибка SQL или подключения)
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) {
            $errorMessage = "Ошибка выполнения SQL запроса (IsAvailable=false)."
        }
    }

    # --- 7. Формирование итогового результата (используем $details, сформированный выше) ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch {
    # --- Обработка КРИТИЧЕСКИХ ОШИБОК ---
    $isAvailable = $false
    $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $critErrorMessage = "Критическая ошибка при выполнении SQL-запроса: {0}" -f $exceptionMessage
    $detailsError = @{
        error           = $critErrorMessage
        ErrorRecord     = $_.ToString()
        server_instance = $TargetIP
        database_name   = $Parameters?.sql_database
        query_executed  = $Parameters?.sql_query
    }
    $finalResult = @{
        IsAvailable  = $isAvailable
        CheckSuccess = $checkSuccess
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        Details      = $detailsError
        ErrorMessage = $critErrorMessage
    }
    Write-Error "[$NodeName] Check-SQL_QUERY_EXECUTE: Критическая ошибка: $critErrorMessage"
}

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE (v2.0.1): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult