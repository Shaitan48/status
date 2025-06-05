# powershell/result_loader/result_loader.ps1
# --- Загрузчик Результатов для Status Monitor (v5.x - Pipeline Архитектура) ---
# --- Версия 5.0.0 ---
# Изменения:
# - Адаптирован для обработки .zrpu файлов, содержащих агрегированные результаты выполнения pipeline-заданий.
# - Каждый элемент в массиве 'results' .zrpu файла теперь представляет собой результат целого pipeline.
# - При формировании payload для API /checks/bulk (или /checks):
#   - 'is_available' берется из общего IsAvailable pipeline-результата.
#   - 'check_timestamp' берется из общего Timestamp pipeline-результата.
#   - 'detail_type' устанавливается в "PIPELINE_AGGREGATED_RESULT" (или аналогично).
#   - 'detail_data' содержит объект Details из pipeline-результата (включая 'steps_results' и 'pipeline_status_message').
#   - 'CheckSuccessFromAgent' и 'ErrorMessageFromAgentCheck' (если есть в pipeline-результате) добавляются в 'detail_data'.
# - Обновлены комментарии и версия скрипта.
# - Логика отправки и обработки ответа от /checks/bulk остается схожей.

<#
.SYNOPSIS
    Обрабатывает файлы *.zrpu от Гибридного Агента (Offline режим, v5.x),
    содержащие агрегированные результаты выполнения pipeline-заданий,
    и отправляет эти данные в API Status Monitor (/api/v1/checks/bulk). (v5.0.0)
.DESCRIPTION
    Скрипт-загрузчик результатов оффлайн мониторинга:
    1. Сканирует указанную папку на наличие *.zrpu файлов.
    2. Читает каждый файл, извлекая метаданные и массив 'results'.
       Каждый элемент в 'results' - это агрегированный результат одного pipeline-задания.
    3. Для каждого агрегированного результата формирует payload для API,
       включая 'detail_data' с результатами всех шагов этого pipeline.
    4. Отправляет пакет результатов (все из одного файла) на API эндпоинт /api/v1/checks/bulk.
    5. После обработки ответа API, отправляет событие FILE_PROCESSED в /api/v1/events.
    6. Атомарно перемещает обработанный файл в 'Processed', 'Error' или 'Unrecoverable' папку.
.PARAMETER ConfigFile
    [string] Путь к файлу конфигурации загрузчика (JSON).
    По умолчанию: "$PSScriptRoot\config.json".
.NOTES
    Версия: 5.0.0
    Дата: [Актуальная Дата]
    Зависимости: PowerShell 5.1+, Сетевой доступ к API, Права доступа к папкам.
    Ожидает, что .zrpu файлы сгенерированы Гибридным Агентом v7.1.0+ (Pipeline).
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\config.json",
    # Параметры для переопределения значений из конфига (для тестов или специфических запусков)
    [string]$apiBaseUrlOverride = $null,
    [string]$apiKeyOverride = $null,
    [string]$checkFolderOverride = $null,
    [string]$logFileOverride = $null,
    [string]$logLevelOverride = $null
)

# --- 1. Глобальные переменные и константы ---
$ScriptVersion = "5.0.0" # <<< ОБНОВЛЕНА ВЕРСИЯ СКРИПТА
$script:Config = $null
$script:EffectiveLogLevel = "Info" # Уровень логирования по умолчанию
$script:LogFilePath = $null
$script:ComputerName = $env:COMPUTERNAME
# Значения по умолчанию для некоторых параметров конфигурации
$DefaultLogLevel = "Info"; $DefaultScanInterval = 30; $DefaultApiTimeout = 60;
$DefaultMaxRetries = 3; $DefaultRetryDelay = 5;
$ValidLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error");
$script:EffectiveApiKey = $null # Будет установлено из конфига или параметра

# --- 2. Вспомогательные функции (Write-Log, Get-OrElse, Invoke-ApiRequestWithRetry) ---
# (Эти функции остаются без изменений от версии result_loader.ps1 v4.2.3,
#  только в Write-Log добавим версию скрипта загрузчика для информативности)
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
        $logLine = "[$timestamp] [$Level] [$($script:ComputerName)] (Loader_v$ScriptVersion) - $Message" # Добавлена версия
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

