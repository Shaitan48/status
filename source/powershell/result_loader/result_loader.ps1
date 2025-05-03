# powershell/result_loader/result_loader.ps1
# Загрузчик результатов оффлайн-агентов v3.18 (исправления -f через интерполяцию)
# Исправлены ошибки ParameterBindingException путем замены оператора -f на строковую интерполяцию.
<#
.SYNOPSIS
    Обрабатывает файлы *.zrpu от оффлайн-агентов
    и отправляет данные пакетом в API Status Monitor (v3.18).
.DESCRIPTION
    Скрипт-загрузчик результатов. Выполняется на машине, имеющей
    доступ как к папке с результатами от оффлайн-агентов (`check_folder`),
    так и к API сервера мониторинга (`api_base_url`).

    Принцип работы:
    1. Читает параметры конфигурации из 'config.json'.
    2. В бесконечном цикле с интервалом (`scan_interval_seconds`):
       a. Сканирует `check_folder` на наличие файлов `*_OfflineChecks.json.status*.zrpu`.
       b. Для каждого найденного файла:
          i.   Читает и парсит JSON.
          ii.  Проверяет базовую структуру (наличие `results`, `agent_script_version`, `assignment_config_version`).
          iii. Если файл валиден и содержит результаты:
               - Формирует тело Bulk-запроса (весь распарсенный JSON).
               - Отправляет ОДИН POST-запрос на `/api/v1/checks/bulk`, используя функцию `Invoke-ApiRequestWithRetry`.
          iv.  Анализирует ответ от Bulk API (`status`, `processed`, `failed`, `errors`).
          v.   Определяет итоговый статус обработки файла (`success`, `partial_error`, `error_api`, `error_local`).
          vi.  Отправляет событие `FILE_PROCESSED` в API `/api/v1/events` с деталями обработки.
          vii. Перемещает обработанный файл в подпапку `Processed` или `Error`.
       c. Если файлов нет, ждет.
    3. Ждет `scan_interval_seconds` и повторяет цикл.
    4. Логирует все действия.
.PARAMETER ConfigFile
    [string] Путь к файлу конфигурации загрузчика (JSON).
    По умолчанию: "$PSScriptRoot\config.json".
# ... (остальные параметры для переопределения) ...
.EXAMPLE
    # Запуск с конфигом по умолчанию
    .\result_loader.ps1
.NOTES
    Версия: 3.18
    Дата: 2025-05-02
    Изменения v3.18:
        - Исправлены ошибки ParameterBindingException путем замены оператора -f на строковую интерполяцию в Invoke-ApiRequestWithRetry.
    # ... (предыдущая история изменений) ...
    Зависимости: PowerShell 5.1+, Сетевой доступ к API, Права доступа к папке check_folder.
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\config.json",
    # --- Параметры для переопределения конфига ---
    [string]$apiBaseUrl = $null,
    [string]$apiKey = $null,
    [string]$checkFolder = $null,
    [string]$logFile = $null,
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
    [string]$LogLevel = $null,
    [int]$ScanIntervalSeconds = $null,
    [int]$ApiTimeoutSeconds = $null,
    [int]$MaxApiRetries = $null,
    [int]$RetryDelaySeconds = $null
)

# --- Глобальные переменные и константы ---
$ScriptVersion = "3.18" # Обновляем версию
$script:Config = $null
$script:EffectiveLogLevel = "Info"
$script:logFilePath = $null
$script:ComputerName = $env:COMPUTERNAME
$DefaultLogLevel = "Info"; $DefaultScanInterval = 30; $DefaultApiTimeout = 30; $DefaultMaxRetries = 3; $DefaultRetryDelay = 5;
$ValidLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error");
$script:EffectiveApiKey = $null

# --- Функции ---

#region Функции

