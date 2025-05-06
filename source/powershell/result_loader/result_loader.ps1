# powershell/result_loader/result_loader.ps1
# --- Загрузчик Результатов v4.2 ---
# Изменения:
# - Удалена опция и логика use_bulk_api.
# - Всегда отправляет массив результатов на POST /api/v1/checks.
# - Добавлена папка unrecoverable_error_folder (DLQ) для ошибок API.
# - Улучшено атомарное перемещение файлов.
# - Убрана зависимость от PowerShell v5.1 (он и так был совместим).

<#
.SYNOPSIS
    Обрабатывает файлы *.zrpu от оффлайн-агентов и отправляет данные
    массивом на унифицированный API эндпоинт /api/v1/checks (v4.2).
.DESCRIPTION
    Скрипт-загрузчик результатов оффлайн мониторинга.
    1. Читает конфигурацию из 'config.json'.
    2. Циклически сканирует `check_folder` на наличие *.zrpu файлов.
    3. Для каждого файла:
       - Читает и парсит JSON. При ошибке - перемещает в `error_folder`.
       - Извлекает метаданные и массив 'results'.
       - Формирует payload (массив объектов для API), добавляя метаданные
         из файла в КАЖДЫЙ элемент массива.
       - Отправляет ВЕСЬ payload ОДНИМ запросом на `POST /api/v1/checks`.
       - Обрабатывает ответ API (200/207).
       - Отправляет событие `FILE_PROCESSED` в API.
       - Атомарно перемещает файл:
         - В `processed_folder` при полном успехе.
         - В `unrecoverable_error_folder` при ошибках API (включая 207)
           или ошибке отправки события.
         - В `error_folder` при локальных ошибках (парсинг).
.PARAMETER ConfigFile
    [string] Путь к файлу конфигурации загрузчика (JSON).
    По умолчанию: "$PSScriptRoot\config.json".
.NOTES
    Версия: 4.2
    Дата: [Актуальная Дата]
    Зависимости: PowerShell 5.1+, Сетевой доступ к API, Права доступа к папкам.
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\config.json",
    # Параметры для переопределения конфига (можно убрать, если не нужны)
    [string]$apiBaseUrlOverride = $null,
    [string]$apiKeyOverride = $null,
    [string]$checkFolderOverride = $null,
    [string]$logFileOverride = $null,
    [string]$logLevelOverride = $null
)

# --- 1. Глобальные переменные и константы ---
$ScriptVersion = "4.2" # Обновляем версию
$script:Config = $null
$script:EffectiveLogLevel = "Info"
$script:LogFilePath = $null
$script:ComputerName = $env:COMPUTERNAME
$DefaultLogLevel = "Info"; $DefaultScanInterval = 30; $DefaultApiTimeout = 30; $DefaultMaxRetries = 3; $DefaultRetryDelay = 5;
$ValidLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error");
$script:EffectiveApiKey = $null

# --- 2. Функции ---

#region Функции

<#
.SYNOPSIS Пишет сообщение в лог и/или консоль. (Код без изменений от Hybrid)
#>
function Write-Log {
    param( [Parameter(Mandatory=$true)][string]$Message, [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)][string]$Level = "Info" )
    $logLevels=@{"Debug"=4;"Verbose"=3;"Info"=2;"Warn"=1;"Error"=0}; $currentLevelValue=$logLevels[$script:EffectiveLogLevel]; if($null -eq $currentLevelValue){ $currentLevelValue = $logLevels["Info"] }; $messageLevelValue=$logLevels[$Level]; if($null -eq $messageLevelValue){ $messageLevelValue = $logLevels["Info"] };
    if ($messageLevelValue -le $currentLevelValue) { $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage = "[$timestamp] [$Level] [$($script:ComputerName)] - $Message"; $consoleColor = switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}; Write-Host $logMessage -ForegroundColor $consoleColor; if ($script:LogFilePath) { try { $logDir = Split-Path $script:LogFilePath -Parent; if ($logDir -and (-not(Test-Path $logDir -PathType Container))) { Write-Host "[INFO] Создание папки логов: '$logDir'"; New-Item -Path $logDir -ItemType Directory -Force -EA Stop | Out-Null }; Add-Content -Path $script:LogFilePath -Value $logMessage -Encoding UTF8 -Force -EA Stop } catch { Write-Host ("[Error] Не удалось записать в лог '{0}': {1}" -f $script:LogFilePath, $_.Exception.Message) -ForegroundColor Red } } }
}