filter Get-OrElse { # Фильтр для получения значения по умолчанию, если основное null/пустое
    param([object]$DefaultValue)
    if ($null -ne $_ -and (($_ -isnot [string]) -or (-not [string]::IsNullOrWhiteSpace($_)))) { $_ } else { $DefaultValue }
}

function Invoke-ApiRequestWithRetry { # Функция для выполнения API запросов с повторами
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$false)]$BodyObject = $null,
        [Parameter(Mandatory=$true)][hashtable]$Headers,
        [Parameter(Mandatory=$true)][string]$Description
    )
    # ... (реализация функции Invoke-ApiRequestWithRetry без изменений от версии 4.2.3) ...
    # Важно: ConvertTo-Json использует -Depth 10 для сохранения структуры pipeline.
    $currentTry = 0; $responseObject = $null
    $maxRetries = $script:Config.max_api_retries | Get-OrElse $DefaultMaxRetries
    $timeoutSec = $script:Config.api_timeout_sec | Get-OrElse $DefaultApiTimeout
    $retryDelaySec = $script:Config.retry_delay_seconds | Get-OrElse $DefaultRetryDelay

    $invokeParams = @{ Uri = $Uri; Method = $Method.ToUpper(); Headers = $Headers; TimeoutSec = $timeoutSec; ErrorAction = 'Stop' }
    if ($null -ne $BodyObject -and $invokeParams.Method -notin @('GET', 'DELETE', 'HEAD', 'OPTIONS')) {
        try {
            $jsonBody = $BodyObject | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue # Depth 10 для pipeline
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
            # ... (обработка WebException без изменений) ...
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
            # ... (обработка других исключений без изменений) ...
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
# (Загрузка и валидация конфигурации - без изменений от версии 4.2.3)
# ...
Write-Host "Запуск Загрузчика Результатов PowerShell v$ScriptVersion (Pipeline-архитектура)"
Write-Log "Чтение конфигурации из '$ConfigFile'..." "Info"
# ... (остальная часть загрузки и валидации конфигурации, создание папок - без изменений) ...
$scanInterval = $script:Config.scan_interval_seconds | Get-OrElse $DefaultScanInterval
# ...
Write-Log "Инициализация загрузчика v$ScriptVersion завершена." -Level Info
Write-Log ("Параметры: API='{0}', Папка='{1}', Интервал={2} сек, Лог='{3}', Уровень='{4}'" -f $script:Config.api_base_url, $checkFolder, $scanInterval, $script:LogFilePath, $script:EffectiveLogLevel) -Level Info

# --- 4. Основной цикл сканирования и обработки ---
Write-Log "Начало цикла сканирования папки '$checkFolder' для файлов *.zrpu..." -Level Info
while ($true) {
    Write-Log "Сканирование папки '$checkFolder'..." -Level Verbose
    $filesToProcess = @()
    try {
        $resultsFileFilter = "*.zrpu" # Фильтр остается прежним
        $filesToProcess = Get-ChildItem -Path $checkFolder -Filter $resultsFileFilter -File -ErrorAction Stop
    } catch {
        Write-Log ("Критическая ошибка доступа к папке '$checkFolder': $($_.Exception.Message). Пропуск итерации.") -Level Error
        Start-Sleep -Seconds $scanInterval; continue
    }

    if ($filesToProcess.Count -eq 0) {
        Write-Log "Нет файлов *.zrpu для обработки." -Level Verbose
    } else {
        Write-Log "Найдено файлов для обработки: $($filesToProcess.Count)." -Level Info

        foreach ($fileInfo in $filesToProcess) { # Используем $fileInfo для ясности
            $fileProcessingStartTime = [DateTimeOffset]::UtcNow
            Write-Log "--- Начало обработки файла: '$($fileInfo.FullName)' ---" -Level Info
            $currentFileProcessingStatus = "unknown_status" # Статус обработки файла
            $currentFileProcessingMessage = "" # Сообщение для события FILE_PROCESSED
            $eventDetailsForFile = @{ file_name = $fileInfo.Name } # Детали для события
            # Переменные для статистики файла
            $fileAgentVersionFromFile = "[не указана]"; $fileAssignmentVersionFromFile = "[не указана]"; $fileObjectIdFromFile = "[не указан]"
            $totalAggregatedResultsInFile = 0
            $payloadItemsForApiBulkRequest = [System.Collections.Generic.List[object]]::new() # Массив для /checks/bulk
            $finalDestinationFolderForFile = $errorFolder # По умолчанию - в папку ошибок чтения/парсинга

            try {
                Write-Log "Чтение и парсинг файла '$($fileInfo.Name)'..." -Level Debug
                $fileJsonContent = Get-Content -Path $fileInfo.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $payloadFromFileZrpu = $fileJsonContent | ConvertFrom-Json -ErrorAction Stop # ConvertFrom-Json вернет PSCustomObject
                Write-Log "Файл '$($fileInfo.Name)' успешно прочитан и распарсен." -Level Debug

                # --- Валидация базовой структуры .zrpu файла ---
                if ($null -eq $payloadFromFileZrpu `
                    -or (-not ($payloadFromFileZrpu.PSObject.Properties.Name -contains 'results' -and $payloadFromFileZrpu.results -is [array])) `
                    -or (-not $payloadFromFileZrpu.PSObject.Properties.Name -contains 'agent_script_version') `
                    -or (-not $payloadFromFileZrpu.PSObject.Properties.Name -contains 'assignment_config_version') `
                    -or (-not $payloadFromFileZrpu.PSObject.Properties.Name -contains 'object_id')) {
                    throw "Некорректная структура JSON файла '$($fileInfo.Name)' (отсутствуют обязательные мета-поля или массив 'results')."
                }
                
                # Извлекаем метаданные файла
                $fileAgentVersionFromFile = $payloadFromFileZrpu.agent_script_version | Get-OrElse "[не указана_в_файле]"
                $fileAssignmentVersionFromFile = $payloadFromFileZrpu.assignment_config_version | Get-OrElse "[не указана_в_файле]"
                $fileObjectIdFromFile = $payloadFromFileZrpu.object_id
                $eventDetailsForFile.agent_version_in_file = $fileAgentVersionFromFile
                $eventDetailsForFile.assignment_version_in_file = $fileAssignmentVersionFromFile
                $eventDetailsForFile.source_object_id_in_file = $fileObjectIdFromFile
                
                $aggregatedResultsArrayFromFile = @($payloadFromFileZrpu.results) # Гарантируем, что это массив
                $totalAggregatedResultsInFile = $aggregatedResultsArrayFromFile.Count
                $eventDetailsForFile.total_records_in_file = $totalAggregatedResultsInFile
                Write-Log ("Файл '$($fileInfo.Name)' содержит записей (агрегированных результатов pipeline): $totalAggregatedResultsInFile. " +
                           "AgentVer: '$fileAgentVersionFromFile', ConfigVer: '$fileAssignmentVersionFromFile', SourceOID: $fileObjectIdFromFile") -Level Info

                if ($totalAggregatedResultsInFile -eq 0) {
                    $currentFileProcessingStatus = "success_empty_file"
                    $currentFileProcessingMessage = "Файл '$($fileInfo.Name)' пуст (массив 'results' не содержит агрегированных результатов pipeline)."
                } else {
                    # --- Формирование элементов для /checks/bulk ---
                    $skippedItemsDueToFormatErrorInFile = 0
                    foreach ($aggregatedResultItemRaw in $aggregatedResultsArrayFromFile) {
                        $aggregatedResultItem = [PSCustomObject]$aggregatedResultItemRaw # Для единообразия доступа к свойствам
                        $itemPropertiesInAggregated = $aggregatedResultItem.PSObject.Properties.Name
                        
                        # Проверяем наличие обязательных полей в агрегированном результате
                        $hasAssignmentIdInAgg = $itemPropertiesInAggregated -contains 'assignment_id'
                        $hasIsAvailableInAgg  = $itemPropertiesInAggregated -contains 'IsAvailable' # PascalCase из агента
                        $hasTimestampInAgg    = $itemPropertiesInAggregated -contains 'Timestamp'   # PascalCase из агента
                        
                        if ($aggregatedResultItem -ne $null `
                            -and $hasAssignmentIdInAgg -and $aggregatedResultItem.assignment_id -ne $null `
                            -and $hasIsAvailableInAgg  -and $aggregatedResultItem.IsAvailable -ne $null `
                            -and $hasTimestampInAgg    -and $aggregatedResultItem.Timestamp -ne $null) {

                            # --- Преобразование агрегированного результата в payload для API /checks ---
                            $apiPayloadItem = @{
                                assignment_id             = $aggregatedResultItem.assignment_id
                                is_available              = [bool]$aggregatedResultItem.IsAvailable # Приводим к bool
                                check_timestamp           = $aggregatedResultItem.Timestamp        # ISO строка
                                # --- Заполняем detail_type и detail_data ---
                                # detail_type может быть стандартным или извлекаться из агрегированного результата, если он там есть
                                detail_type               = "PIPELINE_AGGREGATED_RESULT" # Стандартный тип для всего pipeline
                                # detail_data будет содержать объект Details из агрегированного результата
                                detail_data               = if($itemPropertiesInAggregated -contains 'Details' -and $aggregatedResultItem.Details -is [hashtable]){ $aggregatedResultItem.Details }else{ @{} }
                                # --- Добавляем версии из файла .zrpu ---
                                agent_script_version      = $fileAgentVersionFromFile
                                assignment_config_version = $fileAssignmentVersionFromFile
                                # --- Добавляем информацию об исполнителе ---
                                executor_object_id        = $fileObjectIdFromFile # ID объекта, где работал агент
                                executor_host             = $null # Имя хоста обычно не передается в .zrpu, можно добавить, если агент будет его писать
                                resolution_method         = 'offline_loader_pipeline' # Источник - загрузчик pipeline
                            }
                            
                            # Добавляем CheckSuccess и ErrorMessage (общие для pipeline) в detail_data,
                            # так как API /checks ожидает их там (в виде CheckSuccessFromAgent и ErrorMessageFromAgentCheck)
                            if ($itemPropertiesInAggregated -contains 'CheckSuccess' -and $aggregatedResultItem.CheckSuccess -ne $null) {
                                if (-not ($apiPayloadItem.detail_data -is [hashtable])) { $apiPayloadItem.detail_data = @{} } # Гарантируем, что detail_data - это Hashtable
                                $apiPayloadItem.detail_data.CheckSuccessFromPipeline = [bool]$aggregatedResultItem.CheckSuccess
                            }
                            if ($itemPropertiesInAggregated -contains 'ErrorMessage' -and -not [string]::IsNullOrEmpty($aggregatedResultItem.ErrorMessage)) {
                                if (-not ($apiPayloadItem.detail_data -is [hashtable])) { $apiPayloadItem.detail_data = @{} }
                                $apiPayloadItem.detail_data.ErrorMessageFromPipeline = $aggregatedResultItem.ErrorMessage
                            }
                            $payloadItemsForApiBulkRequest.Add($apiPayloadItem)
                        } else { # Ошибка формата элемента в .zrpu
                            $skippedItemsDueToFormatErrorInFile++
                            $missingFieldsLogAgg = @()
                            if (-not $hasAssignmentIdInAgg -or ($hasAssignmentIdInAgg -and $aggregatedResultItem.assignment_id -eq $null)) { $missingFieldsLogAgg += "assignment_id" }
                            if (-not $hasIsAvailableInAgg  -or ($hasIsAvailableInAgg -and $aggregatedResultItem.IsAvailable -eq $null))  { $missingFieldsLogAgg += "IsAvailable" }
                            if (-not $hasTimestampInAgg    -or ($hasTimestampInAgg -and $aggregatedResultItem.Timestamp -eq $null))    { $missingFieldsLogAgg += "Timestamp" }
                            Write-Log ("Пропущен некорректный агрегированный результат в файле '$($fileInfo.Name)' (индекс $($payloadItemsForApiBulkRequest.Count + $skippedItemsDueToFormatErrorInFile - 1)): " +
                                       "отсутствует или null одно из полей ({0}). Данные: {1}" -f `
                                       ($missingFieldsLogAgg -join ', '), 
                                       ($aggregatedResultItemRaw | ConvertTo-Json -Depth 2 -Compress -WarningAction SilentlyContinue)) -Level Warn
                        }
                    } # Конец foreach ($aggregatedResultItemRaw in ...)

                    if ($skippedItemsDueToFormatErrorInFile -gt 0) {
                        $currentFileProcessingMessage = "Записей (агрегированных результатов) в файле: $totalAggregatedResultsInFile. Пропущено из-за ошибок формата: $skippedItemsDueToFormatErrorInFile."
                        $currentFileProcessingStatus = "partial_error_local_format" # Новый статус
                        $eventDetailsForFile.skipped_format_error = $skippedItemsDueToFormatErrorInFile
                    }
                    if ($payloadItemsForApiBulkRequest.Count -eq 0 -and $totalAggregatedResultsInFile -gt 0) {
                         throw "Все $totalAggregatedResultsInFile агрегированных результатов в файле '$($fileInfo.Name)' имеют некорректный формат, нечего отправлять в API."
                    } elseif ($payloadItemsForApiBulkRequest.Count -eq 0 -and $totalAggregatedResultsInFile -eq 0) { # Это уже обработано выше
                         # $currentFileProcessingStatus = "success_empty_file"
                         # $currentFileProcessingMessage = ...
                    }
                } # Конец if ($totalAggregatedResultsInFile -gt 0)

                # --- Отправка подготовленных данных в API /checks/bulk ---
                if ($payloadItemsForApiBulkRequest.Count -gt 0) {
                    $apiUrlForBulkChecks = "$($script:Config.api_base_url.TrimEnd('/'))/v1/checks/bulk"
                    $headersForBulkChecks = @{ 'X-API-Key' = $script:EffectiveApiKey }
                    # Тело запроса для /checks/bulk должно быть объектом с ключом "results", значение которого - массив
                    $apiBodyForBulkRequest = @{ results = $payloadItemsForApiBulkRequest.ToArray() } # Преобразуем Generic.List в обычный массив
                    
                    $apiParamsForBulkChecks = @{
                        Uri         = $apiUrlForBulkChecks
                        Method      = 'Post'
                        BodyObject  = $apiBodyForBulkRequest
                        Headers     = $headersForBulkChecks
                        Description = "Отправка $($payloadItemsForApiBulkRequest.Count) агрегированных результатов из файла '$($fileInfo.Name)'"
                    }
                    Write-Log ("Отправка $($payloadItemsForApiBulkRequest.Count) агрегированных результатов из файла '$($fileInfo.Name)' на $apiUrlForBulkChecks...") -Level Info
                    
                    $apiResponseForBulkChecks = Invoke-ApiRequestWithRetry @apiParamsForBulkChecks
                    
                    # Анализ ответа от /checks/bulk (логика без изменений от версии 4.2.3)
                    if ($apiResponseForBulkChecks -ne $null) {
                        $processedByApi = $apiResponseForBulkChecks.processed | Get-OrElse 0
                        $failedInApi = $apiResponseForBulkChecks.failed | Get-OrElse 0
                        $statusFromApi = $apiResponseForBulkChecks.status | Get-OrElse "unknown_api_status"
                        $apiErrorsListFromFile = $apiResponseForBulkChecks.errors
                        Write-Log ("Ответ API для файла '$($fileInfo.Name)': Статус='{0}', Обработано API={1}, Ошибки API={2}" -f $statusFromApi, $processedByApi, $failedInApi) -Level Info
                        if ($apiErrorsListFromFile) { Write-Log "Детали ошибок API: $($apiErrorsListFromFile | ConvertTo-Json -Depth 3 -Compress -WarningAction SilentlyContinue)" -Level Warn }
                        
                        $eventDetailsForFile.api_status = $statusFromApi; $eventDetailsForFile.api_processed = $processedByApi; $eventDetailsForFile.api_failed = $failedInApi
                        if ($apiErrorsListFromFile) { $eventDetailsForFile.api_errors = $apiErrorsListFromFile }

                        if ($statusFromApi -eq "success" -and $failedInApi -eq 0) {
                            $currentFileProcessingStatus = "success_api_all_processed"
                            $currentFileProcessingMessage += " Успешно обработано API: $processedByApi."
                        } else { # Были ошибки в API или статус не 'success'
                            $currentFileProcessingStatus = "error_api_partial_or_full"
                            $currentFileProcessingMessage += " Обработано API: $processedByApi, Ошибки API: $failedInApi."
                        }
                    } else { # Ошибка самого Invoke-ApiRequestWithRetry (например, сеть недоступна)
                        $currentFileProcessingStatus = "error_api_request_failed"
                        $currentFileProcessingMessage += " Ошибка отправки результатов в API после всех попыток."
                        $eventDetailsForFile.error_api_request = "API request to /checks/bulk failed after retries."
                    }
                } elseif ($currentFileProcessingStatus -eq "success_empty_file") {
                     Write-Log ($currentFileProcessingMessage) -Level Info
                }
                # Если $payloadItemsForApiBulkRequest пуст из-за ошибок формата, статус уже установлен

            } catch { # Обработка ошибок чтения/парсинга файла или критических ошибок при формировании payload
                $errorMessageTextForFile = "Критическая локальная ошибка обработки файла '$($fileInfo.FullName)': $($_.Exception.Message)"
                Write-Log $errorMessageTextForFile -Level Error
                $currentFileProcessingStatus = "error_local_critical"
                $currentFileProcessingMessage = "Ошибка чтения, парсинга JSON или критическая ошибка валидации структуры файла."
                $eventDetailsForFile.error_local_critical = $errorMessageTextForFile
                $eventDetailsForFile.ErrorRecord_local = $_.ToString()
            }

            # --- Отправка события FILE_PROCESSED ---
            # (Логика отправки события остается без изменений от версии 4.2.3,
            #  но $currentFileProcessingStatus и $currentFileProcessingMessage теперь отражают результат обработки pipeline)
            # ...
            $fileProcessingEndTime = [DateTimeOffset]::UtcNow
            $processingTimeMsForFile = ($fileProcessingEndTime - $fileProcessingStartTime).TotalSeconds * 1000
            $eventDetailsForFile.processing_time_ms = [math]::Round($processingTimeMsForFile)
            $eventSeverityForFile = "INFO"
            if ($currentFileProcessingStatus -like "error*") { $eventSeverityForFile = "ERROR" }
            elseif ($currentFileProcessingStatus -like "partial_error*") { $eventSeverityForFile = "WARN" }

            $eventBodyForFile = @{
                event_type        = "FILE_PROCESSED"
                severity          = $eventSeverityForFile
                message           = $currentFileProcessingMessage | Get-OrElse ("Обработка файла '{0}' завершена со статусом '{1}'." -f $fileInfo.Name, $currentFileProcessingStatus)
                source            = "result_loader.ps1 (v$ScriptVersion)"
                related_entity    = "ZRPU_PIPELINE_FILE" # Указываем, что это файл с pipeline-результатами
                related_entity_id = $fileInfo.Name
                details           = $eventDetailsForFile
            }
            $eventApiResponseForFile = $null; $eventSentSuccessfullyForFile = $false
            try {
                 $eventApiUrlForFile = "$($script:Config.api_base_url.TrimEnd('/'))/v1/events"
                 $eventHeadersForFile = @{ 'X-API-Key' = $script:EffectiveApiKey }
                 $eventApiParamsForFile = @{ Uri=$eventApiUrlForFile; Method='Post'; BodyObject=$eventBodyForFile; Headers=$eventHeadersForFile; Description="Отправка события FILE_PROCESSED для '$($fileInfo.Name)'"}
                 Write-Log ("Отправка события FILE_PROCESSED для файла '$($fileInfo.Name)' (Статус файла: $currentFileProcessingStatus)...") -Level Info
                 $eventApiResponseForFile = Invoke-ApiRequestWithRetry @eventApiParamsForFile
                 if ($eventApiResponseForFile -ne $null -and $eventApiResponseForFile.status -eq 'success') {
                     Write-Log ("Событие FILE_PROCESSED для '$($fileInfo.Name)' успешно отправлено (EventID: $($eventApiResponseForFile.event_id | Get-OrElse '?')).") -Level Info
                     $eventSentSuccessfullyForFile = $true
                 } else { throw ("API не вернул 'success' при отправке события FILE_PROCESSED. Ответ: $($eventApiResponseForFile | ConvertTo-Json -Depth 2 -Compress)") }
            } catch {
                Write-Log ("Критическая ошибка отправки события FILE_PROCESSED для '$($fileInfo.Name)': $($_.Exception.Message)") -Level Error
                if ($currentFileProcessingStatus -notlike "error*") { $currentFileProcessingStatus = "error_event_sending" } # Если до этого было успешно, но событие не ушло
            }

            # --- Определение финальной папки и перемещение файла ---
            # (Логика выбора папки и атомарного перемещения остается без изменений от версии 4.2.3,
            #  используя $currentFileProcessingStatus и $eventSentSuccessfullyForFile)
            # ...
            switch ($currentFileProcessingStatus) {
                "success_api_all_processed"  { $finalDestinationFolderForFile = $processedFolder }
                "success_empty_file"         { $finalDestinationFolderForFile = $processedFolder } # Пустые файлы тоже в Processed
                "error_local_critical"       { $finalDestinationFolderForFile = $errorFolder } # Ошибки чтения/парсинга
                "partial_error_local_format" { $finalDestinationFolderForFile = $errorFolder } # Если были ошибки формата внутри .zrpu, но что-то отправили
                "error_api_request_failed"   { $finalDestinationFolderForFile = $unrecoverableFolder } # Ошибка самого запроса к API
                "error_api_partial_or_full"  { $finalDestinationFolderForFile = $unrecoverableFolder } # API вернул ошибки для некоторых/всех записей
                "error_event_sending"        { $finalDestinationFolderForFile = $unrecoverableFolder } # Ошибка отправки события после успешной обработки API
                default                      { $finalDestinationFolderForFile = $unrecoverableFolder } # Неизвестный статус - в DLQ
            }
            # Дополнительная проверка: если API обработал успешно, но событие не ушло - в DLQ
            if ($currentFileProcessingStatus -eq "success_api_all_processed" -and (-not $eventSentSuccessfullyForFile)) {
                Write-Log "Результаты из файла '$($fileInfo.Name)' были успешно отправлены в API, но событие FILE_PROCESSED не удалось отправить. Перемещение файла в DLQ ($unrecoverableFolder)." "Warn"
                $finalDestinationFolderForFile = $unrecoverableFolder
            }

            $destinationPathForFile = Join-Path $finalDestinationFolderForFile $fileInfo.Name
            $tempDestinationPathForFile = Join-Path $finalDestinationFolderForFile ($fileInfo.BaseName + ".tmp" + $fileInfo.Extension)
            Write-Log ("Перемещение файла '$($fileInfo.Name)' в '$finalDestinationFolderForFile' (Итоговый статус файла: $currentFileProcessingStatus, Событие отправлено: $eventSentSuccessfullyForFile)...") -Level Info
            try {
                Copy-Item -Path $fileInfo.FullName -Destination $tempDestinationPathForFile -Force -ErrorAction Stop
                Remove-Item -Path $fileInfo.FullName -Force -ErrorAction Stop
                Move-Item -Path $tempDestinationPathForFile -Destination $destinationPathForFile -Force -ErrorAction Stop
                Write-Log ("Файл '$($fileInfo.Name)' успешно перемещен (атомарно) в '$finalDestinationFolderForFile'.") -Level Info
            } catch {
                Write-Log ("КРИТИЧЕСКАЯ ОШИБКА атомарного перемещения файла '$($fileInfo.Name)' в '$destinationPathForFile'. Ошибка: $($_.Exception.Message). Попытка простого перемещения...") -Level Error
                try { if (Test-Path $fileInfo.FullName -PathType Leaf) { Move-Item -Path $fileInfo.FullName -Destination $destinationPathForFile -Force -ErrorAction SilentlyContinue } }
                catch { Write-Log "Простое перемещение файла '$($fileInfo.Name)' также не удалось: $($_.Exception.Message)" -Level Error }
                if (Test-Path $tempDestinationPathForFile -PathType Leaf) { try { Remove-Item $tempDestinationPathForFile -Force -EA SilentlyContinue } catch {} }
            }
            Write-Log "--- Завершение обработки файла: '$($fileInfo.FullName)' ---" -Level Info
        } # Конец foreach ($fileInfo in $filesToProcess)
    } # Конец else ($filesToProcess.Count -eq 0)

    Write-Log "Пауза $scanInterval сек перед следующим сканированием папки '$checkFolder'..." -Level Verbose
    Start-Sleep -Seconds $scanInterval
} # Конец while ($true)

# Эта часть не должна достигаться при нормальной работе
Write-Log "Загрузчик результатов завершил работу непредвиденно (выход из основного цикла while)." "Error"
exit 1