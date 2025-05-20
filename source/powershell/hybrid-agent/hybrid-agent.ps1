# powershell/hybrid-agent/hybrid-agent.ps1
# --- Гибридный Агент Мониторинга v7.0.5 ---
# Изменения:
# - Исправлен анализ ответа API для Online режима при отправке одиночного результата.
# - (Остальные изменения из v7.0.4 сохранены)

<#
.SYNOPSIS
    Гибридный агент системы мониторинга Status Monitor v7.0.5.
    (Описание без изменений)
.NOTES
    Версия: 7.0.5
    Дата: [Актуальная Дата]
    (Остальное без изменений)
#>
param (
    [string]$ConfigFile = "$PSScriptRoot\config.json"
)

# --- 1. Загрузка общего модуля утилит ---
# ... (без изменений) ...
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
# ... (без изменений, кроме версии) ...
$script:ComputerName = $env:COMPUTERNAME
$script:Config = $null
$script:EffectiveLogLevel = "Info"
$script:LogFilePath = $null
$script:AgentVersion = "hybrid_agent_v7.0.5" # Обновляем версию

$script:ActiveAssignmentsOnline = @{}
$script:LastExecutedTimesOnline = @{}
$script:LastApiPollTimeOnline = [DateTimeOffset]::MinValue

$script:CurrentAssignmentsOffline = $null
$script:CurrentConfigVersionOffline = $null
$script:LastProcessedConfigFileFullNameOffline = $null
$script:LastConfigFileWriteTimeOffline = [DateTime]::MinValue

# --- 3. Вспомогательные функции ---
# ... (Write-Log, Invoke-ApiRequestWithRetry без изменений) ...
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
        $logLine = "[$timestamp] [$Level] [$script:ComputerName] - $Message"
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
            if ($httpStatusCode -ge 400 -and $httpStatusCode -lt 500) { Write-Log ("Критическая ошибка API ($Description - Код $httpStatusCode), повторные попытки отменены.") -Level Error; throw $exceptionDetails }
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
# ... (Чтение конфига, валидация общих полей - без изменений) ...
Write-Host "Запуск Гибридного Агента Мониторинга v$($script:AgentVersion)..." -ForegroundColor Yellow
Write-Log "Чтение конфигурации из '$ConfigFile'..." -Level Info
if (-not (Test-Path $ConfigFile -PathType Leaf)) { Write-Log "Критическая ошибка: Файл конфигурации '$ConfigFile' не найден. Агент не может быть запущен." -Level Error; if ($Host.Name -eq "ConsoleHost") { Read-Host "Нажмите Enter для выхода" }; exit 1 }
try { $script:Config = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Log "Критическая ошибка: Ошибка чтения или парсинга JSON из '$ConfigFile': $($_.Exception.Message). Агент не может быть запущен." -Level Error; if ($Host.Name -eq "ConsoleHost") { Read-Host "Нажмите Enter для выхода" }; exit 1 }
$requiredCommonFields = @("mode", "object_id", "log_file", "log_level", "agent_script_version")
$missingOrEmptyCommonFields = $requiredCommonFields | Where-Object { -not ($script:Config.PSObject.Properties.Name -contains $_) -or $null -eq $script:Config.$_ -or (($script:Config.$_ -is [string]) -and ([string]::IsNullOrWhiteSpace($script:Config.$_))) }
if ($missingOrEmptyCommonFields.Count -gt 0) { Write-Log ("Критическая ошибка: В '$ConfigFile' отсутствуют или пусты обязательные общие поля: $($missingOrEmptyCommonFields -join ', '). Агент не может быть запущен.") -Level Error; if ($Host.Name -eq "ConsoleHost") { Read-Host "Нажмите Enter для выхода" }; exit 1 }
$script:LogFilePath = $script:Config.log_file
$script:EffectiveLogLevel = $script:Config.log_level
$validLogLevelsList = @("Debug", "Verbose", "Info", "Warn", "Error")
if ($script:EffectiveLogLevel -notin $validLogLevelsList) { Write-Log ("Некорректный LogLevel '$($script:EffectiveLogLevel)' в конфигурации. Используется уровень 'Info'.") -Level Warn; $script:EffectiveLogLevel = "Info" }
if ($script:Config.agent_script_version -ne $script:AgentVersion) { Write-Log ("Версия агента в конфигурации ('$($script:Config.agent_script_version)') отличается от версии скрипта ('$($script:AgentVersion)'). Используется версия из скрипта.") -Level Info }
Write-Log "Гибридный агент v$($script:AgentVersion) запущен. Имя хоста: $script:ComputerName" -Level Info
Write-Log "Режим работы (из config.json): $($script:Config.mode)" -Level Info
Write-Log "ObjectID (из config.json): $($script:Config.object_id)" -Level Info
Write-Log "Логирование будет осуществляться в '$script:LogFilePath' с уровнем '$script:EffectiveLogLevel'." -Level Info
$agentMode = ""; if ($script:Config.mode -is [string]) { $agentMode = $script:Config.mode.Trim().ToLower() }