<#
.SYNOPSIS Возвращает значение по умолчанию, если исходное пустое. (Код без изменений от Hybrid)
#>
filter Get-OrElse {
    param([object]$DefaultValue)
    if ($null -ne $_ -and (($_ -isnot [string]) -or (-not [string]::IsNullOrWhiteSpace($_)))) { $_ } else { $DefaultValue }
}

<#
.SYNOPSIS Выполняет HTTP-запрос к API с логикой повторных попыток. (Код без изменений от Hybrid)
#>
function Invoke-ApiRequestWithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$false)]$BodyObject = $null,
        [Parameter(Mandatory=$true)][hashtable]$Headers,
        [Parameter(Mandatory=$true)][string]$Description
    )
    $retryCount=0; $responseObject=$null; $maxRetries=$script:Config.max_api_retries | Get-OrElse 3; $timeoutSec=$script:Config.api_timeout_sec | Get-OrElse 60; $retryDelaySec=$script:Config.retry_delay_seconds | Get-OrElse 5;
    $invokeParams=@{Uri=$Uri; Method=$Method; Headers=$Headers; TimeoutSec=$timeoutSec; ErrorAction='Stop'}; if($BodyObject -ne $null -and $Method.ToUpper() -notin @('GET','DELETE')){ try{ $jsonBody = $BodyObject | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue; $invokeParams.ContentType = 'application/json; charset=utf-8'; $invokeParams.Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBody); Write-Log "Тело запроса для ($Description): $jsonBody" -Level Debug } catch { Write-Log "Критическая ошибка ConvertTo-Json для ($Description): $($_.Exception.Message)" -Level Error; throw "Ошибка преобразования тела запроса в JSON." } }
    while($retryCount -lt $maxRetries -and $responseObject -eq $null){ try{ Write-Log ("Выполнение запроса ({0}) (Попытка {1}/{2}): {3} {4}" -f $Description,($retryCount+1),$maxRetries,$Method,$Uri) -Level Verbose; $responseObject = Invoke-RestMethod @invokeParams; Write-Log ("Успешный ответ API ({0})." -f $Description) -Level Verbose; return $responseObject } catch [System.Net.WebException]{ $retryCount++; $exception=$_.Exception; $statusCode=$null; $errorResponseBody="[Не удалось прочитать тело ошибки]"; if($exception.Response -ne $null){ try{ $statusCode = [int]$exception.Response.StatusCode } catch {}; try{ $errorStream = $exception.Response.GetResponseStream(); $reader=New-Object System.IO.StreamReader($errorStream); $errorResponseBody = $reader.ReadToEnd(); $reader.Close(); $errorStream.Dispose(); try{ $errorJson=$errorResponseBody|ConvertFrom-Json; $errorResponseBody=$errorJson }catch{} }catch{} }; $errorMessage=$exception.Message.Replace('{','{{').Replace('}','}}'); $errorDetails=$errorResponseBody; Write-Log ("Ошибка API ({0}) (Попытка {1}/{2}). Код: {3}. Error: {4}. Ответ: {5}" -f $Description,$retryCount,$maxRetries,($statusCode|Get-OrElse 'N/A'),$errorMessage,($errorDetails|Out-String -Width 300)) -Level Error; if($statusCode -in @(400,401,403,404,409,422)){ Write-Log ("Критическая ошибка API ({0} - Код {1}), повторные попытки отменены." -f $Description,$statusCode) -Level Error; throw $exception }; if($retryCount -ge $maxRetries){ Write-Log ("Превышено кол-во попыток ({0}) для ({1})." -f $maxRetries,$Description) -Level Error; throw $exception }; Write-Log ("Пауза $retryDelaySec сек перед повторной попыткой...") -Level Warn; Start-Sleep -Seconds $retryDelaySec } catch { $retryCount++; $errorMessage=$_.Exception.Message.Replace('{','{{').Replace('}','}}'); Write-Log ("Неожиданная ошибка ({0}) (Попытка {1}/{2}): {3}" -f $Description,$retryCount,$maxRetries,$errorMessage) -Level Error; throw $_.Exception } }; return $null
}

