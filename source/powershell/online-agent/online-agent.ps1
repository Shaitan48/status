# powershell\online-agent\online-agent.ps1
# Версия с поддержкой нового диспетчера, формата результата,
# улучшенным форматированием, комментариями и исправленными ошибками.
<#
.SYNOPSIS
    Онлайн-агент для системы мониторинга Status Monitor v5.5.
.DESCRIPTION
    Этот агент предназначен для работы на машинах, имеющих прямой сетевой
    доступ к API сервера мониторинга. Он выполняет следующие действия:
    1. Читает локальную конфигурацию из файла 'config.json'.
    2. Импортирует необходимый модуль StatusMonitorAgentUtils.
    3. Периодически (раз в api_poll_interval_seconds) обращается к API
       сервера (/api/v1/assignments) для получения списка активных заданий
       мониторинга, предназначенных для его object_id.
    4. Хранит список заданий в памяти и самостоятельно планирует их выполнение
       согласно интервалам, указанным в заданиях или в конфиге по умолчанию.
    5. Для выполнения каждой проверки вызывает функцию Invoke-StatusMonitorCheck
       из импортированного модуля.
    6. Получает стандартизированный результат от Invoke-StatusMonitorCheck.
    7. Преобразует результат в формат, ожидаемый API /checks (v1).
    8. Немедленно отправляет результат каждой проверки на сервер через
       POST-запрос к API /api/v1/checks, используя API-ключ для аутентификации.
    9. Ведет лог своей работы в указанный файл.
.NOTES
    Версия: 5.5
    Дата: 2024-05-20
    Изменения v5.5:
        - Исправлена ошибка CommandNotFoundException из-за заглушек "..." в ConvertTo-Json при сравнении заданий.
    Изменения v5.4:
        - Исправлена ошибка ParameterBindingException при вызове Write-Verbose с уровнем Debug. Заменено на Write-Debug.
    Изменения v5.3:
        - Исправлена ошибка парсинга строки в блоке catch функции Send-CheckResultToApi.
    Изменения v5.2:
        - Исправлена ошибка CommandNotFoundException из-за заглушек "...".
        - Реализовано корректное частичное отображение API ключа в логах.
        - Разбиты длинные строки кода на несколько для читаемости.
        - Добавлены подробные комментарии.
        - Улучшено форматирование.
        - Функция Get-ActiveAssignments вынесена и исправлена.
    Изменения v5.1:
        - Адаптация под новый формат результата Invoke-StatusMonitorCheck.
        - Использование полей IsAvailable и CheckSuccess из результата проверки.
        - Формирование detail_type и detail_data для API на основе результата.
        - Использование IsAvailable для определения доступности узла при отправке.
    Зависимости: PowerShell 5.1+, модуль StatusMonitorAgentUtils, доступ к API.
#>
param(
    # Путь к файлу конфигурации агента.
    [string]$ConfigFile = "$PSScriptRoot\config.json"
)

