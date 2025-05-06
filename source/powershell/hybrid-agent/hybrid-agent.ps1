# powershell/hybrid-agent/hybrid-agent.ps1
# --- Гибридный Агент Мониторинга v7.0 ---
<#
.SYNOPSIS
    Гибридный агент системы мониторинга Status Monitor v7.0.
    Работает в режимах Online или Offline в зависимости от конфигурации.
.DESCRIPTION
    Этот агент выполняет мониторинг узлов и отправляет результаты.
    Режим работы определяется параметром 'mode' в файле config.json.

    Online режим:
    - Получает задания от API сервера (/api/v1/assignments).
    - Выполняет задания по расписанию.
    - Отправляет результат КАЖДОЙ проверки массивом из одного элемента на API (/api/v1/checks).

    Offline режим:
    - Читает задания из локального файла конфигурации (*.json.status.*).
    - Выполняет ВСЕ задания за один цикл.
    - Собирает результаты и сохраняет их в файл *.zrpu для последующей загрузки.
.NOTES
    Версия: 7.0
    Дата: [Актуальная Дата]
    Объединяет функциональность Online и Offline агентов.
    Использует модуль StatusMonitorAgentUtils.
    Требует PowerShell 5.1+.
    Совместим с API Status Monitor v5.2+.
#>
param (
    # Путь к единому файлу конфигурации агента.
    [string]$ConfigFile = "$PSScriptRoot\config.json"
)

# --- 1. Загрузка общего модуля утилит ---
$ErrorActionPreference = "Stop" # Строгий режим на время импорта
try {
    # Путь к манифесту Utils относительно папки hybrid-agent
    $ModuleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1"
    Write-Host "[INFO] Загрузка модуля '$ModuleManifestPath'..."
    Import-Module $ModuleManifestPath -Force -ErrorAction Stop
    Write-Host "[INFO] Модуль Utils успешно загружен."
} catch {
    Write-Host "[CRITICAL] Критическая ошибка загрузки модуля '$ModuleManifestPath': $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[CRITICAL] Агент не может работать без модуля Utils. Завершение." -ForegroundColor Red
    exit 1 # Критическая ошибка - выходим
} finally {
    $ErrorActionPreference = "Continue" # Возвращаем стандартный режим
}
# --- Конец загрузки модуля ---

# --- 2. Глобальные переменные ---
$script:ComputerName = $env:COMPUTERNAME
$script:Config = $null         # Конфигурация из config.json
$script:LogLevel = "Info"      # Уровень логирования
$script:LogFilePath = $null    # Полный путь к лог-файлу
$script:AgentVersion = "hybrid_agent_v7.0" # Версия скрипта для логов/результатов

# Переменные для Online режима
$script:ActiveAssignmentsOnline = @{} # Активные задания (ID -> Объект)
$script:LastExecutedTimesOnline = @{} # Время последнего выполнения (ID -> DateTimeOffset UTC)
$script:LastApiPollTimeOnline = [DateTimeOffset]::MinValue # Время последнего опроса API

# Переменные для Offline режима
$script:CurrentAssignmentsOffline = $null # Текущие задания из файла (массив)
$script:CurrentConfigVersionOffline = $null # Текущая версия файла конфига
$script:LastProcessedConfigFileOffline = $null # Путь к последнему обработанному файлу

# --- 3. Вспомогательные функции ---

#region Функции

<#
.SYNOPSIS Записывает сообщение в лог и/или консоль.
#>
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
        [string]$Level = "Info"
    )
    # Уровни логирования (числовое представление)
    $logLevels = @{ "Debug" = 4; "Verbose" = 3; "Info" = 2; "Warn" = 1; "Error" = 0 }
    $effectiveLogLevelValue = $logLevels[$script:LogLevel] # Текущий установленный уровень
    if ($null -eq $effectiveLogLevelValue) { $effectiveLogLevelValue = $logLevels["Info"] } # Fallback
    $messageLevelValue = $logLevels[$Level] # Уровень текущего сообщения
    if ($null -eq $messageLevelValue) { $messageLevelValue = $logLevels["Info"] } # Fallback

    # Проверяем, нужно ли писать сообщение
    if ($messageLevelValue -le $effectiveLogLevelValue) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logMessage = "[$timestamp] [$Level] [$script:ComputerName] - $Message"
        # Определение цвета для консоли
        $consoleColor = switch($Level) {
            "Error"   { "Red" }
            "Warn"    { "Yellow" }
            "Info"    { "White" }
            "Verbose" { "Gray" }
            "Debug"   { "DarkGray" }
            Default   { "Gray" }
        }
        # Вывод в консоль
        Write-Host $logMessage -ForegroundColor $consoleColor

        # Запись в файл, если путь задан
        if ($script:LogFilePath) {
            try {
                # Проверяем/создаем папку для лога
                $logDir = Split-Path $script:LogFilePath -Parent
                if ($logDir -and (-not (Test-Path $logDir -PathType Container))) {
                    Write-Host "[INFO] Создание папки для лога: '$logDir'"
                    New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                # Добавляем сообщение в файл
                Add-Content -Path $script:LogFilePath -Value $logMessage -Encoding UTF8 -Force -ErrorAction Stop
            } catch {
                # Ошибка записи в основной лог
                Write-Host ("[CRITICAL] Ошибка записи в лог '{0}': {1}" -f $script:LogFilePath, $_.Exception.Message) -ForegroundColor Red
                # Попытка записи в запасной лог в папке скрипта
                try {
                    $fallbackLog = "$PSScriptRoot\hybrid_agent_fallback.log"
                    $fallbackMessage = "[$timestamp] [$Level] [$script:ComputerName] - $Message"
                    $errorMessageLine = "[CRITICAL] FAILED TO WRITE TO '$($script:LogFilePath)': $($_.Exception.Message)"
                    Add-Content -Path $fallbackLog -Value $fallbackMessage -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                    Add-Content -Path $fallbackLog -Value $errorMessageLine -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                } catch {
                    # Игнорируем ошибки записи в запасной лог
                }
            }
        }
    }
}

