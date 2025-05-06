# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-PROCESS_LIST.ps1
# --- Версия 2.1.0 --- Рефакторинг для читаемости, PS 5.1, удален Get-OrElse
<#
.SYNOPSIS
    Получает список запущенных процессов. (v2.1.0)
.DESCRIPTION
    Использует Get-Process. Позволяет фильтровать/сортировать по имени, ID, CPU, памяти, времени запуска.
    Может включать имя пользователя и путь к исполняемому файлу.
    Формирует $Details с массивом 'processes', содержащим стандартизированную информацию.
    Вызывает Test-SuccessCriteria для определения CheckSuccess на основе собранных данных.
.PARAMETER TargetIP
    [string] Обязательный. IP или имя хоста (в текущей реализации Get-Process выполняется локально,
             поэтому TargetIP используется в основном для логирования и идентификации задания).
.PARAMETER Parameters
    [hashtable] Опциональный. Параметры для настройки выборки и вывода:
                - process_names ([string[]]): Массив имен процессов для фильтрации (поддерживаются wildcard).
                - include_username ([bool]): Включить ли имя пользователя процесса. По умолчанию $false.
                - include_path ([bool]): Включить ли путь к исполняемому файлу. По умолчанию $false.
                - sort_by ([string]): Поле для сортировки. Допустимые: 'id', 'name', 'cpu' (или 'cpu_seconds'),
                                      'memory' (или 'mem', 'ws', 'memory_ws_mb'), 'start_time'. По умолчанию 'name'.
                - sort_descending ([bool]): Сортировать по убыванию. По умолчанию $false.
                - top_n ([int]): Вернуть только указанное количество процессов после сортировки.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха для оценки массива 'processes' в $Details.
                Примеры:
                - Наличие процесса: @{ processes = @{ _condition_='count'; _where_=@{name='notepad.exe'}; _count_=@{'>='=1}} }
                - Отсутствие процесса: @{ processes = @{ _condition_='none'; _where_=@{name='malware.exe'}} }
                - Проверка CPU/памяти: @{ processes = @{ _condition_='all'; _where_=@{name='sqlservr.exe'}; _criteria_=@{memory_ws_mb=@{'<'=2048}}} }
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки, созданный New-CheckResultObject.
.NOTES
    Версия: 2.1.0
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria из модуля StatusMonitorAgentUtils.
    Get-Process выполняется локально. Для удаленного выполнения потребуется обертка с Invoke-Command.
    Получение username и path может быть ресурсоемким и требовать повышенных прав.
#>
param(
    [Parameter(Mandatory = $false)] # <--- ИЗМЕНЕНО: Сделан не обязательным
    [string]$TargetIP,             # Тип [string] по умолчанию допускает $null, если Mandatory=$false
    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node (PROCESS_LIST)"
)

# --- Инициализация основных переменных ---
$isAvailable = $false             # Смогли ли мы вообще выполнить Get-Process
$checkSuccess = $null            # Результат проверки SuccessCriteria
$errorMessage = $null            # Сообщение об ошибке
$finalResult = $null             # Итоговый объект для возврата
# $details будет содержать массив 'processes' и, возможно, 'message' или 'error'
$details = @{
    processes = [System.Collections.Generic.List[object]]::new() # Список для хранения обработанных процессов
}

# Используем NodeName для ясности, TargetIP теперь опционален и больше для контекста
$logTargetDisplay = if (-not [string]::IsNullOrWhiteSpace($TargetIP)) { $TargetIP } else { $env:COMPUTERNAME + " (локально)" }
Write-Verbose "[$NodeName] Check-PROCESS_LIST (v2.1.1): Начало получения списка процессов. Цель (контекст): $logTargetDisplay"

# --- Основной блок Try/Catch для всей логики скрипта ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>

    # --- 1. Обработка входных параметров ($Parameters) ---
    $processNamesFilter = $null
    $filteringByName = $false
    if ($Parameters.ContainsKey('process_names') -and ($Parameters.process_names -is [array]) -and ($Parameters.process_names.Count -gt 0)) {
        $processNamesFilter = $Parameters.process_names
        $filteringByName = $true
        Write-Verbose "[$NodeName] Фильтрация по именам процессов: $($processNamesFilter -join ', ')"
    }

    $includeUsername = $false
    if ($Parameters.ContainsKey('include_username')) {
        try { $includeUsername = [bool]$Parameters.include_username }
        catch { Write-Warning "[$NodeName] Некорректное значение для 'include_username': '$($Parameters.include_username)'. Используется $false." }
    }
    Write-Verbose "[$NodeName] Включить имя пользователя: $includeUsername"

    $includePath = $false
    if ($Parameters.ContainsKey('include_path')) {
        try { $includePath = [bool]$Parameters.include_path }
        catch { Write-Warning "[$NodeName] Некорректное значение для 'include_path': '$($Parameters.include_path)'. Используется $false." }
    }
    Write-Verbose "[$NodeName] Включить путь к файлу: $includePath"

    # Определение поля для сортировки ($sortByActual)
    $sortByInputString = 'name' # По умолчанию
    if ($Parameters.ContainsKey('sort_by') -and (-not [string]::IsNullOrWhiteSpace($Parameters.sort_by))) {
        $sortByInputString = $Parameters.sort_by.ToString().Trim()
    }
    
    $validSortFieldsMap = @{ # Карта псевдонимов к реальным именам полей в $procInfo
        'id'           = 'id'
        'name'         = 'name'
        'cpu'          = 'cpu_seconds'
        'cpu_seconds'  = 'cpu_seconds'
        'memory'       = 'memory_ws_mb'
        'mem'          = 'memory_ws_mb'
        'ws'           = 'memory_ws_mb'
        'memory_ws_mb' = 'memory_ws_mb'
        'start_time'   = 'start_time'
    }
    $sortByActual = 'name' # Поле для сортировки по умолчанию
    if ($validSortFieldsMap.ContainsKey($sortByInputString.ToLower())) {
        $sortByActual = $validSortFieldsMap[$sortByInputString.ToLower()]
    } else {
        Write-Warning "[$NodeName] Некорректное значение для 'sort_by': '$sortByInputString'. Используется сортировка по 'name'."
    }
    Write-Verbose "[$NodeName] Поле для сортировки: $sortByActual"

    $sortDescending = $false
    if ($Parameters.ContainsKey('sort_descending')) {
        try { $sortDescending = [bool]$Parameters.sort_descending }
        catch { Write-Warning "[$NodeName] Некорректное значение для 'sort_descending': '$($Parameters.sort_descending)'. Используется $false." }
    }
    Write-Verbose "[$NodeName] Сортировать по убыванию: $sortDescending"

    $topN = 0 # 0 означает без ограничения
    if ($Parameters.ContainsKey('top_n') -and $Parameters.top_n -ne $null) {
        $parsedTopNValue = 0
        if ([int]::TryParse($Parameters.top_n.ToString(), [ref]$parsedTopNValue) -and $parsedTopNValue -ge 0) { # Разрешаем 0 (без ограничения)
            $topN = $parsedTopNValue
        } else {
            Write-Warning "[$NodeName] Некорректное значение для 'top_n': '$($Parameters.top_n)'. Ограничение не будет применяться."
        }
    }
    Write-Verbose "[$NodeName] Отобразить топ N процессов: $(if ($topN -gt 0) {$topN} else {'Все'})"

    # --- 2. Выполнение Get-Process ---
    $getProcessCmdParams = @{}
    # ErrorAction Stop для общего случая, SilentlyContinue если фильтруем по имени и процесс может быть не найден
    $getProcessCmdParams.ErrorAction = if ($filteringByName) { 'SilentlyContinue' } else { 'Stop' }
    
    if ($filteringByName) {
        $getProcessCmdParams.Name = $processNamesFilter
    }
    # Для PS 5.1, Get-Process -ComputerName требует соответствующей настройки и прав,
    # и не всегда работает надежно. Текущая реализация выполняет Get-Process локально.
    # Если TargetIP не localhost, это просто для информации/контекста.
    # if ($TargetIP -ne $env:COMPUTERNAME -and $TargetIP -ne 'localhost' -and $TargetIP -ne '127.0.0.1') {
    #    $getProcessCmdParams.ComputerName = $TargetIP # Потребует WinRM и прав
    # }

    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Вызов Get-Process с параметрами: $($getProcessCmdParams | ConvertTo-Json -Compress -Depth 1)"
    $processesRaw = Get-Process @getProcessCmdParams
    
    # Проверяем специфичную ошибку "ProcessNotFoundException" при фильтрации по имени
    $processNotFoundErrorOccurred = $false
    if ($filteringByName -and $Error.Count -gt 0) {
        foreach ($errRec in $Error) {
            if ($errRec.CategoryInfo.Reason -eq 'ProcessNotFoundException') {
                $processNotFoundErrorOccurred = $true
                Write-Verbose "[$NodeName] Примечание: Один или несколько процессов из фильтра '$($processNamesFilter -join ', ')' не найдены."
                # Можно добавить $errRec.Exception.Message в $details.messages, если нужно
                break 
            }
        }
        $Error.Clear() # Очищаем ошибки, связанные с ненайденными процессами, чтобы они не считались критическими
    }

    $isAvailable = $true # Если мы дошли сюда без исключения из Get-Process (кроме ProcessNotFound), считаем, что команда отработала
    $rawProcessCount = if ($null -ne $processesRaw) { @($processesRaw).Count } else { 0 } # @() для гарантии массива, даже если 1 элемент
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Get-Process выполнен. Найдено процессов (до обработки): $rawProcessCount."

    # --- 3. Обработка результатов Get-Process и формирование $details.processes ---
    if ($rawProcessCount -gt 0) {
        $tempProcessedList = foreach ($proc in $processesRaw) {
            # Создаем хэш-таблицу для информации о процессе
            $procInfo = [ordered]@{ # Используем ordered для предсказуемого порядка в JSON
                id              = $proc.Id
                name            = $proc.ProcessName
                cpu_seconds     = $null # Будет заполнено ниже
                memory_ws_mb    = $null # Рабочий набор (Working Set)
                username        = $null # Будет заполнено, если $includeUsername
                path            = $null # Будет заполнено, если $includePath
                start_time      = $null # Время запуска
            }
            
            # Пытаемся получить дополнительные свойства, обрабатывая возможные ошибки
            try { $procInfo.cpu_seconds = [math]::Round($proc.CPU, 2) } catch { Write-Verbose "[$NodeName] Не удалось получить CPU для процесса $($proc.Id) ($($proc.ProcessName)): $($_.Exception.Message)" }
            try { $procInfo.memory_ws_mb = [math]::Round($proc.WS / 1MB, 1) } catch { Write-Verbose "[$NodeName] Не удалось получить WS для процесса $($proc.Id) ($($proc.ProcessName)): $($_.Exception.Message)" }
            try { if ($proc.StartTime) { $procInfo.start_time = $proc.StartTime.ToUniversalTime().ToString("o") } } catch { Write-Verbose "[$NodeName] Не удалось получить StartTime для процесса $($proc.Id) ($($proc.ProcessName)): $($_.Exception.Message)" }

            if ($includeUsername) {
                try {
                    # Get-CimInstance более надежен для получения владельца, чем $proc.UserName (которого нет)
                    $ownerDetails = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Owner -ErrorAction SilentlyContinue
                    if ($ownerDetails -and $ownerDetails.User) {
                        $procInfo.username = if ($ownerDetails.Domain) { "$($ownerDetails.Domain)\$($ownerDetails.User)" } else { $ownerDetails.User }
                    } else {
                        $procInfo.username = '[N/A_User]' # Пользователь не определен или нет доступа
                    }
                } catch {
                    $procInfo.username = '[AccessError_User]' # Ошибка при попытке получить пользователя
                    Write-Verbose "[$NodeName] Ошибка получения пользователя для процесса $($proc.Id): $($_.Exception.Message)"
                }
            }

            if ($includePath) {
                try {
                    $executablePath = $proc.Path # Это свойство есть у объектов Get-Process
                    if (-not $executablePath -and $proc.MainModule) { # Fallback, если Path пуст, но есть MainModule
                        try { $executablePath = $proc.MainModule.FileName } catch {}
                    }
                    $procInfo.path = if ([string]::IsNullOrWhiteSpace($executablePath)) { '[N/A_Path]' } else { $executablePath }
                } catch {
                    $procInfo.path = '[AccessError_Path]' # Ошибка при попытке получить путь
                    Write-Verbose "[$NodeName] Ошибка получения пути для процесса $($proc.Id): $($_.Exception.Message)"
                }
            }
            # Возвращаем PSCustomObject для удобства сортировки и обработки далее
            [PSCustomObject]$procInfo 
        } # Конец foreach ($proc in $processesRaw)

        # Сортировка (если список не пустой)
        if ($tempProcessedList.Count -gt 0) {
            Write-Verbose "[$NodeName] Сортировка списка процессов по '$sortByActual' (убывание: $sortDescending)..."
            try {
                $tempProcessedList = $tempProcessedList | Sort-Object -Property $sortByActual -Descending:$sortDescending
            } catch {
                Write-Warning "[$NodeName] Ошибка при сортировке по '$sortByActual'. Применена сортировка по 'name'. Ошибка: $($_.Exception.Message)"
                $tempProcessedList = $tempProcessedList | Sort-Object -Property 'name' # Fallback сортировка
            }
        }
        
        # Ограничение Top N (если нужно и список не пустой)
        if ($topN -gt 0 -and $tempProcessedList.Count -gt $topN) {
            Write-Verbose "[$NodeName] Применение Top N: $topN"
            $tempProcessedList = $tempProcessedList | Select-Object -First $topN
        }
        
        # Добавляем обработанные процессы в $details
        $details.processes.AddRange($tempProcessedList)
        Write-Verbose "[$NodeName] В $details.processes добавлено $($tempProcessedList.Count) процессов."

    } elseif ($filteringByName -and $processNotFoundErrorOccurred) {
        # Если был фильтр по имени и процессы не найдены (это НЕ ошибка доступности проверки)
        $details.message = "Процессы, соответствующие фильтру '$($processNamesFilter -join ', ')', не найдены."
        Write-Verbose "[$NodeName] $($details.message)"
    } else {
        # Если процессов нет вообще (не из-за фильтра) или Get-Process вернул $null
        $details.message = "Список запущенных процессов пуст или не удалось получить данные."
        Write-Verbose "[$NodeName] $($details.message)"
    }

    # --- 4. Проверка критериев успеха ---
    # Критерии проверяются на основе $details.processes
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-PROCESS_LIST: Вызов Test-SuccessCriteria..."
            # $details передается целиком, Test-SuccessCriteria будет работать с $details.processes, если критерий нацелен на него
            $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
            
            $checkSuccess = $criteriaProcessingResult.Passed
            $failReasonFromCriteria = $criteriaProcessingResult.FailReason

            if ($checkSuccess -ne $true) {
                if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) {
                    $errorMessage = $failReasonFromCriteria
                } else {
                    $errorMessage = "Критерии успеха для списка процессов не пройдены (CheckSuccess: $($checkSuccess | ForEach-Object {if ($_ -eq $null) {'[null]'} else {$_}}))."
                }
                Write-Verbose "[$NodeName] ... SuccessCriteria НЕ пройдены или ошибка оценки. ErrorMessage: $errorMessage"
            } else {
                $errorMessage = $null # Критерии пройдены
                Write-Verbose "[$NodeName] ... SuccessCriteria пройдены."
            }
        } else {
            # Критерии не заданы - считаем успешным, если сама проверка прошла
            $checkSuccess = $true
            $errorMessage = $null
            Write-Verbose "[$NodeName] Check-PROCESS_LIST: SuccessCriteria не заданы, CheckSuccess установлен в true (т.к. IsAvailable=true)."
        }
    } else {
        # IsAvailable = $false (ошибка при Get-Process)
        $checkSuccess = $null # Критерии не оценивались
        # $errorMessage уже должен быть установлен в блоке catch ниже, если была критическая ошибка Get-Process
        if ([string]::IsNullOrEmpty($errorMessage)) {
            $errorMessage = "Ошибка получения списка процессов (IsAvailable=false), критерии не проверялись."
        }
    }

    # --- 5. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch { # <<< ОСНОВНОЙ CATCH для критических ошибок (например, Stop ErrorAction из Get-Process) >>>
    $isAvailable = $false # Гарантированно false при критической ошибке
    $checkSuccess = $null   # Критерии не могли быть оценены
    
    $critErrorMessage = "Критическая ошибка в Check-PROCESS_LIST для '$TargetIP': $($_.Exception.Message)"
    Write-Error "[$NodeName] Check-PROCESS_LIST: $critErrorMessage ScriptStackTrace: $($_.ScriptStackTrace)"
    
    # $details может быть уже частично заполнен, добавляем информацию об ошибке
    if ($null -eq $details) { $details = @{} }
    $details.error = $critErrorMessage
    $details.ErrorRecord = $_.ToString()
    
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $critErrorMessage
} # <<< КОНЕЦ ОСНОВНОГО CATCH >>>

# --- Отладка перед возвратом (можно закомментировать после отладки) ---
Write-Host "DEBUG (Check-PROCESS_LIST): --- Начало отладки finalResult.Details ---" -ForegroundColor Green
if ($finalResult -and $finalResult.Details) {
    Write-Host "DEBUG (Check-PROCESS_LIST): Тип finalResult.Details: $($finalResult.Details.GetType().FullName)" -ForegroundColor Green
    if ($finalResult.Details -is [hashtable]) {
        Write-Host "DEBUG (Check-PROCESS_LIST): Ключи в finalResult.Details: $($finalResult.Details.Keys -join ', ')" -ForegroundColor Green
        Write-Host "DEBUG (Check-PROCESS_LIST): Количество процессов в Details: $($finalResult.Details.processes.Count)" -ForegroundColor Green
    }
    # Write-Host "DEBUG (Check-PROCESS_LIST): Полное содержимое finalResult.Details (JSON): $($finalResult.Details | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue)" -ForegroundColor DarkGreen
} elseif ($finalResult) {
    Write-Host "DEBUG (Check-PROCESS_LIST): finalResult.Details является $null или отсутствует." -ForegroundColor Yellow
} else {
    Write-Host "DEBUG (Check-PROCESS_LIST): finalResult сам по себе $null (ошибка до его формирования)." -ForegroundColor Red
}
Write-Host "DEBUG (Check-PROCESS_LIST): --- Конец отладки finalResult.Details ---" -ForegroundColor Green

# --- Возврат результата ---
$isAvailableStrForLog = if ($finalResult) { $finalResult.IsAvailable } else { '[finalResult is null]' }
$checkSuccessStrForLog = if ($finalResult) { if ($null -eq $finalResult.CheckSuccess) {'[null]'} else {$finalResult.CheckSuccess} } else { '[finalResult is null]' }
Write-Verbose "[$NodeName] Check-PROCESS_LIST (v2.1.0): Завершение. IsAvailable=$isAvailableStrForLog, CheckSuccess=$checkSuccessStrForLog"

return $finalResult