<#
.SYNOPSIS Пишет сообщение в лог и/или консоль.
#>
function Write-Log{
    param ( [Parameter(Mandatory=$true)][string]$Message, [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)][string]$Level = "Info" )
    # ... (код функции Write-Log без изменений) ...
    if (-not $script:logFilePath) { Write-Host "[$Level] $Message"; return }
    $logLevels=@{"Debug"=4;"Verbose"=3;"Info"=2;"Warn"=1;"Error"=0}; $currentLevelValue=$logLevels[$script:EffectiveLogLevel]; if($null -eq $currentLevelValue){ $currentLevelValue = $logLevels["Info"] }; $messageLevelValue=$logLevels[$Level]; if($null -eq $messageLevelValue){ $messageLevelValue = $logLevels["Info"] };
    if ($messageLevelValue -le $currentLevelValue) { $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage = "[$timestamp] [$Level] [$($script:ComputerName)] - $Message"; $consoleColor = switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}; Write-Host $logMessage -ForegroundColor $consoleColor; if ($script:logFilePath) { try { $logDir = Split-Path $script:logFilePath -Parent; if ($logDir -and (-not(Test-Path $logDir -PathType Container))) { Write-Host "[INFO] Создание папки логов: '$logDir'"; New-Item -Path $logDir -ItemType Directory -Force -EA Stop | Out-Null }; Add-Content -Path $script:logFilePath -Value $logMessage -Encoding UTF8 -Force -EA Stop } catch { Write-Host ("[Error] Не удалось записать в лог '{0}': {1}" -f $script:logFilePath, $_.Exception.Message) -ForegroundColor Red } } }

}

<#
.SYNOPSIS Возвращает значение по умолчанию, если исходное пустое.
#>
filter Get-OrElse_Internal{ param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }

<#
.SYNOPSIS Выполняет HTTP-запрос к API с логикой повторных попыток.
#>
function Invoke-ApiRequestWithRetry {
    param(
        [Parameter(Mandatory=$true)] [string]$Uri,
        [Parameter(Mandatory=$true)] [string]$Method,
        [Parameter(Mandatory=$false)]$Body = $null,
        [Parameter(Mandatory=$true)] [hashtable]$Headers, # Включая X-API-Key
        [Parameter(Mandatory=$true)] [string]$Description
    )

    $retryCount = 0
    $response = $null
    $currentMaxRetries = $script:EffectiveMaxApiRetries | Get-OrElse_Internal $DefaultMaxRetries
    $currentTimeoutSec = $script:EffectiveApiTimeoutSeconds | Get-OrElse_Internal $DefaultApiTimeout
    $currentRetryDelay = $script:EffectiveRetryDelaySeconds | Get-OrElse_Internal $DefaultRetryDelay

    $invokeParams = @{ Uri = $Uri; Method = $Method; Headers = $Headers; TimeoutSec = $currentTimeoutSec; ErrorAction = 'Stop' }
    if ($Body -ne $null -and $Method -notin @('GET', 'DELETE')) {
        if ($Body -is [array] -and $Body.Count -gt 0 -and $Body[0] -is [byte]) { $invokeParams.Body = $Body }
        elseif ($Body -is [string]) { $invokeParams.Body = [System.Text.Encoding]::UTF8.GetBytes($Body) }
        else { $invokeParams.Body = $Body }
        if (-not $invokeParams.Headers.ContainsKey('Content-Type')) { $invokeParams.Headers.'Content-Type' = 'application/json; charset=utf-8' }
    }

    while ($retryCount -lt $currentMaxRetries -and $response -eq $null) {
        try {
            Write-Log ("Выполнение запроса ({0}): {1} {2}" -f $Description, $Method, $Uri) -Level Verbose
            if ($invokeParams.Body) {
                 if ($invokeParams.Body -is [array] -and $invokeParams.Body[0] -is [byte]) { Write-Log "Тело (байты): $($invokeParams.Body.Count) bytes" -Level Debug }
                 else { Write-Log "Тело: $($invokeParams.Body | Out-String -Width 500)..." -Level Debug }
            }

            $response = Invoke-RestMethod @invokeParams

            if ($null -eq $response -and $? -and ($Error.Count -eq 0)) {
                 Write-Log ("API вернул успешный ответ без тела (вероятно, 204 No Content) для ({0})." -f $Description) -Level Verbose
                 return $true
            }
            Write-Log ("Успешный ответ API ({0})." -f $Description) -Level Verbose
            return $response

        } catch {
            $retryCount++
            $statusCode = $null; if ($_.Exception.Response) { try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {} }; $errorMessage = $_.Exception.Message;
            $errorResponseBody = "[Не удалось прочитать тело ошибки]"; if ($_.Exception.Response) { try { $errorStream = $_.Exception.Response.GetResponseStream(); $reader = New-Object System.IO.StreamReader($errorStream); $errorResponseBody = $reader.ReadToEnd(); $reader.Close(); $errorStream.Dispose() } catch { } };
            # <<<< ИСПРАВЛЕНО: Используем СТРОКОВУЮ ИНТЕРПОЛЯЦИЮ >>>>
            Write-Log "Ошибка API ($Description) (Попытка $retryCount/$currentMaxRetries). Код: $($statusCode | Get-OrElse_Internal 'N/A'). Error: $($errorMessage.Replace('{','{{').Replace('}','}}')). Ответ: $($errorResponseBody.Replace('{','{{').Replace('}','}}'))" "Error"

            if ($statusCode -eq 401 -or $statusCode -eq 403) { Write-Log ("Критическая ошибка аутентификации/авторизации ({0}). Проверьте API ключ и его роль ('loader'). Завершение работы." -f $Description) -Level Error; exit 1 };
            if ($retryCount -ge $currentMaxRetries) {
                 # <<<< ИСПРАВЛЕНО: Используем СТРОКОВУЮ ИНТЕРПОЛЯЦИЮ >>>>
                 Write-Log "Превышено кол-во попыток ($currentMaxRetries) для ($Description)." -Level Error;
                 return $null
            };
            Write-Log ("Пауза $currentRetryDelay сек перед повторной попыткой...") "Warn"; Start-Sleep -Seconds $currentRetryDelay
        }
    } # Конец while
    return $null
}

