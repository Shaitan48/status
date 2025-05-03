<#
.SYNOPSIS
    Получает список запущенных процессов.
.DESCRIPTION
    Использует Get-Process для получения информации о процессах локально.
    Поддерживает фильтрацию по имени, сортировку, выбор N верхних,
    а также опциональное включение имени пользователя и пути к файлу.
.PARAMETER TargetIP
    [string] IP или имя хоста (игнорируется, используется для логирования).
.PARAMETER Parameters
    [hashtable] Необязательный. Параметры для Get-Process и форматирования:
    - process_names ([string[]]): Массив имен процессов для фильтрации (wildcards *?).
    - include_username ([bool]): Включать ли имя пользователя ($false).
    - include_path ([bool]):     Включать ли путь к файлу ($false).
    - sort_by ([string]):        Поле для сортировки ('Name', 'Id', 'CPU', 'Memory'/'WS', 'StartTime'). По умолч. 'Name'.
    - sort_descending ([bool]):  Сортировать по убыванию? ($false).
    - top_n ([int]):             Показать только топ N процессов.
.PARAMETER SuccessCriteria
    [hashtable] Необязательный. Критерии успеха (ПОКА НЕ РЕАЛИЗОВАНЫ).
.PARAMETER NodeName
    [string] Необязательный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
                Details содержит массив 'processes'.
.NOTES
    Версия: 1.2 (Добавлен параметр SuccessCriteria, но без реализации логики).
    Зависит от функции New-CheckResultObject.
    Получение Username/Path может требовать повышенных прав.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP,

    [Parameter(Mandatory=$false)]
    [hashtable]$Parameters = @{},

    [Parameter(Mandatory=$false)] # <<<< ДОБАВЛЕН ПАРАМЕТР
    [hashtable]$SuccessCriteria = $null,

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
        Write-Error "Check-PROCESS_LIST: Критическая ошибка: Не удалось загрузить New-CheckResultObject! $($_.Exception.Message)"
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}

# --- Инициализация результата ---
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{ processes = [System.Collections.Generic.List[object]]::new() }
    ErrorMessage = $null
}

Write-Verbose "[$NodeName] Check-PROCESS_LIST: Начало получения списка процессов с $TargetIP (локально)"

