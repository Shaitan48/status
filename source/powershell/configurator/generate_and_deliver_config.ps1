# powershell/configurator/generate_and_deliver_config.ps1
# --- Версия 4.1 --- (с расширенной отладкой)
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

# --- Вспомогательные функции ---
filter Get-OrElse_Internal { param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }
function Write-Log { param ([Parameter(Mandatory=$true)][string]$Message, [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)][string]$Level = "Info"); if (-not $script:Config -or -not $script:Config.log_file) { Write-Host "[$Level] $Message"; return }; $logLevels = @{ "Debug" = 4; "Verbose" = 3; "Info" = 2; "Warn" = 1; "Error" = 0 }; $currentLevelValue = $logLevels[$script:EffectiveLogLevel]; if ($null -eq $currentLevelValue) { $currentLevelValue = $logLevels["Info"] }; $messageLevelValue = $logLevels[$Level]; if ($null -eq $messageLevelValue) { $messageLevelValue = $logLevels["Info"] }; if ($messageLevelValue -le $currentLevelValue) { $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage = "[$timestamp] [$Level] - $Message"; Write-Host $logMessage -ForegroundColor $(switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}); try { $logDir = Split-Path $script:Config.log_file -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { Write-Host "[INFO] Создание папки для лога: '$logDir'"; New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }; $logMessage | Out-File -FilePath $script:Config.log_file -Append -Encoding UTF8 -ErrorAction Stop } catch { Write-Host "[Error] Невозможно записать в лог '$($script:Config.log_file)': $($_.Exception.Message)" -ForegroundColor Red } } }

# --- Начало скрипта ---
$ScriptVersion = "4.1"
$script:Config = $null
$script:EffectiveLogLevel = "Info"
# $script:ApiKey больше не нужен, если используем Способ 2

# --- Шаг 1: Чтение и валидация конфигурации ---
Write-Host "Загрузка конфигурации из файла: $ConfigFile"
$configObject = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($null -eq $configObject) {
    Write-Error "Критическая ошибка: Не удалось прочитать или распарсить JSON из '$ConfigFile'. Объект конфигурации пуст."
    try {
        $rawContentForError = Get-Content -Path $ConfigFile -Raw -Encoding Default
        Write-Error "Содержимое файла (первые 200 символов): $($rawContentForError.Substring(0, [System.Math]::Min($rawContentForError.Length, 200)))"
    } catch {}
    exit 1
}
$script:Config = $configObject

# --- <<< НАЧАЛО ОТЛАДКИ ЧТЕНИЯ КОНФИГА (УЖЕ БЫЛО, ОСТАВЛЯЕМ) >>> ---
Write-Host "--- ОТЛАДКА ЧТЕНИЯ КОНФИГА ---" -ForegroundColor Cyan
Write-Host "Тип объекта \$script:Config: $($script:Config.GetType().FullName)" -ForegroundColor Cyan
if ($script:Config -is [System.Management.Automation.PSCustomObject]) {
    Write-Host "\$script:Config является PSCustomObject. Проверка свойств:" -ForegroundColor Cyan
    $script:Config.PSObject.Properties | ForEach-Object { Write-Host "  Свойство: '$($_.Name)', Значение: '$($_.Value)'" -ForegroundColor Cyan }
    if ($script:Config.PSObject.Properties.Name -contains 'api_key') { Write-Host "  \$script:Config.api_key НАЙДЕНО. Значение: '$($script:Config.api_key)'" -ForegroundColor Green }
    else { Write-Host "  \$script:Config.api_key НЕ НАЙДЕНО!" -ForegroundColor Red }
} elseif ($script:Config -is [hashtable]) {
    Write-Host "\$script:Config является Hashtable. Проверка ключей:" -ForegroundColor Cyan
    $script:Config.GetEnumerator() | ForEach-Object { Write-Host "  Ключ: '$($_.Key)', Значение: '$($_.Value)'" -ForegroundColor Cyan }
    if ($script:Config.ContainsKey('api_key')) { Write-Host "  \$script:Config['api_key'] НАЙДЕНО. Значение: '$($script:Config['api_key'])'" -ForegroundColor Green }
    else { Write-Host "  \$script:Config['api_key'] НЕ НАЙДЕНО!" -ForegroundColor Red }
} else { Write-Host "НЕИЗВЕСТНЫЙ тип объекта \$script:Config." -ForegroundColor Red }
Write-Host "--- КОНЕЦ ОТЛАДКИ ЧТЕНИЯ КОНФИГА ---" -ForegroundColor Cyan
# --- <<< КОНЕЦ ОТЛАДКИ ЧТЕНИЯ КОНФИГА >>> ---

$requiredConfigFields = @("api_base_url", "api_key", "output_path_base", "delivery_path_base", "log_file", "log_level", "subdivision_ids_to_process", "output_filename_template", "delivery_subdir_template", "api_timeout_sec")
$foundMissingFields = [System.Collections.Generic.List[string]]::new()
foreach ($field in $requiredConfigFields) {
    $fieldExists = $false; $fieldValue = $null
    if ($script:Config -is [hashtable]) { if ($script:Config.ContainsKey($field)) { $fieldExists = $true; $fieldValue = $script:Config[$field] } }
    elseif ($script:Config -is [System.Management.Automation.PSCustomObject]) { if ($script:Config.PSObject.Properties.Name -contains $field) { $fieldExists = $true; $fieldValue = $script:Config.$field } }
    else { Write-Error "Критическая ошибка: Объект конфигурации имеет неожиданный тип '$($script:Config.GetType().FullName)'." ; exit 1 }
    if (-not $fieldExists) { $foundMissingFields.Add("'$field' (полностью отсутствует)") }
    elseif ($fieldValue -eq $null -and $field -ne 'delivery_path_base') { $foundMissingFields.Add("'$field' (равен `$null)") }
    elseif (($fieldValue -is [string] -and [string]::IsNullOrWhiteSpace($fieldValue)) -and $field -ne 'delivery_path_base' -and $field -ne 'api_key') { $foundMissingFields.Add("'$field' (пустая строка)") }
}
if ($foundMissingFields.Count -gt 0) { Write-Error "Критическая ошибка: В '$ConfigFile' отсутствуют, `$null или пусты следующие обязательные поля: $($foundMissingFields -join ', ')"; exit 1 }

# --- Шаг 2: Инициализация и логирование ---
$logDir = Split-Path $script:Config.log_file -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { try { New-Item -Path $logDir -ItemType Directory -Force -EA Stop | Out-Null } catch { Write-Error "Не удалось создать папку для лог-файла: $($_.Exception.Message)"; exit 1 } }
$script:EffectiveLogLevel = $script:Config.log_level
if ($PSBoundParameters.ContainsKey('ParamLogFile') -and $ParamLogFile) { $script:Config.log_file = $ParamLogFile }
if ($PSBoundParameters.ContainsKey('ParamLogLevel') -and $ParamLogLevel) { $script:EffectiveLogLevel = $ParamLogLevel }
Write-Log "Скрипт конфигуратора (v$ScriptVersion) запущен." "Info"
Write-Log "Конфигурация загружена: $($script:Config | ConvertTo-Json -Depth 3 -Compress)" "Debug"
# Убедимся, что api_key не попадает в ConvertTo-Json для общего лога, если он не в Debug
# Это уже учтено Write-Log, который не выводит Debug, если уровень Info

# --- Шаг 3: Определение списка ObjectId для обработки ---
$objectIdsToProcess = @()
if ($script:Config.subdivision_ids_to_process -is [array] -and $script:Config.subdivision_ids_to_process.Count -gt 0) {
    $objectIdsToProcess = $script:Config.subdivision_ids_to_process | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
} else {
    Write-Log "Запрос всех подразделений с кодом ТС из API..." "Info"
    $apiUrlSubdivisions = "$($script:Config.api_base_url.TrimEnd('/'))/v1/subdivisions?limit=1000"
    # --- ИСПОЛЬЗУЕМ $script:Config.api_key НАПРЯМУЮ ---
    $headers = @{ 'X-API-Key' = $script:Config.api_key }
    try {
        $response = Invoke-RestMethod -Uri $apiUrlSubdivisions -Method Get -Headers $headers -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse_Internal 60) -ErrorAction Stop
        if ($response -and $response.items -is [array]) {
            $objectIdsToProcess = $response.items | Where-Object { $_.transport_system_code -and $_.object_id } | Select-Object -ExpandProperty object_id
            Write-Log "Найдено для обработки (через API): $($objectIdsToProcess.Count)" "Info"
        }
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
    $versionTag = "[error]"
    $transportCode = "[error]"

    # 1. Запрос конфигурации
    $apiUrlConfig = "$($script:Config.api_base_url.TrimEnd('/'))/v1/objects/${currentObjectId}/offline_config"
    
    # --- <<< УТОЧНЕННАЯ ОТЛАДКА КЛЮЧА ПЕРЕД ЗАПРОСОМ >>> ---
    $keyToCheck = $script:Config.api_key # Получаем значение один раз
    $keyIsNull = ($null -eq $keyToCheck)
    $keyIsWhitespace = $false
    if (-not $keyIsNull) {
        try { $keyIsWhitespace = [string]::IsNullOrWhiteSpace($keyToCheck) }
        catch { Write-Log "ОШИБКА при вызове IsNullOrWhiteSpace для ключа '$keyToCheck'" "Error"; $keyIsWhitespace = $true }
    }
    $keyLength = if (-not $keyIsNull) { $keyToCheck.Length } else { 'N/A' }

    Write-Log "ОТЛАДКА КЛЮЧА (непосредственно перед формированием заголовка):" "Debug"
    Write-Log "  Значение \$script:Config.api_key: '$keyToCheck'" "Debug"
    Write-Log "  \$keyToCheck IS NULL: $keyIsNull" "Debug"
    Write-Log "  \$keyToCheck IsNullOrWhiteSpace: $keyIsWhitespace" "Debug"
    Write-Log "  Длина \${keyToCheck}: $keyLength" "Debug"

    if ($keyIsNull -or $keyIsWhitespace) {
        Write-Log "КРИТИЧЕСКАЯ ОШИБКА (УТОЧНЕННАЯ): API ключ из \$script:Config.api_key ('$keyToCheck') пуст или null ПРЯМО ПЕРЕД использованием в заголовке!" "Error"
    }
    # --- <<< КОНЕЦ УТОЧНЕННОЙ ОТЛАДКИ >>> ---

    # --- ИСПОЛЬЗУЕМ $script:Config.api_key НАПРЯМУЮ ---
    $headersConfig = @{ 'X-API-Key' = $script:Config.api_key }
    
    Write-Log "Запрос конфигурации: GET $apiUrlConfig" "Verbose"
    try {
        $apiResponse = Invoke-RestMethod -Uri $apiUrlConfig -Method Get -Headers $headersConfig -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse_Internal 60) -ErrorAction Stop
        if (-not ($apiResponse -is [PSCustomObject]) -or `
            (-not $apiResponse.PSObject.Properties.Name.Contains('assignment_config_version')) -or `
            (-not $apiResponse.PSObject.Properties.Name.Contains('transport_system_code')) -or `
            (-not $apiResponse.PSObject.Properties.Name.Contains('assignments'))) {
            if ($apiResponse -is [PSCustomObject] -and $apiResponse.PSObject.Properties.Name.Contains('error')) { throw "API вернул ошибку: $($apiResponse.error)" }
            else { throw "Некорректная структура ответа API /offline_config." }
        }
        $versionTag = $apiResponse.assignment_config_version
        $transportCode = $apiResponse.transport_system_code
        $assignmentCount = if ($apiResponse.assignments -is [array]) { $apiResponse.assignments.Count } else { 0 }
        Write-Log "Конфигурация получена. Версия: ${versionTag}. Заданий: ${assignmentCount}. Код ТС: ${transportCode}." "Info"

    } catch {
        $currentException = $_; $exceptionMessageForLog = "[Исключение отсутствует или неизвестно]"; $statusCodeForLog = "[N/A_Code]"; $responseBodyForLog = "[N/A_Body]"
        if ($null -ne $currentException) {
            if ($null -ne $currentException.Exception) {
                $exceptionMessageForLog = $currentException.Exception.Message
                if ($currentException.Exception -is [System.Net.WebException] -and $null -ne $currentException.Exception.Response) {
                    try { $statusCodeForLog = ([int]$currentException.Exception.Response.StatusCode).ToString() } catch { $statusCodeForLog = "[Ошибка получения кода]" }
                    try { $errorStream = $currentException.Exception.Response.GetResponseStream(); $reader = New-Object System.IO.StreamReader($errorStream); $responseBodyForLog = $reader.ReadToEnd(); $reader.Close(); $errorStream.Close(); try { $responseBodyForLog = ($responseBodyForLog | ConvertFrom-Json | ConvertTo-Json -Depth 3 -Compress) } catch {} } catch { $responseBodyForLog = "[Ошибка чтения тела ответа]" }
                } elseif ($null -ne $currentException.Exception.InnerException) { $responseBodyForLog = "InnerException: $($currentException.Exception.InnerException.Message)" }
                else { $responseBodyForLog = $currentException.Exception.ToString() }
            } else { $exceptionMessageForLog = $currentException.ToString() }
        }
        Write-Log "Ошибка получения конфигурации от API для ObjectId ${currentObjectId}: $exceptionMessageForLog (Код: $statusCodeForLog). Ответ/Детали: $responseBodyForLog" "Error"; continue
    }

    # 2. Формирование имен файлов
    $outputFileNameBase = $script:Config.output_filename_template -replace "{version_tag}", $versionTag -replace "{transport_code}", $transportCode
    $outputFileName = $outputFileNameBase -replace '[\\/:*?"<>|]', '_'
    $outputFilePath = Join-Path -Path $script:Config.output_path_base -ChildPath $outputFileName
    $tempOutputFilePath = $outputFilePath + ".tmp"
    $outputDir = Split-Path $outputFilePath -Parent

    # 3. Создание папки вывода
    if (-not (Test-Path $outputDir -PathType Container)) {
        Write-Log "Создание папки вывода '$outputDir'" "Verbose"
        try { New-Item -Path $outputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        catch { Write-Log "Ошибка создания папки вывода '$outputDir'. Пропуск ${currentObjectId}. Error: $($_.Exception.Message)" "Error"; continue }
    }

    # 4. Атомарное сохранение JSON
    Write-Log "Сохранение конфигурации во временный файл: $tempOutputFilePath" "Verbose"
    $saveSuccess = $false
    try {
        $jsonToSave = $apiResponse | ConvertTo-Json -Depth 10 -WarningAction SilentlyContinue
        $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempOutputFilePath, $jsonToSave, $Utf8NoBomEncoding)
        Write-Log "Данные записаны во временный файл." "Debug"
        Move-Item -Path $tempOutputFilePath -Destination $outputFilePath -Force -ErrorAction Stop
        Write-Log "Файл '$outputFileName' успешно сохранен (атомарно) в '$outputDir'." "Info"
        $saveSuccess = $true
    } catch {
        Write-Log "Ошибка сохранения/переименования файла '$outputFilePath'. Пропуск ${currentObjectId}. Error: $($_.Exception.Message)" "Error"
        if (Test-Path $tempOutputFilePath -PathType Leaf) { try { Remove-Item -Path $tempOutputFilePath -Force -ErrorAction SilentlyContinue } catch {} }
        continue
    }

    # 5. Атомарная доставка файла
    if ($saveSuccess -and $script:Config.delivery_path_base) {
        $deliverySubDir = $script:Config.delivery_subdir_template -replace "{transport_code}", $transportCode
        $deliveryPath = Join-Path -Path $script:Config.delivery_path_base -ChildPath $deliverySubDir
        $deliveryFileName = $outputFileName
        $deliveryFilePath = Join-Path -Path $deliveryPath -ChildPath $deliveryFileName
        $tempDeliveryFilePath = $deliveryFilePath + ".tmp"
        Write-Log "Проверка пути доставки: $deliveryFilePath" "Info"
        if (-not (Test-Path $deliveryPath -PathType Container)) {
            Write-Log "Папка доставки '$deliveryPath' не найдена. Создание..." "Warn"
            try { New-Item -Path $deliveryPath -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "Папка '$deliveryPath' создана." "Verbose" }
            catch { Write-Log "Ошибка создания папки доставки '$deliveryPath'. Пропуск доставки. Error: $($_.Exception.Message)" "Error"; continue }
        }
        Write-Log "Копирование '$outputFilePath' -> '$tempDeliveryFilePath'" "Verbose"
        try {
             Copy-Item -Path $outputFilePath -Destination $tempDeliveryFilePath -Force -ErrorAction Stop
             Write-Log "Временный файл доставки создан." "Debug"
             Move-Item -Path $tempDeliveryFilePath -Destination $deliveryFilePath -Force -ErrorAction Stop
             Write-Log "Файл '$outputFileName' успешно доставлен (атомарно) в '$deliveryPath'." "Info"
        } catch {
             Write-Log "Ошибка копирования/переименования при доставке в '$deliveryFilePath'. Error: $($_.Exception.Message)" "Error"
             if (Test-Path $tempDeliveryFilePath -PathType Leaf) { try { Remove-Item -Path $tempDeliveryFilePath -Force -ErrorAction SilentlyContinue } catch {} }
        }
    } elseif ($saveSuccess) {
         Write-Log "delivery_path_base не задан. Пропуск доставки." "Info"
    }
    Write-Log "--- Обработка ObjectId: $currentObjectId завершена ---" "Info"
} # --- Конец цикла foreach ---

Write-Log "Работа скрипта конфигуратора успешно завершена." "Info"