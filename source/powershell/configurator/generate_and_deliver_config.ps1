# powershell/configurator/generate_and_deliver_config.ps1
# --- Конфигуратор для Гибридного Агента Status Monitor (v5.x - Pipeline Архитектура) ---
# --- Версия 5.0.0 ---
# Изменения:
# - Обновлены комментарии и версия для соответствия архитектуре v5.x (Гибридный Агент, pipeline-задания).
# - Логика запроса и сохранения JSON остается прежней, так как API /offline_config уже должен
#   возвращать конфигурацию с pipeline-заданиями.
# - Подтверждена атомарность операций сохранения и доставки.
# - Улучшено логирование некоторых шагов.

<#
.SYNOPSIS
    Генерирует и (опционально) атомарно доставляет конфигурационные файлы
    с pipeline-заданиями для Гибридного Агента Status Monitor (v5.x),
    работающего в Offline-режиме.
.DESCRIPTION
    Скрипт выполняет следующие действия:
    1. Читает параметры конфигурации из указанного JSON-файла (по умолчанию `config.json`).
    2. Определяет список ObjectId (подразделений), для которых нужно сгенерировать конфигурацию.
       Этот список может быть задан в конфиге или получен от API (для всех подразделений с кодом ТС).
    3. Для каждого ObjectId:
       - Выполняет GET-запрос к API эндпоинту `/api/v1/objects/{ObjectId}/offline_config`.
         API должен вернуть полную JSON-конфигурацию, включающую метаданные
         (версия конфигурации, код транспортной системы) и массив `assignments`,
         где каждое задание содержит поле `pipeline` с массивом шагов.
       - Проверяет корректность ответа от API.
       - Формирует имя файла конфигурации на основе шаблона и данных из ответа
         (например, `{version_tag}_assignments.json.status.{transport_code}`).
       - **Атомарно сохраняет** полученную JSON-конфигурацию:
         - Сначала во временный файл (`.tmp`) в папке `output_path_base`.
         - Затем, при успехе, переименовывает временный файл в основной.
       - Если указан путь `delivery_path_base` в конфигурации:
         - **Атомарно доставляет** (копирует и переименовывает) сгенерированный файл
           в целевую папку доставки (обычно `delivery_path_base` / `delivery_subdir_template`).
    Атомарность операций важна, чтобы агент не прочитал частично записанный файл.
.NOTES
    Версия: 5.0.0
    Дата: [Актуальная Дата]
    Требует PowerShell v5.1+.
    Для корректной работы API эндпоинт /api/v1/objects/{ObjectId}/offline_config
    должен возвращать конфигурацию с pipeline-заданиями.
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\config.json", # Путь к файлу конфигурации скрипта
    [string]$ParamLogFile = $null, # Переопределение пути к лог-файлу через параметр
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
    [string]$ParamLogLevel = $null # Переопределение уровня логирования через параметр
)

# --- Вспомогательные функции ---
# Get-OrElse_Internal: Возвращает значение по умолчанию, если основное значение $null или пустое.
filter Get-OrElse_Internal { param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }

# Write-Log: Кастомная функция логирования с уровнями и записью в файл.
function Write-Log {
    param (
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
        [string]$Level = "Info"
    )
    # Проверка, что конфигурация и путь к логу загружены
    if (-not $script:Config -or -not $script:Config.log_file) {
        Write-Host "[$Level] $Message"; return # Если нет, выводим только в консоль
    }
    # Определение числовых уровней логирования для сравнения
    $logLevels = @{ "Debug" = 4; "Verbose" = 3; "Info" = 2; "Warn" = 1; "Error" = 0 }
    $currentLevelValue = $logLevels[$script:EffectiveLogLevel]
    if ($null -eq $currentLevelValue) { $currentLevelValue = $logLevels["Info"] } # По умолчанию Info
    $messageLevelValue = $logLevels[$Level]
    if ($null -eq $messageLevelValue) { $messageLevelValue = $logLevels["Info"] }

    # Логируем, только если уровень сообщения не ниже установленного
    if ($messageLevelValue -le $currentLevelValue) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logMessage = "[$timestamp] [$Level] [Configurator_v$($ScriptVersion)] - $Message" # Добавляем версию конфигуратора
        # Устанавливаем цвет для вывода в консоль
        $consoleColor = switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}
        Write-Host $logMessage -ForegroundColor $consoleColor
        try {
            # Создаем директорию для лог-файла, если она не существует
            $logDir = Split-Path $script:Config.log_file -Parent
            if ($logDir -and (-not (Test-Path $logDir -PathType Container))) {
                Write-Host "[INFO] Создание папки для лога: '$logDir'";
                New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            # Записываем сообщение в лог-файл
            $logMessage | Out-File -FilePath $script:Config.log_file -Append -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Host "[Error] Невозможно записать в лог '$($script:Config.log_file)': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# --- Начало скрипта ---
$ScriptVersion = "5.0.0" # <<< ОБНОВЛЕНА ВЕРСИЯ СКРИПТА
$script:Config = $null
$script:EffectiveLogLevel = "Info" # Уровень логирования по умолчанию

# --- Шаг 1: Чтение и валидация файла конфигурации скрипта ---
Write-Host "Конфигуратор (v$ScriptVersion): Загрузка конфигурации из файла: $ConfigFile"
$configObject = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($null -eq $configObject) {
    Write-Error "Критическая ошибка: Не удалось прочитать или распарсить JSON из '$ConfigFile'. Объект конфигурации пуст."
    # Попытка вывести часть содержимого файла для диагностики
    try { $rawContentForError = Get-Content -Path $ConfigFile -Raw -Encoding Default; Write-Error "Содержимое файла (UTF8 по умолчанию, первые 200 симв.): $($rawContentForError.Substring(0, [System.Math]::Min($rawContentForError.Length, 200)))" } catch {}
    exit 1
}
$script:Config = $configObject # Сохраняем конфигурацию в глобальную переменную скрипта

# Валидация обязательных полей в конфигурации
$requiredConfigFields = @("api_base_url", "api_key", "output_path_base", "log_file", "log_level", "subdivision_ids_to_process", "output_filename_template", "delivery_subdir_template", "api_timeout_sec")
# Поле delivery_path_base может быть $null (опционально)
$foundMissingFields = [System.Collections.Generic.List[string]]::new()
foreach ($field in $requiredConfigFields) {
    $fieldExists = $false; $fieldValue = $null
    # Проверка существования поля в зависимости от типа объекта конфигурации (Hashtable или PSCustomObject)
    if ($script:Config -is [hashtable]) { if ($script:Config.ContainsKey($field)) { $fieldExists = $true; $fieldValue = $script:Config[$field] } }
    elseif ($script:Config -is [System.Management.Automation.PSCustomObject]) { if ($script:Config.PSObject.Properties.Name -contains $field) { $fieldExists = $true; $fieldValue = $script:Config.$field } }
    else { Write-Error "Критическая ошибка: Объект конфигурации имеет неожиданный тип '$($script:Config.GetType().FullName)'." ; exit 1 }

    if (-not $fieldExists) { $foundMissingFields.Add("'$field' (полностью отсутствует)") }
    # Проверяем на $null (кроме delivery_path_base, которое может быть null)
    elseif ($fieldValue -eq $null -and $field -ne 'delivery_path_base') { $foundMissingFields.Add("'$field' (равен `$null)") }
    # Проверяем на пустую строку (кроме delivery_path_base и api_key, которые могут быть пустыми, если не используются)
    elseif (($fieldValue -is [string] -and [string]::IsNullOrWhiteSpace($fieldValue)) -and $field -notin @('delivery_path_base', 'api_key')) { $foundMissingFields.Add("'$field' (пустая строка)") }
}
if ($foundMissingFields.Count -gt 0) { Write-Error "Критическая ошибка: В '$ConfigFile' отсутствуют, `$null или пусты следующие обязательные поля: $($foundMissingFields -join ', ')"; exit 1 }

# --- Шаг 2: Инициализация логирования и переопределение параметров из командной строки ---
# Создание папки для логов, если ее нет
$logDirForInit = Split-Path $script:Config.log_file -Parent; if ($logDirForInit -and (-not (Test-Path $logDirForInit -PathType Container))) { try { New-Item -Path $logDirForInit -ItemType Directory -Force -EA Stop | Out-Null } catch { Write-Error "Не удалось создать папку для лог-файла: $($_.Exception.Message)"; exit 1 } }
# Установка эффективного уровня логирования (из конфига или параметра)
$script:EffectiveLogLevel = $script:Config.log_level
if ($PSBoundParameters.ContainsKey('ParamLogFile') -and $ParamLogFile) { $script:Config.log_file = $ParamLogFile }
if ($PSBoundParameters.ContainsKey('ParamLogLevel') -and $ParamLogLevel) { $script:EffectiveLogLevel = $ParamLogLevel }

Write-Log "Скрипт конфигуратора (v$ScriptVersion) запущен." "Info"
Write-Log "Конфигурация загружена: $($script:Config | ConvertTo-Json -Depth 3 -Compress)" "Debug"

# --- Шаг 3: Определение списка ObjectId (подразделений) для обработки ---
$objectIdsToProcess = @() # Массив для хранения ID подразделений
if ($script:Config.subdivision_ids_to_process -is [array] -and $script:Config.subdivision_ids_to_process.Count -gt 0) {
    # Если список ID задан в конфиге, используем его
    $objectIdsToProcess = $script:Config.subdivision_ids_to_process | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    Write-Log "Будут обработаны ObjectId из конфигурационного файла: $($objectIdsToProcess -join ', ')" "Info"
} else {
    # Если список ID не задан, запрашиваем у API все подразделения с кодом транспортной системы (ТС)
    Write-Log "Запрос всех подразделений с кодом ТС из API (т.к. subdivision_ids_to_process не задан или пуст)..." "Info"
    $apiUrlSubdivisions = "$($script:Config.api_base_url.TrimEnd('/'))/v1/subdivisions?limit=1000&has_transport_code=true" # Добавлен фильтр has_transport_code
    $headersApi = @{ 'X-API-Key' = $script:Config.api_key }
    try {
        $responseApiSubdivisions = Invoke-RestMethod -Uri $apiUrlSubdivisions -Method Get -Headers $headersApi -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse_Internal 60) -ErrorAction Stop
        if ($responseApiSubdivisions -and $responseApiSubdivisions.items -is [array]) {
            # Отбираем только object_id для подразделений, у которых есть transport_system_code
            $objectIdsToProcess = $responseApiSubdivisions.items | Where-Object { $_.transport_system_code -and $_.object_id } | Select-Object -ExpandProperty object_id
            Write-Log "Найдено для обработки (через API, с кодом ТС): $($objectIdsToProcess.Count) подразделений. ID: $($objectIdsToProcess -join ', ')" "Info"
        } else {
            Write-Log "API не вернул список подразделений или вернул некорректный формат. Обработка невозможна." "Warn"
        }
    } catch {
        $rawErrorMessage = $_.Exception.Message; $responseBody="[N/A]"; $statusCode=$null; if($_.Exception.Response){try{$statusCode=$_.Exception.Response.StatusCode}catch{}; try{$stream=[System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream());$responseBody=$stream.ReadToEnd();$stream.Close()}catch{}};
        Write-Log "Критическая ошибка получения списка подразделений из API: $rawErrorMessage - Code: $statusCode - Resp: $responseBody" "Error"; exit 1
    }
}
if ($objectIdsToProcess.Count -eq 0) { Write-Log "Нет ObjectId для обработки (список пуст). Завершение работы скрипта." "Info"; exit 0 }

# --- Шаг 4: Цикл обработки каждого ObjectId ---
Write-Log "Начало цикла обработки для $($objectIdsToProcess.Count) подразделений." "Info"
foreach ($currentObjectId in $objectIdsToProcess) {
    Write-Log "--- Обработка ObjectId: $currentObjectId ---" "Info"
    $apiConfigResponse = $null # Ответ от API с конфигурацией
    $versionTagFromApi = "[error_version]" # Тег версии конфигурации из ответа API
    $transportCodeFromApi = "[error_tc]"    # Код транспортной системы из ответа API

    # 1. Запрос конфигурации у API для текущего ObjectId
    $apiUrlObjectConfig = "$($script:Config.api_base_url.TrimEnd('/'))/v1/objects/${currentObjectId}/offline_config"
    $headersConfigApi = @{ 'X-API-Key' = $script:Config.api_key }
    
    Write-Log "Запрос конфигурации для ObjectId $currentObjectId : GET $apiUrlObjectConfig" "Verbose"
    try {
        $apiConfigResponse = Invoke-RestMethod -Uri $apiUrlObjectConfig -Method Get -Headers $headersConfigApi -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse_Internal 60) -ErrorAction Stop
        
        # Проверка структуры ответа (должен быть PSCustomObject с нужными полями)
        if (-not ($apiConfigResponse -is [PSCustomObject]) -or `
            (-not $apiConfigResponse.PSObject.Properties.Name.Contains('assignment_config_version')) -or `
            (-not $apiConfigResponse.PSObject.Properties.Name.Contains('transport_system_code')) -or `
            (-not $apiConfigResponse.PSObject.Properties.Name.Contains('assignments')) -or `
            (-not ($apiConfigResponse.assignments -is [array])) ) { # 'assignments' должен быть массивом
            # Проверяем, не вернула ли SQL-функция ошибку внутри JSON
            if ($apiConfigResponse -is [PSCustomObject] -and $apiConfigResponse.PSObject.Properties.Name.Contains('error')) {
                throw "API вернул ожидаемую ошибку (из SQL-функции): $($apiConfigResponse.error)"
            } else {
                throw "Некорректная структура ответа API /offline_config. Ожидался объект с полями 'assignment_config_version', 'transport_system_code' и массивом 'assignments'."
            }
        }
        $versionTagFromApi = $apiConfigResponse.assignment_config_version
        $transportCodeFromApi = $apiConfigResponse.transport_system_code
        $assignmentCountInConfig = $apiConfigResponse.assignments.Count
        Write-Log "Конфигурация для ObjectId $currentObjectId успешно получена. Версия: '$versionTagFromApi'. Заданий: $assignmentCountInConfig. Код ТС: '$transportCodeFromApi'." "Info"

    } catch {
        # Обработка ошибок Invoke-RestMethod или выброшенных исключений
        $currentException = $_; $exceptionMessageForLog = "[Исключение отсутствует или неизвестно]"; $statusCodeForLog = "[N/A_Code]"; $responseBodyForLog = "[N/A_Body]"
        if ($null -ne $currentException) {
            if ($null -ne $currentException.Exception) {
                $exceptionMessageForLog = $currentException.Exception.Message
                if ($currentException.Exception -is [System.Net.WebException] -and $null -ne $currentException.Exception.Response) {
                    try { $statusCodeForLog = ([int]$currentException.Exception.Response.StatusCode).ToString() } catch { $statusCodeForLog = "[Ошибка получения кода]" }
                    try { $errorStream = $currentException.Exception.Response.GetResponseStream(); $reader = New-Object System.IO.StreamReader($errorStream); $responseBodyForLog = $reader.ReadToEnd(); $reader.Close(); $errorStream.Close(); try { $responseBodyForLog = ($responseBodyForLog | ConvertFrom-Json | ConvertTo-Json -Depth 3 -Compress) } catch {} } catch { $responseBodyForLog = "[Ошибка чтения тела ответа]" }
                } elseif ($null -ne $currentException.Exception.InnerException) { $responseBodyForLog = "InnerException: $($currentException.Exception.InnerException.Message)" }
                else { $responseBodyForLog = $currentException.Exception.ToString() } # Для не-WebException
            } else { $exceptionMessageForLog = $currentException.ToString() }
        }
        Write-Log "Ошибка получения конфигурации от API для ObjectId $currentObjectId : $exceptionMessageForLog (Код HTTP: $statusCodeForLog). Ответ/Детали: $responseBodyForLog. Пропуск этого ObjectId." "Error";
        continue # Переходим к следующему ObjectId в цикле
    }

    # 2. Формирование имен файлов на основе шаблонов и данных из API
    # Замена плейсхолдеров в шаблоне имени файла
    $outputFileNameBase = $script:Config.output_filename_template -replace "{version_tag}", $versionTagFromApi -replace "{transport_code}", $transportCodeFromApi
    # Очистка имени файла от недопустимых символов
    $outputFileNameCleaned = $outputFileNameBase -replace '[\\/:*?"<>|]', '_' # Заменяем на подчеркивание
    $outputFilePathFullName = Join-Path -Path $script:Config.output_path_base -ChildPath $outputFileNameCleaned
    $tempOutputFilePathFullName = $outputFilePathFullName + ".tmp" # Имя временного файла
    $outputDirectoryPath = Split-Path $outputFilePathFullName -Parent

    # 3. Создание папки для сохранения конфигурации, если она не существует
    if (-not (Test-Path $outputDirectoryPath -PathType Container)) {
        Write-Log "Создание папки вывода '$outputDirectoryPath' для конфигураций..." "Verbose"
        try { New-Item -Path $outputDirectoryPath -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        catch { Write-Log "Ошибка создания папки вывода '$outputDirectoryPath'. Пропуск сохранения для ObjectId $currentObjectId. Ошибка: $($_.Exception.Message)" "Error"; continue }
    }

    # 4. Атомарное сохранение JSON-конфигурации
    Write-Log "Сохранение конфигурации (версия '$versionTagFromApi') для ObjectId $currentObjectId во временный файл: $tempOutputFilePathFullName" "Verbose"
    $saveOperationSuccess = $false
    try {
        # Конвертируем полученный объект конфигурации обратно в JSON-строку для сохранения
        # Depth 10 для сохранения вложенных pipeline
        $jsonConfigToSave = $apiConfigResponse | ConvertTo-Json -Depth 10 -WarningAction SilentlyContinue -Compress
        # Используем UTF-8 без BOM (Byte Order Mark) для лучшей совместимости
        $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempOutputFilePathFullName, $jsonConfigToSave, $utf8NoBomEncoding)
        Write-Log "Данные конфигурации успешно записаны во временный файл." "Debug"
        # Переименовываем временный файл в основной (атомарная операция на большинстве ФС)
        Move-Item -Path $tempOutputFilePathFullName -Destination $outputFilePathFullName -Force -ErrorAction Stop
        Write-Log "Файл конфигурации '$outputFileNameCleaned' успешно сохранен (атомарно) в '$outputDirectoryPath'." "Info"
        $saveOperationSuccess = $true
    } catch {
        Write-Log "Ошибка сохранения/переименования файла конфигурации '$outputFilePathFullName' для ObjectId $currentObjectId. Ошибка: $($_.Exception.Message)" "Error"
        # Удаляем временный файл, если он остался
        if (Test-Path $tempOutputFilePathFullName -PathType Leaf) { try { Remove-Item -Path $tempOutputFilePathFullName -Force -ErrorAction SilentlyContinue } catch {} }
        continue # Пропускаем доставку, если сохранение не удалось
    }

    # 5. Атомарная доставка файла (если настроено и сохранение прошло успешно)
    if ($saveOperationSuccess -and $script:Config.delivery_path_base) {
        # Формируем путь для доставки
        $deliverySubDirName = $script:Config.delivery_subdir_template -replace "{transport_code}", $transportCodeFromApi
        $deliveryDirectoryPath = Join-Path -Path $script:Config.delivery_path_base -ChildPath $deliverySubDirName
        $deliveryFilePathFullName = Join-Path -Path $deliveryDirectoryPath -ChildPath $outputFileNameCleaned # Имя файла то же
        $tempDeliveryFilePathFullName = $deliveryFilePathFullName + ".tmp" # Временный файл в папке доставки

        Write-Log "Проверка пути доставки для ObjectId $currentObjectId : $deliveryFilePathFullName" "Info"
        # Создаем папку доставки, если ее нет
        if (-not (Test-Path $deliveryDirectoryPath -PathType Container)) {
            Write-Log "Папка доставки '$deliveryDirectoryPath' не найдена. Создание..." "Warn"
            try { New-Item -Path $deliveryDirectoryPath -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "Папка доставки '$deliveryDirectoryPath' успешно создана." "Verbose" }
            catch { Write-Log "Ошибка создания папки доставки '$deliveryDirectoryPath'. Пропуск доставки для ObjectId $currentObjectId. Ошибка: $($_.Exception.Message)" "Error"; continue }
        }
        Write-Log "Копирование файла '$outputFilePathFullName' во временный файл доставки '$tempDeliveryFilePathFullName'..." "Verbose"
        try {
             Copy-Item -Path $outputFilePathFullName -Destination $tempDeliveryFilePathFullName -Force -ErrorAction Stop
             Write-Log "Временный файл доставки успешно создан." "Debug"
             # Переименовываем временный файл в основной в папке доставки
             Move-Item -Path $tempDeliveryFilePathFullName -Destination $deliveryFilePathFullName -Force -ErrorAction Stop
             Write-Log "Файл конфигурации '$outputFileNameCleaned' успешно доставлен (атомарно) в '$deliveryDirectoryPath'." "Info"
        } catch {
             Write-Log "Ошибка копирования/переименования при доставке файла в '$deliveryFilePathFullName' для ObjectId $currentObjectId. Ошибка: $($_.Exception.Message)" "Error"
             # Удаляем временный файл доставки, если он остался
             if (Test-Path $tempDeliveryFilePathFullName -PathType Leaf) { try { Remove-Item -Path $tempDeliveryFilePathFullName -Force -ErrorAction SilentlyContinue } catch {} }
        }
    } elseif ($saveOperationSuccess) { # Если сохранение успешно, но доставка не настроена
         Write-Log "delivery_path_base не задан в конфигурации. Пропуск шага доставки для ObjectId $currentObjectId." "Info"
    }
    Write-Log "--- Обработка ObjectId: $currentObjectId успешно завершена ---" "Info"
} # --- Конец цикла foreach по ObjectId ---

Write-Log "Работа скрипта конфигуратора (v$ScriptVersion) успешно завершена." "Info"