<#
.SYNOPSIS Возвращает значение по умолчанию, если входное значение $null или пустое.
#>
filter Get-OrElse {
    param([object]$DefaultValue)
    if ($null -ne $_ -and (($_ -isnot [string]) -or (-not [string]::IsNullOrWhiteSpace($_)))) {
        $_
    } else {
        $DefaultValue
    }
}

<#
.SYNOPSIS Выполняет HTTP-запрос к API с логикой повторных попыток.
#>
function Invoke-ApiRequestWithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$false)]$BodyObject = $null, # Принимаем объект PS
        [Parameter(Mandatory=$true)][hashtable]$Headers, # Включая X-API-Key
        [Parameter(Mandatory=$true)][string]$Description # Описание для логов
    )

    $retryCount = 0
    $responseObject = $null # Результат (распарсенный JSON)
    $maxRetries = $script:Config.max_api_retries | Get-OrElse 3
    $timeoutSec = $script:Config.api_timeout_sec | Get-OrElse 60
    $retryDelaySec = $script:Config.retry_delay_seconds | Get-OrElse 5

    # Параметры для Invoke-RestMethod
    $invokeParams = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $Headers
        TimeoutSec  = $timeoutSec
        ErrorAction = 'Stop' # Ловим ошибки через try/catch
    }
    # Добавляем тело, если это не GET/DELETE и тело передано
    if ($BodyObject -ne $null -and $Method.ToUpper() -notin @('GET', 'DELETE')) {
        try {
            # Преобразуем объект в JSON строку
            $jsonBody = $BodyObject | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
            # Устанавливаем ContentType и тело запроса (байты UTF-8)
            $invokeParams.ContentType = 'application/json; charset=utf-8'
            $invokeParams.Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
             Write-Log "Тело запроса для ($Description): $jsonBody" -Level Debug
        } catch {
            Write-Log "Критическая ошибка ConvertTo-Json для ($Description): $($_.Exception.Message)" -Level Error
            # Write-Log "Проблемный объект: $($BodyObject | Out-String -Width 500)" -Level Debug # Может быть очень большим
            throw "Ошибка преобразования тела запроса в JSON." # Прерываем
        }
    }

    # Цикл повторных попыток
    while ($retryCount -lt $maxRetries -and $responseObject -eq $null) {
        try {
            Write-Log ("Выполнение запроса ({0}) (Попытка {1}/{2}): {3} {4}" -f $Description, ($retryCount + 1), $maxRetries, $Method, $Uri) -Level Verbose
            # Выполняем запрос
            $responseObject = Invoke-RestMethod @invokeParams
            # Успех!
            Write-Log ("Успешный ответ API ({0})." -f $Description) -Level Verbose
            return $responseObject # Возвращаем результат (распарсенный JSON)

        } catch [System.Net.WebException] { # Ловим специфичные ошибки веб-запросов
            $retryCount++
            $exception = $_.Exception
            $statusCode = $null
            $errorResponseBody = "[Не удалось прочитать тело ошибки]"
            if ($exception.Response -ne $null) {
                try { $statusCode = [int]$exception.Response.StatusCode } catch { }
                try {
                    $errorStream = $exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($errorStream)
                    $errorResponseBody = $reader.ReadToEnd()
                    $reader.Close()
                    $errorStream.Dispose()
                     # Попытка распарсить тело ошибки как JSON
                     try { $errorJson = $errorResponseBody | ConvertFrom-Json; $errorResponseBody = $errorJson } catch {}
                } catch { }
            }
            # Формируем сообщение об ошибке
            $errorMessage = $exception.Message.Replace('{','{{').Replace('}','}}') # Экранируем фигурные скобки для -f
            $errorDetails = $errorResponseBody
            Write-Log ("Ошибка API ({0}) (Попытка {1}/{2}). Код: {3}. Error: {4}. Ответ: {5}" -f `
                        $Description, $retryCount, $maxRetries, ($statusCode | Get-OrElse 'N/A'), $errorMessage, ($errorDetails | Out-String -Width 300)) -Level Error

            # Критические ошибки, после которых нет смысла повторять
            if ($statusCode -in @(400, 401, 403, 404, 409, 422)) { # Bad Request, Unauthorized, Forbidden, Not Found, Conflict, Validation
                Write-Log ("Критическая ошибка API ({0} - Код {1}), повторные попытки отменены." -f $Description, $statusCode) -Level Error
                throw $exception # Пробрасываем исключение, чтобы основной код мог его обработать
            }
            # Если не критическая ошибка и попытки не кончились - пауза и повтор
            if ($retryCount -ge $maxRetries) {
                 Write-Log ("Превышено кол-во попыток ({0}) для ({1})." -f $maxRetries, $Description) -Level Error
                 throw $exception # Пробрасываем последнюю ошибку
            }
            Write-Log ("Пауза $retryDelaySec сек перед повторной попыткой...") -Level Warn
            Start-Sleep -Seconds $retryDelaySec

        } catch { # Ловим другие возможные ошибки (например, ConvertTo-Json выше или ошибки PS)
             $retryCount++ # Считаем попытку
             $errorMessage = $_.Exception.Message.Replace('{','{{').Replace('}','}}')
             Write-Log ("Неожиданная ошибка ({0}) (Попытка {1}/{2}): {3}" -f $Description, $retryCount, $maxRetries, $errorMessage) -Level Error
             # Сразу пробрасываем другие ошибки
             throw $_.Exception
        }
    } # Конец while
    # Сюда не должны попасть, если все работает как надо
    return $null
}

#endregion Функции

# --- 4. Основная логика ---

# 4.1 Чтение и валидация конфигурации
Write-Host "Запуск Гибридного Агента Мониторинга v$($script:AgentVersion)..."
Write-Log "Чтение конфигурации из '$ConfigFile'..." -Level Info
if (-not (Test-Path $ConfigFile -PathType Leaf)) { Write-Log "Критическая ошибка: Файл конфигурации '$ConfigFile' не найден." -Level Error; exit 1 }
try {
    $script:Config = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Log "Критическая ошибка: Ошибка чтения/парсинга JSON из '$ConfigFile': $($_.Exception.Message)" -Level Error
    exit 1
}

# --- Валидация ОБЩИХ обязательных полей ---
$requiredCommonFields = @("mode", "object_id", "log_file", "log_level", "agent_script_version")
$missingCommon = $requiredCommonFields | Where-Object { -not ($script:Config.PSObject.Properties.Name -contains $_) -or $null -eq $script:Config.$_ -or ($script:Config.$_ -is [string] -and [string]::IsNullOrWhiteSpace($script:Config.$_)) }
if ($missingCommon) { Write-Log ("Критическая ошибка: В '$ConfigFile' отсутствуют или пусты обязательные общие поля: $($missingCommon -join ', ')") -Level Error; exit 1 }

# Установка пути к лог-файлу и уровня логирования
$script:LogFilePath = $script:Config.log_file
$script:LogLevel = $script:Config.log_level
$validLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error")
if ($script:LogLevel -notin $validLogLevels) { Write-Log ("Некорректный LogLevel '$($script:LogLevel)'. Используется 'Info'.") -Level Warn; $script:LogLevel = "Info" }

# Логирование базовой информации
Write-Log "Гибридный агент v$($script:AgentVersion) запущен. Имя хоста: $script:ComputerName" -Level Info
Write-Log "Режим работы: $($script:Config.mode)" -Level Info
Write-Log "ObjectID: $($script:Config.object_id)" -Level Info
Write-Log "Логирование в '$script:LogFilePath' с уровнем '$script:LogLevel'" -Level Info

# --- 4.2 Запуск логики для выбранного режима ---
$agentMode = $script:Config.mode.Trim().ToLower()

# --- ========================== ---
# ---      ONLINE РЕЖИМ        ---
# --- ========================== ---
if ($agentMode -eq 'online') {

    # --- Валидация параметров Online режима ---
    Write-Log "Проверка конфигурации для Online режима..." -Level Verbose
    $requiredOnlineFields = @("api_base_url", "api_key", "api_poll_interval_seconds", "default_check_interval_seconds")
    $missingOnline = $requiredOnlineFields | Where-Object { -not ($script:Config.PSObject.Properties.Name -contains $_) -or $null -eq $script:Config.$_ -or ($script:Config.$_ -is [string] -and [string]::IsNullOrWhiteSpace($script:Config.$_)) }
    if ($missingOnline) { Write-Log ("Критическая ошибка: Для Online режима в '$ConfigFile' отсутствуют поля: $($missingOnline -join ', ')") -Level Error; exit 1 }

    # Получаем интервалы (с проверкой)
    $apiPollInterval = 60; if ($script:Config.api_poll_interval_seconds -and [int]::TryParse($script:Config.api_poll_interval_seconds,[ref]$null) -and $script:Config.api_poll_interval_seconds -ge 10) { $apiPollInterval = $script:Config.api_poll_interval_seconds } else { Write-Log "..." "Warn" }
    $defaultCheckInterval = 300; if ($script:Config.default_check_interval_seconds -and [int]::TryParse($script:Config.default_check_interval_seconds,[ref]$null) -and $script:Config.default_check_interval_seconds -ge 5) { $defaultCheckInterval = $script:Config.default_check_interval_seconds } else { Write-Log "..." "Warn" }
    $apiPollTimeSpan = [TimeSpan]::FromSeconds($apiPollInterval)
    $defaultCheckTimeSpan = [TimeSpan]::FromSeconds($defaultCheckInterval)
    Write-Log ("Online режим: Опрос API каждые {0} сек, стандартный интервал {1} сек." -f $apiPollInterval, $defaultCheckInterval) -Level Info

    # --- Основной цикл Online режима ---
    Write-Log "Запуск основного цикла Online режима..." -Level Info
    while ($true) {
        $loopStartTime = [DateTimeOffset]::UtcNow # Используем UTC для сравнений
        Write-Log "Начало итерации цикла Online." -Level Verbose

        # --- Обновление списка заданий по расписанию ---
        if (($loopStartTime - $script:LastApiPollTimeOnline) -ge $apiPollTimeSpan) {
            Write-Log "Время обновить список заданий с API." -Level Info
            $apiUrl = "$($script:Config.apiBaseUrl.TrimEnd('/'))/v1/assignments?object_id=$($script:Config.object_id)"
            $headers = @{ 'X-API-Key' = $script:Config.api_key }
            try {
                # Запрашиваем задания с помощью обертки с retry
                $fetchedAssignmentsRaw = Invoke-ApiRequestWithRetry `
                                            -Uri $apiUrl `
                                            -Method Get `
                                            -Headers $headers `
                                            -Description "Получение заданий (ObjectID $($script:Config.object_id))"

                if ($fetchedAssignmentsRaw -ne $null -and $fetchedAssignmentsRaw -is [array]) {
                     Write-Log "Получено $($fetchedAssignmentsRaw.Count) активных заданий от API." -Level Info
                    $newAssignmentMap = @{} # ID -> Объект
                    $fetchedIds = [System.Collections.Generic.List[int]]::new()
                    foreach ($assignmentRaw in $fetchedAssignmentsRaw) {
                        # Валидация полученного задания
                        if ($assignmentRaw -ne $null -and $assignmentRaw.PSObject -ne $null `
                            -and $assignmentRaw.PSObject.Properties.Name -contains 'assignment_id' `
                            -and $assignmentRaw.assignment_id -ne $null)
                        {
                            $id = $null
                            if([int]::TryParse($assignmentRaw.assignment_id, [ref]$id)) {
                                $newAssignmentMap[$id] = [PSCustomObject]$assignmentRaw # Сохраняем как PSCustomObject
                                $fetchedIds.Add($id)
                            } else { Write-Log "Нечисловой assignment_id получен от API: '$($assignmentRaw.assignment_id)'" -Level Warn }
                        } else { Write-Log "Получено некорректное задание от API: $($assignmentRaw | Out-String)" -Level Warn }
                    }

                    # Синхронизация с текущим списком
                    $currentIds = $script:ActiveAssignmentsOnline.Keys | ForEach-Object { [int]$_ }
                    $removedIds = $currentIds | Where-Object { $fetchedIds -notcontains $_ }
                    $addedCount = 0; $updatedCount = 0
                    # Удаляем устаревшие
                    if ($removedIds) {
                        foreach ($removedId in $removedIds) {
                            Write-Log "Удалено задание ID $removedId из активного списка." -Level Info
                            $script:ActiveAssignmentsOnline.Remove($removedId)
                            $script:LastExecutedTimesOnline.Remove($removedId)
                        }
                    }
                    # Добавляем/обновляем
                    foreach ($id in $fetchedIds) {
                        if (-not $script:ActiveAssignmentsOnline.ContainsKey($id)) {
                            $script:ActiveAssignmentsOnline[$id] = $newAssignmentMap[$id]
                            # Устанавливаем время последнего выполнения в далекое прошлое, чтобы выполнилось сразу
                            $script:LastExecutedTimesOnline[$id] = [DateTimeOffset]::UtcNow.AddDays(-1)
                            $addedCount++
                            Write-Log "Добавлено новое задание ID $id." -Level Info
                        } else {
                            # Проверка на изменения (сравниваем JSON представления)
                            $oldJson = $script:ActiveAssignmentsOnline[$id] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue
                            $newJson = $newAssignmentMap[$id] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue
                            if ($oldJson -ne $newJson) {
                                $script:ActiveAssignmentsOnline[$id] = $newAssignmentMap[$id]
                                # Не сбрасываем время выполнения при обновлении, чтобы не было всплеска
                                $updatedCount++
                                Write-Log "Обновлено задание ID $id." -Level Verbose
                            }
                        }
                    }
                    Write-Log ("Синхронизация заданий завершена. Добавлено:{0}. Обновлено:{1}. Удалено:{2}." `
                                -f $addedCount, $updatedCount, $removedIds.Count) -Level Info
                    $script:LastApiPollTimeOnline = $loopStartTime # Обновляем время последней успешной синхронизации

                } elseif ($fetchedAssignmentsRaw -eq $null) {
                    Write-Log "API вернул пустой ответ (возможно, нет активных заданий или ошибка)." -Level Warn
                    # Обработка случая, когда ВСЕ задания были удалены
                    if ($script:ActiveAssignmentsOnline.Count -gt 0) {
                         Write-Log "Очистка активных заданий, так как API вернул пустой список." -Level Info
                         $script:ActiveAssignmentsOnline.Clear()
                         $script:LastExecutedTimesOnline.Clear()
                    }
                    $script:LastApiPollTimeOnline = $loopStartTime # Считаем опрос успешным, хоть и пустым
                } else { # Не массив
                     Write-Log "API вернул некорректные данные заданий (не массив). Текущий список не изменен." -Level Error
                     # Не обновляем $script:LastApiPollTimeOnline, попробуем в след. раз
                }
            } catch { # Ошибка при вызове Invoke-ApiRequestWithRetry
                 Write-Log "Ошибка при получении заданий от API: $($_.Exception.Message). Используется текущий список заданий." -Level Error
                 # Не обновляем $script:LastApiPollTimeOnline
            }
        } else {
            Write-Log "Опрос API еще не требуется..." -Level Verbose
        }

        # --- Выполнение запланированных проверок ---
        $currentTime = [DateTimeOffset]::UtcNow # Текущее время UTC
        if ($script:ActiveAssignmentsOnline.Count -gt 0) {
            Write-Log "Проверка запланированных заданий ($($script:ActiveAssignmentsOnline.Count) активно)..." -Level Verbose
            # Копируем ключи, чтобы избежать проблем при изменении коллекции во время итерации
            $assignmentIdsToCheck = @($script:ActiveAssignmentsOnline.Keys)

            foreach ($id in $assignmentIdsToCheck) {
                # Проверяем, не удалили ли задание во время синхронизации
                if (-not $script:ActiveAssignmentsOnline.ContainsKey($id)) { continue }

                $assignment = $script:ActiveAssignmentsOnline[$id]
                # Определяем интервал для этого задания
                $checkIntervalSec = $assignment.check_interval_seconds | Get-OrElse $defaultCheckInterval
                if ($checkIntervalSec -le 0) { $checkIntervalSec = $defaultCheckInterval }
                $checkIntervalTimeSpan = [TimeSpan]::FromSeconds($checkIntervalSec)

                # Получаем время последнего выполнения
                $lastRunTime = [DateTimeOffset]::MinValue # Если не выполнялось, то давно пора
                if ($script:LastExecutedTimesOnline.ContainsKey($id)) {
                    $lastRunTime = $script:LastExecutedTimesOnline[$id]
                }

                # Вычисляем время следующего запуска
                $nextRunTime = $lastRunTime + $checkIntervalTimeSpan

                # Если пора выполнять
                if ($currentTime -ge $nextRunTime) {
                     Write-Log ("НАЧАЛО ВЫПОЛНЕНИЯ задания ID {0} ({1} для '{2}')." -f `
                                 $id, $assignment.method_name, $assignment.node_name) -Level Info
                    $checkResult = $null
                    try {
                        # --- Вызов основной функции проверки ---
                        $checkResult = Invoke-StatusMonitorCheck -Assignment $assignment `
                                                                  -Verbose:$false ` # Передаем текущие настройки Verbose/Debug
                                                                  -Debug:$false   # или можно жестко задать $false

                        if ($checkResult -eq $null -or $checkResult.IsAvailable -eq $null) { throw "Invoke-StatusMonitorCheck вернул некорректный результат." }

                        Write-Log ("Результат проверки ID {0}: IsAvailable={1}, CheckSuccess={2}, Error='{3}'" -f `
                                   $id, $checkResult.IsAvailable, $checkResult.CheckSuccess, $checkResult.ErrorMessage) -Level Verbose

                        # --- Формирование payload для API ---
                        # API /checks теперь ожидает МАССИВ результатов
                        $payloadItem = @{
                            assignment_id        = $id
                            is_available         = $checkResult.IsAvailable
                            # CheckSuccess и ErrorMessage ИДУТ ВНУТРЬ details!
                            check_timestamp      = $checkResult.Timestamp # Уже в UTC ISO 8601
                            executor_object_id   = $script:Config.object_id # ID объекта, где работает агент
                            executor_host        = $script:ComputerName
                            resolution_method    = $assignment.method_name
                            detail_type          = $null # Тип будет определен по методу или внутри details
                            detail_data          = $checkResult.Details # Передаем объект Details как есть
                            agent_script_version = $script:AgentVersion
                            # assignment_config_version не актуально для Online
                        }
                        # Добавляем CheckSuccess и ErrorMessage в details, если они есть
                         if ($checkResult.PSObject.Properties.Name -contains 'CheckSuccess' -and $checkResult.CheckSuccess -ne $null) {
                             if ($payloadItem.detail_data -eq $null) { $payloadItem.detail_data = @{} }
                             $payloadItem.detail_data.CheckSuccess = $checkResult.CheckSuccess
                         }
                         if (-not [string]::IsNullOrEmpty($checkResult.ErrorMessage)) {
                              if ($payloadItem.detail_data -eq $null) { $payloadItem.detail_data = @{} }
                             $payloadItem.detail_data.ErrorMessageFromCheck = $checkResult.ErrorMessage
                             # Устанавливаем тип детализации ERROR, если он еще не установлен
                             if ($payloadItem.detail_type -eq $null) { $payloadItem.detail_type = "ERROR" }
                         }
                         # Если тип детализации все еще не установлен, используем имя метода
                         if ($payloadItem.detail_type -eq $null) {
                             $payloadItem.detail_type = $assignment.method_name.ToUpper() -replace '[^A-Z0-9_]','_'
                         }


                        # Создаем МАССИВ из одного элемента
                        $payloadArray = @( $payloadItem )

                        # --- Отправка результата в API ---
                        $apiUrlChecks = "$($script:Config.apiBaseUrl.TrimEnd('/'))/v1/checks"
                        $sendSuccess = $false
                        try {
                             # Вызов API с retry (передаем МАССИВ в BodyObject)
                             $apiResponse = Invoke-ApiRequestWithRetry `
                                                -Uri $apiUrlChecks `
                                                -Method Post `
                                                -BodyObject $payloadArray `
                                                -Headers $headers `
                                                -Description "Отправка результата ID $id"

                             # Анализируем ответ (200 OK или 207 Multi-Status)
                             # Для массива из 1 элемента ожидаем 200 OK или 207 с 1 обработанным и 0 ошибок
                             if ($apiResponse -ne $null -and $apiResponse.status -eq 'success' `
                                 -and $apiResponse.processed -eq 1 -and $apiResponse.failed -eq 0) {
                                 $sendSuccess = $true
                                 Write-Log "Результат ID $id успешно отправлен в API." -Level Info
                             } elseif ($apiResponse -ne $null) { # Ответ есть, но не success или не 1/0
                                Write-Log ("Ответ API при отправке ID {0} не был 'success' или счетчики неверны. Статус: {1}, Обработано: {2}, Ошибки: {3}" -f `
                                            $id, $apiResponse.status, $apiResponse.processed, $apiResponse.failed) -Level Error
                                if($apiResponse.errors) { Write-Log "Ошибки от API: $($apiResponse.errors | ConvertTo-Json -Depth 3 -Compress)" -Level Error }
                            } else { # apiResponse = $null (Invoke-ApiRequestWithRetry не смог)
                                Write-Log "Не удалось отправить результат ID $id в API после всех попыток." -Level Error
                            }
                        } catch { # Ошибка в Invoke-ApiRequestWithRetry
                            Write-Log "Критическая ошибка при отправке результата ID $id в API: $($_.Exception.Message)" -Level Error
                        }

                        # Обновляем время выполнения только при УСПЕШНОЙ отправке
                        if ($sendSuccess) {
                            $script:LastExecutedTimesOnline[$id] = $currentTime
                            Write-Log "Время последнего выполнения ID $id обновлено." -Level Verbose
                        } else {
                             Write-Log "Время последнего выполнения ID $id НЕ обновлено из-за ошибки отправки." -Level Warn
                        }

                    } catch { # Ошибка при ВЫПОЛНЕНИИ Invoke-StatusMonitorCheck
                        Write-Log "Критическая ошибка при ВЫПОЛНЕНИИ задания ID ${id}: $($_.Exception.Message)" -Level Error
                        # Время выполнения НЕ обновляем
                    } finally {
                         Write-Log "ЗАВЕРШЕНИЕ ВЫПОЛНЕНИЯ задания ID $id." -Level Info
                    }
                } # Конец if ($currentTime -ge $nextRunTime)
            } # Конец foreach ($id in $assignmentIdsToCheck)
        } else {
            Write-Log "Нет активных заданий для выполнения." -Level Verbose
        }

        # --- Пауза перед следующей итерацией основного цикла ---
        # Короткая пауза, чтобы не загружать процессор на 100%
        Start-Sleep -Seconds 1

    } # --- Конец while ($true) Online ---

# --- =========================== ---
# ---      OFFLINE РЕЖИМ        ---
# --- =========================== ---
} elseif ($agentMode -eq 'offline') {

    # --- Валидация параметров Offline режима ---
    Write-Log "Проверка конфигурации для Offline режима..." -Level Verbose
    $requiredOfflineFields = @("assignments_file_path_pattern", "output_path", "output_name_template", "offline_cycle_interval_seconds")
    $missingOffline = $requiredOfflineFields | Where-Object { -not ($script:Config.PSObject.Properties.Name -contains $_) -or $null -eq $script:Config.$_ -or (($script:Config.$_ -is [string]) -and ([string]::IsNullOrWhiteSpace($script:Config.$_))) } # Позволяем 0 для offline_cycle_interval_seconds
    if ($missingOffline) { Write-Log ("Критическая ошибка: Для Offline режима в '$ConfigFile' отсутствуют поля: $($missingOffline -join ', ')") -Level Error; exit 1 }

    # Проверка путей
    $assignmentsFolderPath = $script:Config.assignments_file_path_pattern.TrimEnd('\*') # Убираем маску для проверки папки
    $outputPath = $script:Config.output_path
    $outputNameTemplate = $script:Config.output_name_template
    if(-not(Test-Path $assignmentsFolderPath -PathType Container)){ Write-Log "Критическая ошибка: Папка для файлов заданий '$assignmentsFolderPath' не найдена." -Level Error; exit 1 }
    if(-not(Test-Path $outputPath -PathType Container)){ Write-Log "Папка для результатов '$outputPath' не найдена. Попытка создать..." -Level Warn; try { New-Item -Path $outputPath -ItemType Directory -Force -EA Stop | Out-Null; Write-Log "Папка '$outputPath' успешно создана." -Level Info } catch { Write-Log "Критическая ошибка: Не удалось создать папку '$outputPath': $($_.Exception.Message)" -Level Error; exit 1 } };

    # Интервал цикла
    $offlineInterval = 0; if($script:Config.offline_cycle_interval_seconds -and [int]::TryParse($script:Config.offline_cycle_interval_seconds,[ref]$null) -and $script:Config.offline_cycle_interval_seconds -gt 0){ $offlineInterval = $script:Config.offline_cycle_interval_seconds }
    $runContinuously = ($offlineInterval -gt 0)
    if ($runContinuously) { Write-Log ("Offline режим: Запуск в циклическом режиме с интервалом {0} сек." -f $offlineInterval) -Level Info }
    else { Write-Log "Offline режим: Запуск в однократном режиме." -Level Info }

    # --- Основной цикл/запуск Offline режима ---
    do { # Используем do-while для гарантии хотя бы одного выполнения
        $cycleStartTime = [DateTimeOffset]::UtcNow
        Write-Log "Начало цикла/запуска Offline ($($cycleStartTime.ToString('s')))." -Level Info

        # --- Поиск и чтение файла конфигурации заданий ---
        $latestConfigFile = $null; $configError = $null; $configData = $null
        try {
            $assignmentsFilePattern = $script:Config.assignments_file_path_pattern
            Write-Log ("Поиск файла конфигурации в '$assignmentsFolderPath' по шаблону '$assignmentsFilePattern'...") -Level Debug
            # Ищем самый новый файл по LastWriteTime
            $foundFiles = Get-ChildItem -Path $assignmentsFilePattern -File -ErrorAction SilentlyContinue
            if ($Error.Count -gt 0 -and $Error[0].CategoryInfo.Category -eq 'ReadError') { throw ("Ошибка доступа при поиске файла: " + $Error[0].Exception.Message); $Error.Clear() }

            if ($foundFiles) {
                $latestConfigFile = $foundFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                Write-Log "Найден последний файл конфигурации: $($latestConfigFile.FullName)" -Level Verbose
            } else { Write-Log "Файлы конфигурации по шаблону '$assignmentsFilePattern' не найдены." -Level Warn }
        } catch { $configError = "Ошибка поиска файла конфигурации: $($_.Exception.Message)"; Write-Log $configError -Level Error }

        # Обрабатываем файл, только если он новый или еще не обрабатывался
        if ($latestConfigFile -ne $null -and $configError -eq $null) {
            if ($latestConfigFile.FullName -ne $script:lastProcessedConfigFileOffline) {
                Write-Log "Обнаружен новый/обновленный файл конфигурации: $($latestConfigFile.Name). Чтение..." -Level Info
                $tempAssignments = $null; $tempVersionTag = $null
                try {
                    $fileContent = Get-Content -Path $latestConfigFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                    $fileContentClean = $fileContent.TrimStart([char]0xFEFF); # Убираем BOM, если есть
                    $configData = $fileContentClean | ConvertFrom-Json -ErrorAction Stop
                    # Валидация структуры конфига
                    if ($null -eq $configData -or (-not $configData.PSObject.Properties.Name.Contains('assignments')) -or ($configData.assignments -isnot [array]) -or (-not $configData.PSObject.Properties.Name.Contains('assignment_config_version')) -or (-not $configData.assignment_config_version) ) { throw ("Файл '$($latestConfigFile.Name)' имеет некорректную структуру JSON (отсутствуют 'assignments' или 'assignment_config_version').") };

                    $tempVersionTag = $configData.assignment_config_version
                    $tempAssignments = $configData.assignments
                    Write-Log ("Файл '{0}' успешно прочитан. Заданий: {1}, Версия конфига: '{2}'." -f $latestConfigFile.Name, $tempAssignments.Count, $tempVersionTag) -Level Info
                    # Обновляем глобальные переменные Offline режима
                    $script:CurrentAssignmentsOffline = $tempAssignments
                    $script:CurrentConfigVersionOffline = $tempVersionTag
                    $script:LastProcessedConfigFileOffline = $latestConfigFile.FullName
                } catch {
                    $errorMsg = "Критическая ошибка обработки файла '$($latestConfigFile.Name)': $($_.Exception.Message)"; Write-Log $errorMsg -Level Error
                    Write-Log ("Продолжаем использовать предыдущий список заданий (версия: {0})." -f ($script:currentConfigVersionOffline | Get-OrElse '[неизвестно]')) -Level Warn
                    # Не обновляем $script:lastProcessedConfigFileOffline
                }
            } else { Write-Log "Файл конфигурации '$($latestConfigFile.Name)' не изменился." -Level Verbose }
        } elseif ($configError -ne $null) { Write-Log "Продолжаем использовать предыдущий список заданий из-за ошибки поиска файла." -Level Warn }
        elseif ($script:lastProcessedConfigFileOffline -ne $null) { Write-Log "Файлы конфигурации не найдены. Продолжаем использовать предыдущий список." -Level Warn }
        else { Write-Log "Файлы конфигурации не найдены и нет предыдущего списка. Задания не будут выполнены." -Level Info }

        # --- Выполнение текущего списка заданий ---
        $cycleCheckResultsList = [System.Collections.Generic.List[object]]::new()
        if ($script:CurrentAssignmentsOffline -ne $null -and $script:CurrentAssignmentsOffline.Count -gt 0) {
            $assignmentsCount = $script:CurrentAssignmentsOffline.Count
            Write-Log ("Начало выполнения {0} заданий (Версия конфига: {1})..." -f $assignmentsCount, ($script:CurrentConfigVersionOffline | Get-OrElse 'N/A')) -Level Info
            $completedCount = 0

            foreach ($assignmentRaw in $script:CurrentAssignmentsOffline) {
                $completedCount++
                $assignment = $null # Сбрасываем перед каждой итерацией
                $currentAssignmentId = $null
                $currentMethodName = "[unknown method]"
                $currentNodeName = "[unknown node]"

                try {
                     # Преобразуем в PSCustomObject и валидируем базовую структуру
                     $assignment = [PSCustomObject]$assignmentRaw
                     $currentAssignmentId = $assignment.assignment_id
                     $currentMethodName = $assignment.method_name
                     $currentNodeName = $assignment.node_name | Get-OrElse "Assignment $currentAssignmentId"

                     if ($null -eq $assignment -or $null -eq $currentAssignmentId -or -not $currentMethodName) { throw "Некорректная структура задания в файле конфигурации." }

                     Write-Log ("Выполнение {0}/{1} (ID: {2}, Метод: {3}, Узел: '{4}')..." -f $completedCount, $assignmentsCount, $currentAssignmentId, $currentMethodName, $currentNodeName) -Level Verbose

                     # --- Вызов основной функции проверки ---
                     $checkResult = Invoke-StatusMonitorCheck -Assignment $assignment `
                                                               -Verbose:$false `
                                                               -Debug:$false

                     if ($checkResult -eq $null -or $checkResult.IsAvailable -eq $null) { throw "Invoke-StatusMonitorCheck вернул некорректный результат." }

                     Write-Log ("Результат ID {0}: IsAvail={1}, ChkSucc={2}, Err='{3}'" -f `
                                $currentAssignmentId, $checkResult.IsAvailable, $checkResult.CheckSuccess, $checkResult.ErrorMessage) -Level Verbose

                    # --- СОЗДАЕМ НОВЫЙ ОБЪЕКТ С ДОБАВЛЕННЫМ assignment_id ---
                     $resultToSave = @{ assignment_id = $currentAssignmentId } + $checkResult
                    # --- КОНЕЦ СОЗДАНИЯ ---

                     # Добавляем результат в список для файла
                     $cycleCheckResultsList.Add($resultToSave)

                } catch { # Ловим ошибки ВАЛИДАЦИИ или ВЫПОЛНЕНИЯ КОНКРЕТНОГО ЗАДАНИЯ
                     $errorMessage = "Ошибка обработки/выполнения задания ID {0} ({1} для '{2}'): {3}" -f `
                                     ($currentAssignmentId | Get-OrElse '[N/A]'), $currentMethodName, $currentNodeName, $_.Exception.Message
                     Write-Log $errorMessage -Level Error
                     # Формируем результат с ошибкой и добавляем его в список
                     $errorDetails = @{ ErrorRecord = $_.ToString(); OriginalAssignment = ($assignmentRaw | ConvertTo-Json -Depth 2 -Compress -WarningAction SilentlyContinue) }
                     $errorResultBase = New-CheckResultObject -IsAvailable $false -ErrorMessage $errorMessage -Details $errorDetails
                     # Добавляем ID, если он был
                     $errorResultToSave = @{ assignment_id = $currentAssignmentId } + $errorResultBase
                     $cycleCheckResultsList.Add($errorResultToSave)
                 }
            } # Конец foreach assignment
            Write-Log "Выполнение $assignmentsCount заданий завершено. Собрано результатов: $($cycleCheckResultsList.Count)." -Level Info
        } else { Write-Log "Нет активных заданий для выполнения." -Level Verbose }

        # --- Формирование и АТОМАРНОЕ сохранение файла *.zrpu ---
        if ($cycleCheckResultsList.Count -gt 0) {
             $timestampForFile = Get-Date -Format "ddMMyy_HHmmss"
             $outputFileName = $outputNameTemplate -replace "{object_id}", $script:Config.object_id -replace "{ddMMyy_HHmmss}", $timestampForFile
             $outputFileName = $outputFileName -replace '[\\/:*?"<>|]', '_' # Убираем недопустимые символы
             $outputFileFullPath = Join-Path $outputPath $outputFileName
             # Путь к временному файлу
             $tempOutputFileFullPath = $outputFileFullPath + ".tmp"

             Write-Log ("Сохранение {0} результатов в файл: '{1}'" -f $cycleCheckResultsList.Count, $outputFileFullPath) -Level Info
             Write-Log ("Версия агента: {0}, Версия конфига заданий: {1}" -f $script:AgentVersion, ($script:CurrentConfigVersionOffline | Get-OrElse 'N/A')) -Level Verbose

             # Формируем итоговый объект
             $finalPayload = @{
                 agent_script_version      = $script:AgentVersion
                 assignment_config_version = $script:CurrentConfigVersionOffline
                 object_id                 = $script:Config.object_id # Для идентификации источника Загрузчиком
                 execution_timestamp_utc   = $cycleStartTime.ToString("o") # Время начала цикла
                 results                   = $cycleCheckResultsList
             }

             # Атомарное сохранение
             try {
                 # 1. Сохраняем во временный файл
                 $jsonToSave = $finalPayload | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
                 $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
                 [System.IO.File]::WriteAllText($tempOutputFileFullPath, $jsonToSave, $Utf8NoBomEncoding)
                 Write-Log "Данные успешно записаны во временный файл: '$tempOutputFileFullPath'" -Level Debug

                 # 2. Переименовываем временный файл в основной (атомарно в NTFS)
                 Move-Item -Path $tempOutputFileFullPath -Destination $outputFileFullPath -Force -ErrorAction Stop
                 Write-Log "Файл результатов '$outputFileName' успешно сохранен (атомарно)." -Level Info

             } catch {
                 Write-Log ("Критическая ошибка сохранения/переименования файла результатов '{0}': {1}" `
                            -f $outputFileFullPath, $_.Exception.Message) -Level Error
                 # Пытаемся удалить временный файл, если он остался
                 if (Test-Path $tempOutputFileFullPath -PathType Leaf) {
                     try { Remove-Item -Path $tempOutputFileFullPath -Force -ErrorAction SilentlyContinue } catch {}
                 }
             }
        } else {
             Write-Log "Нет результатов для сохранения в файл." -Level Verbose
        }

        # --- Пауза (если в циклическом режиме) ---
        if ($runContinuously) {
            $cycleEndTime = [DateTimeOffset]::UtcNow
            $elapsedSeconds = ($cycleEndTime - $cycleStartTime).TotalSeconds
            $sleepSeconds = $offlineInterval - $elapsedSeconds
            if ($sleepSeconds -lt 1) { $sleepSeconds = 1 }
            Write-Log ("Итерация Offline заняла {0:N2} сек. Пауза {1:N2} сек..." -f $elapsedSeconds, $sleepSeconds) -Level Verbose
            Start-Sleep -Seconds $sleepSeconds
        }

    } while ($runContinuously) # --- Конец do-while Offline ---

    Write-Log ("Offline режим завершен ({0})." -f ($runContinuously ? 'цикл прерван?' : 'однократный запуск')) -Level Info
    exit 0 # Успешный выход (особенно для однократного режима)

# --- ============================= ---
# --- НЕИЗВЕСТНЫЙ РЕЖИМ / ОШИБКА  ---
# --- ============================= ---
} else {
     Write-Log "Критическая ошибка: Неизвестный или некорректный режим работы '$($script:Config.mode)' в файле конфигурации." -Level Error
     Write-Log "Допустимые режимы: 'Online' или 'Offline'." -Level Error
     exit 1
}

# Код сюда не должен доходить при нормальной работе
Write-Log "Агент завершает работу непредвиденно." -Level Error
exit 1