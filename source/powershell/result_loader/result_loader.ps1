# powershell/result_loader/result_loader.ps1
# --- Загрузчик Результатов v4.2.3 ---
# Изменения:
# - Исправлен регистр ключей 'IsAvailable' и 'Timestamp' при формировании payload для API.
# - (Остальные изменения из v4.2.2 сохранены)

<#
.SYNOPSIS
    Обрабатывает файлы *.zrpu от оффлайн-агентов и отправляет данные
    массивом на унифицированный API эндпоинт /api/v1/checks/bulk (v4.2.3).
.DESCRIPTION
    Скрипт-загрузчик результатов оффлайн мониторинга.
    (Описание без изменений)
.PARAMETER ConfigFile
    [string] Путь к файлу конфигурации загрузчика (JSON).
    По умолчанию: "$PSScriptRoot\config.json".
.NOTES
    Версия: 4.2.3
    Дата: [Актуальная Дата]
    Зависимости: PowerShell 5.1+, Сетевой доступ к API, Права доступа к папкам.
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\config.json",
    [string]$apiBaseUrlOverride = $null,
    [string]$apiKeyOverride = $null,
    [string]$checkFolderOverride = $null,
    [string]$logFileOverride = $null,
    [string]$logLevelOverride = $null
)

# --- 1. Глобальные переменные и константы ---
$ScriptVersion = "4.2.3" # Обновляем версию
$script:Config = $null
$script:EffectiveLogLevel = "Info"
$script:LogFilePath = $null
$script:ComputerName = $env:COMPUTERNAME
$DefaultLogLevel = "Info"; $DefaultScanInterval = 30; $DefaultApiTimeout = 60;
$DefaultMaxRetries = 3; $DefaultRetryDelay = 5;
$ValidLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error");
$script:EffectiveApiKey = $null

# --- 2. Функции ---
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
        $logLine = "[$timestamp] [$Level] [$($script:ComputerName)] - $Message"
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
                    $fallbackLogPath = Join-Path -Path $PSScriptRoot -ChildPath "result_loader_fallback.log"
                    Add-Content -Path $fallbackLogPath -Value $logLine -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                    Add-Content -Path $fallbackLogPath -Value "[CRITICAL] FAILED TO WRITE TO '$($script:LogFilePath)': $($_.Exception.Message)" -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                } catch {}
            }
        }
    }
}

