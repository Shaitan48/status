# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-PROCESS_LIST.ps1
# --- Версия 2.0 ---
# Изменения:
# - Логика проверки SuccessCriteria вынесена в универсальную функцию Test-SuccessCriteria.
# - Стандартизирован формат $Details.
# - Добавлен вызов Test-SuccessCriteria.

<#
.SYNOPSIS
    Получает список запущенных процессов на локальной машине. (v2.0)
.DESCRIPTION
    Использует Get-Process для получения информации о процессах.
    Позволяет фильтровать, сортировать, ограничивать вывод и включать
    дополнительные данные (Username, Path).
    Формирует стандартизированный объект $Details со списком найденных процессов.
    Для определения итогового CheckSuccess использует универсальную функцию
    Test-SuccessCriteria, сравнивающую $Details с переданным $SuccessCriteria.
    Ожидаемый формат SuccessCriteria для проверки наличия/количества:
    @{ processes = @{ _condition_ = 'any'; _where_ = @{ name = 'notepad.exe'}; _count_ = @{ '>=' = 1 } } }
    (Пример: хотя бы 1 процесс notepad.exe должен быть найден).
.PARAMETER TargetIP
    [string] Обязательный. IP или имя хоста. Используется для логирования,
             скрипт выполняется локально.
.PARAMETER Parameters
    [hashtable] Необязательный. Параметры настройки вывода:
    - process_names ([string[]]): Фильтр имен процессов (с wildcard *?).
    - include_username ([bool]): Включать имя пользователя (default: $false).
    - include_path ([bool]): Включать путь к файлу (default: $false).
    - sort_by ([string]): Поле для сортировки ('Name', 'Id', 'CPU', 'Memory', 'StartTime', default: 'Name').
    - sort_descending ([bool]): Сортировать по убыванию (default: $false).
    - top_n ([int]): Отобразить только N верхних процессов.
.PARAMETER SuccessCriteria
    [hashtable] Необязательный. Критерии успеха для сравнения с массивом 'processes' в $Details.
                Пример: @{ processes = @{ _condition_='none'; _where_=@{name='malware.exe'} } }
                (Процесс malware.exe не должен быть найден).
                Обрабатывается функцией Test-SuccessCriteria.
.PARAMETER NodeName
    [string] Необязательный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
                Поле Details (hashtable) содержит:
                - processes (List<object>): Массив объектов [PSCustomObject] с данными процессов
                  (id, name, cpu_seconds, memory_ws_mb, username, path, start_time).
                - message (string): Опциональное сообщение (напр., если процессы не найдены).
                - error (string): Опциональное сообщение об ошибке выполнения.
                - ErrorRecord (string): Опционально, полный текст исключения.
.NOTES
    Версия: 2.0.1 (Добавлены комментарии, форматирование, корректная обработка ошибок Get-CimInstance).
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria.
    Получение Username и Path может требовать повышенных прав.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIP,

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
$details = @{
    processes = [System.Collections.Generic.List[object]]::new() # Инициализируем пустой список
}

Write-Verbose "[$NodeName] Check-PROCESS_LIST (v2.0.1): Начало получения списка процессов для $TargetIP (локально на $env:COMPUTERNAME)"