#endregion Функции

# --- Основная логика ---

# 1. Чтение и валидация конфигурации
Write-Host "Запуск загрузчика результатов PowerShell v$ScriptVersion"
Write-Log "Чтение конфигурации..." "Info"
# ... (код чтения конфига без изменений) ...
if (Test-Path $ConfigFile -PathType Leaf) {
    try { $script:Config = Get-Content $ConfigFile -Raw -Enc UTF8 | ConvertFrom-Json -EA Stop }
    catch { Write-Log ("Ошибка чтения/парсинга JSON из '{0}': {1}. Используются параметры по умолчанию/командной строки." -f $ConfigFile, $_.Exception.Message) "Error" }
} else { Write-Log ("Файл конфигурации '{0}' не найден. Используются параметры по умолчанию/командной строки." -f $ConfigFile) "Warn" }
$EffectiveApiBaseUrl = $apiBaseUrl | Get-OrElse_Internal $script:Config.api_base_url
$script:EffectiveApiKey = $apiKey | Get-OrElse_Internal $script:Config.api_key
$EffectiveCheckFolder = $checkFolder | Get-OrElse_Internal $script:Config.check_folder
$EffectiveLogFile = $logFile | Get-OrElse_Internal ($script:Config.log_file | Get-OrElse_Internal "$PSScriptRoot\result_loader.log")
$EffectiveLogLevel = $LogLevel | Get-OrElse_Internal ($script:Config.log_level | Get-OrElse_Internal $DefaultLogLevel)
$EffectiveScanIntervalSeconds = $ScanIntervalSeconds | Get-OrElse_Internal ($script:Config.scan_interval_seconds | Get-OrElse_Internal $DefaultScanInterval)
$EffectiveApiTimeoutSeconds = $ApiTimeoutSeconds | Get-OrElse_Internal ($script:Config.api_timeout_sec | Get-OrElse_Internal $DefaultApiTimeout)
$EffectiveMaxApiRetries = $MaxApiRetries | Get-OrElse_Internal ($script:Config.max_api_retries | Get-OrElse_Internal $DefaultMaxRetries)
$EffectiveRetryDelaySeconds = $RetryDelaySeconds | Get-OrElse_Internal ($script:Config.retry_delay_sec | Get-OrElse_Internal $DefaultRetryDelay)
$script:logFilePath = $EffectiveLogFile
$script:EffectiveLogLevel = $EffectiveLogLevel
if (-not $ValidLogLevels.Contains($script:EffectiveLogLevel)) { Write-Log ("Некорректный LogLevel '{0}'. Используется '{1}'." -f $script:EffectiveLogLevel, $DefaultLogLevel) "Warn"; $script:EffectiveLogLevel = $DefaultLogLevel }
if (-not $EffectiveApiBaseUrl) { Write-Log "Критическая ошибка: Не задан 'api_base_url'." "Error"; exit 1 }; if (-not $script:EffectiveApiKey) { Write-Log "Критическая ошибка: Не задан 'api_key'." "Error"; exit 1 }; if (-not $EffectiveCheckFolder) { Write-Log "Критическая ошибка: Не задан 'check_folder'." "Error"; exit 1 }
if ($EffectiveScanIntervalSeconds -lt 5) { Write-Log "ScanIntervalSeconds < 5. Установлено 5 сек." "Warn"; $EffectiveScanIntervalSeconds = 5 }
if ($EffectiveApiTimeoutSeconds -le 0) { $EffectiveApiTimeoutSeconds = $DefaultApiTimeout }; if ($EffectiveMaxApiRetries -lt 0) { $EffectiveMaxApiRetries = $DefaultMaxRetries }; if ($EffectiveRetryDelaySeconds -lt 0) { $EffectiveRetryDelaySeconds = $DefaultRetryDelay }
$script:EffectiveScanIntervalSeconds = $EffectiveScanIntervalSeconds; $script:EffectiveApiTimeoutSeconds = $EffectiveApiTimeoutSeconds; $script:EffectiveMaxApiRetries = $EffectiveMaxApiRetries; $script:EffectiveRetryDelaySeconds = $EffectiveRetryDelaySeconds


