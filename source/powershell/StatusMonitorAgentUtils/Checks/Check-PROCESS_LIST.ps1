# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-PROCESS_LIST.ps1
# --- Версия 2.0.2 --- Интеграция Test-SuccessCriteria
<#
.SYNOPSIS
    Получает список запущенных процессов. (v2.0.2)
.DESCRIPTION
    Использует Get-Process. Позволяет фильтровать/сортировать.
    Формирует $Details с массивом 'processes'.
    Вызывает Test-SuccessCriteria для определения CheckSuccess.
.PARAMETER TargetIP
    [string] Обязательный. IP или имя хоста (для логирования).
.PARAMETER Parameters
    [hashtable] Опциональный. Параметры: process_names, include_username,
                include_path, sort_by, sort_descending, top_n.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха для массива 'processes' в $Details
                (напр., @{ processes = @{ _condition_='none'; _where_=@{name='malware*'} } }).
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
.NOTES
    Версия: 2.0.2 (Интеграция Test-SuccessCriteria).
    Зависит от New-CheckResultObject, Test-SuccessCriteria.
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

# --- Инициализация ---
$isAvailable = $false; $checkSuccess = $null; $errorMessage = $null; $finalResult = $null
$details = @{ processes = [System.Collections.Generic.List[object]]::new() }

Write-Verbose "[$NodeName] Check-PROCESS_LIST (v2.0.2): Начало получения списка процессов на $TargetIP (локально)"

# --- Основной Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>

    # --- 1. Обработка параметров ---
    $processNamesFilter = $null; $filteringByName = $false
    if ($Parameters.ContainsKey('process_names') -and $Parameters.process_names -is [array] -and $Parameters.process_names.Count -gt 0) { $processNamesFilter = $Parameters.process_names; $filteringByName = $true }
    $includeUsername = ($Parameters.ContainsKey('include_username') -and ([bool]$Parameters.include_username))
    $includePath = ($Parameters.ContainsKey('include_path') -and ([bool]$Parameters.include_path))
    $sortByInput = $Parameters.sort_by | Get-OrElse 'Name'
    $validSortFields = @('id', 'name', 'cpu_seconds', 'memory_ws_mb', 'start_time'); $sortByActual = switch ($sortByInput.ToLower()) { 'memory'|'mem'|'ws' {$s='memory_ws_mb'}; 'cpu' {$s='cpu_seconds'}; default {if($sortByInput -in $validSortFields){$sortByInput}else{'name'}}}; if($sortByActual -notin $validSortFields){$sortByActual = 'name'}
    $sortDesc = ($Parameters.ContainsKey('sort_descending') -and ([bool]$Parameters.sort_descending))
    $topN = $null; if ($Parameters.ContainsKey('top_n') -and $Parameters.top_n -ne $null) { $parsedTopN = 0; if ([int]::TryParse($Parameters.top_n, [ref]$parsedTopN) -and $parsedTopN -gt 0) { $topN = $parsedTopN } }

    # --- 2. Выполнение Get-Process ---
    $getProcessParams = @{ ErrorAction = 'Stop' }; if ($filteringByName) { $getProcessParams.Name = $processNamesFilter; $getProcessParams.ErrorAction = 'SilentlyContinue' }
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Вызов Get-Process..."
    $processesRaw = Get-Process @getProcessParams
    $processNotFoundError = $null; if ($filteringByName -and $Error.Count -gt 0 -and $Error[0].CategoryInfo.Reason -eq 'ProcessNotFoundException') { $processNotFoundError = $Error[0].Exception.Message; $Error.Clear() }
    $isAvailable = $true # Успех, если не было необработанного исключения
    $processCount = if ($processesRaw) { @($processesRaw).Count } else { 0 }
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Get-Process выполнен. Найдено: $processCount."

    # --- 3. Обработка результата и формирование $details.processes ---
    if ($processCount -gt 0) {
        $processedList = foreach ($proc in $processesRaw) {
             $procInfo = [ordered]@{ id=$proc.Id; name=$proc.ProcessName; cpu_seconds=$null; memory_ws_mb=$null; username=$null; path=$null; start_time=$null }
             try { $procInfo.cpu_seconds = [math]::Round($proc.CPU, 2) } catch { }
             try { $procInfo.memory_ws_mb = [math]::Round($proc.WS / 1MB, 1) } catch { }
             try { $procInfo.start_time = $proc.StartTime.ToUniversalTime().ToString("o") } catch { }
             if ($includeUsername) { try { $ownerInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($proc.Id)" | Select-Object -ExpandProperty Owner -EA SilentlyContinue; $procInfo.username = if ($ownerInfo?.User) { "$($ownerInfo.Domain)\$($ownerInfo.User)" } else { '[N/A]' } } catch { $procInfo.username = '[Access Error]' } }
             if ($includePath) { try { $procPath = $proc.Path; if (-not $procPath -and $proc.MainModule) { try { $procPath = $proc.MainModule.FileName } catch {} }; $procInfo.path = $procPath } catch { $procInfo.path = '[Access Error]' } }
             [PSCustomObject]$procInfo
        }
        try { $processedList = $processedList | Sort-Object -Property $sortByActual -Descending:$sortDesc } catch { Write-Warning "... Ошибка сортировки ..."; $processedList = $processedList | Sort-Object 'name' }
        if ($topN -gt 0) { $processedList = $processedList | Select-Object -First $topN }
        $details.processes.AddRange($processedList)
    } elseif ($filteringByName) { $details.message = "Процессы по фильтру '$($processNamesFilter -join ', ')' не найдены." }
    else { $details.message = "Список процессов пуст." }

    # --- 4. Проверка критериев успеха ---
    $failReason = $null
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.PSObject.Properties.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-PROCESS_LIST: Вызов Test-SuccessCriteria..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason
            if ($checkSuccess -ne $true) { $errorMessage = $failReason | Get-OrElse "Критерии успеха для процессов не пройдены."; Write-Verbose "[$NodeName] ... SuccessCriteria НЕ пройдены/ошибка: $errorMessage" }
            else { $errorMessage = $null; Write-Verbose "[$NodeName] ... SuccessCriteria пройдены." }
        } else {
            $checkSuccess = $true; $errorMessage = $null
            Write-Verbose "[$NodeName] Check-PROCESS_LIST: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = "Ошибка получения списка процессов (IsAvailable=false)." }
    }

    # --- 5. Формирование результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch { # <<< ОСНОВНОЙ CATCH >>>
    $isAvailable = $false; $checkSuccess = $null
    $critErrorMessage = "Критическая ошибка Check-PROCESS_LIST: $($_.Exception.Message)"
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString() }
    $finalResult = @{ IsAvailable=$isAvailable; CheckSuccess=$checkSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$detailsError; ErrorMessage=$critErrorMessage }
    Write-Error "[$NodeName] Check-PROCESS_LIST: Критическая ошибка: $critErrorMessage"
} # <<< КОНЕЦ ОСНОВНОГО CATCH >>>

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-PROCESS_LIST (v2.0.2): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult