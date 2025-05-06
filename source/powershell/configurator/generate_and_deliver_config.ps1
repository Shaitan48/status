# powershell/configurator/generate_and_deliver_config.ps1
# --- Версия 4.1 ---
# Изменения:
# - Добавлена атомарность при сохранении и доставке файлов.
<#
.SYNOPSIS
    Генерирует и доставляет конфигурационные файлы для оффлайн-режима
    гибридного агента Status Monitor (v4.1).
.DESCRIPTION
    Запрашивает конфигурацию у API и АТОМАРНО сохраняет/доставляет JSON файлы.
    1. Читает `config.json`.
    2. Определяет список ObjectId для обработки.
    3. Для каждого ObjectId:
       - Запрашивает `GET /api/v1/objects/{ObjectId}/offline_config`.
       - Проверяет ответ.
       - Формирует имя файла.
       - **Сохраняет JSON во временный файл в `output_path_base`.**
       - **Переименовывает временный файл в основной.**
       - Если задан `delivery_path_base`:
         - **Копирует основной файл во временный файл в папке доставки.**
         - **Переименовывает временный файл доставки в основной.**
.NOTES
    Версия: 4.1
    Дата: [Актуальная Дата]
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\config.json",
    [string]$ParamLogFile = $null,
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
    [string]$ParamLogLevel = $null
)

# --- Вспомогательные функции (без изменений от предыдущей версии) ---
filter Get-OrElse_Internal { param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }
function Write-Log { param ([Parameter(Mandatory=$true)][string]$Message, [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)][string]$Level = "Info"); if (-not $script:Config -or -not $script:Config.log_file) { Write-Host "[$Level] $Message"; return }; $logLevels = @{ "Debug" = 4; "Verbose" = 3; "Info" = 2; "Warn" = 1; "Error" = 0 }; $currentLevelValue = $logLevels[$script:EffectiveLogLevel]; if ($null -eq $currentLevelValue) { $currentLevelValue = $logLevels["Info"] }; $messageLevelValue = $logLevels[$Level]; if ($null -eq $messageLevelValue) { $messageLevelValue = $logLevels["Info"] }; if ($messageLevelValue -le $currentLevelValue) { $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage = "[$timestamp] [$Level] - $Message"; Write-Host $logMessage -ForegroundColor $(switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}); try { $logDir = Split-Path $script:Config.log_file -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { Write-Host "[INFO] Создание папки для лога: '$logDir'"; New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }; $logMessage | Out-File -FilePath $script:Config.log_file -Append -Encoding UTF8 -ErrorAction Stop } catch { Write-Host "[Error] Невозможно записать в лог '$($script:Config.log_file)': $($_.Exception.Message)" -ForegroundColor Red } } }

# --- Начало скрипта ---
$ScriptVersion = "4.1"
$script:Config = $null
$script:EffectiveLogLevel = "Info"
$script:ApiKey = $null

# --- Шаг 1: Чтение и валидация конфигурации ---
# (Код без изменений, проверяет все поля, включая delivery_path_base)
Write-Host "Загрузка конфигурации из файла: $ConfigFile"
if (-not (Test-Path $ConfigFile -PathType Leaf)) { Write-Error "Критическая ошибка: Файл конфигурации '$ConfigFile' не найден."; exit 1 }
try { $script:Config = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Error "Критическая ошибка: Ошибка чтения/парсинга JSON '$ConfigFile'. Ошибка: $($_.Exception.Message)"; exit 1 }
$requiredConfigFields = @("api_base_url", "api_key", "output_path_base", "delivery_path_base", "log_file", "log_level", "subdivision_ids_to_process", "output_filename_template", "delivery_subdir_template", "api_timeout_sec")
$missingFields = $requiredConfigFields | Where-Object { -not $script:Config.PSObject.Properties.Name.Contains($_) -or (-not ($script:Config.PSObject.Properties.$_ -ne $null) -and $_ -ne 'delivery_path_base') } # delivery_path_base может быть null
if ($missingFields) { Write-Error "Критическая ошибка: В '$ConfigFile' отсутствуют поля: $($missingFields -join ', ')"; exit 1 }
if ($script:Config.subdivision_ids_to_process -isnot [array]) { Write-Error "..."; exit 1 }
if ($ParamLogFile) { $script:Config.log_file = $ParamLogFile }
if ($ParamLogLevel) { $script:Config.log_level = $ParamLogLevel }
$validLogLevelsMap = @{ "Debug" = 0; "Verbose" = 1; "Info" = 2; "Warn" = 3; "Error" = 4 }
if (-not $validLogLevelsMap.ContainsKey($script:Config.log_level)) { $script:Config.log_level = "Info" }
$script:EffectiveLogLevel = $script:Config.log_level
$script:ApiKey = $script:Config.api_key

# --- Шаг 2: Инициализация и логирование ---
# (Код без изменений)
$logDir = Split-Path $script:Config.log_file -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { try { New-Item -Path $logDir -ItemType Directory -Force -EA Stop | Out-Null } catch { Write-Error "..."; exit 1 } }
Write-Log "Скрипт конфигуратора (v$ScriptVersion) запущен." "Info"
# ... (логирование параметров конфига) ...

# --- Шаг 3: Определение списка ObjectId для обработки ---
# (Код без изменений, использует Invoke-RestMethod)
$objectIdsToProcess = @()
if ($script:Config.subdivision_ids_to_process.Count -gt 0) { $objectIdsToProcess = $script:Config.subdivision_ids_to_process | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } }
else {
    Write-Log "Запрос всех подразделений с кодом ТС из API..." "Info"
    $apiUrlSubdivisions = "$($script:Config.api_base_url.TrimEnd('/'))/v1/subdivisions?limit=1000"
    $headers = @{ 'X-API-Key' = $script:ApiKey }
    try {
        $response = Invoke-RestMethod -Uri $apiUrlSubdivisions -Method Get -Headers $headers -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse_Internal 60) -ErrorAction Stop
        if ($response -and $response.items -is [array]) { $objectIdsToProcess = $response.items | Where-Object { $_.transport_system_code -and $_.object_id } | Select-Object -ExpandProperty object_id; Write-Log "Найдено для обработки: $($objectIdsToProcess.Count)" "Info" }
    } catch {
        $rawErrorMessage = $_.Exception.Message; $responseBody="[N/A]"; $statusCode=$null; if($_.Exception.Response){try{$statusCode=$_.Exception.Response.StatusCode}catch{}; try{$stream=[System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream());$responseBody=$stream.ReadToEnd();$stream.Close()}catch{}};
        Write-Log "Критическая ошибка получения списка подразделений: $rawErrorMessage - Code: $statusCode - Resp: $responseBody" "Error"; exit 1
    }
}
if ($objectIdsToProcess.Count -eq 0) { Write-Log "Нет ObjectId для обработки. Завершение." "Info"; exit 0 }

# --- Шаг 4: Цикл обработки каждого ObjectId ---
Write-Log "Начало цикла обработки для $($objectIdsToProcess.Count) подразделений." "Info"
foreach ($currentObjectId in $objectIdsToProcess) {
    Write-Log "--- Обработка ObjectId: $currentObjectId ---" "Info"
    $apiResponse = $null
    $versionTag = "[error]" # Значение по умолчанию
    $transportCode = "[error]" # Значение по умолчанию

    # 1. Запрос конфигурации
    $apiUrlConfig = "$($script:Config.api_base_url.TrimEnd('/'))/v1/objects/${currentObjectId}/offline_config"
    $headersConfig = @{ 'X-API-Key' = $script:ApiKey }
    Write-Log "Запрос конфигурации: GET $apiUrlConfig" "Verbose"
    try {
        $apiResponse = Invoke-RestMethod -Uri $apiUrlConfig -Method Get -Headers $headersConfig -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse_Internal 60) -ErrorAction Stop
        # Валидация ответа API
        if (-not ($apiResponse -is [PSCustomObject]) -or (-not $apiResponse.PSObject.Properties.Name.Contains('assignment_config_version')) -or (-not $apiResponse.PSObject.Properties.Name.Contains('transport_system_code')) -or (-not $apiResponse.PSObject.Properties.Name.Contains('assignments'))) {
             if($apiResponse -is [PSCustomObject] -and $apiResponse.error){ throw "API вернул ошибку: $($apiResponse.error)" }
             else { throw "Некорректная структура ответа API /offline_config." }
        }
        $versionTag = $apiResponse.assignment_config_version
        $transportCode = $apiResponse.transport_system_code
        $assignmentCount = $apiResponse.assignments.Count
        Write-Log "Конфигурация получена. Версия: ${versionTag}. Заданий: ${assignmentCount}. Код ТС: ${transportCode}." "Info"

    } catch {
        # Обработка ошибок API
        $exceptionMessage = $_.Exception.Message; $statusCode = $null; if ($_.Exception.Response) { try {$statusCode = $_.Exception.Response.StatusCode} catch {} };
        Write-Log "Ошибка получения конфигурации от API для ObjectId ${currentObjectId}: $exceptionMessage (Код: $statusCode)" "Error";
        continue # Пропускаем этот ID
    }

    # 2. Формирование имен файлов
    $outputFileNameBase = $script:Config.output_filename_template -replace "{version_tag}", $versionTag -replace "{transport_code}", $transportCode
    $outputFileName = $outputFileNameBase -replace '[\\/:*?"<>|]', '_' # Убираем недопустимые символы
    # Полные пути
    $outputFilePath = Join-Path -Path $script:Config.output_path_base -ChildPath $outputFileName
    $tempOutputFilePath = $outputFilePath + ".tmp" # Временный файл рядом
    $outputDir = Split-Path $outputFilePath -Parent

    # 3. Создание папки вывода
    if (-not (Test-Path $outputDir -PathType Container)) {
        Write-Log "Создание папки вывода '$outputDir'" "Verbose"
        try { New-Item -Path $outputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        catch { Write-Log "Ошибка создания папки вывода '$outputDir'. Пропуск ${currentObjectId}. Error: $($_.Exception.Message)" "Error"; continue }
    }

    # --- 4. Атомарное сохранение JSON в output_path_base ---
    Write-Log "Сохранение конфигурации во временный файл: $tempOutputFilePath" "Verbose"
    $saveSuccess = $false
    try {
        $jsonToSave = $apiResponse | ConvertTo-Json -Depth 10 -WarningAction SilentlyContinue
        $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempOutputFilePath, $jsonToSave, $Utf8NoBomEncoding)
        Write-Log "Данные записаны во временный файл." "Debug"
        # Переименование во временный файл
        Move-Item -Path $tempOutputFilePath -Destination $outputFilePath -Force -ErrorAction Stop
        Write-Log "Файл '$outputFileName' успешно сохранен (атомарно) в '$outputDir'." "Info"
        $saveSuccess = $true
    } catch {
        Write-Log "Ошибка сохранения/переименования файла '$outputFilePath'. Пропуск ${currentObjectId}. Error: $($_.Exception.Message)" "Error"
        # Пытаемся удалить временный файл, если он остался
        if (Test-Path $tempOutputFilePath -PathType Leaf) { try { Remove-Item -Path $tempOutputFilePath -Force -ErrorAction SilentlyContinue } catch {} }
        continue # Пропускаем доставку, если сохранение не удалось
    }

    # --- 5. Атомарная доставка файла (если нужно) ---
    if ($saveSuccess -and $script:Config.delivery_path_base) {
        $deliverySubDir = $script:Config.delivery_subdir_template -replace "{transport_code}", $transportCode
        $deliveryPath = Join-Path -Path $script:Config.delivery_path_base -ChildPath $deliverySubDir
        $deliveryFileName = $outputFileName # Имя файла то же
        $deliveryFilePath = Join-Path -Path $deliveryPath -ChildPath $deliveryFileName
        $tempDeliveryFilePath = $deliveryFilePath + ".tmp" # Временный файл доставки
        Write-Log "Проверка пути доставки: $deliveryFilePath" "Info"

        # Создаем папку доставки, если ее нет
        if (-not (Test-Path $deliveryPath -PathType Container)) {
            Write-Log "Папка доставки '$deliveryPath' не найдена. Создание..." "Warn"
            try { New-Item -Path $deliveryPath -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "Папка '$deliveryPath' создана." "Verbose" }
            catch { Write-Log "Ошибка создания папки доставки '$deliveryPath'. Пропуск доставки. Error: $($_.Exception.Message)" "Error"; continue } # Пропускаем, если не удалось создать
        }

        # Атомарное копирование (Copy -> Rename)
        Write-Log "Копирование '$outputFilePath' -> '$tempDeliveryFilePath'" "Verbose"
        try {
             # 1. Копируем во временный файл
             Copy-Item -Path $outputFilePath -Destination $tempDeliveryFilePath -Force -ErrorAction Stop
             Write-Log "Временный файл доставки создан." "Debug"
             # 2. Переименовываем временный в основной
             Move-Item -Path $tempDeliveryFilePath -Destination $deliveryFilePath -Force -ErrorAction Stop
             Write-Log "Файл '$outputFileName' успешно доставлен (атомарно) в '$deliveryPath'." "Info"
        } catch {
             Write-Log "Ошибка копирования/переименования при доставке в '$deliveryFilePath'. Error: $($_.Exception.Message)" "Error"
             # Пытаемся удалить временный файл доставки, если он остался
             if (Test-Path $tempDeliveryFilePath -PathType Leaf) { try { Remove-Item -Path $tempDeliveryFilePath -Force -ErrorAction SilentlyContinue } catch {} }
        }
    } elseif ($saveSuccess) {
         Write-Log "delivery_path_base не задан. Пропуск доставки." "Info"
    }

    Write-Log "--- Обработка ObjectId: $currentObjectId завершена ---" "Info"
} # --- Конец цикла foreach ---

Write-Log "Работа скрипта конфигуратора успешно завершена." "Info"