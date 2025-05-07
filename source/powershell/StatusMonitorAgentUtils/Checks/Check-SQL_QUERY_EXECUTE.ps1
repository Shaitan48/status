# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SQL_QUERY_EXECUTE.ps1
# --- Версия 2.1.1 --- Рефакторинг, PS 5.1 совместимость, улучшенная обработка ошибок и логов
<#
.SYNOPSIS
    Выполняет SQL-запрос к MS SQL Server и возвращает результат в указанном формате. (v2.1.1)
.DESCRIPTION
    Скрипт подключается к указанному экземпляру SQL Server и базе данных,
    выполняет предоставленный SQL-запрос и обрабатывает результат согласно
    параметру 'return_format'. 
    Поддерживаемые форматы вывода:
    - 'first_row': Возвращает первую строку результата как хэш-таблицу.
    - 'all_rows': Возвращает все строки результата как массив хэш-таблиц. (Осторожно с большими объемами!)
    - 'row_count': Возвращает количество строк, затронутых/возвращенных запросом.
    - 'scalar': Возвращает значение из первого столбца первой строки.
    - 'non_query': Для запросов, не возвращающих данные (например, INSERT, UPDATE, DDL). Сообщает об успехе выполнения.

    Скрипт формирует детальный объект $Details, содержащий как параметры запроса, так и его результат.
    Затем вызывает Test-SuccessCriteria (если критерии предоставлены) для определения CheckSuccess.
    Ошибки подключения к SQL, выполнения запроса или обработки результатов логируются и влияют на IsAvailable.
.PARAMETER TargetIP
    [string] Обязательный. Имя или IP-адрес SQL Server instance (например, 'SERVER\SQLEXPRESS' или 'localhost,1433').
.PARAMETER Parameters
    [hashtable] Обязательный. Хэш-таблица с параметрами для SQL-запроса:
                - sql_database ([string], Обязательный): Имя целевой базы данных.
                - sql_query ([string], Обязательный): Текст SQL-запроса для выполнения.
                - return_format ([string], Опциональный, по умолч. 'first_row'): Формат возвращаемого результата.
                                            Допустимые: 'first_row', 'all_rows', 'row_count', 'scalar', 'non_query'.
                - sql_username ([string], Опциональный): Имя пользователя для SQL Server аутентификации.
                                                         Если не указано, используется Windows-аутентификация.
                - sql_password ([string], Опциональный): Пароль для SQL Server аутентификации. 
                                                         Обязателен, если указан sql_username. (Использование не рекомендуется из соображений безопасности).
                - query_timeout_sec ([int], Опциональный, по умолч. 30): Таймаут выполнения SQL-запроса в секундах.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха, применяемые к объекту $details.
                Примеры:
                - Для 'row_count': @{ row_count = @{'>=' = 1} }
                - Для 'scalar': @{ scalar_value = "OK" } или @{ scalar_value = @{'matches' = '^Error.*'} }
                - Для 'first_row' (проверка поля 'Status'): @{ query_result = @{ Status = "Completed" } }
                - Для 'all_rows' (все строки должны иметь Value > 0): 
                  @{ query_result = @{ _condition_ = "all"; _criteria_ = @{ Value = @{">"=0} } } }
.PARAMETER NodeName
    [string] Опциональный. Имя узла (для логирования).
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки, созданный New-CheckResultObject.
.NOTES
    Версия: 2.1.1
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria из модуля StatusMonitorAgentUtils.
    Требует наличия модуля 'SqlServer' на машине, где выполняется скрипт.
    Рекомендуется использовать Windows-аутентификацию для подключения к SQL Server.
#>
param(
    [Parameter(Mandatory = $true)] # TargetIP здесь - это SQL Server Instance, он должен быть обязательным
    [string]$TargetIP, 
    [Parameter(Mandatory = $false)] # Проверяем наличие ключей внутри
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node (SQL_QUERY_EXECUTE)"
)

# --- Инициализация ---
$isAvailable = $false             # Смогли ли мы успешно выполнить запрос и получить данные/статус
$checkSuccess = $null            # Результат проверки SuccessCriteria
$errorMessage = $null            # Сообщение об ошибке
$finalResult = $null             # Итоговый объект для возврата
# $details инициализируется основными параметрами, затем дополняется результатами
$details = @{ 
    server_instance    = $TargetIP
    database_name      = $null 
    query_executed     = $null 
    return_format_used = 'first_row' # Значение по умолчанию, будет обновлено
    # Поля для результатов будут добавлены в зависимости от return_format:
    # query_result (для first_row, all_rows)
    # rows_returned (для first_row, all_rows)
    # row_count (для row_count)
    # scalar_value (для scalar)
    # non_query_success (для non_query)
}