# --- Основной блок Try/Catch ---
try {
    # --- 1. Обработка входных параметров ($Parameters) ---
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Обработка параметров..."
    # Фильтр по именам
    $processNamesFilter = $null
    $filteringByName = $false
    if ($Parameters.ContainsKey('process_names') -and $Parameters.process_names -is [array] -and $Parameters.process_names.Count -gt 0) {
        $processNamesFilter = $Parameters.process_names
        $filteringByName = $true
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: Фильтр по именам: $($processNamesFilter -join ', ')"
    } else { Write-Verbose "[$NodeName] Check-PROCESS_LIST: Получение всех процессов." }
    # Включение Username/Path
    $includeUsername = ($Parameters.ContainsKey('include_username') -and ([bool]$Parameters.include_username))
    $includePath = ($Parameters.ContainsKey('include_path') -and ([bool]$Parameters.include_path))
    if ($includeUsername) { Write-Verbose "[$NodeName] Check-PROCESS_LIST: Включая Username." }
    if ($includePath) { Write-Verbose "[$NodeName] Check-PROCESS_LIST: Включая Path." }
    # Сортировка
    $sortByInput = if ($Parameters.ContainsKey('sort_by') -and -not [string]::IsNullOrWhiteSpace($Parameters.sort_by)) { $Parameters.sort_by } else { 'Name' }
    $validSortFields = @('id', 'name', 'cpu_seconds', 'memory_ws_mb', 'start_time')
    $sortByActual = switch ($sortByInput.ToLower()) { 'memory' {$s='memory_ws_mb'}; 'mem' {$s='memory_ws_mb'}; 'ws' {$s='memory_ws_mb'}; 'cpu' {$s='cpu_seconds'}; default {if($sortByInput -in $validSortFields){$sortByInput}else{'name'}}}; if($sortByActual -notin $validSortFields){$sortByActual = 'name'}
    $sortDesc = ($Parameters.ContainsKey('sort_descending') -and ([bool]$Parameters.sort_descending))
    $sortDirectionText = if ($sortDesc) { 'Desc' } else { 'Asc' }; Write-Verbose "[$NodeName] Check-PROCESS_LIST: Сортировка по '$sortByActual' ($sortDirectionText)"
    # Top N
    $topN = $null
    if ($Parameters.ContainsKey('top_n') -and $Parameters.top_n -ne $null) {
        $parsedTopN = 0
        if ([int]::TryParse($Parameters.top_n, [ref]$parsedTopN) -and $parsedTopN -gt 0) {
            $topN = $parsedTopN; Write-Verbose "[$NodeName] Check-PROCESS_LIST: Выбор топ $topN процессов."
        } else { Write-Warning "[$NodeName] Check-PROCESS_LIST: Некорректное 'top_n', лимит не применяется." }
    }

    # --- 2. Выполнение Get-Process ---
    $getProcessParams = @{ ErrorAction = 'Stop' } # По умолчанию - падаем при любой ошибке Get-Process
    if ($filteringByName) {
        $getProcessParams.Name = $processNamesFilter
        $getProcessParams.ErrorAction = 'SilentlyContinue' # Подавляем ТОЛЬКО ошибку "не найдено"
    }
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Вызов Get-Process @($getProcessParams | Out-String -Width 200)..."
    $processesRaw = Get-Process @getProcessParams
    # Проверяем, была ли ошибка "не найдено" (которая была подавлена)
    $processNotFoundError = $null
    if ($filteringByName -and $Error.Count -gt 0 -and $Error[0].CategoryInfo.Reason -eq 'ProcessNotFoundException') {
        $processNotFoundError = $Error[0].Exception.Message
        $Error.Clear() # Очищаем ошибку "не найдено"
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: Процесс(ы) по фильтру не найдены ($processNotFoundError)"
    }
    # Если Get-Process не выбросил исключение (или ошибка была "не найдено"), считаем проверку доступной
    $isAvailable = $true
    $processCount = if ($processesRaw) { @($processesRaw).Count } else { 0 }
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Get-Process выполнен. Найдено процессов: $processCount"

    # --- 3. Обработка и форматирование результата для $Details ---
    if ($processCount -gt 0) {
        # Преобразуем объекты процессов в стандартизированный формат для $Details
        $processedList = foreach ($proc in $processesRaw) {
            $procInfo = [ordered]@{
                id           = $proc.Id
                name         = $proc.ProcessName
                cpu_seconds  = $null; memory_ws_mb = $null; username = $null; path = $null; start_time = $null
            }
            # Безопасное получение дополнительных полей
            try { $procInfo.cpu_seconds = [math]::Round($proc.CPU, 2) } catch { }
            try { $procInfo.memory_ws_mb = [math]::Round($proc.WS / 1MB, 1) } catch { }
            try { $procInfo.start_time = $proc.StartTime.ToUniversalTime().ToString("o") } catch { }
            # Username через WMI/CIM
            if ($includeUsername) {
                try {
                    # Используем CIM, ErrorAction SilentlyContinue на случай ошибок доступа к конкретному процессу
                    $ownerInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($proc.Id)" | Select-Object -ExpandProperty Owner -ErrorAction SilentlyContinue
                    $procInfo.username = if ($ownerInfo -and $ownerInfo.User) { if ($ownerInfo.Domain) { "$($ownerInfo.Domain)\$($ownerInfo.User)" } else { $ownerInfo.User } } else { '[N/A]' }
                } catch { $procInfo.username = '[Access Error]' }
            }
            # Path
            if ($includePath) {
                try {
                    # Пытаемся получить Path, потом MainModule.FileName
                    $procPath = $proc.Path
                    if (-not $procPath -and $proc.MainModule) { try { $procPath = $proc.MainModule.FileName } catch {} }
                    $procInfo.path = $procPath
                } catch { $procInfo.path = '[Access Error]' }
            }
            [PSCustomObject]$procInfo # Возвращаем стандартизированный объект
        } # Конец foreach

        # Сортировка
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: Сортировка по '$sortByActual' ($sortDirectionText)"
        try { $processedList = $processedList | Sort-Object -Property $sortByActual -Descending:$sortDesc }
        catch { Write-Warning "[$NodeName] Check-PROCESS_LIST: Ошибка сортировки по '$sortByActual'. Используется сортировка по 'name'." ; try { $processedList = $processedList | Sort-Object -Property 'name' } catch {} }

        # Top N
        if ($topN -gt 0) {
            Write-Verbose "[$NodeName] Check-PROCESS_LIST: Выбор топ $topN процессов."
            $processedList = $processedList | Select-Object -First $topN
        }

        # Запись результата в $Details
        $details.processes.AddRange($processedList)
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: Добавлено в $Details.processes: $($details.processes.Count) записей."

    } elseif ($filteringByName) {
        # Если фильтровали по имени и НИЧЕГО не найдено
        $details.message = "Процессы, соответствующие фильтру '$($processNamesFilter -join ', ')', не найдены."
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: $($details.message)"
        # В этом случае CheckSuccess будет $true, если нет критериев, требующих наличия
    } else {
        # Если не фильтровали, но список пуст (очень маловероятно)
         $details.message = "Список процессов пуст."
         Write-Verbose "[$NodeName] Check-PROCESS_LIST: $($details.message)"
    }

    # --- 4. Вызов универсальной функции проверки критериев ---
    $failReason = $null

    if ($isAvailable) { # Проверяем критерии только если Get-Process выполнился
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-PROCESS_LIST: Вызов Test-SuccessCriteria..."
            # Передаем $Details (который содержит массив 'processes') и $SuccessCriteria
            # Функция Test-SuccessCriteria должна будет уметь обрабатывать критерии для массивов
            # (например, _condition_, _where_, _count_)
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason

            if ($checkSuccess -eq $null) {
                $errorMessage = "Ошибка при обработке SuccessCriteria: $failReason"
                Write-Warning "[$NodeName] $errorMessage"
            } elseif ($checkSuccess -eq $false) {
                $errorMessage = $failReason
                Write-Verbose "[$NodeName] Check-PROCESS_LIST: SuccessCriteria НЕ пройдены: $failReason"
            } else {
                $errorMessage = $null
                Write-Verbose "[$NodeName] Check-PROCESS_LIST: SuccessCriteria пройдены."
            }
        } else {
            # Критерии не заданы
            $checkSuccess = $true
            $errorMessage = $null
            Write-Verbose "[$NodeName] Check-PROCESS_LIST: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        # Если IsAvailable = $false
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) {
            $errorMessage = "Ошибка выполнения проверки списка процессов (IsAvailable=false)."
        }
    }

    # --- 5. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

# <<< Закрываем основной try >>>
} catch {
    # --- Обработка КРИТИЧЕСКИХ ОШИБОК ---
    # Например, ошибка Get-Process (если ErrorAction=Stop) или другая ошибка PowerShell
    $isAvailable = $false
    $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $critErrorMessage = "Критическая ошибка при получении списка процессов: {0}" -f $exceptionMessage

    # Формируем Details с ошибкой
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString() }

    # Создаем финальный результат ВРУЧНУЮ
    $finalResult = @{
        IsAvailable  = $isAvailable
        CheckSuccess = $checkSuccess
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        Details      = $detailsError
        ErrorMessage = $critErrorMessage
    }
    Write-Error "[$NodeName] Check-PROCESS_LIST: Критическая ошибка: $critErrorMessage"
} # <<< Закрываем основной catch >>>

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-PROCESS_LIST (v2.0.1): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult