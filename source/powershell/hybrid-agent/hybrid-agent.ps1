# powershell/hybrid-agent/hybrid-agent.ps1
# --- Гибридный Агент Мониторинга Status Monitor (Pipeline-архитектура) ---
# --- Версия 7.1.0 ---
# Изменения:
# - Полная адаптация под выполнение pipeline-заданий.
# - В Online режиме: для каждого задания выполняется pipeline, собираются результаты всех шагов,
#   формируется один агрегированный результат для задания и отправляется в API.
#   Поле 'detail_data' агрегированного результата содержит массив результатов шагов.
# - В Offline режиме: аналогично, результаты выполнения pipeline-заданий (с детализацией по шагам)
#   сохраняются в .zrpu файл.
# - Улучшено логирование для отражения выполнения pipeline и его шагов.
# - Обновлена версия агента.
# - Инициализация $checkExecutionResult перед циклом шагов.

<#
.SYNOPSIS
    Гибридный агент системы мониторинга Status Monitor v7.1.0 (Pipeline-архитектура).
    Выполняет pipeline-задания в Online или Offline режиме.
.DESCRIPTION
    Online режим:
    - Запрашивает pipeline-задания у API сервера.
    - Для каждого задания выполняет последовательность шагов из его 'pipeline'.
    - Собирает результаты всех шагов и формирует агрегированный результат задания.
    - Отправляет агрегированный результат в API.
    Offline режим:
    - Читает pipeline-задания из локального файла конфигурации.
    - Выполняет шаги для каждого задания.
    - Собирает агрегированные результаты всех заданий.
    - Сохраняет их в .zrpu файл для последующей загрузки.
.NOTES
    Версия: 7.1.0
    Дата: [Актуальная Дата]
    Зависит от модуля StatusMonitorAgentUtils (v2.1.3+).
#>
param (
    [string]$ConfigFile = "$PSScriptRoot\config.json"
)

# --- 1. Загрузка общего модуля утилит StatusMonitorAgentUtils ---
# (Код загрузки модуля без изменений от предыдущей версии v7.0.5)
$ErrorActionPreference = "Stop"
try {
    $ModuleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1"
    Write-Host "[INFO] Загрузка модуля '$ModuleManifestPath'..." -ForegroundColor Green
    Import-Module $ModuleManifestPath -Force -ErrorAction Stop
    Write-Host "[INFO] Модуль StatusMonitorAgentUtils успешно загружен." -ForegroundColor Green
} catch {
    Write-Host "[CRITICAL] Критическая ошибка загрузки модуля '$ModuleManifestPath': $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[CRITICAL] Агент не может работать без модуля Utils. Завершение." -ForegroundColor Red
    if ($Host.Name -eq "ConsoleHost") { Read-Host "Нажмите Enter для выхода" }
    exit 1
} finally {
    $ErrorActionPreference = "Continue"
}

# --- 2. Глобальные переменные ---
# (Инициализация общих переменных, версия агента обновлена)
$script:ComputerName = $env:COMPUTERNAME
$script:Config = $null
$script:EffectiveLogLevel = "Info"
$script:LogFilePath = $null
$script:AgentVersion = "hybrid_agent_v7.1.0" # <<< ОБНОВЛЕНА ВЕРСИЯ АГЕНТА

# Переменные для Online режима
$script:ActiveAssignmentsOnline = @{} # Хранит { assignment_id = $AssignmentObject (с pipeline) }
$script:LastExecutedTimesOnline = @{} # Хранит { assignment_id = [DateTimeOffset] }
$script:LastApiPollTimeOnline = [DateTimeOffset]::MinValue

# Переменные для Offline режима
$script:CurrentFullConfigOffline = $null # Хранит весь объект из файла (включая assignments и метаданные)
$script:LastProcessedConfigFileFullNameOffline = $null
$script:LastConfigFileWriteTimeOffline = [DateTime]::MinValue

# --- 3. Вспомогательные функции ---
# (Write-Log, Invoke-ApiRequestWithRetry - без изменений от v7.0.5)
#region Функции
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
        [string]$Level = "Info"
    )
    $logLevelsNumeric = @{ "Debug" = 4; "Verbose" = 3; "Info" = 2; "Warn" = 1; "Error" = 0 }
    $currentLogLevelSetting = $script:EffectiveLogLevel
    if (-not $logLevelsNumeric.ContainsKey($currentLogLevelSetting)) { $currentLogLevelSetting = "Info" }
    $effectiveNumericLevel = $logLevelsNumeric[$currentLogLevelSetting]
    $messageNumericLevel = $logLevelsNumeric[$Level]
    if ($null -eq $messageNumericLevel) { $messageNumericLevel = $logLevelsNumeric["Info"] }

    if ($messageNumericLevel -le $effectiveNumericLevel) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logLine = "[$timestamp] [$Level] [$script:ComputerName] ($script:AgentVersion) - $Message" # Добавлена версия агента
        $consoleColor = "Gray"; switch ($Level.ToLower()) { "error" { $consoleColor = "Red" }; "warn" { $consoleColor = "Yellow" }; "info" { $consoleColor = "White" }; "verbose" { $consoleColor = "Cyan" }; "debug" { $consoleColor = "DarkGray" } }
        Write-Host $logLine -ForegroundColor $consoleColor
        if (-not [string]::IsNullOrWhiteSpace($script:LogFilePath)) {
            try {
                $logDirectory = Split-Path -Path $script:LogFilePath -Parent
                if ($logDirectory -and (-not (Test-Path -Path $logDirectory -PathType Container))) {
                    Write-Host "[INFO] Write-Log: Создание папки для лог-файла: '$logDirectory'"
                    New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                Add-Content -Path $script:LogFilePath -Value $logLine -Encoding UTF8 -Force -ErrorAction Stop
            } catch {
                Write-Host ("[CRITICAL] Write-Log: Ошибка записи в основной лог-файл '{0}': {1}" -f $script:LogFilePath, $_.Exception.Message) -ForegroundColor Red
                try {
                    $fallbackLogPath = Join-Path -Path $PSScriptRoot -ChildPath "hybrid_agent_fallback.log"
                    Add-Content -Path $fallbackLogPath -Value $logLine -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                    Add-Content -Path $fallbackLogPath -Value "[CRITICAL] FAILED TO WRITE TO '$($script:LogFilePath)': $($_.Exception.Message)" -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                } catch {}
            }
        }
    }
}

function Invoke-ApiRequestWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$false)]$BodyObject = $null,
        [Parameter(Mandatory=$true)][hashtable]$Headers,
        [Parameter(Mandatory=$true)][string]$Description
    )
    $currentTry = 0; $apiResponseObject = $null
    $maxRetriesForRequest = if ($script:Config -and $script:Config.PSObject.Properties.Name -contains 'max_api_retries') { [int]$script:Config.max_api_retries } else { 3 }
    $timeoutForRequestSec = if ($script:Config -and $script:Config.PSObject.Properties.Name -contains 'api_timeout_sec') { [int]$script:Config.api_timeout_sec } else { 60 }
    $delayBetweenRetriesSec = if ($script:Config -and $script:Config.PSObject.Properties.Name -contains 'retry_delay_seconds') { [int]$script:Config.retry_delay_seconds } else { 5 }
    $invokeRestParams = @{ Uri = $Uri; Method = $Method.ToUpper(); Headers = $Headers; TimeoutSec = $timeoutForRequestSec; ErrorAction = 'Stop' }
    if ($null -ne $BodyObject -and $invokeRestParams.Method -notin @('GET', 'DELETE', 'HEAD', 'OPTIONS')) {
        try {
            $jsonRequestBody = $BodyObject | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
            $invokeRestParams.ContentType = 'application/json; charset=utf-8'
            $invokeRestParams.Body = [System.Text.Encoding]::UTF8.GetBytes($jsonRequestBody)
            Write-Log "Тело запроса для ($Description) (длина: $($invokeRestParams.Body.Length) байт): $jsonRequestBody" -Level Debug
        } catch { Write-Log "Критическая ошибка ConvertTo-Json для ($Description): $($_.Exception.Message)" -Level Error; throw "Ошибка преобразования тела запроса в JSON для операции '$Description'." }
    }
    while ($currentTry -lt $maxRetriesForRequest) {
        $currentTry++
        try {
            Write-Log ("Выполнение API запроса ($Description) (Попытка $currentTry/$maxRetriesForRequest): $($invokeRestParams.Method) $Uri") -Level Verbose
            $apiResponseObject = Invoke-RestMethod @invokeRestParams
            Write-Log ("Успешный ответ от API для ($Description).") -Level Verbose
            return $apiResponseObject
        } catch [System.Net.WebException] {
            $exceptionDetails = $_.Exception; $httpStatusCode = $null; $errorResponseBodyText = "[Не удалось прочитать тело ответа на ошибку]"
            if ($exceptionDetails.Response -ne $null) {
                try { $httpStatusCode = [int]$exceptionDetails.Response.StatusCode } catch {}
                try {
                    $errorResponseStream = $exceptionDetails.Response.GetResponseStream(); $streamReader = New-Object System.IO.StreamReader($errorResponseStream); $errorResponseBodyText = $streamReader.ReadToEnd(); $streamReader.Close(); $errorResponseStream.Dispose()
                    try { $errorJsonObj = $errorResponseBodyText | ConvertFrom-Json; $errorResponseBodyText = ($errorJsonObj | ConvertTo-Json -Depth 3 -Compress) } catch {}
                } catch {}
            }
            $webExceptionMessage = $exceptionDetails.Message.Replace('{','{{').Replace('}','}}')
            $httpStatusCodeForLog = if ($null -eq $httpStatusCode) { 'N/A' } else { $httpStatusCode.ToString() }
            Write-Log ("Ошибка API ($Description) (Попытка $currentTry/$maxRetriesForRequest). HTTP Код: $httpStatusCodeForLog. Сообщение: $webExceptionMessage. Ответ сервера (если есть): $errorResponseBodyText") -Level Error
            if ($httpStatusCode -ge 400 -and $httpStatusCode -lt 500 -and $httpStatusCode -ne 429) { Write-Log ("Критическая ошибка API ($Description - Код $httpStatusCode), повторные попытки отменены.") -Level Error; throw $exceptionDetails }
            if ($currentTry -ge $maxRetriesForRequest) { Write-Log ("Превышено максимальное количество попыток ($maxRetriesForRequest) для ($Description).") -Level Error; throw $exceptionDetails }
            Write-Log ("Пауза $delayBetweenRetriesSec сек перед следующей попыткой...") -Level Warn; Start-Sleep -Seconds $delayBetweenRetriesSec
        } catch {
             $unexpectedErrorMessage = $_.Exception.Message.Replace('{','{{').Replace('}','}}')
             Write-Log ("Неожиданная ошибка при выполнении API запроса ($Description) (Попытка $currentTry/$maxRetriesForRequest): $unexpectedErrorMessage") -Level Error
             throw $_.Exception
        }
    }
    Write-Log ("Не удалось выполнить API запрос ($Description) после $maxRetriesForRequest попыток, результат $null.") -Level Error
    return $null
}
#endregion Функции

# --- 4. Основная логика ---
# (Чтение конфига, валидация общих полей - без изменений от v7.0.5, но версия агента в логах обновлена)
Write-Host "Запуск Гибридного Агента Мониторинга v$($script:AgentVersion)..." -ForegroundColor Yellow
Write-Log "Чтение конфигурации из '$ConfigFile'..." -Level Info
# ... (остальная часть загрузки и валидации общей конфигурации остается без изменений) ...
# Внутри Write-Log будет использоваться обновленный $script:AgentVersion
# Пример:
# Write-Log "Гибридный агент v$($script:AgentVersion) запущен. Имя хоста: $script:ComputerName" -Level Info
# ...