$logTargetDisplay = if (-not [string]::IsNullOrWhiteSpace($TargetIP)) { $TargetIP } else { "[SQL Server не указан]" }
Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE (v2.1.1): Начало выполнения SQL. Сервер: $logTargetDisplay"

# --- Основной блок Try/Catch для всей логики скрипта ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>

    # --- 1. Извлечение и валидация параметров из $Parameters ---
    $SqlServerInstance = $TargetIP # TargetIP является экземпляром SQL Server

    if (-not $Parameters.ContainsKey('sql_database') -or [string]::IsNullOrWhiteSpace($Parameters.sql_database)) {
        throw "Отсутствует или пуст обязательный параметр 'sql_database' в Parameters."
    }
    $DatabaseName = $Parameters.sql_database.Trim()
    $details.database_name = $DatabaseName

    if (-not $Parameters.ContainsKey('sql_query') -or [string]::IsNullOrWhiteSpace($Parameters.sql_query)) {
        throw "Отсутствует или пуст обязательный параметр 'sql_query' в Parameters."
    }
    $SqlQuery = $Parameters.sql_query.Trim()
    $details.query_executed = $SqlQuery
    
    $SqlUsername = $null
    if ($Parameters.ContainsKey('sql_username')) {
        $SqlUsername = $Parameters.sql_username # Может быть $null или пустой строкой
    }
    $SqlPassword = $null # Пароль нужен, только если есть имя пользователя
    if (-not [string]::IsNullOrWhiteSpace($SqlUsername)) {
        if (-not $Parameters.ContainsKey('sql_password') -or $Parameters.sql_password -eq $null) { # Пароль может быть пустой строкой, если SQL Server это позволяет
            throw "Параметр 'sql_password' обязателен и не должен быть `$null, если указан 'sql_username'."
        }
        $SqlPassword = $Parameters.sql_password
    }

    $ReturnFormat = 'first_row' # Значение по умолчанию
    if ($Parameters.ContainsKey('return_format') -and (-not [string]::IsNullOrWhiteSpace($Parameters.return_format))) {
        $tempFormat = $Parameters.return_format.ToString().ToLower().Trim()
        $validFormats = @('first_row', 'all_rows', 'row_count', 'scalar', 'non_query')
        if ($tempFormat -in $validFormats) {
            $ReturnFormat = $tempFormat
        } else {
            throw "Недопустимое значение для 'return_format': '$($Parameters.return_format)'. Допустимые: $($validFormats -join ', ')."
        }
    }
    $details.return_format_used = $ReturnFormat
    Write-Verbose "[$NodeName] SQL: Используется return_format: '$ReturnFormat'."

    $QueryTimeoutSec = 30 # Значение по умолчанию
    if ($Parameters.ContainsKey('query_timeout_sec') -and $Parameters.query_timeout_sec -ne $null) {
        $parsedTimeout = 0
        if ([int]::TryParse($Parameters.query_timeout_sec.ToString(), [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
            $QueryTimeoutSec = $parsedTimeout
        } else {
            Write-Warning "[$NodeName] SQL: Некорректное значение 'query_timeout_sec': '$($Parameters.query_timeout_sec)'. Используется $QueryTimeoutSec сек."
        }
    }
    Write-Verbose "[$NodeName] SQL: Используется query_timeout_sec: $QueryTimeoutSec сек."

    # --- 2. Подготовка параметров для Invoke-Sqlcmd ---
    $invokeSqlParams = @{
        ServerInstance       = $SqlServerInstance
        Database             = $DatabaseName
        Query                = $SqlQuery
        QueryTimeout         = $QueryTimeoutSec
        ErrorAction          = 'Stop' # Важно для перехвата ошибок SQL в блоке catch
        TrustServerCertificate = $true   # Часто необходимо для тестовых/внутренних сред
        OutputSqlErrors      = $true   # Выводить ошибки SQL в поток ошибок PowerShell
    }
    if (-not [string]::IsNullOrWhiteSpace($SqlUsername)) {
        $securePassword = ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($SqlUsername, $securePassword)
        $invokeSqlParams.Credential = $credential
        Write-Verbose "[$NodeName] SQL: Используется SQL аутентификация для пользователя '$SqlUsername'."
    } else {
        Write-Verbose "[$NodeName] SQL: Используется Windows аутентификация."
    }

    # --- 3. Проверка наличия модуля SqlServer ---
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
        Write-Warning "[$NodeName] SQL: Командлет Invoke-Sqlcmd не найден. Попытка импорта модуля 'SqlServer'..."
        try {
            Import-Module SqlServer -ErrorAction Stop -Scope Local # Импорт в локальную область видимости
            Write-Verbose "[$NodeName] SQL: Модуль 'SqlServer' успешно импортирован."
        } catch {
            throw "Модуль 'SqlServer' не установлен или не может быть импортирован. Установите его командой: Install-Module SqlServer -Scope CurrentUser. Ошибка импорта: $($_.Exception.Message)"
        }
    }

    # --- 4. Выполнение SQL-запроса ---
    Write-Verbose "[$NodeName] SQL: Выполнение запроса к '$SqlServerInstance/$DatabaseName' (формат: $ReturnFormat)..."
    $queryResultData = $null # Результат от Invoke-Sqlcmd
    
    if ($ReturnFormat -eq 'non_query') {
        Invoke-Sqlcmd @invokeSqlParams | Out-Null # Ошибки (включая SQL ошибки) будут пойманы в catch благодаря ErrorAction=Stop и OutputSqlErrors=$true
        $isAvailable = $true # Если дошли сюда без исключения, команда на сервере выполнена
        $details.non_query_success = $true
        Write-Verbose "[$NodeName] SQL: non-query запрос успешно выполнен."
    } else {
        $queryResultData = Invoke-Sqlcmd @invokeSqlParams
        $isAvailable = $true # Если нет исключения, значит, подключение к БД и выполнение запроса удалось
        Write-Verbose "[$NodeName] SQL: запрос, возвращающий данные, выполнен."
        
        # 5. Обработка результата ($queryResultData) в зависимости от $ReturnFormat
        # $details был инициализирован ранее, здесь мы добавляем/обновляем ключи с результатами
        switch ($ReturnFormat) {
            'first_row' { 
                $firstRowResult = $null
                $returnedRowCount = 0
                if ($null -ne $queryResultData) {
                    $queryResultArray = @($queryResultData) # Гарантируем, что это массив
                    $returnedRowCount = $queryResultArray.Count
                    if ($returnedRowCount -gt 0) {
                        $firstRowResult = @{} # Создаем Hashtable для первой строки
                        # Копируем все свойства из объекта DataRow (или PSCustomObject) в Hashtable
                        $queryResultArray[0].PSObject.Properties | ForEach-Object { $firstRowResult[$_.Name] = $_.Value }
                    }
                }
                $details.query_result = $firstRowResult # Будет $null, если запрос не вернул строк
                $details.rows_returned = $returnedRowCount
            }
            'all_rows' { 
                $allRowsResult = [System.Collections.Generic.List[object]]::new()
                $returnedRowCount = 0
                if ($null -ne $queryResultData) {
                    foreach($rowItem in @($queryResultData)) { # Гарантируем массив
                        $rowDataHashtable = @{}
                        $rowItem.PSObject.Properties | ForEach-Object { $rowDataHashtable[$_.Name] = $_.Value }
                        $allRowsResult.Add($rowDataHashtable)
                    }
                    $returnedRowCount = $allRowsResult.Count
                }
                $details.query_result = $allRowsResult # Будет пустым списком, если нет строк
                $details.rows_returned = $returnedRowCount
            }
            'row_count' { 
                $returnedRowCount = 0
                if ($null -ne $queryResultData) { $returnedRowCount = @($queryResultData).Count }
                $details.row_count = $returnedRowCount
            }
            'scalar' { 
                $scalarResultValue = $null
                if ($null -ne $queryResultData) {
                    $queryResultArray = @($queryResultData)
                    if ($queryResultArray.Count -gt 0) {
                        $firstRowObject = $queryResultArray[0]
                        # Получаем имя первого свойства первого объекта результата
                        if ($firstRowObject.PSObject.Properties.Count -gt 0) {
                            $firstPropertyName = $firstRowObject.PSObject.Properties[0].Name
                            $scalarResultValue = $firstRowObject.$firstPropertyName
                        }
                    }
                }
                $details.scalar_value = $scalarResultValue # Будет $null, если запрос не вернул строк/столбцов
            }
        }
        Write-Verbose "[$NodeName] SQL: Результат запроса обработан для формата '$ReturnFormat'."
    }

    # --- 6. Проверка критериев успеха ---
    # $isAvailable уже должен быть true, если не было исключений при выполнении SQL
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] SQL: Вызов Test-SuccessCriteria..."
            $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
            
            $checkSuccess = $criteriaProcessingResult.Passed
            $failReasonFromCriteria = $criteriaProcessingResult.FailReason

            if ($checkSuccess -ne $true) { # Если $false или $null (ошибка критерия)
                if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) {
                    $errorMessage = $failReasonFromCriteria
                } else {
                    $errorMessage = "Критерии успеха для SQL-запроса не пройдены (CheckSuccess: $($checkSuccess | ForEach-Object {if ($_ -eq $null) {'[null]'} else {$_}}))."
                }
                Write-Verbose "[$NodeName] SQL: SuccessCriteria НЕ пройдены или ошибка оценки. ErrorMessage: $errorMessage"
            } else {
                $errorMessage = $null # Критерии пройдены
                Write-Verbose "[$NodeName] SQL: SuccessCriteria пройдены."
            }
        } else {
            # Критерии не заданы - считаем успешным, если сама SQL-проверка прошла (isAvailable=true)
            $checkSuccess = $true 
            $errorMessage = $null
            Write-Verbose "[$NodeName] SQL: SuccessCriteria не заданы, CheckSuccess установлен в true."
        }
    } else { # Этот блок не должен выполняться, если isAvailable=false из-за исключения выше, т.к. будет выполнен основной catch
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) { 
            $errorMessage = "Ошибка выполнения SQL-запроса (IsAvailable=false), критерии не проверялись."
        }
    }

    # --- 7. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch { # <<< Основной CATCH для критических ошибок (подключение, выполнение SQL, валидация параметров, импорт модуля) >>>
    $isAvailable = $false 
    $checkSuccess = $null   
    
    # Формируем информативное сообщение об ошибке
    $exceptionMessage = $_.Exception.Message
    # Invoke-Sqlcmd при OutputSqlErrors=$true может помещать SQL ошибки в InnerException
    if ($_.Exception.InnerException) {
        $exceptionMessage += " Внутренняя ошибка SQL: $($_.Exception.InnerException.Message)"
    }
    $critErrorMessageFromCatch = "Критическая ошибка в Check-SQL_QUERY_EXECUTE для '$($TargetIP)/$($details.database_name)': $exceptionMessage"
    Write-Error "[$NodeName] Check-SQL_QUERY_EXECUTE: $critErrorMessageFromCatch ScriptStackTrace: $($_.ScriptStackTrace)"
    
    # $details может быть уже частично заполнен, добавляем информацию об ошибке
    if ($null -eq $details) { $details = @{} } 
    if (-not $details.ContainsKey('server_instance')) { $details.server_instance = $TargetIP }
    if (-not $details.ContainsKey('database_name') -and $DatabaseName) { $details.database_name = $DatabaseName } # $DatabaseName может быть не установлен, если ошибка до его парсинга
    if (-not $details.ContainsKey('query_executed') -and $SqlQuery) { $details.query_executed = $SqlQuery }     # Аналогично для $SqlQuery

    $details.error = $critErrorMessageFromCatch # Перезаписываем или добавляем поле error
    $details.ErrorRecord = $_.ToString()        # Сохраняем полный объект ошибки
    
    # Если это была ошибка non_query, помечаем ее неуспешной
    if ($ReturnFormat -eq 'non_query' -and $details.ContainsKey('non_query_success')) {
        $details.non_query_success = $false
    }
    
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $critErrorMessageFromCatch
} # <<< КОНЕЦ ОСНОВНОГО CATCH >>>