filter Get-OrElse {
    param([object]$DefaultValue)
    if ($null -ne $_ -and (($_ -isnot [string]) -or (-not [string]::IsNullOrWhiteSpace($_)))) { $_ } else { $DefaultValue }
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
    $currentTry = 0; $responseObject = $null
    $maxRetries = $script:Config.max_api_retries | Get-OrElse $DefaultMaxRetries
    $timeoutSec = $script:Config.api_timeout_sec | Get-OrElse $DefaultApiTimeout
    $retryDelaySec = $script:Config.retry_delay_seconds | Get-OrElse $DefaultRetryDelay

    $invokeParams = @{ Uri = $Uri; Method = $Method.ToUpper(); Headers = $Headers; TimeoutSec = $timeoutSec; ErrorAction = 'Stop' }
    if ($null -ne $BodyObject -and $invokeParams.Method -notin @('GET', 'DELETE', 'HEAD', 'OPTIONS')) {
        try {
            $jsonBody = $BodyObject | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
            $invokeParams.ContentType = 'application/json; charset=utf-8'
            $invokeParams.Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
            Write-Log "Тело запроса для ($Description) (длина: $($invokeParams.Body.Length) байт): $jsonBody" -Level Debug
        } catch {
            Write-Log "Критическая ошибка ConvertTo-Json для ($Description): $($_.Exception.Message)" -Level Error
            throw "Ошибка преобразования тела запроса в JSON для операции '$Description'."
        }
    }

    while ($currentTry -lt $maxRetries) {
        $currentTry++
        try {
            Write-Log ("Выполнение запроса ({0}) (Попытка {1}/{2}): {3} {4}" -f $Description, $currentTry, $maxRetries, $invokeParams.Method, $Uri) -Level Verbose
            $responseObject = Invoke-RestMethod @invokeParams
            Write-Log ("Успешный ответ API ({0})." -f $Description) -Level Verbose
            return $responseObject
        } catch [System.Net.WebException] {
            $webException = $_.Exception
            $httpStatusCode = $null; $errorResponseBodyText = "[Не удалось прочитать тело ответа на ошибку]"
            if ($webException.Response -ne $null) {
                try { $httpStatusCode = [int]$webException.Response.StatusCode } catch {}
                try {
                    $errorResponseStream = $webException.Response.GetResponseStream()
                    $streamReader = New-Object System.IO.StreamReader($errorResponseStream)
                    $errorResponseBodyText = $streamReader.ReadToEnd(); $streamReader.Close(); $errorResponseStream.Dispose()
                    try { $errorJsonObj = $errorResponseBodyText | ConvertFrom-Json; $errorResponseBodyText = ($errorJsonObj | ConvertTo-Json -Depth 3 -Compress) } catch {}
                } catch {}
            }
            $errorMessageCleaned = $webException.Message.Replace('{','{{').Replace('}','}}')
            $httpStatusCodeForLog = if ($null -eq $httpStatusCode) { 'N/A' } else { $httpStatusCode.ToString() }

            Write-Log ("Ошибка API ({0}) (Попытка {1}/{2}). HTTP Код: {3}. Сообщение: {4}. Ответ сервера (если есть): {5}" -f `
                $Description, $currentTry, $maxRetries, $httpStatusCodeForLog, $errorMessageCleaned, $errorResponseBodyText) -Level Error
            if ($httpStatusCode -ge 400 -and $httpStatusCode -lt 500 -and $httpStatusCode -ne 429) {
                Write-Log ("Критическая ошибка API ({0} - Код {1}), повторные попытки отменены." -f $Description, $httpStatusCodeForLog) -Level Error
                throw $webException
            }
            if ($currentTry -ge $maxRetries) {
                Write-Log ("Превышено максимальное количество попыток ({0}) для ({1})." -f $maxRetries, $Description) -Level Error
                throw $webException
            }
            Write-Log ("Пауза $retryDelaySec сек перед следующей попыткой...") -Level Warn
            Start-Sleep -Seconds $retryDelaySec
        } catch {
            Write-Log ("Неожиданная ошибка при выполнении API запроса ({0}) (Попытка {1}/{2}): {3}" -f `
                $Description, $currentTry, $maxRetries, ($_.Exception.Message.Replace('{','{{').Replace('}','}}'))) -Level Error
            throw $_.Exception
        }
    }
    Write-Log ("Не удалось выполнить API запрос ($Description) после $maxRetries попыток, результат `$null.") -Level Error
    return $null
}
#endregion Функции