# 2. Подготовка окружения
Write-Log "Инициализация загрузчика." "Info"
Write-Log ("Параметры: API='{0}', Папка='{1}', Интервал={2} сек, Лог='{3}', Уровень='{4}'" -f $EffectiveApiBaseUrl, $EffectiveCheckFolder, $script:EffectiveScanIntervalSeconds, $script:logFilePath, $script:EffectiveLogLevel) "Info"
$apiKeyPart = "[не задан]"; if($script:EffectiveApiKey){ $l=$script:EffectiveApiKey.Length; $p=$script:EffectiveApiKey.Substring(0,[math]::Min(4,$l)); $s=if($l -gt 8){$script:EffectiveApiKey.Substring($l-4,4)}else{""}; $apiKeyPart="$p....$s" }; Write-Log "API ключ (частично): $apiKeyPart" "Debug"
if (-not (Test-Path $EffectiveCheckFolder -PathType Container)) { Write-Log "Критическая ошибка: Папка для сканирования '$($EffectiveCheckFolder)' не существует." "Error"; exit 1 };
$processedFolder = Join-Path $EffectiveCheckFolder "Processed"; $errorFolder = Join-Path $EffectiveCheckFolder "Error"; foreach ($folder in @($processedFolder, $errorFolder)) { if (-not (Test-Path $folder -PathType Container)) { Write-Log "Создание папки: $folder" "Info"; try { New-Item -Path $folder -ItemType Directory -Force -EA Stop | Out-Null } catch { Write-Log ("Критическая ошибка: Не удалось создать папку '{0}'. Ошибка: {1}" -f $folder, $_.Exception.Message) "Error"; exit 1 } } }