# --- Логика для Online режима ---
if ($agentMode -eq 'online') {
    # (Валидация полей для Online режима - без изменений от v7.0.5)
    # ...
    Write-Log "Агент переходит в Online режим." -Level Info
    # ... (определение $apiPollIntervalSec, $defaultCheckIntervalSec - без изменений) ...
    Write-Log "Запуск основного цикла Online режима (Pipeline-архитектура)..." -Level Info

    while ($true) {
        $loopIterationStartTimeOnline = [DateTimeOffset]::UtcNow
        Write-Log "Начало итерации основного цикла Online режима." -Level Verbose

        # --- Получение заданий (pipeline) от API ---
        if (($loopIterationStartTimeOnline - $script:LastApiPollTimeOnline) -ge $apiPollTimeSpan) {
            Write-Log "Время обновить список pipeline-заданий с API сервера." -Level Info
            $assignmentsApiUrl = "$($script:Config.api_base_url.TrimEnd('/'))/v1/assignments?object_id=$($script:Config.object_id)"
            $apiHeaders = @{ 'X-API-Key' = $script:Config.api_key }
            try {
                # API должен вернуть массив объектов, где каждый объект - это ЗАДАНИЕ,
                # и у каждого задания есть поле 'pipeline' (массив шагов).
                $fetchedRawAssignmentsFromApi = Invoke-ApiRequestWithRetry -Uri $assignmentsApiUrl -Method Get -Headers $apiHeaders -Description "Получение pipeline-заданий (ObjectID $($script:Config.object_id))"
                
                # Валидация и обработка полученных заданий
                if ($null -ne $fetchedRawAssignmentsFromApi -and $fetchedRawAssignmentsFromApi -is [array]) {
                    Write-Log "Получено $($fetchedRawAssignmentsFromApi.Count) объектов заданий от API." -Level Info
                    $newAssignmentMapOnline = @{}
                    $currentAssignmentIdsFromApi = [System.Collections.Generic.List[int]]::new()

                    foreach ($rawAssignmentData in $fetchedRawAssignmentsFromApi) {
                        # Проверяем базовую структуру задания и наличие поля pipeline
                        if ($null -eq $rawAssignmentData -or `
                            -not ($rawAssignmentData.PSObject.Properties.Name -contains 'assignment_id' -and $null -ne $rawAssignmentData.assignment_id) -or `
                            -not ($rawAssignmentData.PSObject.Properties.Name -contains 'pipeline' -and $rawAssignmentData.pipeline -is [array])) {
                            Write-Log "Получено некорректное задание от API (отсутствует assignment_id или pipeline не массив): $($rawAssignmentData | ConvertTo-Json -Depth 2 -Compress)." -Level Warn
                            continue
                        }
                        $parsedAssignmentId = 0
                        if([int]::TryParse($rawAssignmentData.assignment_id.ToString(), [ref]$parsedAssignmentId)) {
                            # Сохраняем все задание (включая pipeline)
                            $newAssignmentMapOnline[$parsedAssignmentId] = [PSCustomObject]$rawAssignmentData 
                            $currentAssignmentIdsFromApi.Add($parsedAssignmentId) | Out-Null
                        } else { Write-Log "Получено задание от API с нечисловым assignment_id: '$($rawAssignmentData.assignment_id)'. Задание пропущено." -Level Warn }
                    }
                    
                    # Синхронизация с $script:ActiveAssignmentsOnline (логика без изменений от v7.0.5)
                    $existingAssignmentIdsInMemory = @($script:ActiveAssignmentsOnline.Keys | ForEach-Object { [int]$_ })
                    $removedAssignmentIds = $existingAssignmentIdsInMemory | Where-Object { $currentAssignmentIdsFromApi -notcontains $_ }
                    $addedCount = 0; $updatedCount = 0; $removedCount = 0
                    if ($removedAssignmentIds.Count -gt 0) { foreach ($idToRemove in $removedAssignmentIds) { Write-Log "Pipeline-задание ID $idToRemove удалено из активного списка." -Level Info; $script:ActiveAssignmentsOnline.Remove($idToRemove); $script:LastExecutedTimesOnline.Remove($idToRemove); $removedCount++ } }
                    foreach ($idFromApi in $currentAssignmentIdsFromApi) { $newAssignmentObject = $newAssignmentMapOnline[$idFromApi]; if (-not $script:ActiveAssignmentsOnline.ContainsKey($idFromApi)) { $script:ActiveAssignmentsOnline[$idFromApi] = $newAssignmentObject; $script:LastExecutedTimesOnline[$idFromApi] = [DateTimeOffset]::UtcNow.AddDays(-1); $addedCount++; Write-Log "Добавлено новое pipeline-задание ID $idFromApi в активный список." -Level Info } else { $oldAssignmentJson = $script:ActiveAssignmentsOnline[$idFromApi] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue; $newAssignmentJson = $newAssignmentObject | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue; if ($oldAssignmentJson -ne $newAssignmentJson) { $script:ActiveAssignmentsOnline[$idFromApi] = $newAssignmentObject; $updatedCount++; Write-Log "Pipeline-задание ID $idFromApi обновлено." -Level Verbose } } }
                    Write-Log ("Синхронизация pipeline-заданий с API завершена. Активно: $($script:ActiveAssignmentsOnline.Count). Добавлено: $addedCount. Обновлено: $updatedCount. Удалено: $removedCount.") -Level Info
                    $script:LastApiPollTimeOnline = $loopIterationStartTimeOnline
                } # (обработка других случаев ответа API - пустой, некорректный - без изменений от v7.0.5)
                # ...
            } catch { Write-Log "Критическая ошибка при получении pipeline-заданий от API: $($_.Exception.Message). Используется текущий список (если есть)." -Level Error }
        } else { Write-Log "Опрос API для обновления pipeline-заданий еще не требуется." -Level Verbose }

        # --- Выполнение запланированных pipeline-заданий ---
        $currentTimeUtcOnline = [DateTimeOffset]::UtcNow
        if ($script:ActiveAssignmentsOnline.Count -gt 0) {
            Write-Log "Проверка запланированных pipeline-заданий (активно: $($script:ActiveAssignmentsOnline.Count))..." -Level Verbose
            $assignmentIdsToProcessThisLoopOnline = @($script:ActiveAssignmentsOnline.Keys)

            foreach ($currentAssignmentIdOnline in $assignmentIdsToProcessThisLoopOnline) {
                # (проверка, что задание еще активно - без изменений от v7.0.5)
                # ...
                $assignmentObjectToExecute = $script:ActiveAssignmentsOnline[$currentAssignmentIdOnline]
                # (определение интервала - без изменений от v7.0.5)
                # ...
                
                if ($currentTimeUtcOnline -ge $nextRunTimeOnline) { # $nextRunTimeOnline рассчитывается как раньше
                    $nodeNameToLogForPipeline = if (-not [string]::IsNullOrWhiteSpace($assignmentObjectToExecute.node_name)) { $assignmentObjectToExecute.node_name } else { "[N/A_Node]" }
                    $methodNameToLogForPipeline = if (-not [string]::IsNullOrWhiteSpace($assignmentObjectToExecute.method_name)) { $assignmentObjectToExecute.method_name } else { "[N/A_Method]" } # method_name на верхнем уровне задания - для общей классификации
                    
                    Write-Log ("НАЧАЛО ВЫПОЛНЕНИЯ pipeline-задания ID $currentAssignmentIdOnline (Класс: '$methodNameToLogForPipeline', Узел: '$nodeNameToLogForPipeline').") -Level Info
                    
                    # --- НЕПОСРЕДСТВЕННО ВЫПОЛНЕНИЕ PIPELINE ---
                    $pipelineSteps = $assignmentObjectToExecute.pipeline # Это должен быть массив шагов
                    $allStepResults = [System.Collections.Generic.List[object]]::new() # Для сбора результатов каждого шага
                    $pipelineOverallSuccess = $true # Изначально считаем, что весь pipeline успешен
                    $pipelineOverallIsAvailable = $true # Изначально считаем, что весь pipeline доступен для выполнения
                    $pipelineErrorMessage = $null # Общее сообщение об ошибке для всего pipeline

                    if (-not ($pipelineSteps -is [array]) -or $pipelineSteps.Count -eq 0) {
                        Write-Log "Pipeline-задание ID $currentAssignmentIdOnline не содержит шагов (поле 'pipeline' пустое или не массив). Задание пропущено." -Level Warn
                        $pipelineOverallIsAvailable = $false # Нечего выполнять
                        $pipelineErrorMessage = "Pipeline не содержит шагов."
                        # Тем не менее, нужно отправить результат с IsAvailable=false, чтобы сервер знал о проблеме
                    } else {
                        Write-Log "Найдено $($pipelineSteps.Count) шагов в pipeline для задания ID $currentAssignmentIdOnline." -Level Verbose
                        $stepCounter = 0
                        foreach ($stepObject in $pipelineSteps) {
                            $stepCounter++
                            $stepTypeForLog = if($stepObject -and $stepObject.PSObject.Properties.Name -contains 'type') {$stepObject.type} else {'[UnknownStepType]'}
                            Write-Log "  Выполнение шага $stepCounter/$($pipelineSteps.Count) (Тип: '$stepTypeForLog') для задания ID $currentAssignmentIdOnline..." -Level Verbose
                            
                            # Формируем объект для Invoke-StatusMonitorCheck (который теперь Invoke-PipelineStep по сути)
                            # Передаем $TargetIP и $NodeName из контекста всего ЗАДАНИЯ,
                            # но скрипт шага (например, Check-PING) может их переопределить из $stepObject.parameters.target
                            $stepContext = [PSCustomObject]@{
                                type            = $stepObject.type # Или method_name, если используется
                                parameters      = if($stepObject.PSObject.Properties.Name -contains 'parameters'){$stepObject.parameters}else{@{}}
                                success_criteria= if($stepObject.PSObject.Properties.Name -contains 'success_criteria'){$stepObject.success_criteria}else{$null}
                                # Добавляем информацию из родительского задания для контекста
                                node_name       = $assignmentObjectToExecute.node_name
                                ip_address      = $assignmentObjectToExecute.ip_address 
                                # Можно добавить и другие поля, если они нужны скриптам шагов
                            }
                            
                            $stepResult = $null # Инициализируем результат шага
                            try {
                                $stepResult = Invoke-StatusMonitorCheck -Assignment $stepContext # Выполняем шаг
                                if ($null -eq $stepResult -or -not $stepResult.PSObject.Properties.Name -contains 'IsAvailable') {
                                    throw "Invoke-StatusMonitorCheck (для шага '$stepTypeForLog') вернул некорректный результат или `$null."
                                }
                                Write-Log ("  Шаг $stepCounter ('$stepTypeForLog') выполнен: IsAvailable=$($stepResult.IsAvailable), CheckSuccess=$($stepResult.CheckSuccess | ForEach-Object {if($_ -eq $null){'[null]'}else{$_}})") -Level Debug
                            } catch {
                                $stepExecErrorMsg = "Критическая ошибка при выполнении шага $stepCounter ('$stepTypeForLog') задания ID $currentAssignmentIdOnline : $($_.Exception.Message)"
                                Write-Log $stepExecErrorMsg -Level Error
                                # Создаем объект ошибки для этого шага
                                $stepResult = New-CheckResultObject -IsAvailable $false -ErrorMessage $stepExecErrorMsg -Details @{StepType=$stepTypeForLog; ErrorRecord=$_.ToString()}
                            }
                            
                            # Добавляем тип шага в его результат для последующего анализа
                            if ($stepResult -is [hashtable] -and -not $stepResult.ContainsKey('StepType')) {
                                $stepResult.StepType = $stepTypeForLog
                            }
                            $allStepResults.Add($stepResult) # Сохраняем результат шага

                            # --- Логика определения общего статуса pipeline ---
                            # Если шаг недоступен, весь pipeline считается недоступным
                            if (-not $stepResult.IsAvailable) {
                                $pipelineOverallIsAvailable = $false
                                if (-not $pipelineErrorMessage) { $pipelineErrorMessage = "Шаг $stepCounter ('$stepTypeForLog') не был доступен (IsAvailable=false)." }
                                # TODO: Добавить обработку флага 'continue_on_failure' для шага, если он будет реализован
                                # Если continue_on_failure = $false (по умолчанию), то прерываем pipeline
                                Write-Log "  Шаг $stepCounter ('$stepTypeForLog') не выполнен (IsAvailable=false). Выполнение pipeline ID $currentAssignmentIdOnline прервано (или помечено как неуспешное)." -Level Warn
                                break # Прерываем выполнение остальных шагов pipeline
                            }
                            # Если шаг провален по критериям, общий CheckSuccess pipeline тоже false
                            # (но pipeline продолжается, если не указано иное)
                            if ($stepResult.CheckSuccess -eq $false) {
                                $pipelineOverallSuccess = $false
                                if (-not $pipelineErrorMessage) { $pipelineErrorMessage = "Шаг $stepCounter ('$stepTypeForLog') не прошел по критериям (CheckSuccess=false)." }
                            }
                            # Если оценка критериев шага дала $null, общий CheckSuccess pipeline тоже $null
                            if ($stepResult.CheckSuccess -eq $null -and $pipelineOverallSuccess -ne $false) { # $null "хуже" чем $true, но "лучше" чем $false
                                $pipelineOverallSuccess = $null
                                if (-not $pipelineErrorMessage) { $pipelineErrorMessage = "Ошибка оценки критериев для шага $stepCounter ('$stepTypeForLog') (CheckSuccess=null)." }
                            }
                        } # Конец цикла по шагам
                    }

                    # --- Формирование и отправка АГРЕГИРОВАННОГО результата для всего pipeline-задания ---
                    $aggregatedPipelineResultPayload = @{
                        assignment_id           = $currentAssignmentIdOnline
                        is_available            = $pipelineOverallIsAvailable
                        check_success_final     = $pipelineOverallSuccess # Отправляем итоговый CheckSuccess для всего pipeline
                        check_timestamp         = $currentTimeUtcOnline.ToString("o") # Время завершения всего pipeline
                        executor_object_id      = $script:Config.object_id
                        executor_host           = $script:ComputerName
                        resolution_method       = $assignmentObjectToExecute.method_name # Основной метод задания
                        detail_type             = "PIPELINE_RESULT" # Специальный тип для агрегированного результата
                        detail_data             = @{ # Детали верхнего уровня - это массив результатов шагов
                                                    steps_results = $allStepResults.ToArray() # Преобразуем Generic.List в обычный массив
                                                    pipeline_status_message = if($pipelineErrorMessage){$pipelineErrorMessage}else{"Все шаги pipeline выполнены."}
                                                  }
                        agent_script_version    = $script:AgentVersion
                        # assignment_config_version здесь не передаем, т.к. это результат онлайн-задания
                    }
                    
                    # Если у агрегированного результата есть ошибка, добавляем ее в payload
                    if ($pipelineErrorMessage) {
                         # Добавляем в detail_data, а не на верхний уровень, чтобы не конфликтовать с ErrorMessage шагов
                         $aggregatedPipelineResultPayload.detail_data.pipeline_error_message = $pipelineErrorMessage
                    }

                    $checksApiUrlOnline = "$($script:Config.api_base_url.TrimEnd('/'))/v1/checks"
                    $sendAggregatedResultSuccess = $false
                    try {
                        $apiResponseFromPostAggregated = Invoke-ApiRequestWithRetry -Uri $checksApiUrlOnline -Method Post -BodyObject $aggregatedPipelineResultPayload -Headers $apiHeaders -Description "Отправка агрегированного результата pipeline ID $currentAssignmentIdOnline"
                        
                        # Анализ ответа (как в v7.0.5 для одиночной отправки)
                        $statusFromApiAggregated = $null
                        if ($null -ne $apiResponseFromPostAggregated) {
                            if ($apiResponseFromPostAggregated -is [hashtable] -and $apiResponseFromPostAggregated.ContainsKey('status')) { $statusFromApiAggregated = $apiResponseFromPostAggregated['status'] }
                            elseif ($apiResponseFromPostAggregated -is [System.Management.Automation.PSCustomObject] -and $apiResponseFromPostAggregated.PSObject.Properties.Name -contains 'status') { $statusFromApiAggregated = $apiResponseFromPostAggregated.status }
                        }
                        if ($statusFromApiAggregated -eq 'success') {
                            $sendAggregatedResultSuccess = $true
                            Write-Log "Агрегированный результат для pipeline-задания ID $currentAssignmentIdOnline успешно отправлен и обработан API." -Level Info
                        } else {
                             $logStatusAgg = if ($null -ne $statusFromApiAggregated) { $statusFromApiAggregated } else { '[N/A_Status]' }
                             Write-Log ("Ответ API при отправке агрегированного результата ID $currentAssignmentIdOnline не был 'success'. Статус: '$logStatusAgg'. Ответ API: $($apiResponseFromPostAggregated | ConvertTo-Json -Depth 2 -Compress)") -Level Error
                        }
                    } catch { Write-Log "Критическая ошибка при отправке агрегированного результата pipeline ID $currentAssignmentIdOnline в API: $($_.Exception.Message)" -Level Error }

                    if ($sendAggregatedResultSuccess) { $script:LastExecutedTimesOnline[$currentAssignmentIdOnline] = $currentTimeUtcOnline; Write-Log "Время последнего выполнения для pipeline-задания ID $currentAssignmentIdOnline обновлено на $currentTimeUtcOnline." -Level Verbose }
                    else { Write-Log "Время последнего выполнения для pipeline-задания ID $currentAssignmentIdOnline НЕ обновлено из-за ошибки отправки результата в API." -Level Warn }

                    Write-Log "ЗАВЕРШЕНИЕ ОБРАБОТКИ pipeline-задания ID $currentAssignmentIdOnline." -Level Info
                } # Конец if ($currentTimeUtcOnline -ge $nextRunTimeOnline)
            } # Конец foreach ($currentAssignmentIdOnline in ...)
        } else { Write-Log "Нет активных pipeline-заданий для выполнения в Online режиме." -Level Verbose }
        
        # (Пауза в конце цикла Online режима - без изменений от v7.0.5)
        # ...
        $loopIterationEndTimeOnline = [DateTimeOffset]::UtcNow; $elapsedMsInLoopOnline = ($loopIterationEndTimeOnline - $loopIterationStartTimeOnline).TotalMilliseconds
        Write-Log "Итерация основного цикла Online режима заняла $($elapsedMsInLoopOnline) мс." -Level Debug; Start-Sleep -Milliseconds 500
    } # Конец while ($true) для Online режима
} elseif ($agentMode -eq 'offline') {
    # --- Логика для Offline режима ---
    # (Валидация полей для Offline режима - без изменений от v7.0.5)
    # ...
    Write-Log "Агент переходит в Offline режим (Pipeline-архитектура)." -Level Info
    # ... (определение $offlineCycleIntervalSec, $runOfflineContinuously - без изменений) ...
    
    do { # Основной цикл Offline режима (может быть однократным)
        $offlineCycleStartTime = [DateTimeOffset]::UtcNow
        Write-Log "Начало цикла/запуска Offline режима ($($offlineCycleStartTime.ToString('s')))." -Level Info

        # --- Чтение файла конфигурации с pipeline-заданиями ---
        # (Логика поиска и чтения файла .json.status.* - без изменений от v7.0.5,
        #  но теперь $script:CurrentFullConfigOffline должен содержать 'assignments' с полем 'pipeline')
        #  $script:CurrentAssignmentsOffline будет массивом заданий, каждое с 'pipeline'.
        #  $script:CurrentConfigVersionOffline будет версией конфигурации.
        # ... (код чтения файла конфигурации) ...
        # Убедимся, что при успешном чтении $script:CurrentAssignmentsOffline - это массив объектов заданий,
        # а $script:CurrentConfigVersionOffline - это строка версии.
        # И что $script:CurrentFullConfigOffline - это весь объект из файла.

        $currentCycleAggregatedResultsList = [System.Collections.Generic.List[object]]::new() # Для сбора агрегированных результатов ВСЕХ заданий

        if ($null -ne $script:CurrentFullConfigOffline -and `
            $script:CurrentFullConfigOffline.PSObject.Properties.Name -contains 'assignments' -and `
            $script:CurrentFullConfigOffline.assignments -is [array] -and `
            $script:CurrentFullConfigOffline.assignments.Count -gt 0) {
            
            $assignmentsFromConfigFile = $script:CurrentFullConfigOffline.assignments
            $configVersionFromFile = $script:CurrentFullConfigOffline.assignment_config_version
            $totalAssignmentsInCurrentConfigOffline = $assignmentsFromConfigFile.Count
            Write-Log ("Начало выполнения $totalAssignmentsInCurrentConfigOffline pipeline-заданий из Offline конфигурации (Версия: '$configVersionFromFile')...") -Level Info
            
            $completedAssignmentCountOffline = 0
            foreach ($assignmentObjectRawFromConfig in $assignmentsFromConfigFile) {
                $completedAssignmentCountOffline++
                $currentOfflineAssignmentId = "[N/A_ID]"; $currentOfflineMethodNameLog = "[N/A_Method]"; $currentOfflineNodeNameLog = "[N/A_Node]"
                
                # Валидация базовой структуры задания из конфига
                if ($null -eq $assignmentObjectRawFromConfig -or `
                    -not ($assignmentObjectRawFromConfig.PSObject.Properties.Name -contains 'assignment_id' -and $null -ne $assignmentObjectRawFromConfig.assignment_id) -or `
                    -not ($assignmentObjectRawFromConfig.PSObject.Properties.Name -contains 'pipeline' -and $assignmentObjectRawFromConfig.pipeline -is [array])) {
                    Write-Log "  Пропущено некорректное задание (отсутствует assignment_id или pipeline) в offline-конфиге: $($assignmentObjectRawFromConfig | ConvertTo-Json -Depth 1 -Compress)." -Level Warn
                    # Собираем информацию об ошибке для этого "задания"
                    $errorResultBaseForZrpu = New-CheckResultObject -IsAvailable $false -ErrorMessage "Некорректная структура задания в файле конфигурации." -Details @{OriginalAssignmentSnippet=($assignmentObjectRawFromConfig|ConvertTo-Json -Depth 2 -Compress -WA SilentlyContinue)}
                    $currentCycleAggregatedResultsList.Add(@{ assignment_id=$currentOfflineAssignmentId } + $errorResultBaseForZrpu) # Используем $currentOfflineAssignmentId если он есть, или N/A
                    continue
                }
                
                $currentOfflineAssignmentConfigObj = [PSCustomObject]$assignmentObjectRawFromConfig
                $currentOfflineAssignmentId = $currentOfflineAssignmentConfigObj.assignment_id.ToString()
                if($currentOfflineAssignmentConfigObj.PSObject.Properties.Name -contains 'method_name'){$currentOfflineMethodNameLog = $currentOfflineAssignmentConfigObj.method_name}
                if($currentOfflineAssignmentConfigObj.PSObject.Properties.Name -contains 'node_name'){$currentOfflineNodeNameLog = $currentOfflineAssignmentConfigObj.node_name}

                Write-Log ("  Выполнение pipeline-задания $completedAssignmentCountOffline/$totalAssignmentsInCurrentConfigOffline (ID: $currentOfflineAssignmentId, Класс: '$currentOfflineMethodNameLog', Узел: '$currentOfflineNodeNameLog')...") -Level Verbose

                # --- ВЫПОЛНЕНИЕ PIPELINE ДЛЯ ОФФЛАЙН ЗАДАНИЯ ---
                $pipelineStepsOffline = $currentOfflineAssignmentConfigObj.pipeline
                $allStepResultsOffline = [System.Collections.Generic.List[object]]::new()
                $pipelineOverallSuccessOffline = $true
                $pipelineOverallIsAvailableOffline = $true
                $pipelineErrorMessageOffline = $null

                if ($pipelineStepsOffline.Count -eq 0) {
                    Write-Log "  Pipeline-задание ID $currentOfflineAssignmentId не содержит шагов. Пропущено." -Level Warn
                    $pipelineOverallIsAvailableOffline = $false
                    $pipelineErrorMessageOffline = "Pipeline не содержит шагов."
                } else {
                    Write-Log "  Найдено $($pipelineStepsOffline.Count) шагов в pipeline для задания ID $currentOfflineAssignmentId (offline)." -Level Debug
                    $stepCounterOffline = 0
                    foreach ($stepObjectOffline in $pipelineStepsOffline) {
                        $stepCounterOffline++
                        $stepTypeForLogOffline = if($stepObjectOffline -and $stepObjectOffline.PSObject.Properties.Name -contains 'type') {$stepObjectOffline.type} else {'[UnknownStepType]'}
                        Write-Log "    Выполнение шага $stepCounterOffline/$($pipelineStepsOffline.Count) (Тип: '$stepTypeForLogOffline') для offline-задания ID $currentOfflineAssignmentId..." -Level Debug
                        
                        $stepContextOffline = [PSCustomObject]@{
                            type = $stepObjectOffline.type
                            parameters = if($stepObjectOffline.PSObject.Properties.Name -contains 'parameters'){$stepObjectOffline.parameters}else{@{}}
                            success_criteria = if($stepObjectOffline.PSObject.Properties.Name -contains 'success_criteria'){$stepObjectOffline.success_criteria}else{$null}
                            node_name = $currentOfflineAssignmentConfigObj.node_name # Из родительского задания
                            ip_address = $currentOfflineAssignmentConfigObj.ip_address # Из родительского задания
                        }
                        
                        $stepResultOffline = $null
                        try {
                            $stepResultOffline = Invoke-StatusMonitorCheck -Assignment $stepContextOffline
                            if ($null -eq $stepResultOffline -or -not $stepResultOffline.PSObject.Properties.Name -contains 'IsAvailable') {
                                throw "Invoke-StatusMonitorCheck (для шага '$stepTypeForLogOffline') вернул некорректный результат."
                            }
                        } catch {
                            $stepExecErrorMsgOffline = "Критическая ошибка при выполнении шага $stepCounterOffline ('$stepTypeForLogOffline') offline-задания ID $currentOfflineAssignmentId : $($_.Exception.Message)"
                            Write-Log $stepExecErrorMsgOffline -Level Error
                            $stepResultOffline = New-CheckResultObject -IsAvailable $false -ErrorMessage $stepExecErrorMsgOffline -Details @{StepType=$stepTypeForLogOffline; ErrorRecord=$_.ToString()}
                        }
                        if ($stepResultOffline -is [hashtable] -and -not $stepResultOffline.ContainsKey('StepType')) { $stepResultOffline.StepType = $stepTypeForLogOffline }
                        $allStepResultsOffline.Add($stepResultOffline)

                        if (-not $stepResultOffline.IsAvailable) {
                            $pipelineOverallIsAvailableOffline = $false
                            if (-not $pipelineErrorMessageOffline) { $pipelineErrorMessageOffline = "Шаг $stepCounterOffline ('$stepTypeForLogOffline') не был доступен." }
                            break # Прерываем pipeline
                        }
                        if ($stepResultOffline.CheckSuccess -eq $false) {
                            $pipelineOverallSuccessOffline = $false
                            if (-not $pipelineErrorMessageOffline) { $pipelineErrorMessageOffline = "Шаг $stepCounterOffline ('$stepTypeForLogOffline') не прошел по критериям." }
                        }
                        if ($stepResultOffline.CheckSuccess -eq $null -and $pipelineOverallSuccessOffline -ne $false) {
                            $pipelineOverallSuccessOffline = $null
                            if (-not $pipelineErrorMessageOffline) { $pipelineErrorMessageOffline = "Ошибка оценки критериев для шага $stepCounterOffline ('$stepTypeForLogOffline')." }
                        }
                    } # Конец foreach ($stepObjectOffline in $pipelineStepsOffline)
                } # Конец else ($pipelineStepsOffline.Count -eq 0)
                
                # Формируем агрегированный результат для этого offline-задания
                # Важно: структура должна быть совместима с тем, что ожидает Загрузчик и API /checks/bulk (поле 'IsAvailable', 'Timestamp' и т.д.)
                $aggregatedResultForThisOfflineAssignment = @{
                    assignment_id = $currentOfflineAssignmentConfigObj.assignment_id
                    # Используем PascalCase для IsAvailable и Timestamp, как ожидает /checks/bulk
                    IsAvailable  = $pipelineOverallIsAvailableOffline
                    CheckSuccess = $pipelineOverallSuccessOffline # Итоговый CheckSuccess для всего pipeline
                    Timestamp    = $offlineCycleStartTime.ToUniversalTime().ToString("o") # Время начала выполнения всего цикла оффлайн агента
                    Details      = @{ # Детали верхнего уровня - это массив результатов шагов
                                    steps_results = $allStepResultsOffline.ToArray()
                                    pipeline_status_message = if($pipelineErrorMessageOffline){$pipelineErrorMessageOffline}else{"Все шаги offline pipeline выполнены."}
                                  }
                    # ErrorMessage для всего pipeline (если был)
                    ErrorMessage = if($pipelineErrorMessageOffline){$pipelineErrorMessageOffline}else{$null}
                }
                $currentCycleAggregatedResultsList.Add($aggregatedResultForThisOfflineAssignment)
                Write-Log "  Завершено выполнение pipeline-задания ID $currentOfflineAssignmentId. Агрегированный результат добавлен в .zrpu." -Level Verbose

            } # Конец foreach ($assignmentObjectRawFromConfig in $assignmentsFromConfigFile)
            Write-Log "Выполнение всех ($totalAssignmentsInCurrentConfigOffline) offline pipeline-заданий завершено. Собрано результатов: $($currentCycleAggregatedResultsList.Count)." -Level Info
        } else { Write-Log "Нет активных pipeline-заданий для выполнения в Offline режиме (файл конфигурации пуст или не найден)." -Level Info }

        # --- Сохранение всех агрегированных результатов в .zrpu файл ---
        if ($currentCycleAggregatedResultsList.Count -gt 0) {
            $timestampForFileNameOffline = Get-Date -Format "ddMMyy_HHmmss"
            $outputFileNameTemplateOffline = $script:Config.output_name_template
            $outputFileNameGeneratedOffline = $outputFileNameTemplateOffline -replace "{object_id}", $script:Config.object_id -replace "{ddMMyy_HHmmss}", $timestampForFileNameOffline
            $outputFileNameCleanedOffline = $outputFileNameGeneratedOffline -replace '[\\/:*?"<>|]', '_'
            $outputFileFullPathOffline = Join-Path -Path $outputResultsPath -ChildPath $outputFileNameCleanedOffline
            $tempOutputFileFullPathOffline = $outputFileFullPathOffline + ".tmp"
            
            # Версия конфигурации берется из прочитанного файла
            $configVersionForPayload = if ($script:CurrentFullConfigOffline) { $script:CurrentFullConfigOffline.assignment_config_version } else { 'N/A_ConfigVersion' }

            Write-Log ("Сохранение $($currentCycleAggregatedResultsList.Count) агрегированных результатов pipeline в: '$outputFileFullPathOffline'") -Level Info
            Write-Log ("Версия агента: $script:AgentVersion. Версия конфига: '$configVersionForPayload'. ObjectID: $($script:Config.object_id).") -Level Verbose
            
            # Структура .zrpu файла
            $finalPayloadForZrpuFile = @{
                agent_script_version      = $script:AgentVersion
                assignment_config_version = $configVersionForPayload
                object_id                 = $script:Config.object_id
                execution_timestamp_utc   = $offlineCycleStartTime.ToString("o") # Время начала всего цикла
                results                   = $currentCycleAggregatedResultsList.ToArray() # Массив агрегированных результатов заданий
            }
            try {
                $jsonToSaveToFileOffline = $finalPayloadForZrpuFile | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
                $utf8EncodingNoBomOffline = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($tempOutputFileFullPathOffline, $jsonToSaveToFileOffline, $utf8EncodingNoBomOffline)
                Write-Log "Данные записаны во временный файл ($tempOutputFileFullPathOffline)." -Level Debug
                Move-Item -Path $tempOutputFileFullPathOffline -Destination $outputFileFullPathOffline -Force -ErrorAction Stop
                Write-Log "Файл '$outputFileNameCleanedOffline' успешно сохранен (атомарно)." -Level Info
            } catch {
                Write-Log ("Критическая ошибка сохранения файла результатов '$outputFileFullPathOffline': $($_.Exception.Message)") -Level Error
                if (Test-Path $tempOutputFileFullPathOffline -PathType Leaf) { try { Remove-Item -Path $tempOutputFileFullPathOffline -Force -ErrorAction SilentlyContinue } catch {} }
            }
        } else { Write-Log "Нет агрегированных результатов pipeline для сохранения в .zrpu файл." -Level Info }

        # (Пауза в конце цикла Offline режима - без изменений от v7.0.5)
        # ...
        if ($runOfflineContinuously) {
             $offlineCycleEndTime = [DateTimeOffset]::UtcNow; $elapsedSecondsInCycleOffline = ($offlineCycleEndTime - $offlineCycleStartTime).TotalSeconds; $sleepDurationSecondsOffline = $offlineCycleIntervalSec - $elapsedSecondsInCycleOffline
             if ($sleepDurationSecondsOffline -lt 1) { Write-Log ("Итерация Offline цикла заняла {0:N2} сек (>= интервала {1} сек). Пауза 1 сек." -f $elapsedSecondsInCycleOffline, $offlineCycleIntervalSec) -Level Warn; $sleepDurationSecondsOffline = 1 }
             else { Write-Log ("Итерация Offline цикла заняла {0:N2} сек. Пауза {1:N2} сек..." -f $elapsedSecondsInCycleOffline, $sleepDurationSecondsOffline) -Level Verbose }
             Start-Sleep -Seconds $sleepDurationSecondsOffline
        }
    } while ($runOfflineContinuously) # Конец do...while для Offline режима
    
    # (Завершение Offline режима - без изменений от v7.0.5)
    # ...
    $offlineCompletionReason = if ($runOfflineContinuously) { 'цикл прерван (внешнее событие)' } else { 'однократный запуск завершен' }
    Write-Log ("Offline режим завершен ({0})." -f $offlineCompletionReason) -Level Info; exit 0

} else { # Неизвестный режим работы
     Write-Log "Критическая ошибка: Неизвестный режим работы '$($script:Config.mode)' указан в конфигурационном файле." -Level Error; exit 1
}

# Эта строка не должна достигаться при нормальной работе
Write-Log "Агент завершает работу непредвиденно (достигнут конец скрипта без выхода по exit)." -Level Error; exit 1