# --- 3. Основная логика ---
Write-Host "Запуск Загрузчика Результатов PowerShell v$ScriptVersion"
Write-Log "Чтение конфигурации из '$ConfigFile'..." "Info"
if (-not (Test-Path $ConfigFile -PathType Leaf)) { Write-Log "Критическая ошибка: Файл конфигурации '$ConfigFile' не найден." -Level Error; exit 1 }
try { $script:Config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Log "Критическая ошибка: Ошибка чтения/парсинга JSON из '$ConfigFile': $($_.Exception.Message)" -Level Error; exit 1 }
$effectiveConfig = $script:Config.PSObject.Copy()
if ($apiBaseUrlOverride) { $effectiveConfig.api_base_url = $apiBaseUrlOverride }
if ($apiKeyOverride) { $effectiveConfig.api_key = $apiKeyOverride }
if ($checkFolderOverride) { $effectiveConfig.check_folder = $checkFolderOverride }
if ($logFileOverride) { $effectiveConfig.log_file = $logFileOverride }
if ($logLevelOverride) { $effectiveConfig.log_level = $logLevelOverride }
$script:Config = [PSCustomObject]$effectiveConfig
$requiredFields = @("api_base_url", "api_key", "check_folder", "log_file", "log_level", "processed_folder", "error_folder", "unrecoverable_error_folder", "scan_interval_seconds", "max_api_retries", "retry_delay_seconds", "api_timeout_sec")
$missingFields = $requiredFields | Where-Object { -not ($script:Config.PSObject.Properties.Name -contains $_) -or $null -eq $script:Config.$_ -or (($script:Config.$_ -is [string]) -and ([string]::IsNullOrWhiteSpace($script:Config.$_))) }
if ($missingFields.Count -gt 0) { Write-Log ("Критическая ошибка: В конфигурации отсутствуют или пусты обязательные поля: $($missingFields -join ', ')") -Level Error; exit 1 }
$script:LogFilePath = $script:Config.log_file
$script:EffectiveLogLevel = $script:Config.log_level
if ($script:EffectiveLogLevel -notin $ValidLogLevels) { Write-Log "Некорректный LogLevel '$($script:EffectiveLogLevel)'. Используется '$DefaultLogLevel'." -Level Warn; $script:EffectiveLogLevel = $DefaultLogLevel }
$script:EffectiveApiKey = $script:Config.api_key
$checkFolder = $script:Config.check_folder
$processedFolder = $script:Config.processed_folder
$errorFolder = $script:Config.error_folder
$unrecoverableFolder = $script:Config.unrecoverable_error_folder
$foldersToCheck = @($checkFolder, $processedFolder, $errorFolder, $unrecoverableFolder)
foreach ($folder in $foldersToCheck) { if (-not (Test-Path $folder -PathType Container)) { Write-Log "Папка '$folder' не найдена. Попытка создать..." -Level Warn; try { New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "Папка '$folder' создана." -Level Info } catch { Write-Log "Критическая ошибка: Не удалось создать папку '$folder': $($_.Exception.Message)" -Level Error; exit 1 } } }
$scanInterval = $script:Config.scan_interval_seconds | Get-OrElse $DefaultScanInterval
if (-not ($scanInterval -is [int] -and $scanInterval -ge 5)) { Write-Log "Некорректный scan_interval_seconds. Используется $DefaultScanInterval." -Warn; $scanInterval = $DefaultScanInterval }
Write-Log "Инициализация загрузчика v$ScriptVersion завершена." -Level Info
Write-Log ("Параметры: API='{0}', Папка='{1}', Интервал={2} сек, Лог='{3}', Уровень='{4}'" -f $script:Config.api_base_url, $checkFolder, $scanInterval, $script:LogFilePath, $script:EffectiveLogLevel) -Level Info