# --- 3. Основной цикл сканирования и обработки ---
Write-Log "Начало цикла сканирования папки '$($EffectiveCheckFolder)'..." "Info"
while ($true) {
    Write-Log "Сканирование папки..." "Verbose"
    $filesToProcess = @()
    try {
        $resultsFileFilter = "*_OfflineChecks.json.status*.zrpu"
        $filesToProcess = Get-ChildItem -Path $EffectiveCheckFolder -Filter $resultsFileFilter -File -ErrorAction Stop
    } catch {
        # <<<< ИСПРАВЛЕНО: Используем интерполяцию >>>>
        Write-Log "Критическая ошибка доступа к папке '$EffectiveCheckFolder': $($_.Exception.Message). Пропуск итерации." "Error";
        Start-Sleep -Seconds $script:EffectiveScanIntervalSeconds; continue
    }

    if ($filesToProcess.Count -eq 0) { Write-Log "Нет файлов *.zrpu для обработки." "Verbose" }
    else {
        Write-Log "Найдено файлов для обработки: $($filesToProcess.Count)." "Info"
        # --- Обработка каждого файла ---
        foreach ($file in $filesToProcess) {
            $fileStartTime = Get-Date; Write-Log "--- Начало обработки файла: '$($file.FullName)' ---" "Info"
            $fileProcessingStatus = "unknown"; $fileProcessingMessage = ""; $fileEventDetails = @{}; $apiResponse = $null;

            try {
                # --- Чтение и парсинг файла ---
                Write-Log "Чтение файла '$($file.Name)'..." "Debug"
                $fileContent = Get-Content -Path $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $fileContentClean = $fileContent.TrimStart([char]0xFEFF)
                $payloadFromFile = $fileContentClean | ConvertFrom-Json -ErrorAction Stop
                Write-Log "Файл '$($file.Name)' успешно прочитан и распарсен." "Debug"

                # --- Валидация структуры файла ---
                if ($null -eq $payloadFromFile -or -not $payloadFromFile.PSObject.Properties.Name.Contains('results') -or $payloadFromFile.results -isnot [array] -or -not $payloadFromFile.PSObject.Properties.Name.Contains('agent_script_version') -or -not $payloadFromFile.PSObject.Properties.Name.Contains('assignment_config_version')) {
                     # <<<< ИСПРАВЛЕНО: Используем интерполяцию в throw >>>>
                    throw "Некорректная структура JSON файла '$($file.Name)'. Отсутствуют обязательные поля."
                }
                $resultsArray = $payloadFromFile.results
                $fileAgentVersion = $payloadFromFile.agent_script_version | Get-OrElse_Internal "[не указана]"
                $fileAssignmentVersion = $payloadFromFile.assignment_config_version | Get-OrElse_Internal "[не указана]"
                $totalRecordsInFile = $resultsArray.Count
                # <<<< ИСПРАВЛЕНО: Форматируем строку ДО вызова Write-Log >>>>
                $logMsgFileRead = "Файл '{0}' содержит записей: {1}. AgentVer: '{2}', ConfigVer: '{3}'" -f $file.Name, $totalRecordsInFile, $fileAgentVersion, $fileAssignmentVersion
                Write-Log $logMsgFileRead "Info"

                if ($totalRecordsInFile -eq 0) {
                    # <<<< ИСПРАВЛЕНО: Форматируем строку ДО вызова Write-Log >>>>
                    Write-Log ("Файл '{0}' не содержит записей в массиве 'results'. Файл будет перемещен в Processed." -f $file.Name) "Warn"
                    $fileProcessingStatus = "success_empty"
                    $fileProcessingMessage = "Обработка файла завершена (пустой массив results)."
                    $fileEventDetails = @{ total_records_in_file = 0; agent_version_in_file = $fileAgentVersion; assignment_version_in_file = $fileAssignmentVersion }
                } else {
                    # --- Отправка Bulk запроса ---
                    $apiUrlBulk = "$EffectiveApiBaseUrl/v1/checks/bulk"
                    $jsonBodyToSend = $null
                    try {
                         $jsonBodyToSend = $payloadFromFile | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
                    } catch {
                        # <<<< ИСПРАВЛЕНО: Используем интерполяцию в throw >>>>
                        throw "Ошибка сериализации данных файла '$($file.Name)' в JSON: $($_.Exception.Message)"
                    }
                    $headersForBulk = @{ 'Content-Type' = 'application/json; charset=utf-8'; 'X-API-Key' = $script:EffectiveApiKey }
                    $bulkApiParams = @{ Uri = $apiUrlBulk; Method = 'Post'; Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBodyToSend); Headers = $headersForBulk; Description = "Отправка Bulk из файла '$($file.Name)' ($totalRecordsInFile записей)" }
                    Write-Log ("Отправка Bulk запроса для файла '$($file.Name)' ({0} записей)..." -f $totalRecordsInFile) -Level Info
                    $apiResponse = Invoke-ApiRequestWithRetry @bulkApiParams

                    # Обработка ответа Bulk API
                    if ($apiResponse -eq $null) {
                        $fileProcessingStatus = "error_api"
                        $fileProcessingMessage = "Ошибка отправки Bulk запроса в API после всех попыток."
                        $fileEventDetails.error = "API request failed after retries."; $fileEventDetails.api_response_status = $null
                    } else {
                        $processed = $apiResponse.processed | Get-OrElse_Internal 0; $failed = $apiResponse.failed | Get-OrElse_Internal 0; $apiStatus = $apiResponse.status | Get-OrElse_Internal "unknown"
                        if ($apiStatus -eq "success") { $fileProcessingStatus = "success"; $fileProcessingMessage = "Пакетная обработка файла успешно завершена API. Обработано: $processed." }
                        elseif ($apiStatus -eq "partial_error") { $fileProcessingStatus = "partial_error"; $fileProcessingMessage = "Пакетная обработка файла завершена API с ошибками. Успешно: $processed, Ошибки: $failed."; $fileEventDetails.api_errors = $apiResponse.errors }
                        else { $fileProcessingStatus = "error_api_response"; $fileProcessingMessage = "API вернул статус '$apiStatus' при пакетной обработке. Успешно: $processed, Ошибки: $failed."; $fileEventDetails.error = "API processing error status: $apiStatus"; $fileEventDetails.api_errors = $apiResponse.errors }
                        $fileEventDetails.api_response_status = $apiStatus; $fileEventDetails.api_processed_count = $processed; $fileEventDetails.api_failed_count = $failed
                        $fileEventDetails.total_records_in_file = $totalRecordsInFile; $fileEventDetails.agent_version_in_file = $fileAgentVersion; $fileEventDetails.assignment_version_in_file = $fileAssignmentVersion
                    }
                    # --- Конец Bulk запроса ---
                } # Конец else ($totalRecordsInFile -eq 0)

            } catch { # Обработка ошибок чтения/парсинга файла
                $errorMessage = "Критическая ошибка обработки файла '$($file.FullName)': $($_.Exception.Message)"
                Write-Log $errorMessage "Error"
                $fileProcessingStatus = "error_local"
                $fileProcessingMessage = "Ошибка чтения или парсинга JSON файла."
                $fileEventDetails = @{ error = $errorMessage; ErrorRecord = $_.ToString() }
            }

            # --- Отправка события FILE_PROCESSED ---
            $fileEndTime = Get-Date; $processingTimeMs = ($fileEndTime - $fileStartTime).TotalMilliseconds;
            $fileLogSeverity = "INFO"; if ($fileProcessingStatus -like "error*") { $fileLogSeverity = "ERROR" } elseif ($fileProcessingStatus -eq "partial_error") { $fileLogSeverity = "WARN" }
            $fileEventDetails.processing_time_ms = [math]::Round($processingTimeMs)
            if ($fileProcessingStatus -eq "error_event") { $fileEventDetails.event_sending_error = $true }

            $fileEventBody = @{ event_type = "FILE_PROCESSED"; severity = $fileLogSeverity; message = $fileProcessingMessage; source = "result_loader.ps1 (v$ScriptVersion)"; related_entity = "FILE"; related_entity_id = $file.Name; details = $fileEventDetails }
            $fileEventJsonBody = $fileEventBody | ConvertTo-Json -Compress -Depth 5 -WarningAction SilentlyContinue;
            $apiUrlEvents = "$EffectiveApiBaseUrl/v1/events";
            $headersForEvent = @{ 'Content-Type' = 'application/json; charset=utf-8'; 'X-API-Key' = $script:EffectiveApiKey }
            $eventApiParams = @{ Uri = $apiUrlEvents; Method = 'Post'; Body = [System.Text.Encoding]::UTF8.GetBytes($fileEventJsonBody); Headers = $headersForEvent; Description = "Отправка события FILE_PROCESSED для '$($file.Name)'" }

            Write-Log ("Отправка события FILE_PROCESSED для '$($file.Name)' (Статус: $fileProcessingStatus)...") "Info"
            $eventResponse = Invoke-ApiRequestWithRetry @eventApiParams

            if ($eventResponse -eq $null) {
                 Write-Log ("Не удалось отправить событие FILE_PROCESSED для '$($file.Name)'. Помечаем статус как 'error_event'.") "Error";
                 $fileProcessingStatus = "error_event"
            } else {
                $eventId = if ($eventResponse -is [PSCustomObject] -and $eventResponse.PSObject.Properties.Name.Contains('event_id')) { $eventResponse.event_id } else { '(id ?)' };
                Write-Log ("Событие FILE_PROCESSED для '$($file.Name)' отправлено. Event ID: $eventId") "Info"
            }

            # --- Перемещение файла ---
            $destinationFolder = if ($fileProcessingStatus -like "success*") { $processedFolder } else { $errorFolder };
            $destinationPath = Join-Path $destinationFolder $file.Name;
            # <<<< ИСПРАВЛЕНО: Форматируем строку ДО вызова Write-Log >>>>
            $moveLogMsg = "Перемещение '{0}' в '{1}' (Итоговый статус: {2})." -f $file.Name, $destinationFolder, $fileProcessingStatus
            Write-Log $moveLogMsg "Info";
            try {
                Move-Item -Path $file.FullName -Destination $destinationPath -Force -ErrorAction Stop;
                Write-Log ("Файл '$($file.Name)' успешно перемещен.") "Info"
            } catch {
                 # <<<< ИСПРАВЛЕНО: Форматируем строку ДО вызова Write-Log >>>>
                 Write-Log ("КРИТИЧЕСКАЯ ОШИБКА перемещения файла '{0}' в '{1}'. Файл может быть обработан повторно! Ошибка: {2}" -f $file.Name, $destinationPath, $_.Exception.Message) "Error";
            }

            Write-Log "--- Завершение обработки файла: '$($file.FullName)' ---" "Info"

        } # Конец foreach ($file in $filesToProcess)
    } # Конец else ($filesToProcess.Count -eq 0)

    # --- Пауза перед следующим сканированием ---
    Write-Log "Пауза $script:EffectiveScanIntervalSeconds сек перед следующим сканированием..." "Verbose"
    Start-Sleep -Seconds $script:EffectiveScanIntervalSeconds

} # --- Конец while ($true) ---

Write-Log "Загрузчик результатов завершил работу непредвиденно (выход из цикла while)." "Error"
exit 1