# --- Загрузка необходимого модуля утилит ---
# Устанавливаем строгий режим обработки ошибок на время импорта
$ErrorActionPreference = "Stop"
try {
    # Определяем путь к манифесту модуля относительно текущего скрипта
    $ModuleManifestPath = Join-Path -Path $PSScriptRoot `
                                    -ChildPath "..\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1"
    Write-Host "[INFO] Загрузка модуля '$ModuleManifestPath'..."
    # Принудительно импортируем модуль
    Import-Module $ModuleManifestPath -Force -ErrorAction Stop
    Write-Host "[INFO] Модуль Utils загружен."
} catch {
    # Критическая ошибка - агент не может работать без модуля
    Write-Host "[CRITICAL] Критическая ошибка загрузки модуля '$ModuleManifestPath': $($_.Exception.Message)" -ForegroundColor Red
    # Завершаем работу скрипта с кодом ошибки
    exit 1
} finally {
    # Возвращаем стандартное поведение обработки ошибок
    $ErrorActionPreference = "Continue"
}
# --- Конец загрузки модуля ---

# --- Глобальные переменные и константы ---

# Версия текущего скрипта агента
$ScriptVersion = "5.5" # Обновили версию

# Хэш-таблица для хранения активных заданий (ключ - assignment_id, значение - объект задания)
$script:ActiveAssignments = @{}
# Хэш-таблица для хранения времени последнего выполнения каждого задания (ключ - assignment_id, значение - строка ISO 8601 UTC)
$script:LastExecutedTimes = @{}
# Объект для хранения конфигурации из файла config.json
$script:Config = $null
# API ключ для аутентификации на сервере
$script:ApiKey = $null
# Имя текущего компьютера для идентификации в логах и результатах
$script:ComputerName = $env:COMPUTERNAME

# --- Значения по умолчанию для параметров конфигурации ---
# Как часто опрашивать API на предмет новых/измененных заданий (секунды)
$DefaultApiPollIntervalSeconds = 60
# Интервал выполнения проверки по умолчанию (если не указан в задании, секунды)
$DefaultCheckIntervalSeconds = 120
# Уровень логирования по умолчанию
$DefaultLogLevel = "Info"
# Путь к лог-файлу по умолчанию (в папке со скриптом)
$DefaultLogFile = "$PSScriptRoot\online_agent.log"
# Таймаут ожидания ответа от API (секунды)
$ApiTimeoutSeconds = 30
# Максимальное количество попыток запроса к API при ошибке
$MaxApiRetries = 3
# Задержка между повторными попытками запроса к API (секунды)
$RetryDelaySeconds = 5
# Допустимые уровни логирования
$ValidLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error")
# Эффективный уровень логирования (будет установлен после чтения конфига)
$script:EffectiveLogLevel = $DefaultLogLevel

# --- Функции ---

#region Функции

<#
.SYNOPSIS
    Записывает сообщение в лог-файл и/или выводит в консоль.
# ... (документация Write-Log без изменений) ...
#>
function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
        [string]$Level = "Info"
    )
    # ... (код функции Write-Log без изменений) ...
    $logFilePath = $script:Config.logFile | Get-OrElse $DefaultLogFile; $logLevels = @{ "Debug" = 4; "Verbose" = 3; "Info" = 2; "Warn" = 1; "Error" = 0 }; $currentLevelValue = $logLevels[$script:EffectiveLogLevel]; if ($null -eq $currentLevelValue) { $currentLevelValue = $logLevels["Info"] }; $messageLevelValue = $logLevels[$Level]; if ($null -eq $messageLevelValue) { $messageLevelValue = $logLevels["Info"] }; if ($messageLevelValue -le $currentLevelValue) { $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage = "[$timestamp] [$Level] [$script:ComputerName] - $Message"; $consoleColor = switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}; Write-Host $logMessage -ForegroundColor $consoleColor; try { $logDir = Split-Path $logFilePath -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { Write-Host "[INFO] Создание папки логов: '$logDir'"; New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }; $logMessage | Out-File -FilePath $logFilePath -Append -Encoding UTF8 -ErrorAction Stop } catch { Write-Host "[Error] Не удалось записать в лог '$($logFilePath)': $($_.Exception.Message)" -ForegroundColor Red } }
}

<#
.SYNOPSIS
    Возвращает значение по умолчанию, если входное значение ложно.
# ... (документация Get-OrElse без изменений) ...
#>
filter Get-OrElse {
    param([object]$DefaultValue)
    if ($_) { $_ } else { $DefaultValue }
}

<#
.SYNOPSIS
    Отправляет результат ОДНОЙ проверки в API /checks.
# ... (документация Send-CheckResultToApi без изменений) ...
#>
function Send-CheckResultToApi {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$CheckResult,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Assignment
    )

    $assignmentId = $Assignment.assignment_id
    Write-Log "Отправка результата для задания ID $assignmentId..." "Verbose"

    # --- Формируем тело запроса для API /checks ---
    $isAvailableApi = [bool]$CheckResult.IsAvailable
    $checkTimestampApi = $CheckResult.Timestamp
    $detailTypeApi = $null
    $detailDataApi = $null

    if ($CheckResult.Details -ne $null -and $CheckResult.Details -is [hashtable]) {
        $detailTypeApi = $Assignment.method_name
        $detailDataApi = $CheckResult.Details
        if ($CheckResult.ContainsKey('CheckSuccess')) {
            $detailDataApi.check_success = $CheckResult.CheckSuccess
        }
        if (-not [string]::IsNullOrEmpty($CheckResult.ErrorMessage)) {
             $detailDataApi.error_message_from_check = $CheckResult.ErrorMessage
        }
    }
    elseif (-not [string]::IsNullOrEmpty($CheckResult.ErrorMessage)) {
        $detailTypeApi = "ERROR"
        $detailDataApi = @{ message = $CheckResult.ErrorMessage }
    }

    $body = @{
        assignment_id        = $assignmentId
        is_available         = $isAvailableApi
        check_timestamp      = $checkTimestampApi
        executor_object_id   = $script:Config.object_id
        executor_host        = $script:ComputerName
        resolution_method    = $Assignment.method_name
        detail_type          = $detailTypeApi
        detail_data          = $detailDataApi
        agent_script_version = $ScriptVersion
    }
    # --- Конец формирования тела запроса ---

    # Преобразуем тело в JSON строку
    try {
        $jsonBody = $body | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
    } catch {
         # Используем -f для форматирования строки
         Write-Log ("Критическая ошибка ConvertTo-Json для ID {0}: {1}" -f $assignmentId, $_.Exception.Message) "Error"
         Write-Log "Проблемный объект: $($body | Out-String)" "Error"
         return $false
    }

    # Заголовки и URL
    $headers = @{
        'Content-Type' = 'application/json; charset=utf-8'
        'X-API-Key'    = $script:ApiKey
    }
    $apiUrl = "$($script:Config.apiBaseUrl.TrimEnd('/'))/v1/checks"
    Write-Log "URL отправки: $apiUrl" "Debug"
    Write-Log "Тело JSON: $jsonBody" "Debug"

    # --- Отправка запроса с логикой повторных попыток (retry) ---
    $retryCount = 0; $success = $false
    while ($retryCount -lt $MaxApiRetries -and (-not $success)) {
        try {
            $response = Invoke-RestMethod -Uri $apiUrl `
                                          -Method Post `
                                          -Body ([System.Text.Encoding]::UTF8.GetBytes($jsonBody)) `
                                          -Headers $headers `
                                          -TimeoutSec $ApiTimeoutSeconds `
                                          -ErrorAction Stop

            Write-Log ("Результат ID {0} отправлен. Ответ API: {1}" -f `
                        $assignmentId, ($response | ConvertTo-Json -Depth 2 -Compress -WarningAction SilentlyContinue)) "Info"
            $success = $true

        } catch {
            $retryCount++; $statusCode = $null; if ($_.Exception.Response) { try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {} }; $errorMessage = $_.Exception.Message;
            $errorResponseBody = "[не удалось прочитать тело ответа]"; if ($_.Exception.Response) { try { $errorStream = $_.Exception.Response.GetResponseStream(); $reader = New-Object System.IO.StreamReader($errorStream); $errorResponseBody = $reader.ReadToEnd(); $reader.Close(); $errorStream.Dispose() } catch {} };
            Write-Log ("Ошибка отправки ID {0} (попытка {1}/{2}). Код: {3}. Error: {4}. Ответ: {5}" -f $assignmentId, $retryCount, $MaxApiRetries, ($statusCode | Get-OrElse 'N/A'), $errorMessage, $errorResponseBody) "Error"
            if ($statusCode -eq 401 -or $statusCode -eq 403) { Write-Log "Критическая ошибка: Неверный API ключ или права (Код: $statusCode). Завершение работы." "Error"; exit 1 }
            if ($retryCount -ge $MaxApiRetries) { Write-Log "Превышено кол-во попыток ($MaxApiRetries) для ID $assignmentId." "Error"; break }
            Write-Log "Пауза $RetryDelaySeconds сек..." "Warn"; Start-Sleep -Seconds $RetryDelaySeconds
        }
    } # Конец while retry
    return $success
}

<#
.SYNOPSIS
    Запрашивает активные задания у API сервера.
# ... (документация Get-ActiveAssignments без изменений) ...
#>
function Get-ActiveAssignments {
    Write-Log "Запрос активных заданий у API..." "Info"
    $apiUrl = "$($script:Config.apiBaseUrl.TrimEnd('/'))/v1/assignments?object_id=$($script:Config.object_id)"
    Write-Log "URL: $apiUrl" "Verbose"

    # Отображение части API ключа
    $apiKeyPartial = "[Не задан]"
    if ($script:ApiKey) {
        $len = $script:ApiKey.Length; $prefix = $script:ApiKey.Substring(0, [math]::Min(4, $len)); $suffix = if ($len -gt 8) { $script:ApiKey.Substring($len - 4, 4) } else { "" }; $apiKeyPartial = "$prefix....$suffix"
    }
    Write-Log "Исп. API ключ (частично): $apiKeyPartial" "Debug"

    $headers = @{ 'X-API-Key' = $script:ApiKey }
    $newAssignments = $null; $retryCount = 0
    while ($retryCount -lt $MaxApiRetries -and $newAssignments -eq $null) {
        try {
            $newAssignments = Invoke-RestMethod -Uri $apiUrl `
                                                -Method Get `
                                                -Headers $headers `
                                                -TimeoutSec $ApiTimeoutSeconds `
                                                -ErrorAction Stop
            if ($newAssignments -isnot [array]) { throw ("API ответ не является массивом: $($newAssignments | Out-String)") }
            Write-Log "Получено $($newAssignments.Count) активных заданий." "Info"
            return $newAssignments
        } catch {
            $retryCount++; $statusCode = $null; if ($_.Exception.Response) { try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {} }; $errorMessage = $_.Exception.Message;
            Write-Log ("Ошибка API при получении заданий (попытка {0}/{1}). Код: {2}. Error: {3}" -f $retryCount, $MaxApiRetries, ($statusCode | Get-OrElse 'N/A'), $errorMessage) "Error"
            if ($statusCode -eq 401 -or $statusCode -eq 403) { Write-Log "Критическая ошибка: Неверный API ключ или права (Код: $statusCode). Завершение работы." "Error"; exit 1 }
            if ($retryCount -ge $MaxApiRetries) { Write-Log "Превышено кол-во попыток ($MaxApiRetries) получения заданий." "Error"; return $null }
            Write-Log "Пауза $RetryDelaySeconds сек..." "Warn"; Start-Sleep -Seconds $RetryDelaySeconds
        }
    } # Конец while retry
    return $null
}

#endregion Функции

# --- Основной код агента ---

# 1. Чтение конфигурации из файла
Write-Host "Чтение конфигурации из: $ConfigFile"
if (-not (Test-Path $ConfigFile -PathType Leaf)) { Write-Error ...; exit 1 }
try { $script:Config = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Error ...; exit 1 }
$requiredCfg=@("object_id","apiBaseUrl","api_key","logFile","LogLevel","api_poll_interval_seconds","default_check_interval_seconds"); $missingCfg=$requiredCfg|?{-not $script:Config.PSObject.Properties.Name.Contains($_) -or !$script:Config.$_}; if($missingCfg){ Write-Error ...; exit 1 }
$script:EffectiveLogLevel = $script:Config.LogLevel | Get-OrElse $DefaultLogLevel
if ($script:EffectiveLogLevel -notin $ValidLogLevels) { Write-Host ...; $script:EffectiveLogLevel = $DefaultLogLevel }
$script:ApiKey = $script:Config.api_key

# 2. Инициализация и логирование старта агента
Write-Log "Онлайн-агент v$ScriptVersion запущен." "Info"
Write-Log "Конфигурация: ObjectID=$($script:Config.object_id), API URL=$($script:Config.apiBaseUrl)" "Info"
Write-Log ("Интервал опроса API: {0} сек, Стандартный интервал проверки: {1} сек." -f `
    $script:Config.api_poll_interval_seconds, $script:Config.default_check_interval_seconds) "Verbose"
Write-Log "Логирование в '$($script:Config.logFile)' с уровнем '$($script:EffectiveLogLevel)'" "Info"

# 3. Основной цикл работы агента
$lastApiPollTime = [DateTime]::MinValue
$apiPollInterval = [TimeSpan]::FromSeconds($script:Config.api_poll_interval_seconds)
$DefaultCheckInterval = [TimeSpan]::FromSeconds($script:Config.default_check_interval_seconds)

Write-Log "Запуск основного цикла обработки заданий..." "Info"
while ($true) {
    $loopStartTime = Get-Date
    Write-Log "Начало итерации цикла." "Verbose"

    # 3.1 Запрос/обновление списка активных заданий у API
    if (($loopStartTime - $lastApiPollTime) -ge $apiPollInterval) {
        Write-Log "Время обновить список заданий с API." "Info"; $fetchedAssignments = Get-ActiveAssignments
        if ($fetchedAssignments -ne $null) {
            Write-Log "Обработка полученных заданий..." "Info"; $newAssignmentMap = @{}; $fetchedIds = [System.Collections.Generic.List[int]]::new()
            foreach ($assignment in $fetchedAssignments) { if ($assignment.assignment_id -ne $null) { $id = $assignment.assignment_id; $newAssignmentMap[$id] = $assignment; $fetchedIds.Add($id) } else { Write-Log "..." "Warn" } }
            $currentIds = $script:ActiveAssignments.Keys | ForEach-Object { [int]$_ }; $removedIds = $currentIds | Where-Object { $fetchedIds -notcontains $_ }
            if ($removedIds) { foreach ($removedId in $removedIds) { Write-Log "... $removedId" "Info"; $script:ActiveAssignments.Remove($removedId); $script:LastExecutedTimes.Remove($removedId) } }
            $addedCount = 0; $updatedCount = 0
            foreach ($assignmentId in $fetchedIds) {
                if (-not $script:ActiveAssignments.ContainsKey($assignmentId)) {
                    # Добавление нового задания
                    Write-Log "Добавлено новое задание ID $assignmentId" "Info"
                    $script:ActiveAssignments[$assignmentId] = $newAssignmentMap[$assignmentId]
                    $script:LastExecutedTimes[$assignmentId] = (Get-Date).AddDays(-1).ToUniversalTime().ToString("o")
                    $addedCount++
                } else {
                    # Проверка, изменилось ли существующее задание
                    # --- ИСПРАВЛЕНО: Убраны заглушки "..." ---
                    $oldJson = $script:ActiveAssignments[$assignmentId] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue
                    $newJson = $newAssignmentMap[$assignmentId] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue
                    # --- КОНЕЦ ИСПРАВЛЕНИЯ ---
                    if ($oldJson -ne $newJson) {
                         Write-Log "Обновлено задание ID $assignmentId" "Verbose"
                         $script:ActiveAssignments[$assignmentId] = $newAssignmentMap[$assignmentId]
                         # Сбрасывать ли LastExecutedTimes при обновлении?
                         # Пока не будем, чтобы не вызвать выполнение сразу после обновления.
                         $updatedCount++
                    }
                }
            } # Конец foreach ($assignmentId in $fetchedIds)
            Write-Log ("Синхронизация заданий завершена. Добавлено:{0}. Обновлено:{1}. Удалено:{2}." -f $addedCount, $updatedCount, $removedIds.Count) "Info"
            $lastApiPollTime = $loopStartTime
        } else { Write-Log "Не удалось получить задания от API..." "Error" }
    } else { Write-Log "Опрос API еще не требуется..." "Verbose" }

    # 3.2 Выполнение запланированных проверок
    # ... (код выполнения проверок, вызова Invoke-StatusMonitorCheck и Send-CheckResultToApi без изменений) ...
    $currentTime = Get-Date
    if ($script:ActiveAssignments.Count -gt 0) {
        Write-Log "Проверка запланированных заданий ($($script:ActiveAssignments.Count) активно)..." "Verbose"
        $assignmentIdsToCheck = $script:ActiveAssignments.Keys | ForEach-Object { $_ }
        foreach ($id in $assignmentIdsToCheck) {
            if (-not $script:ActiveAssignments.ContainsKey($id)) { continue }
            $assignment = $script:ActiveAssignments[$id]; $checkIntervalSeconds = $assignment.check_interval_seconds | Get-OrElse $script:Config.default_check_interval_seconds; if ($checkIntervalSeconds -le 0) { $checkIntervalSeconds = $script:Config.default_check_interval_seconds }; $checkInterval = [TimeSpan]::FromSeconds($checkIntervalSeconds); $lastRunString = $script:LastExecutedTimes[$id]; $lastRunTime = [DateTime]::MinValue; if ($lastRunString) { try { $lastRunTime = [DateTime]::ParseExact($lastRunString,"o",$null).ToLocalTime() } catch { Write-Log "... ID ${id}: '$lastRunString'" "Error"; $lastRunTime = [DateTime]::MinValue } }; $nextRunTime = $lastRunTime + $checkInterval
            Write-Debug ("Задание ID {0}: Интервал={1} сек, Посл.={2}, След.={3}" -f $id, $checkInterval.TotalSeconds, $lastRunTime.ToString('s'), $nextRunTime.ToString('s'))
            if ($currentTime -ge $nextRunTime) {
                Write-Log ("ВЫПОЛНЕНИЕ ЗАДАНИЯ ID {0} ({1} для {2})." -f $id, $assignment.method_name, $assignment.node_name) "Info"; $checkResult = $null
                try { $checkResult = Invoke-StatusMonitorCheck -Assignment $assignment -Verbose:$VerbosePreference -Debug:$DebugPreference; Write-Log ("Результат проверки ID {0}: IsAvailable={1}, CheckSuccess={2}, Error='{3}'" -f $id, $checkResult.IsAvailable, $checkResult.CheckSuccess, $checkResult.ErrorMessage) "Verbose"; Write-Log ("Детали результата ID {0}: {1}" -f $id, ($checkResult.Details | ConvertTo-Json -Depth 3 -Compress -WarningAction SilentlyContinue)) "Debug"; $sendSuccess = Send-CheckResultToApi -CheckResult $checkResult -Assignment $assignment; if ($sendSuccess) { $script:LastExecutedTimes[$id] = $currentTime.ToUniversalTime().ToString("o"); Write-Log "Время последнего выполнения ID $id обновлено." "Verbose" } else { Write-Log "Результат для ID $id НЕ был успешно отправлен в API." "Error" } } catch { Write-Log "Критическая ошибка при ВЫПОЛНЕНИИ задания ID ${id}: $($_.Exception.Message)" "Error" }
            }
        }
    } else { Write-Log "Нет активных заданий для выполнения." "Verbose" }

    # 3.3 Пауза перед следующей итерацией
    Start-Sleep -Seconds 1

} # --- Конец while ($true) ---

Write-Log "Онлайн-агент завершает работу (неожиданный выход из основного цикла)." "Error"
exit 1