# --- 4. Основной цикл сканирования и обработки ---
Write-Log "Начало цикла сканирования папки '$checkFolder'..." -Level Info
while ($true) {
    Write-Log "Сканирование папки '$checkFolder'..." -Level Verbose
    $filesToProcess = @()
    try {
        $resultsFileFilter = "*.zrpu"
        $filesToProcess = Get-ChildItem -Path $checkFolder -Filter $resultsFileFilter -File -ErrorAction Stop
    } catch {
        Write-Log ("Критическая ошибка доступа к папке '$checkFolder': $($_.Exception.Message). Пропуск итерации.") -Level Error
        Start-Sleep -Seconds $scanInterval; continue
    }

    if ($filesToProcess.Count -eq 0) {
        Write-Log "Нет файлов *.zrpu для обработки." -Level Verbose
    } else {
        Write-Log "Найдено файлов для обработки: $($filesToProcess.Count)." -Level Info

        foreach ($file in $filesToProcess) {
            $fileStartTime = [DateTimeOffset]::UtcNow
            Write-Log "--- Начало обработки файла: '$($file.FullName)' ---" -Level Info
            $fileProcessingStatus = "unknown"
            $fileProcessingMessage = ""
            $fileEventDetails = @{ file_name = $file.Name }
            $apiResponseForChecks = $null
            $payloadArrayForApi = $null
            $totalRecordsInFile = 0
            $fileAgentVersion = "[неизвестно]"; $fileAssignmentVersion = "[неизвестно]"; $fileObjectId = "[неизвестно]"
            $finalDestinationFolder = $errorFolder

            try {
                Write-Log "Чтение файла '$($file.Name)'..." -Level Debug
                $fileContent = Get-Content -Path $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $payloadFromFile = $fileContent | ConvertFrom-Json -ErrorAction Stop
                Write-Log "Файл '$($file.Name)' успешно прочитан и распарсен." -Level Debug

                if ($null -eq $payloadFromFile `
                    -or (-not $payloadFromFile.PSObject.Properties.Name -contains 'results')) {
                    throw "Некорректная структура JSON файла '$($file.Name)' (отсутствует ключ 'results')."
                }
                if ($payloadFromFile.PSObject.Properties.Name -contains 'results' -and $payloadFromFile.results -isnot [array]) {
                     throw "Ключ 'results' в файле '$($file.Name)' не является массивом."
                }
                if (-not $payloadFromFile.PSObject.Properties.Name -contains 'agent_script_version' `
                    -or -not $payloadFromFile.PSObject.Properties.Name -contains 'assignment_config_version' `
                    -or -not $payloadFromFile.PSObject.Properties.Name -contains 'object_id') {
                    throw "Отсутствуют обязательные мета-поля (agent_script_version, assignment_config_version, object_id) в файле '$($file.Name)'."
                }

                $resultsArray = if ($payloadFromFile.results) { @($payloadFromFile.results) } else { @() }
                $fileAgentVersion = $payloadFromFile.agent_script_version | Get-OrElse "[не указана]"
                $fileAssignmentVersion = $payloadFromFile.assignment_config_version | Get-OrElse "[не указана]"
                $fileObjectId = $payloadFromFile.object_id
                $fileEventDetails.agent_version_in_file = $fileAgentVersion
                $fileEventDetails.assignment_version_in_file = $fileAssignmentVersion
                $fileEventDetails.source_object_id_in_file = $fileObjectId
                $totalRecordsInFile = $resultsArray.Count
                $fileEventDetails.total_records_in_file = $totalRecordsInFile
                Write-Log ("Файл '{0}' содержит записей: {1}. AgentVer: '{2}', ConfigVer: '{3}', SourceOID: {4}" `
                    -f $file.Name, $totalRecordsInFile, $fileAgentVersion, $fileAssignmentVersion, $fileObjectId) -Level Info

                if ($totalRecordsInFile -gt 0) {
                    $payloadArrayForApi = [System.Collections.Generic.List[object]]::new()
                    $skippedCountDueToFormatError = 0
                    
                    foreach ($resRaw in $resultsArray) {
                        $res = [PSCustomObject]$resRaw
                        $itemProperties = $res.PSObject.Properties.Name

                        $hasAssignmentId = $itemProperties -contains 'assignment_id'
                        $hasIsAvailable  = $itemProperties -contains 'IsAvailable'
                        $hasTimestamp    = $itemProperties -contains 'Timestamp'
                        
                        if ($res -ne $null `
                            -and $hasAssignmentId -and $res.assignment_id -ne $null `
                            -and $hasIsAvailable  -and $res.IsAvailable -ne $null `
                            -and $hasTimestamp    -and $res.Timestamp -ne $null) {

                            $assignment_id_val = $res.assignment_id
                            $is_available_val  = $res.IsAvailable
                            $timestamp_val     = $res.Timestamp
                            
                            $details_val       = if ($itemProperties -contains 'Details')      { $res.Details }      else { @{} }
                            $check_success_val = if ($itemProperties -contains 'CheckSuccess') { $res.CheckSuccess } else { $null }
                            $error_message_val = if ($itemProperties -contains 'ErrorMessage') { $res.ErrorMessage } else { "" }

                            if ($null -eq $details_val -or -not ($details_val -is [hashtable] -or $details_val -is [System.Management.Automation.PSCustomObject])) {
                                $details_val = @{}
                            } elseif ($details_val -is [System.Management.Automation.PSCustomObject]) {
                                $tempDetailsHashtable = @{}
                                $details_val.PSObject.Properties | ForEach-Object { $tempDetailsHashtable[$_.Name] = $_.Value }
                                $details_val = $tempDetailsHashtable
                            }

                            # --- ИСПРАВЛЕНИЕ РЕГИСТРА КЛЮЧЕЙ ДЛЯ API ---
                            $payloadItem = @{
                                assignment_id        = $assignment_id_val      # snake_case (ожидается API)
                                IsAvailable          = [bool]$is_available_val  # PascalCase (ожидается API)
                                Timestamp            = $timestamp_val           # PascalCase (ожидается API)
                                detail_type          = $null
                                detail_data          = $details_val
                                agent_script_version = $fileAgentVersion
                                assignment_config_version = $fileAssignmentVersion
                                executor_object_id   = $fileObjectId
                                executor_host        = $null
                                resolution_method    = 'offline_loader'
                            }
                            # --- КОНЕЦ ИСПРАВЛЕНИЯ РЕГИСТРА ---
                            
                            if ($null -ne $check_success_val) {
                               $payloadItem.detail_data.CheckSuccessFromAgent = [bool]$check_success_val
                            }
                            if (-not [string]::IsNullOrEmpty($error_message_val)) {
                               $payloadItem.detail_data.ErrorMessageFromAgentCheck = $error_message_val
                            }
                            $payloadArrayForApi.Add($payloadItem)
                        } else {
                            $skippedCountDueToFormatError++
                            $missingFieldsLog = @()
                            if (-not $hasAssignmentId -or ($hasAssignmentId -and $res.assignment_id -eq $null)) { $missingFieldsLog += "assignment_id" }
                            if (-not $hasIsAvailable  -or ($hasIsAvailable -and $res.IsAvailable -eq $null))  { $missingFieldsLog += "IsAvailable" }
                            if (-not $hasTimestamp    -or ($hasTimestamp -and $res.Timestamp -eq $null))    { $missingFieldsLog += "Timestamp" }
                            Write-Log ("Пропущен некорректный элемент в файле '{0}' (индекс {1}): отсутствует или null одно из обязательных полей ({2}). Данные: {3}" `
                                -f $file.Name, 
                                   ($payloadArrayForApi.Count + $skippedCountDueToFormatError - 1), 
                                   ($missingFieldsLog -join ', '), 
                                   ($resRaw | ConvertTo-Json -Depth 2 -Compress -WarningAction SilentlyContinue)) -Level Warn
                        }
                    }

                    if ($skippedCountDueToFormatError -gt 0) {
                        $fileProcessingMessage = "Записей в файле: $totalRecordsInFile. Пропущено из-за ошибок формата: $skippedCountDueToFormatError."
                        $fileProcessingStatus = "partial_error_local"
                        $fileEventDetails.skipped_format_error = $skippedCountDueToFormatError
                    }
                    if ($payloadArrayForApi.Count -eq 0 -and $totalRecordsInFile -gt 0) {
                         throw "Все $totalRecordsInFile записи в файле '$($file.Name)' некорректны, нечего отправлять."
                    } elseif ($payloadArrayForApi.Count -eq 0 -and $totalRecordsInFile -eq 0) {
                         $fileProcessingStatus = "success_empty"
                         $fileProcessingMessage = "Файл '$($file.Name)' пуст (массив 'results' не содержит элементов)."
                    }
                } else {
                    $fileProcessingStatus = "success_empty"
                    $fileProcessingMessage = "Файл '$($file.Name)' пуст (массив 'results' не содержит элементов)."
                }

                if ($payloadArrayForApi -ne $null -and $payloadArrayForApi.Count -gt 0) {
                    $apiUrlChecks = "$($script:Config.api_base_url.TrimEnd('/'))/v1/checks/bulk"
                    $headersForChecks = @{ 'X-API-Key' = $script:EffectiveApiKey }
                    # Передаем массив $payloadArrayForApi как значение ключа "results"
                    $apiBodyForBulk = @{ results = $payloadArrayForApi }
                    $apiParamsForChecks = @{ Uri = $apiUrlChecks; Method = 'Post'; BodyObject = $apiBodyForBulk; Headers = $headersForChecks; Description = "Отправка {$($payloadArrayForApi.Count)} результатов из файла '$($file.Name)'" }
                    Write-Log ("Отправка $($payloadArrayForApi.Count) результатов из файла '$($file.Name)' на $apiUrlChecks...") -Level Info
                    $apiResponseForChecks = Invoke-ApiRequestWithRetry @apiParamsForChecks
                    if ($apiResponseForChecks -ne $null) {
                        $processedApi = $apiResponseForChecks.processed | Get-OrElse 0
                        $failedApi = $apiResponseForChecks.failed | Get-OrElse 0
                        $statusApi = $apiResponseForChecks.status | Get-OrElse "unknown"
                        $apiErrorsList = $apiResponseForChecks.errors
                        Write-Log ("Ответ API для файла '$($file.Name)': Статус='{0}', Обработано={1}, Ошибки API={2}" -f $statusApi, $processedApi, $failedApi) -Level Info
                        if ($apiErrorsList) { Write-Log "Детали ошибок API: $($apiErrorsList | ConvertTo-Json -Depth 3 -Compress -WarningAction SilentlyContinue)" -Level Warn }
                        $fileEventDetails.api_status = $statusApi; $fileEventDetails.api_processed = $processedApi; $fileEventDetails.api_failed = $failedApi
                        if ($apiErrorsList) { $fileEventDetails.api_errors = $apiErrorsList }
                        if ($statusApi -eq "success" -and $failedApi -eq 0) { $fileProcessingStatus = "success"; $fileProcessingMessage += " Успешно обработано API: $processedApi." }
                        else { $fileProcessingStatus = "error_api"; $fileProcessingMessage += " Обработано API: $processedApi, Ошибки API: $failedApi." }
                    } else { $fileProcessingStatus = "error_api"; $fileProcessingMessage += " Ошибка отправки результатов в API после всех попыток."; $fileEventDetails.error = "API request to /checks/bulk failed after retries." }
                } elseif ($fileProcessingStatus -eq "success_empty") {
                     Write-Log ($fileProcessingMessage) -Level Info
                }
            } catch {
                $errorMessageText = "Критическая локальная ошибка обработки файла '$($file.FullName)': $($_.Exception.Message)"
                Write-Log $errorMessageText -Level Error
                $fileProcessingStatus = "error_local"
                $fileProcessingMessage = "Ошибка чтения, парсинга JSON или валидации структуры файла."
                $fileEventDetails.error = $errorMessageText
                $fileEventDetails.ErrorRecord = $_.ToString()
            }

            $fileEndTime = [DateTimeOffset]::UtcNow
            $processingTimeMs = ($fileEndTime - $fileStartTime).TotalSeconds * 1000
            $fileEventDetails.processing_time_ms = [math]::Round($processingTimeMs)
            $eventSeverity = "INFO"; if ($fileProcessingStatus -like "error*") { $eventSeverity = "ERROR" } elseif ($fileProcessingStatus -like "partial_error*") { $eventSeverity = "WARN" }
            $eventBody = @{ event_type = "FILE_PROCESSED"; severity = $eventSeverity; message = $fileProcessingMessage | Get-OrElse ("Обработка файла '{0}' завершена со статусом '{1}'." -f $file.Name, $fileProcessingStatus); source = "result_loader.ps1 (v$ScriptVersion)"; related_entity = "ZRPU_FILE"; related_entity_id = $file.Name; details = $fileEventDetails }
            $eventApiResponse = $null; $eventSentSuccessfully = $false
            try {
                 $eventApiUrl = "$($script:Config.api_base_url.TrimEnd('/'))/v1/events"; $eventHeaders = @{ 'X-API-Key' = $script:EffectiveApiKey }; $eventApiParams = @{ Uri=$eventApiUrl; Method='Post'; BodyObject=$eventBody; Headers=$eventHeaders; Description="Отправка события FILE_PROCESSED для '$($file.Name)'"}
                 Write-Log ("Отправка события FILE_PROCESSED для '{0}' (Статус файла: {1})..." -f $file.Name, $fileProcessingStatus) -Level Info
                 $eventApiResponse = Invoke-ApiRequestWithRetry @eventApiParams
                 if ($eventApiResponse -ne $null -and $eventApiResponse.status -eq 'success') { Write-Log ("Событие FILE_PROCESSED для '{0}' успешно отправлено (EventID: {1})." -f $file.Name, ($eventApiResponse.event_id | Get-OrElse '?')) -Level Info; $eventSentSuccessfully = $true }
                 else { throw ("API не вернул 'success' при отправке события. Ответ: $($eventApiResponse | ConvertTo-Json -Depth 2 -Compress)") }
            } catch { Write-Log ("Критическая ошибка отправки события FILE_PROCESSED для '{0}': {1}" -f $file.Name, $_.Exception.Message) -Level Error; if ($fileProcessingStatus -notlike "error*") { $fileProcessingStatus = "error_event" } }
            switch ($fileProcessingStatus) { "success" { $finalDestinationFolder = $processedFolder }; "success_empty" { $finalDestinationFolder = $processedFolder }; "error_local" { $finalDestinationFolder = $errorFolder }; "partial_error_local" { $finalDestinationFolder = $errorFolder }; "error_api" { $finalDestinationFolder = $unrecoverableFolder }; "error_event" { $finalDestinationFolder = $unrecoverableFolder }; default { $finalDestinationFolder = $errorFolder } }
            if ($fileProcessingStatus -eq "success" -and (-not $eventSentSuccessfully)) { Write-Log "Результаты были успешно отправлены в API, но событие FILE_PROCESSED не удалось отправить. Перемещение файла в DLQ." "Warn"; $finalDestinationFolder = $unrecoverableFolder }
            $destinationPath = Join-Path $finalDestinationFolder $file.Name; $tempDestinationPath = Join-Path $finalDestinationFolder ($file.BaseName + ".tmp" + $file.Extension)
            Write-Log ("Перемещение файла '{0}' в '{1}' (Итоговый статус: {2}, Событие отправлено: {3})..." -f $file.Name, $finalDestinationFolder, $fileProcessingStatus, $eventSentSuccessfully) -Level Info
            try { Copy-Item -Path $file.FullName -Destination $tempDestinationPath -Force -ErrorAction Stop; Remove-Item -Path $file.FullName -Force -ErrorAction Stop; Move-Item -Path $tempDestinationPath -Destination $destinationPath -Force -ErrorAction Stop; Write-Log ("Файл '{0}' успешно перемещен (атомарно)." -f $file.Name) -Level Info }
            catch { Write-Log ("КРИТИЧЕСКАЯ ОШИБКА атомарного перемещения файла '{0}' в '{1}'. Ошибка: {2}. Попытка простого перемещения..." -f $file.Name, $destinationPath, $_.Exception.Message) -Level Error; try { if (Test-Path $file.FullName -PathType Leaf) { Move-Item -Path $file.FullName -Destination $destinationPath -Force -ErrorAction SilentlyContinue } } catch { Write-Log "Простое перемещение также не удалось: $($_.Exception.Message)" -Level Error }; if (Test-Path $tempDestinationPath -PathType Leaf) { try { Remove-Item $tempDestinationPath -Force -EA SilentlyContinue } catch {} } }
            Write-Log "--- Завершение обработки файла: '$($file.FullName)' ---" -Level Info
        }
    }

    Write-Log "Пауза $scanInterval сек перед следующим сканированием..." -Level Verbose
    Start-Sleep -Seconds $scanInterval
}

Write-Log "Загрузчик результатов завершил работу непредвиденно (выход из цикла while)." "Error"
exit 1