#endregion Функции

# --- 3. Основная логика ---

# 3.1 Чтение и валидация конфигурации
Write-Host "Запуск Загрузчика Результатов PowerShell v$ScriptVersion"
Write-Log "Чтение конфигурации..." "Info"
if (-not (Test-Path $ConfigFile -PathType Leaf)) { Write-Log "Критическая ошибка: Файл конфигурации '$ConfigFile' не найден." -Level Error; exit 1 }
try { $script:Config = Get-Content $ConfigFile -Raw -Enc UTF8 | ConvertFrom-Json -EA Stop } catch { Write-Log "Критическая ошибка: Ошибка чтения/парсинга JSON из '$ConfigFile': $($_.Exception.Message)" -Level Error; exit 1 }

# Переопределение из параметров командной строки (если нужно)
$effectiveConfig = $script:Config.PSObject.Copy() # Копируем для изменений
if ($apiBaseUrlOverride) { $effectiveConfig.api_base_url = $apiBaseUrlOverride }
if ($apiKeyOverride) { $effectiveConfig.api_key = $apiKeyOverride }
if ($checkFolderOverride) { $effectiveConfig.check_folder = $checkFolderOverride }
if ($logFileOverride) { $effectiveConfig.log_file = $logFileOverride }
if ($logLevelOverride) { $effectiveConfig.log_level = $logLevelOverride }
$script:Config = [PSCustomObject]$effectiveConfig # Обновляем глобальный конфиг

# Валидация ОБЯЗАТЕЛЬНЫХ полей (убрали use_bulk_api)
$requiredFields = @(
    "api_base_url", "api_key", "check_folder", "log_file", "log_level",
    "processed_folder", "error_folder", "unrecoverable_error_folder", # Добавили папки
    "scan_interval_seconds", "max_api_retries", "retry_delay_seconds"
)
$missingFields = $requiredFields | Where-Object { -not ($script:Config.PSObject.Properties.Name -contains $_) -or $null -eq $script:Config.$_ -or (($script:Config.$_ -is [string]) -and ([string]::IsNullOrWhiteSpace($script:Config.$_))) }
if ($missingFields) { Write-Log ("Критическая ошибка: В конфигурации отсутствуют или пусты обязательные поля: $($missingFields -join ', ')") -Level Error; exit 1 }

# Установка лог-файла и уровня
$script:LogFilePath = $script:Config.log_file
$script:EffectiveLogLevel = $script:Config.log_level
if ($script:EffectiveLogLevel -notin $ValidLogLevels) { Write-Log "..." "Warn"; $script:EffectiveLogLevel = $DefaultLogLevel }
$script:EffectiveApiKey = $script:Config.api_key

# Проверка и создание папок
$checkFolder = $script:Config.check_folder
$processedFolder = $script:Config.processed_folder
$errorFolder = $script:Config.error_folder
$unrecoverableFolder = $script:Config.unrecoverable_error_folder # DLQ
$foldersToCheck = @($checkFolder, $processedFolder, $errorFolder, $unrecoverableFolder)
foreach ($folder in $foldersToCheck) {
     if (-not (Test-Path $folder -PathType Container)) {
         Write-Log "Папка '$folder' не найдена. Попытка создать..." -Level Warn
         try { New-Item -Path $folder -ItemType Directory -Force -EA Stop | Out-Null; Write-Log "Папка '$folder' создана." -Level Info }
         catch { Write-Log "Критическая ошибка: Не удалось создать папку '$folder': $($_.Exception.Message)" -Level Error; exit 1 }
     }
}

# Получение интервалов/попыток
$scanInterval = 30; if($script:Config.scan_interval_seconds -and [int]::TryParse($script:Config.scan_interval_seconds,[ref]$null) -and $script:Config.scan_interval_seconds -ge 5){ $scanInterval = $script:Config.scan_interval_seconds } else { Write-Log "..." "Warn" }