if ($agentMode -eq 'online') {
    # ... (Валидация полей для Online режима - без изменений) ...
    Write-Log "Агент переходит в Online режим." -Level Info
    $requiredOnlineFields = @("api_base_url", "api_key", "api_poll_interval_seconds", "default_check_interval_seconds")
    $missingOrEmptyOnlineFields = $requiredOnlineFields | Where-Object { -not ($script:Config.PSObject.Properties.Name -contains $_) -or $null -eq $script:Config.$_ -or (($script:Config.$_ -is [string]) -and ([string]::IsNullOrWhiteSpace($script:Config.$_))) }
    if ($missingOrEmptyOnlineFields.Count -gt 0) { Write-Log ("Критическая ошибка: Для Online режима в '$ConfigFile' отсутствуют или пусты обязательные поля: $($missingOrEmptyOnlineFields -join ', '). Online режим не может быть запущен.") -Level Error; if ($Host.Name -eq "ConsoleHost") { Read-Host "Нажмите Enter для выхода" }; exit 1 }
    $apiPollIntervalSec = 60
    if ($script:Config.PSObject.Properties.Name -contains 'api_poll_interval_seconds' -and $script:Config.api_poll_interval_seconds -ne $null) { $parsedVal = 0; if ([int]::TryParse($script:Config.api_poll_interval_seconds, [ref]$parsedVal) -and $parsedVal -ge 10) { $apiPollIntervalSec = $parsedVal } else { Write-Log "Некорректное значение 'api_poll_interval_seconds' ('$($script:Config.api_poll_interval_seconds)'). Используется $apiPollIntervalSec сек." "Warn" } }
    $apiPollTimeSpan = [TimeSpan]::FromSeconds($apiPollIntervalSec)
    $defaultCheckIntervalSec = 300
    if ($script:Config.PSObject.Properties.Name -contains 'default_check_interval_seconds' -and $script:Config.default_check_interval_seconds -ne $null) { $parsedVal = 0; if ([int]::TryParse($script:Config.default_check_interval_seconds, [ref]$parsedVal) -and $parsedVal -ge 5) { $defaultCheckIntervalSec = $parsedVal } else { Write-Log "Некорректное значение 'default_check_interval_seconds' ('$($script:Config.default_check_interval_seconds)'). Используется $defaultCheckIntervalSec сек." "Warn" } }
    Write-Log ("Online режим: Опрос API для получения заданий каждые $apiPollIntervalSec сек. Стандартный интервал выполнения проверки (если не указан в задании): $defaultCheckIntervalSec сек.") -Level Info
    Write-Log "Запуск основного цикла Online режима..." -Level Info


    while ($true) {
        # ... (Получение заданий от API - без изменений) ...
        $loopIterationStartTime = [DateTimeOffset]::UtcNow
        Write-Log "Начало итерации основного цикла Online режима." -Level Verbose
        if (($loopIterationStartTime - $script:LastApiPollTimeOnline) -ge $apiPollTimeSpan) {
            Write-Log "Время обновить список заданий с API сервера." -Level Info
            $assignmentsApiUrl = "$($script:Config.api_base_url.TrimEnd('/'))/v1/assignments?object_id=$($script:Config.object_id)"
            $apiHeaders = @{ 'X-API-Key' = $script:Config.api_key }
            try {
                $fetchedAssignmentsFromApi = Invoke-ApiRequestWithRetry -Uri $assignmentsApiUrl -Method Get -Headers $apiHeaders -Description "Получение заданий (ObjectID $($script:Config.object_id))"
                if ($null -ne $fetchedAssignmentsFromApi -and $fetchedAssignmentsFromApi -is [array]) {
                    Write-Log "Получено $($fetchedAssignmentsFromApi.Count) активных заданий от API." -Level Info
                    $newAssignmentIdMap = @{}; $currentAssignmentIdsFromApi = [System.Collections.Generic.List[int]]::new()
                    foreach ($assignmentDataFromApi in $fetchedAssignmentsFromApi) { if ($null -ne $assignmentDataFromApi -and $assignmentDataFromApi.PSObject -ne $null -and $assignmentDataFromApi.PSObject.Properties.Name -contains 'assignment_id' -and $null -ne $assignmentDataFromApi.assignment_id) { $parsedAssignmentId = 0; if([int]::TryParse($assignmentDataFromApi.assignment_id.ToString(), [ref]$parsedAssignmentId)) { $newAssignmentIdMap[$parsedAssignmentId] = [PSCustomObject]$assignmentDataFromApi; $currentAssignmentIdsFromApi.Add($parsedAssignmentId) | Out-Null } else { Write-Log "Получено задание от API с нечисловым assignment_id: '$($assignmentDataFromApi.assignment_id)'. Задание пропущено." -Level Warn } } else { Write-Log "Получено некорректное задание (или его часть) от API (отсутствует assignment_id): $($assignmentDataFromApi | ConvertTo-Json -Depth 2 -Compress)." -Level Warn } }
                    $existingAssignmentIdsInMemory = @($script:ActiveAssignmentsOnline.Keys | ForEach-Object { [int]$_ }); $removedAssignmentIds = $existingAssignmentIdsInMemory | Where-Object { $currentAssignmentIdsFromApi -notcontains $_ }
                    $addedCount = 0; $updatedCount = 0; $removedCount = 0
                    if ($removedAssignmentIds.Count -gt 0) { foreach ($idToRemove in $removedAssignmentIds) { Write-Log "Задание ID $idToRemove удалено из активного списка (более не приходит от API)." -Level Info; $script:ActiveAssignmentsOnline.Remove($idToRemove); $script:LastExecutedTimesOnline.Remove($idToRemove); $removedCount++ } }
                    foreach ($idFromApi in $currentAssignmentIdsFromApi) { $newAssignmentObject = $newAssignmentIdMap[$idFromApi]; if (-not $script:ActiveAssignmentsOnline.ContainsKey($idFromApi)) { $script:ActiveAssignmentsOnline[$idFromApi] = $newAssignmentObject; $script:LastExecutedTimesOnline[$idFromApi] = [DateTimeOffset]::UtcNow.AddDays(-1); $addedCount++; Write-Log "Добавлено новое задание ID $idFromApi в активный список." -Level Info } else { $oldAssignmentJson = $script:ActiveAssignmentsOnline[$idFromApi] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue; $newAssignmentJson = $newAssignmentObject | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue; if ($oldAssignmentJson -ne $newAssignmentJson) { $script:ActiveAssignmentsOnline[$idFromApi] = $newAssignmentObject; $updatedCount++; Write-Log "Задание ID $idFromApi обновлено в активном списке." -Level Verbose } } }
                    Write-Log ("Синхронизация заданий с API завершена. Всего активно: $($script:ActiveAssignmentsOnline.Count). Добавлено: $addedCount. Обновлено: $updatedCount. Удалено: $removedCount.") -Level Info
                    $script:LastApiPollTimeOnline = $loopIterationStartTime
                } elseif ($null -eq $fetchedAssignmentsFromApi -and $currentTry -lt $maxRetriesForRequest) { Write-Log "API вернул пустой ответ (возможно, нет активных заданий или временная ошибка). Повторная попытка будет позже." -Level Warn }
                  elseif ($null -eq $fetchedAssignmentsFromApi) { Write-Log "Не удалось получить задания от API после всех попыток. Текущий список активных заданий не изменен." -Level Error }
                  elseif ($fetchedAssignmentsFromApi -is [array] -and $fetchedAssignmentsFromApi.Count -eq 0) { Write-Log "API вернул пустой массив заданий (активных заданий для этого object_id нет)." -Level Info; if ($script:ActiveAssignmentsOnline.Count -gt 0) { Write-Log "Очистка ранее активных заданий, так как API вернул пустой список." -Level Info; $script:ActiveAssignmentsOnline.Clear(); $script:LastExecutedTimesOnline.Clear() }; $script:LastApiPollTimeOnline = $loopIterationStartTime }
                  else { Write-Log "API вернул некорректные данные для списка заданий (не массив или неожиданный формат). Текущий список активных заданий не изменен." -Level Error }
            } catch { Write-Log "Критическая ошибка при получении заданий от API: $($_.Exception.Message). Используется текущий список заданий (если есть). Следующая попытка через $apiPollIntervalSec сек." -Level Error }
        } else { Write-Log "Опрос API для обновления заданий еще не требуется (прошло меньше $apiPollIntervalSec сек)." -Level Verbose }

        $currentTimeUtc = [DateTimeOffset]::UtcNow
        if ($script:ActiveAssignmentsOnline.Count -gt 0) {
            # ... (Цикл по заданиям - без изменений до отправки результата) ...
            Write-Log "Проверка запланированных заданий (активно: $($script:ActiveAssignmentsOnline.Count))..." -Level Verbose
            $assignmentIdsToProcessThisLoop = @($script:ActiveAssignmentsOnline.Keys)
            foreach ($currentAssignmentId in $assignmentIdsToProcessThisLoop) {
                if (-not $script:ActiveAssignmentsOnline.ContainsKey($currentAssignmentId)) { Write-Log "Задание ID $currentAssignmentId было удалено из активного списка во время итерации. Пропуск." -Level Warn; continue }
                $assignmentToExecute = $script:ActiveAssignmentsOnline[$currentAssignmentId]
                $currentCheckIntervalSec = $defaultCheckIntervalSec
                if ($assignmentToExecute.PSObject.Properties.Name -contains 'check_interval_seconds' -and $null -ne $assignmentToExecute.check_interval_seconds) { $parsedInterval = 0; if ([int]::TryParse($assignmentToExecute.check_interval_seconds.ToString(), [ref]$parsedInterval) -and $parsedInterval -ge 5) { $currentCheckIntervalSec = $parsedInterval } else { Write-Log "Некорректный 'check_interval_seconds' ($($assignmentToExecute.check_interval_seconds)) для задания ID $currentAssignmentId. Используется стандартный интервал $defaultCheckIntervalSec сек." -Level Warn } }
                $currentCheckIntervalTimeSpan = [TimeSpan]::FromSeconds($currentCheckIntervalSec)
                $lastRunTimeForThisAssignment = [DateTimeOffset]::MinValue
                if ($script:LastExecutedTimesOnline.ContainsKey($currentAssignmentId)) { $lastRunTimeForThisAssignment = $script:LastExecutedTimesOnline[$currentAssignmentId] }
                $nextRunTime = $lastRunTimeForThisAssignment + $currentCheckIntervalTimeSpan
                if ($currentTimeUtc -ge $nextRunTime) {
                    $nodeNameToLogForRun = if (-not [string]::IsNullOrWhiteSpace($assignmentToExecute.node_name)) { $assignmentToExecute.node_name } else { "[N/A]" }
                    Write-Log ("НАЧАЛО ВЫПОЛНЕНИЯ задания ID $currentAssignmentId (Метод: $($assignmentToExecute.method_name), Узел: '$nodeNameToLogForRun'). Расчетное время: $nextRunTime, Текущее: $currentTimeUtc") -Level Info
                    $checkExecutionResult = $null
                    try {
                        $checkExecutionResult = Invoke-StatusMonitorCheck -Assignment $assignmentToExecute
                        if ($null -eq $checkExecutionResult -or -not $checkExecutionResult.PSObject.Properties.Name -contains 'IsAvailable') { throw "Invoke-StatusMonitorCheck вернул некорректный результат или `$null для задания ID $currentAssignmentId." }
                        $errorMessageSubstring = ""; if (-not [string]::IsNullOrEmpty($checkExecutionResult.ErrorMessage)) { $maxLength = 100; if ($checkExecutionResult.ErrorMessage.Length -gt $maxLength) { $errorMessageSubstring = $checkExecutionResult.ErrorMessage.Substring(0, $maxLength) + "..." } else { $errorMessageSubstring = $checkExecutionResult.ErrorMessage } }
                        $logMsg = "Результат проверки для задания ID ${currentAssignmentId}: "; $logMsg += "IsAvailable=$($checkExecutionResult.IsAvailable), "; $logMsg += "CheckSuccess="; if ($null -eq $checkExecutionResult.CheckSuccess) { $logMsg += "[null], " } else { $logMsg += "$($checkExecutionResult.CheckSuccess), " }; $logMsg += "ErrorMessage='$errorMessageSubstring'"; Write-Log $logMsg -Level Verbose
                        
                        # --- ИСПРАВЛЕНИЕ ФОРМИРОВАНИЯ PAYLOAD ДЛЯ ОДИНОЧНОЙ ОТПРАВКИ ---
                        # API /checks ожидает одиночный объект, а не массив
                        $payloadForApi = @{
                            assignment_id        = $currentAssignmentId
                            is_available         = $checkExecutionResult.IsAvailable # Используем PascalCase, как в одиночном `add_check_v1`
                            check_timestamp      = $checkExecutionResult.Timestamp   # Используем PascalCase
                            executor_object_id   = $script:Config.object_id
                            executor_host        = $script:ComputerName
                            resolution_method    = $assignmentToExecute.method_name
                            detail_type          = $null # Тип будет извлечен из detail_data на сервере, если нужно
                            detail_data          = $checkExecutionResult.Details
                            agent_script_version = $script:AgentVersion
                        }
                        # Добавляем CheckSuccessFromAgent и ErrorMessageFromAgentCheck в detail_data, если они есть
                        if ($null -ne $checkExecutionResult.CheckSuccess -and ($payloadForApi.detail_data -is [hashtable])) {
                            $payloadForApi.detail_data.CheckSuccessFromAgent = $checkExecutionResult.CheckSuccess
                        }
                        if (-not [string]::IsNullOrEmpty($checkExecutionResult.ErrorMessage) -and ($payloadForApi.detail_data -is [hashtable])) {
                            $payloadForApi.detail_data.ErrorMessageFromAgentCheck = $checkExecutionResult.ErrorMessage
                        }
                        # --- КОНЕЦ ИСПРАВЛЕНИЯ ФОРМИРОВАНИЯ PAYLOAD ---

                        $checksApiUrl = "$($script:Config.api_base_url.TrimEnd('/'))/v1/checks"
                        $sendResultSuccess = $false
                        try {
                             $apiResponseFromPost = Invoke-ApiRequestWithRetry -Uri $checksApiUrl -Method Post -BodyObject $payloadForApi -Headers $apiHeaders -Description "Отправка результата проверки задания ID $currentAssignmentId" # Передаем одиночный объект

                             # --- ИСПРАВЛЕННЫЙ АНАЛИЗ ОТВЕТА ДЛЯ ОДИНОЧНОЙ ОТПРАВКИ ---
                             $statusFromApi = $null
                             if ($null -ne $apiResponseFromPost) {
                                 if ($apiResponseFromPost -is [hashtable] -and $apiResponseFromPost.ContainsKey('status')) {
                                     $statusFromApi = $apiResponseFromPost['status']
                                 } elseif ($apiResponseFromPost -is [System.Management.Automation.PSCustomObject] -and $apiResponseFromPost.PSObject.Properties.Name -contains 'status') {
                                     $statusFromApi = $apiResponseFromPost.status
                                 }
                             }

                             if ($statusFromApi -eq 'success') { # Просто проверяем статус "success"
                             # --- КОНЕЦ ИСПРАВЛЕННОГО АНАЛИЗА ---
                                 $sendResultSuccess = $true
                                 Write-Log "Результат для задания ID $currentAssignmentId успешно отправлен и обработан API." -Level Info
                             } else {
                                 $logStatus = if ($null -ne $statusFromApi) { $statusFromApi } else { '[N/A_Status]' }
                                 Write-Log ("Ответ API при отправке результата ID $currentAssignmentId не был 'success'. Статус: '$logStatus'. Ответ API: $($apiResponseFromPost | ConvertTo-Json -Depth 2 -Compress)") -Level Error
                             }
                        } catch { Write-Log "Критическая ошибка при отправке результата задания ID $currentAssignmentId в API: $($_.Exception.Message)" -Level Error }
                        if ($sendResultSuccess) { $script:LastExecutedTimesOnline[$currentAssignmentId] = $currentTimeUtc; Write-Log "Время последнего выполнения для задания ID $currentAssignmentId обновлено на $currentTimeUtc." -Level Verbose }
                        else { Write-Log "Время последнего выполнения для задания ID $currentAssignmentId НЕ обновлено из-за ошибки отправки результата в API." -Level Warn }
                    } catch { Write-Log "Критическая ошибка при ВЫПОЛНЕНИИ задания ID $currentAssignmentId (Метод: $($assignmentToExecute.method_name)): $($_.Exception.Message)" -Level Error }
                      finally { Write-Log "ЗАВЕРШЕНИЕ ОБРАБОТКИ задания ID $currentAssignmentId." -Level Info }
                }
            }
        } else { Write-Log "Нет активных заданий для выполнения в Online режиме." -Level Verbose }
        $loopIterationEndTime = [DateTimeOffset]::UtcNow; $elapsedMsInLoop = ($loopIterationEndTime - $loopIterationStartTime).TotalMilliseconds
        Write-Log "Итерация основного цикла Online режима заняла $($elapsedMsInLoop) мс." -Level Debug; Start-Sleep -Milliseconds 500
    }
} elseif ($agentMode -eq 'offline') {
    # ... (Логика Offline режима - без изменений от v7.0.4) ...
    Write-Log "Агент переходит в Offline режим." -Level Info
    $requiredOfflineFields = @("assignments_file_path_pattern", "output_path", "output_name_template", "offline_cycle_interval_seconds")
    $missingOrEmptyOfflineFields = $requiredOfflineFields | Where-Object { -not ($script:Config.PSObject.Properties.Name -contains $_) -or $null -eq $script:Config.$_ -or (($script:Config.$_ -is [string]) -and ([string]::IsNullOrWhiteSpace($script:Config.$_))) -or ($_ -eq "offline_cycle_interval_seconds" -and ($script:Config.$_ -is [string] -and [string]::IsNullOrWhiteSpace($script:Config.$_))) }
    if ($missingOrEmptyOfflineFields.Count -gt 0) { Write-Log ("Критическая ошибка: Для Offline режима в '$ConfigFile' отсутствуют или пусты обязательные поля: $($missingOrEmptyOfflineFields -join ', '). Offline режим не может быть запущен.") -Level Error; if ($Host.Name -eq "ConsoleHost") { Read-Host "Нажмите Enter для выхода" }; exit 1 }
    $assignmentsFolderPathForCheck = $null
    try { $assignmentsFolderPathForCheck = Split-Path -Path $script:Config.assignments_file_path_pattern -Parent -ErrorAction Stop; if (-not (Test-Path $assignmentsFolderPathForCheck -PathType Container)) { Write-Log "Папка для файлов заданий '$assignmentsFolderPathForCheck' (из 'assignments_file_path_pattern') не найдена. Попытка создать..." -Level Warn; New-Item -Path $assignmentsFolderPathForCheck -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "Папка '$assignmentsFolderPathForCheck' успешно создана." -Level Info } }
    catch { Write-Log "Критическая ошибка: Не удалось определить или создать папку для файлов заданий из '$($script:Config.assignments_file_path_pattern)': $($_.Exception.Message). Offline режим не может быть запущен." -Level Error; if ($Host.Name -eq "ConsoleHost") { Read-Host "Нажмите Enter для выхода" }; exit 1 }
    $outputResultsPath = $script:Config.output_path
    if (-not (Test-Path $outputResultsPath -PathType Container)) { Write-Log "Папка для файлов результатов '$outputResultsPath' не найдена. Попытка создать..." -Level Warn; try { New-Item -Path $outputResultsPath -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "Папка '$outputResultsPath' успешно создана." -Level Info } catch { Write-Log "Критическая ошибка: Не удалось создать папку для файлов результатов '$outputResultsPath': $($_.Exception.Message). Offline режим не может быть запущен." -Level Error; if ($Host.Name -eq "ConsoleHost") { Read-Host "Нажмите Enter для выхода" }; exit 1 } }
    $offlineCycleIntervalSec = 0
    if ($script:Config.PSObject.Properties.Name -contains 'offline_cycle_interval_seconds' -and $script:Config.offline_cycle_interval_seconds -ne $null) { $parsedInterval = 0; if ([int]::TryParse($script:Config.offline_cycle_interval_seconds.ToString(), [ref]$parsedInterval) -and $parsedInterval -ge 0) { $offlineCycleIntervalSec = $parsedInterval } else { Write-Log "Некорректное значение 'offline_cycle_interval_seconds' ('$($script:Config.offline_cycle_interval_seconds)'). Используется однократный запуск (0 сек)." -Level Warn } }
    $runOfflineContinuously = ($offlineCycleIntervalSec -gt 0)
    if ($runOfflineContinuously) { Write-Log ("Offline режим: Запуск в циклическом режиме с интервалом $offlineCycleIntervalSec сек между полными циклами проверок.") -Level Info }
    else { Write-Log "Offline режим: Запуск в однократном режиме (выполнит один цикл проверок и завершится)." -Level Info }
    do {
        $offlineCycleStartTime = [DateTimeOffset]::UtcNow
        Write-Log "Начало цикла/запуска Offline режима ($($offlineCycleStartTime.ToString('s')))." -Level Info
        $latestAssignmentConfigFileInfo = $null; $assignmentFileReadError = $null; $newAssignmentsData = $null
        try {
            $assignmentFilePattern = $script:Config.assignments_file_path_pattern
            Write-Log ("Поиск файла конфигурации заданий в '$assignmentsFolderPathForCheck' по шаблону '$assignmentFilePattern'...") -Level Debug
            $foundAssignmentFiles = Get-ChildItem -Path $assignmentFilePattern -File -ErrorAction SilentlyContinue
            if ($Error.Count -gt 0 -and $Error[0].CategoryInfo.Category -eq 'ReadError') { throw ("Ошибка доступа при поиске файла конфигурации в '$assignmentsFolderPathForCheck': " + $Error[0].Exception.Message) }
            $Error.Clear()
            if ($foundAssignmentFiles.Count -gt 0) { $latestAssignmentConfigFileInfo = $foundAssignmentFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1; Write-Log "Найден последний файл конфигурации заданий: '$($latestAssignmentConfigFileInfo.FullName)' (Дата изменения: $($latestAssignmentConfigFileInfo.LastWriteTime))." -Level Verbose }
            else { Write-Log "Файлы конфигурации заданий по шаблону '$assignmentFilePattern' в '$assignmentsFolderPathForCheck' не найдены." -Level Warn }
        } catch { $assignmentFileReadError = "Ошибка при поиске файла конфигурации заданий: $($_.Exception.Message)"; Write-Log $assignmentFileReadError -Level Error }
        if ($null -ne $latestAssignmentConfigFileInfo -and $null -eq $assignmentFileReadError) {
            if (($latestAssignmentConfigFileInfo.FullName -ne $script:LastProcessedConfigFileFullNameOffline) -or ($latestAssignmentConfigFileInfo.LastWriteTime -gt $script:LastConfigFileWriteTimeOffline)) {
                Write-Log "Обнаружен новый или обновленный файл конфигурации заданий: '$($latestAssignmentConfigFileInfo.Name)'. Попытка чтения..." -Level Info
                try {
                    $fileJsonContent = Get-Content -Path $latestAssignmentConfigFileInfo.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                    $newAssignmentsData = $fileJsonContent | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $newAssignmentsData) { throw "ConvertFrom-Json вернул `$null после чтения файла '$($latestAssignmentConfigFileInfo.Name)'." }
                    if (-not ($newAssignmentsData.PSObject.Properties.Name -contains 'assignments' -and $newAssignmentsData.assignments -is [array]) -or -not ($newAssignmentsData.PSObject.Properties.Name -contains 'assignment_config_version' -and (-not [string]::IsNullOrWhiteSpace($newAssignmentsData.assignment_config_version))) ) { throw ("Файл '$($latestAssignmentConfigFileInfo.Name)' имеет некорректную структуру JSON.") }
                    $tempConfigVersion = $newAssignmentsData.assignment_config_version; $tempAssignmentsArray = $newAssignmentsData.assignments
                    Write-Log ("Файл конфигурации '$($latestAssignmentConfigFileInfo.Name)' успешно прочитан. Версия конфига: '$tempConfigVersion'. Количество заданий: $($tempAssignmentsArray.Count).") -Level Info
                    $script:CurrentAssignmentsOffline = @($tempAssignmentsArray | ForEach-Object { [PSCustomObject]$_ }); $script:CurrentConfigVersionOffline = $tempConfigVersion; $script:LastProcessedConfigFileFullNameOffline = $latestAssignmentConfigFileInfo.FullName; $script:LastConfigFileWriteTimeOffline = $latestAssignmentConfigFileInfo.LastWriteTime
                    Write-Log "Список заданий для Offline режима обновлен." -Level Info
                } catch { $fileProcessingErrorMsg = "Критическая ошибка при чтении или обработке файла конфигурации '$($latestAssignmentConfigFileInfo.Name)': $($_.Exception.Message)"; Write-Log $fileProcessingErrorMsg -Level Error; $prevConfVersionToLog1 = if (-not [string]::IsNullOrWhiteSpace($script:CurrentConfigVersionOffline)) { $script:CurrentConfigVersionOffline } else { '[неизвестно]' }; Write-Log ("Продолжаем использовать предыдущий список заданий (если он был). Версия предыдущего конфига: '$prevConfVersionToLog1'.") -Level Warn; $newAssignmentsData = $null }
            } else { Write-Log "Файл конфигурации заданий '$($latestAssignmentConfigFileInfo.Name)' не изменился с момента последней обработки. Используется текущий список заданий." -Level Verbose }
        } elseif ($null -ne $assignmentFileReadError) { Write-Log "Из-за ошибки поиска файла конфигурации, продолжаем использовать предыдущий список заданий (если он был)." -Level Warn }
          elseif ($null -ne $script:LastProcessedConfigFileFullNameOffline) { $prevConfVersionToLog2 = if (-not [string]::IsNullOrWhiteSpace($script:CurrentConfigVersionOffline)) { $script:CurrentConfigVersionOffline } else { '[неизвестно]' }; Write-Log "Новые файлы конфигурации заданий не найдены. Продолжаем использовать предыдущий список заданий (из '$($script:LastProcessedConfigFileFullNameOffline)', версия '$prevConfVersionToLog2')." -Level Warn }
          else { Write-Log "Файлы конфигурации заданий не найдены, и нет ранее загруженного списка. Задания не будут выполнены в этом цикле." -Level Info }
        $currentCycleResultsList = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $script:CurrentAssignmentsOffline -and $script:CurrentAssignmentsOffline.Count -gt 0) {
            $totalAssignmentsInCurrentConfig = $script:CurrentAssignmentsOffline.Count; $confVersionToLogForRun = if (-not [string]::IsNullOrWhiteSpace($script:CurrentConfigVersionOffline)) { $script:CurrentConfigVersionOffline } else { 'N/A' }; Write-Log ("Начало выполнения $totalAssignmentsInCurrentConfig заданий из Offline конфигурации (Версия конфига: '$confVersionToLogForRun')...") -Level Info
            $completedAssignmentCount = 0
            foreach ($assignmentToExecuteOfflineRaw in $script:CurrentAssignmentsOffline) {
                $completedAssignmentCount++; $currentOfflineAssignment = $null; $currentOfflineAssignmentId = "[N/A_ID]"; $currentOfflineMethodName = "[unknown_method]"; $currentOfflineNodeName = "[unknown_node]"
                try {
                     $currentOfflineAssignment = [PSCustomObject]$assignmentToExecuteOfflineRaw
                     if ($null -eq $currentOfflineAssignment -or -not ($currentOfflineAssignment.PSObject.Properties.Name -contains 'assignment_id' -and $null -ne $currentOfflineAssignment.assignment_id) -or -not ($currentOfflineAssignment.PSObject.Properties.Name -contains 'method_name' -and (-not [string]::IsNullOrWhiteSpace($currentOfflineAssignment.method_name))) ) { throw "Некорректная структура задания." }
                     $currentOfflineAssignmentId = $currentOfflineAssignment.assignment_id.ToString(); $currentOfflineMethodName = $currentOfflineAssignment.method_name
                     if ($currentOfflineAssignment.PSObject.Properties.Name -contains 'node_name' -and (-not [string]::IsNullOrWhiteSpace($currentOfflineAssignment.node_name))) { $currentOfflineNodeName = $currentOfflineAssignment.node_name } else { $currentOfflineNodeName = "Задание_ID_$currentOfflineAssignmentId" }
                     Write-Log ("Выполнение задания $completedAssignmentCount/$totalAssignmentsInCurrentConfig (ID: $currentOfflineAssignmentId, Метод: $currentOfflineMethodName, Узел: '$currentOfflineNodeName')...") -Level Verbose
                     $checkExecutionResultOffline = Invoke-StatusMonitorCheck -Assignment $currentOfflineAssignment
                     if ($null -eq $checkExecutionResultOffline -or -not $checkExecutionResultOffline.PSObject.Properties.Name -contains 'IsAvailable') { throw "Invoke-StatusMonitorCheck вернул некорректный результат." }
                     $errorMessageForLogOffline = ""; if (-not [string]::IsNullOrEmpty($checkExecutionResultOffline.ErrorMessage)) { $maxErrLengthOffline = 100; if ($checkExecutionResultOffline.ErrorMessage.Length -gt $maxErrLengthOffline) { $errorMessageForLogOffline = $checkExecutionResultOffline.ErrorMessage.Substring(0, $maxErrLengthOffline) + "..." } else { $errorMessageForLogOffline = $checkExecutionResultOffline.ErrorMessage } }
                     $logMessageForResultOffline = "Результат ID ${currentOfflineAssignmentId}: IsAvailable=$($checkExecutionResultOffline.IsAvailable), CheckSuccess="; if ($null -eq $checkExecutionResultOffline.CheckSuccess) { $logMessageForResultOffline += "[null], " } else { $logMessageForResultOffline += "$($checkExecutionResultOffline.CheckSuccess), " }; $logMessageForResultOffline += "Error='$errorMessageForLogOffline'"; Write-Log $logMessageForResultOffline -Level Verbose
                     $resultToSaveInZrpu = @{ assignment_id = $currentOfflineAssignment.assignment_id } + $checkExecutionResultOffline; $currentCycleResultsList.Add($resultToSaveInZrpu)
                } catch { $assignmentProcessingErrorMsg = "Ошибка ID $currentOfflineAssignmentId ($currentOfflineMethodName, '$currentOfflineNodeName'): $($_.Exception.Message)"; Write-Log $assignmentProcessingErrorMsg -Level Error; $errorDetailsForZrpu = @{ ErrorDescription="Локальная ошибка агента"; OriginalNodeName=$currentOfflineNodeName; OriginalMethodName=$currentOfflineMethodName; ExceptionMessage=$_.Exception.Message; ErrorRecordString=$_.ToString(); OriginalAssignmentSnippet=($currentOfflineAssignment|ConvertTo-Json -Depth 2 -Compress -WA SilentlyContinue) }; $errorResultBaseForZrpu = New-CheckResultObject -IsAvailable $false -ErrorMessage $assignmentProcessingErrorMsg -Details $errorDetailsForZrpu; $errorResultToSaveInZrpu = @{ assignment_id=$currentOfflineAssignmentId } + $errorResultBaseForZrpu; $currentCycleResultsList.Add($errorResultToSaveInZrpu) }
            }
            Write-Log "Выполнение $totalAssignmentsInCurrentConfig заданий завершено. Собрано результатов: $($currentCycleResultsList.Count)." -Level Info
        } else { Write-Log "Нет активных заданий для выполнения в Offline режиме." -Level Verbose }
        if ($currentCycleResultsList.Count -gt 0) {
             $timestampForFileName = Get-Date -Format "ddMMyy_HHmmss"; $outputFileNameTemplate = $script:Config.output_name_template; $outputFileNameGenerated = $outputFileNameTemplate -replace "{object_id}", $script:Config.object_id -replace "{ddMMyy_HHmmss}", $timestampForFileName; $outputFileNameCleaned = $outputFileNameGenerated -replace '[\\/:*?"<>|]', '_'; $outputFileFullPath = Join-Path -Path $outputResultsPath -ChildPath $outputFileNameCleaned; $tempOutputFileFullPath = $outputFileFullPath + ".tmp"
             $confVersionForLogPayload = if (-not [string]::IsNullOrWhiteSpace($script:CurrentConfigVersionOffline)) { $script:CurrentConfigVersionOffline } else { 'N/A' }
             Write-Log ("Сохранение $($currentCycleResultsList.Count) результатов в: '$outputFileFullPath'") -Level Info; Write-Log ("Версия агента: $script:AgentVersion. Версия конфига: '$confVersionForLogPayload'. ObjectID: $($script:Config.object_id).") -Level Verbose
             $finalPayloadForZrpu = @{ agent_script_version = $script:AgentVersion; assignment_config_version = $script:CurrentConfigVersionOffline; object_id = $script:Config.object_id; execution_timestamp_utc = $offlineCycleStartTime.ToString("o"); results = $currentCycleResultsList }
             try { $jsonToSaveToFile = $finalPayloadForZrpu | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue; $utf8EncodingNoBom = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllText($tempOutputFileFullPath, $jsonToSaveToFile, $utf8EncodingNoBom); Write-Log "Данные записаны во временный файл." -Level Debug; Move-Item -Path $tempOutputFileFullPath -Destination $outputFileFullPath -Force -ErrorAction Stop; Write-Log "Файл '$outputFileNameCleaned' успешно сохранен." -Level Info }
             catch { Write-Log ("Критическая ошибка сохранения файла '$outputFileFullPath': $($_.Exception.Message)") -Level Error; if (Test-Path $tempOutputFileFullPath -PathType Leaf) { try { Remove-Item -Path $tempOutputFileFullPath -Force -ErrorAction SilentlyContinue } catch {} } }
        } else { Write-Log "Нет результатов для сохранения." -Level Verbose }
        if ($runOfflineContinuously) {
            $offlineCycleEndTime = [DateTimeOffset]::UtcNow; $elapsedSecondsInCycle = ($offlineCycleEndTime - $offlineCycleStartTime).TotalSeconds; $sleepDurationSeconds = $offlineCycleIntervalSec - $elapsedSecondsInCycle
            if ($sleepDurationSeconds -lt 1) { Write-Log ("Итерация заняла {0:N2} сек (>= интервала {1} сек). Пауза 1 сек." -f $elapsedSecondsInCycle, $offlineCycleIntervalSec) -Level Warn; $sleepDurationSeconds = 1 }
            else { Write-Log ("Итерация заняла {0:N2} сек. Пауза {1:N2} сек..." -f $elapsedSecondsInCycle, $sleepDurationSeconds) -Level Verbose }
            Start-Sleep -Seconds $sleepDurationSeconds
        }
    } while ($runOfflineContinuously)
    $offlineCompletionReason = if ($runOfflineContinuously) { 'цикл прерван' } else { 'однократный запуск завершен' }
    Write-Log ("Offline режим завершен ({0})." -f $offlineCompletionReason) -Level Info; exit 0
} else {
     Write-Log "Критическая ошибка: Неизвестный режим работы '$($script:Config.mode)'." -Level Error; exit 1
}
Write-Log "Агент завершает работу непредвиденно." -Level Error; exit 1