# --- Отладка перед возвратом ---
Write-Host "DEBUG (Check-SQL_QUERY_EXECUTE): --- Начало отладки finalResult.Details ---" -ForegroundColor Green
if ($finalResult -and $finalResult.Details) {
    Write-Host "DEBUG (Check-SQL_QUERY_EXECUTE): Тип finalResult.Details: $($finalResult.Details.GetType().FullName)" -ForegroundColor Green
    Write-Host "DEBUG (Check-SQL_QUERY_EXECUTE): Ключи в finalResult.Details: $($finalResult.Details.Keys -join ', ')" -ForegroundColor Green
    # Закомментировано, чтобы не перегружать вывод, но полезно для детальной отладки
    # Write-Host "DEBUG (Check-SQL_QUERY_EXECUTE): Полное содержимое finalResult.Details (JSON): $($finalResult.Details | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue)" -ForegroundColor DarkGreen
} elseif ($finalResult) { Write-Host "DEBUG (Check-SQL_QUERY_EXECUTE): finalResult.Details является $null или отсутствует." -ForegroundColor Yellow}
else { Write-Host "DEBUG (Check-SQL_QUERY_EXECUTE): finalResult сам по себе $null." -ForegroundColor Red }
Write-Host "DEBUG (Check-SQL_QUERY_EXECUTE): --- Конец отладки finalResult.Details ---" -ForegroundColor Green

# --- Возврат результата ---
$isAvailableStrForLog = '[N/A]'
if ($finalResult) { $isAvailableStrForLog = $finalResult.IsAvailable.ToString() }

$checkSuccessStrForLog = '[N/A]'
if ($finalResult) {
    if ($null -eq $finalResult.CheckSuccess) { $checkSuccessStrForLog = '[null]' }
    else { $checkSuccessStrForLog = $finalResult.CheckSuccess.ToString() }
}
Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE (v2.1.1): Завершение. IsAvailable=$isAvailableStrForLog, CheckSuccess=$checkSuccessStrForLog"

return $finalResult