Write-Log "Инициализация загрузчика v$ScriptVersion завершена." -Level Info
Write-Log ("Параметры: API='{0}', Папка='{1}', Интервал={2} сек, Лог='{3}', Уровень='{4}'" `
    -f $script:Config.api_base_url, $checkFolder, $scanInterval, $script:LogFilePath, $script:EffectiveLogLevel) -Level Info

# --- 4. Основной цикл сканирования и обработки ---
Write-Log "Начало цикла сканирования папки '$checkFolder'..." -Level Info
while ($true) {
    Write-Log "Сканирование папки..." -Level Verbose
    $filesToProcess = @()
    try {
        # Маска файла теперь может быть разной, используем *.zrpu
        $resultsFileFilter = "*.zrpu"
        $filesToProcess = Get-ChildItem -Path $checkFolder -Filter $resultsFileFilter -File -ErrorAction Stop
    } catch {
        # Ошибка доступа к папке - критично, но пробуем дальше
        Write-Log ("Критическая ошибка доступа к папке '$checkFolder': $($_.Exception.Message). Пропуск итерации.") -Level Error
        Start-Sleep -Seconds $scanInterval; continue # Ждем и повторяем
    }

    if ($filesToProcess.Count -eq 0) {
        Write-Log "Нет файлов *.zrpu для обработки." -Level Verbose
    } else {
        Write-Log "Найдено файлов для обработки: $($filesToProcess.Count)." -Level Info

        # --- Обработка каждого файла ---
        foreach ($file in $filesToProcess) {
            $fileStartTime = [DateTimeOffset]::UtcNow
            Write-Log "--- Начало обработки файла: '$($file.FullName)' ---" -Level Info
            $fileProcessingStatus = "unknown" # Статусы: unknown, success, partial_error, error_local, error_api, error_event
            $fileProcessingMessage = ""
            $fileEventDetails = @{} # Детали для события FILE_PROCESSED
            $apiResponse = $null # Ответ от API /checks
            $payloadArray = $null # Массив результатов для отправки
            $totalRecordsInFile = 0 # Общее кол-во записей в файле
            $fileAgentVersion = "[неизвестно]"; $fileAssignmentVersion = "[неизвестно]"

            # Блок try/catch для ЛОКАЛЬНЫХ ошибок (чтение, парсинг)
            try {
                # --- Чтение и парсинг файла ---
                Write-Log "Чтение файла '$($file.Name)'..." -Level Debug
                $fileContent = Get-Content -Path $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $fileContentClean = $fileContent.TrimStart([char]0xFEFF)
                $payloadFromFile = $fileContentClean | ConvertFrom-Json -ErrorAction Stop
                Write-Log "Файл '$($file.Name)' успешно прочитан и распарсен." -Level Debug

                # --- Валидация структуры файла ---
                if ($null -eq $payloadFromFile `
                    -or (-not $payloadFromFile.PSObject.Properties.Name.Contains('results')) `
                    -or ($payloadFromFile.results -isnot [array]) `
                    -or (-not $payloadFromFile.PSObject.Properties.Name.Contains('agent_script_version')) `
                    -or (-not $payloadFromFile.PSObject.Properties.Name.Contains('assignment_config_version'))
                    -or (-not $payloadFromFile.PSObject.Properties.Name.Contains('object_id')) ) {
                    throw "Некорректная структура JSON файла '$($file.Name)'. Отсутствуют обязательные поля (results, agent_script_version, assignment_config_version, object_id)."
                }

                # Извлекаем метаданные
                $resultsArray = $payloadFromFile.results
                $fileAgentVersion = $payloadFromFile.agent_script_version | Get-OrElse "[не указана]"
                $fileAssignmentVersion = $payloadFromFile.assignment_config_version | Get-OrElse "[не указана]"
                $fileObjectId = $payloadFromFile.object_id # ID объекта, СГЕНЕРИРОВАВШЕГО файл

                $totalRecordsInFile = $resultsArray.Count
                Write-Log ("Файл '{0}' содержит записей: {1}. AgentVer: '{2}', ConfigVer: '{3}', SourceOID: {4}" `
                    -f $file.Name, $totalRecordsInFile, $fileAgentVersion, $fileAssignmentVersion, $fileObjectId) -Level Info

                # --- Формирование payload для API /checks ---
                if ($totalRecordsInFile -gt 0) {
                    $payloadArray = [System.Collections.Generic.List[object]]::new()
                    $skippedCount = 0
                    foreach ($res in $resultsArray) {
                         # Базовая валидация элемента result
                         if ($res -ne $null -and $res -is [hashtable] `
                             -and $res.ContainsKey('assignment_id') -and $res.assignment_id -ne $null `
                             -and $res.ContainsKey('IsAvailable') -and $res.IsAvailable -ne $null `
                             -and $res.ContainsKey('Timestamp') -and $res.Timestamp -ne $null)
                         {
                             # Формируем объект для API
                             $payloadItem = @{
                                 assignment_id        = $res.assignment_id
                                 is_available         = $res.IsAvailable
                                 check_timestamp      = $res.Timestamp
                                 details              = $res.Details # Передаем как есть
                                 # Добавляем метаданные из файла В КАЖДЫЙ результат
                                 agent_script_version = $fileAgentVersion
                                 assignment_config_version = $fileAssignmentVersion
                                 executor_object_id   = $fileObjectId # OID агента, сделавшего проверку
                                 executor_host        = $null # Оффлайн агент не пишет имя хоста в zrpu
                                 resolution_method    = 'offline_loader'
                             }
                             # Включаем CheckSuccess и ErrorMessage в details, если они есть
                             if ($res.ContainsKey('CheckSuccess') -and $res.CheckSuccess -ne $null) {
                                if ($payloadItem.details -eq $null) { $payloadItem.details = @{} }
                                $payloadItem.details.CheckSuccess = $res.CheckSuccess
                             }
                             if (-not [string]::IsNullOrEmpty($res.ErrorMessage)) {
                                if ($payloadItem.details -eq $null) { $payloadItem.details = @{} }
                                $payloadItem.details.ErrorMessageFromCheck = $res.ErrorMessage
                             }
                             $payloadArray.Add($payloadItem)
                         } else {
                            $skippedCount++
                             Write-Log ("Пропущен некорректный элемент в файле '{0}': отсутствует assignment_id, IsAvailable или Timestamp. Данные: {1}" `
                                         -f $file.Name, ($res | ConvertTo-Json -Depth 2 -Compress -WarningAction SilentlyContinue)) -Level Warn
                         }
                    } # End foreach ($res in $resultsArray)

                    if ($skippedCount -gt 0) {
                        $fileProcessingMessage = " Записей в файле: $totalRecordsInFile. Пропущено из-за ошибок формата: $skippedCount."
                        # Устанавливаем статус как частичная ошибка, т.к. не все данные будут отправлены
                        $fileProcessingStatus = "partial_error"
                        $fileEventDetails.skipped_format_error = $skippedCount
                    }
                    if ($payloadArray.Count -eq 0 -and $totalRecordsInFile -gt 0) {
                        # Все записи были пропущены
                         throw "Все записи в файле '$($file.Name)' некорректны."
                    } elseif ($payloadArray.Count -eq 0 -and $totalRecordsInFile -eq 0) {
                         # Изначально не было записей
                         $fileProcessingStatus = "success_empty"
                         $fileProcessingMessage = "Обработка файла завершена (пустой массив results)."
                         $fileEventDetails = @{ total_records_in_file = 0; agent_version_in_file = $fileAgentVersion; assignment_version_in_file = $fileAssignmentVersion }
                    }
                } else { # totalRecordsInFile == 0
                    $fileProcessingStatus = "success_empty"
                    $fileProcessingMessage = "Обработка файла завершена (пустой массив results)."
                    $fileEventDetails = @{ total_records_in_file = 0; agent_version_in_file = $fileAgentVersion; assignment_version_in_file = $fileAssignmentVersion }
                }

                # --- Отправка запроса в API (если есть что отправлять) ---
                if ($payloadArray -ne $null -and $payloadArray.Count -gt 0) {
                    $apiUrlChecks = "$($script:Config.api_base_url.TrimEnd('/'))/v1/checks"
                    $headersForChecks = @{ 'X-API-Key' = $script:EffectiveApiKey } # Content-Type добавится в Invoke-ApiRequestWithRetry
                    $apiParams = @{
                        Uri = $apiUrlChecks
                        Method = 'Post'
                        BodyObject = $payloadArray # Передаем массив объектов
                        Headers = $headersForChecks
                        Description = "Отправка {0} результатов из файла '{1}'" -f $payloadArray.Count, $file.Name
                    }
                    Write-Log ("Отправка {0} результатов из файла '{1}' на {2}..." -f $payloadArray.Count, $file.Name, $apiUrlChecks) -Level Info

                    # Вызов API с логикой retry
                    $apiResponse = Invoke-ApiRequestWithRetry @apiParams # Может выбросить исключение

                    # Анализ ответа API (если не было исключения)
                    if ($apiResponse -ne $null) {
                        $processedApi = $apiResponse.processed | Get-OrElse 0
                        $failedApi = $apiResponse.failed | Get-OrElse 0
                        $statusApi = $apiResponse.status | Get-OrElse "unknown"
                        $apiErrors = $apiResponse.errors # Может быть $null или массив

                         Write-Log ("Ответ API для файла '{0}': Статус='{1}', Обработано={2}, Ошибки API={3}" `
                                    -f $file.Name, $statusApi, $processedApi, $failedApi) -Level Info
                         if ($apiErrors) { Write-Log "Детали ошибок API: $($apiErrors | ConvertTo-Json -Depth 3 -Compress -WarningAction SilentlyContinue)" -Level Warn }

                        # Определяем итоговый статус файла на основе ответа API
                        if ($statusApi -eq "success" -and $failedApi -eq 0) {
                            $fileProcessingStatus = "success"
                            $fileProcessingMessage += " Успешно обработано API: $processedApi."
                        } else { # partial_error или error от API
                            $fileProcessingStatus = "error_api" # Любая ошибка от API - файл в DLQ
                            $fileProcessingMessage += " Обработано API: $processedApi, Ошибки API: $failedApi."
                            $fileEventDetails.api_status = $statusApi
                            $fileEventDetails.api_processed = $processedApi
                            $fileEventDetails.api_failed = $failedApi
                            if ($apiErrors) { $fileEventDetails.api_errors = $apiErrors }
                        }
                    } else {
                        # Если Invoke-ApiRequestWithRetry вернул $null (все попытки неудачны)
                         $fileProcessingStatus = "error_api" # Ошибка API, файл в DLQ
                         $fileProcessingMessage += " Ошибка отправки в API после всех попыток."
                         $fileEventDetails.error = "API request failed after retries."
                    }
                } # Конец if ($payloadArray -ne $null -and $payloadArray.Count -gt 0)

            # <<< Закрываем локальный try >>>
            } catch {
                # Ошибка чтения/парсинга файла ИЛИ ошибка валидации структуры
                $errorMessage = "Критическая локальная ошибка обработки файла '$($file.FullName)': $($_.Exception.Message)"
                Write-Log $errorMessage -Level Error
                $fileProcessingStatus = "error_local"
                $fileProcessingMessage = "Ошибка чтения, парсинга JSON или валидации структуры файла."
                $fileEventDetails = @{ error = $errorMessage; ErrorRecord = $_.ToString() }
            }
            # --- Конец локального try/catch ---

            # --- Отправка события FILE_PROCESSED (даже если были ошибки) ---
            $fileEndTime = [DateTimeOffset]::UtcNow
            $processingTimeMs = ($fileEndTime - $fileStartTime).TotalSeconds * 1000

            # Определяем Severity для события
            $eventSeverity = "INFO"
            if ($fileProcessingStatus -like "error*") { $eventSeverity = "ERROR" }
            elseif ($fileProcessingStatus -eq "partial_error") { $eventSeverity = "WARN" }

            # Дополняем детали события
            $fileEventDetails.processing_status = $fileProcessingStatus
            $fileEventDetails.processing_time_ms = [math]::Round($processingTimeMs)
            $fileEventDetails.file_name = $file.Name
            # Добавляем метаданные файла в событие
            if ($fileAgentVersion -ne "[неизвестно]") { $fileEventDetails.agent_version_in_file = $fileAgentVersion }
            if ($fileAssignmentVersion -ne "[неизвестно]") { $fileEventDetails.assignment_version_in_file = $fileAssignmentVersion }
            if ($fileObjectId) { $fileEventDetails.source_object_id_in_file = $fileObjectId }
            if ($totalRecordsInFile -gt 0) { $fileEventDetails.total_records_in_file = $totalRecordsInFile }

            $eventBody = @{
                event_type      = "FILE_PROCESSED"
                severity        = $eventSeverity
                message         = $fileProcessingMessage | Get-OrElse ("Обработка файла '{0}' завершена со статусом '{1}'." -f $file.Name, $fileProcessingStatus)
                source          = "result_loader.ps1 (v$ScriptVersion)"
                related_entity  = "ZRPU_FILE" # Указываем тип сущности
                related_entity_id = $file.Name
                details         = $fileEventDetails
            }
            $eventApiResponse = $null
            try {
                 $eventApiUrl = "$($script:Config.api_base_url.TrimEnd('/'))/v1/events"
                 $eventHeaders = @{ 'X-API-Key' = $script:EffectiveApiKey }
                 $eventApiParams = @{ Uri=$eventApiUrl; Method='Post'; BodyObject=$eventBody; Headers=$eventHeaders; Description="Отправка события FILE_PROCESSED для '$($file.Name)'"}
                 Write-Log ("Отправка события FILE_PROCESSED для '{0}' (Статус файла: {1})..." -f $file.Name, $fileProcessingStatus) -Level Info
                 $eventApiResponse = Invoke-ApiRequestWithRetry @eventApiParams # Отправляем событие
                 if ($eventApiResponse -eq $null) { throw "Не удалось отправить событие после всех попыток." }
                 Write-Log ("Событие FILE_PROCESSED для '{0}' успешно отправлено (EventID: {1})." -f $file.Name, ($eventApiResponse.event_id | Get-OrElse '?')) -Level Info
            } catch {
                # Ошибка отправки события - это ухудшает статус файла до error_event
                 Write-Log ("Критическая ошибка отправки события FILE_PROCESSED для '{0}': {1}" -f $file.Name, $_.Exception.Message) -Level Error
                 # Если до этого была ошибка API, она важнее
                 if ($fileProcessingStatus -ne "error_api") { $fileProcessingStatus = "error_event" }
            }

            # --- Атомарное перемещение файла ---
            # Определяем целевую папку
            $destinationFolder = $null
            switch ($fileProcessingStatus) {
                "success"           { $destinationFolder = $processedFolder }
                "success_empty"     { $destinationFolder = $processedFolder }
                "error_local"       { $destinationFolder = $errorFolder }
                "error_api"         { $destinationFolder = $unrecoverableFolder } # Ошибки API -> в DLQ
                "partial_error"     { $destinationFolder = $unrecoverableFolder } # Частичные ошибки API -> тоже в DLQ
                "error_event"       { $destinationFolder = $unrecoverableFolder } # Ошибка события -> в DLQ
                default             { $destinationFolder = $errorFolder } # Неизвестный статус -> в Error
            }

            $destinationPath = Join-Path $destinationFolder $file.Name
            # Используем временный файл при перемещении на ДРУГОЙ том (если папки на разных дисках)
            # Но т.к. папки рядом, скорее всего, том один, и Move-Item атомарен.
            # Для надежности можно всегда копировать во временный, потом удалять исходный.
            # Но пока используем Move-Item.
            Write-Log ("Перемещение файла '{0}' в '{1}' (Итоговый статус: {2})..." `
                        -f $file.Name, $destinationFolder, $fileProcessingStatus) -Level Info
            try {
                Move-Item -Path $file.FullName -Destination $destinationPath -Force -ErrorAction Stop
                Write-Log ("Файл '{0}' успешно перемещен." -f $file.Name) -Level Info
            } catch {
                 # Если перемещение не удалось - это ОЧЕНЬ ПЛОХО, т.к. файл обработается снова
                 Write-Log ("КРИТИЧЕСКАЯ ОШИБКА перемещения файла '{0}' в '{1}'. ФАЙЛ МОЖЕТ БЫТЬ ОБРАБОТАН ПОВТОРНО! Ошибка: {2}" `
                            -f $file.Name, $destinationPath, $_.Exception.Message) -Level Error
                 # Здесь можно попытаться переименовать файл на месте с добавлением .failed_to_move
            }

            Write-Log "--- Завершение обработки файла: '$($file.FullName)' ---" -Level Info

        } # Конец foreach ($file in $filesToProcess)
    } # Конец else ($filesToProcess.Count -eq 0)

    # --- Пауза перед следующим сканированием ---
    Write-Log "Пауза $scanInterval сек перед следующим сканированием..." -Level Verbose
    Start-Sleep -Seconds $scanInterval

} # --- Конец while ($true) ---

Write-Log "Загрузчик результатов завершил работу непредвиденно (выход из цикла while)." "Error"
exit 1