try {
    # 1. Параметры для Get-Process
    $getProcessParams = @{}
    $filteringByName = $false
    if ($Parameters.ContainsKey('process_names') -and $Parameters.process_names -is [array] -and $Parameters.process_names.Count -gt 0) {
        $getProcessParams.Name = $Parameters.process_names
        $getProcessParams.ErrorAction = 'SilentlyContinue' # Не падать, если процесс не найден
        $filteringByName = $true
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: Фильтр по именам: $($Parameters.process_names -join ', ')"
    } else {
        $getProcessParams.ErrorAction = 'Stop' # Падать при общих ошибках
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: Получение всех процессов."
    }

    $includeUsername = [bool]($Parameters.include_username | Get-OrElse $false)
    $includePath = [bool]($Parameters.include_path | Get-OrElse $false)
    if($includeUsername) { Write-Verbose "[$NodeName] Check-PROCESS_LIST: Включая Username." }
    if($includePath) { Write-Verbose "[$NodeName] Check-PROCESS_LIST: Включая Path." }

    # 2. Выполнение Get-Process
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Вызов Get-Process..."
    $processesRaw = Get-Process @getProcessParams
    $resultData.IsAvailable = $true # Если Get-Process не упал, значит проверка доступна
    $processCount = if($processesRaw) { @($processesRaw).Count } else { 0 } # Считаем количество
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Get-Process выполнен. Найдено процессов: $processCount"

    # Обработка случая, когда фильтровали, но ничего не нашли
    if ($filteringByName -and $processCount -eq 0) {
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: Процессы с именами '$($Parameters.process_names -join ', ')' не найдены."
        $resultData.CheckSuccess = $true # Считаем успехом, т.к. запрос выполнился, просто результат пуст
        $resultData.Details.message = "Процессы с указанными именами не найдены."
    }
    # Обработка, если процессы найдены
    elseif ($processCount -gt 0) {
        # 3. Формирование списка результатов
        $processedList = foreach ($proc in $processesRaw) {
            $procInfo = @{
                id = $proc.Id
                name = $proc.ProcessName
                cpu_seconds = $null
                memory_ws_mb = $null
                username = $null
                path = $null
                start_time = $null
            }
            try { $procInfo.cpu_seconds = [math]::Round($proc.CPU, 2) } catch {}
            try { $procInfo.memory_ws_mb = [math]::Round($proc.WS / 1MB, 1) } catch {}
            try { $procInfo.start_time = $proc.StartTime.ToUniversalTime().ToString("o") } catch {}

            if ($includeUsername) {
                try {
                    $ownerInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($proc.Id)" | Select-Object -ExpandProperty Owner -ErrorAction SilentlyContinue
                    $procInfo.username = if ($ownerInfo -and $ownerInfo.User) { if ($ownerInfo.Domain) { "$($ownerInfo.Domain)\$($ownerInfo.User)" } else { $ownerInfo.User } } else { '[N/A]' }
                } catch { $procInfo.username = '[Access Error]' }
            }
            if ($includePath) {
                try {
                    $procPath = $proc.Path
                    if (-not $procPath -and $proc.MainModule) { $procPath = $proc.MainModule.FileName }
                    $procInfo.path = $procPath
                } catch { $procInfo.path = '[Access Error]' }
            }
            [PSCustomObject]$procInfo
        } # Конец foreach

        # 4. Сортировка
        $sortByInput = $Parameters.sort_by | Get-OrElse 'Name'
        $sortDesc = [bool]($Parameters.sort_descending | Get-OrElse $false)
        $validSortFields = @('id', 'name', 'cpu_seconds', 'memory_ws_mb', 'start_time')
        $sortByActual = switch ($sortByInput.ToLower()) {
            {$_ -in @('memory', 'mem', 'ws')} { 'memory_ws_mb' }
            {$_ -in @('processor', 'proc', 'cpu')} { 'cpu_seconds' }
            default { if($sortByInput -in $validSortFields) {$sortByInput} else {'name'} }
        }
        if($sortByActual -notin $validSortFields) {$sortByActual = 'name'}
        $sortDirectionText = if ($sortDesc) { 'Desc' } else { 'Asc' }
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: Сортировка по '$sortByActual' ($sortDirectionText)"
        try { $processedList = $processedList | Sort-Object -Property $sortByActual -Descending:$sortDesc }
        catch { Write-Warning "[$NodeName] Check-PROCESS_LIST: Ошибка сортировки по '$sortByActual'. Используется сортировка по Name." ; try { $processedList = $processedList | Sort-Object -Property 'name' } catch {} }

        # 5. Top N
        $topN = $null; if ($Parameters.ContainsKey('top_n') -and $Parameters.top_n -is [int]) { $topN = $Parameters.top_n }
        if ($topN -gt 0) {
            Write-Verbose "[$NodeName] Check-PROCESS_LIST: Выбор топ $topN процессов."
            $processedList = $processedList | Select-Object -First $topN
        }

        # 6. Запись результата в Details
        $resultData.Details.processes.AddRange($processedList)
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: Добавлено в результат: $($resultData.Details.processes.Count) процессов."

        # 7. Установка CheckSuccess (ПОКА НЕТ КРИТЕРИЕВ)
        $resultData.CheckSuccess = $true # Успешно, если смогли получить список
    }
    # Обработка случая, когда процессы не найдены И НЕ фильтровали по имени
    elseif (-not $filteringByName -and $processCount -eq 0) {
         Write-Verbose "[$NodeName] Check-PROCESS_LIST: Get-Process не вернул процессов (без фильтра по имени)."
         $resultData.CheckSuccess = $true # Считаем успехом, т.к. команда выполнилась
         $resultData.Details.message = "Список процессов пуст."
    }


} catch {
    # Перехват ошибок Get-Process (если ErrorAction=Stop) или других
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "Ошибка получения списка процессов: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    Write-Error "[$NodeName] Check-PROCESS_LIST: Критическая ошибка: $errorMessage"
}

# --- Финальная обработка результата ---
# Если была ошибка IsAvailable = false, то CheckSuccess должен быть null
if ($resultData.IsAvailable -eq $false) {
    $resultData.CheckSuccess = $null
}
# Если IsAvailable = true, но CheckSuccess еще не установлен (не было найдено процессов), ставим true
elseif ($resultData.CheckSuccess -eq $null) {
     $resultData.CheckSuccess = $true
}

# Обработка SuccessCriteria (ПОКА НЕТ РЕАЛИЗАЦИИ)
if ($resultData.IsAvailable -and $resultData.CheckSuccess -and $SuccessCriteria -ne $null) {
     Write-Verbose "[$NodeName] Check-PROCESS_LIST: SuccessCriteria переданы, но их обработка пока не реализована."
     # Здесь можно будет добавить логику, например:
     # if ($SuccessCriteria.ContainsKey('required_process') -and -not $resultData.Details.processes.name.Contains($SuccessCriteria.required_process)) {
     #     $resultData.CheckSuccess = $false
     #     $resultData.ErrorMessage = "Обязательный процесс '$($SuccessCriteria.required_process)' не найден."
     # }
}

# Вызов New-CheckResultObject для финальной стандартизации
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-PROCESS_LIST: Завершение. IsAvailable=$($finalResult.IsAvailable), CheckSuccess=$($finalResult.CheckSuccess)"
return $finalResult