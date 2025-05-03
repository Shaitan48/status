# powershell\configurator\generate_and_deliver_config.ps1 (Версия 3.6 - Полный JSON, без .zrpu)
<#
.SYNOPSIS
    Генерирует и доставляет конфигурационные файлы для оффлайн-агентов v4.4+.
    Файл содержит ПОЛНЫЙ JSON (метаданные + задания + хеш).
    Имя файла формируется БЕЗ .zrpu.
.NOTES
    Версия: 3.6
    Дата: 2024-05-19 (или актуальная)
    Изменения:
        - Сохраняет весь JSON ответ от API /offline_config.
        - Убран суффикс .zrpu из имени файла.
        - Добавлены проверки на наличие обязательных полей в ответе API.
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\config.json",
    [string]$ParamLogFile = $null,
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
    [string]$ParamLogLevel = $null
)

# --- Вспомогательные функции (Sanitize-String, Write-Log, Get-OrElse) ---
filter Get-OrElse { param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }
function Sanitize-String { param([Parameter(Mandatory=$true)][string]$InputString,[string]$ReplacementChar=''); if($null-eq$InputString){return $null};try{return $InputString -replace '\p{C}',$ReplacementChar}catch{Write-Warning "Ошибка санитизации строки: $($_.Exception.Message)";return $InputString} }
function Write-Log { param ([Parameter(Mandatory=$true)][string]$Message, [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)][string]$Level = "Info"); if (-not $script:Config -or -not $script:Config.log_file) { Write-Host "[$Level] $Message"; return }; $logLevels = @{ "Debug" = 4; "Verbose" = 3; "Info" = 2; "Warn" = 1; "Error" = 0 }; $currentLevelValue = $logLevels[$script:EffectiveLogLevel]; if ($null -eq $currentLevelValue) { $currentLevelValue = $logLevels["Info"] }; $messageLevelValue = $logLevels[$Level]; if ($null -eq $messageLevelValue) { $messageLevelValue = $logLevels["Info"] }; if ($messageLevelValue -le $currentLevelValue) { $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage = "[$timestamp] [$Level] - $Message"; Write-Host $logMessage -ForegroundColor $(switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}); try { $logDir = Split-Path $script:Config.log_file -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { Write-Host "[INFO] Создание папки для лога: '$logDir'"; New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }; $logMessage | Out-File -FilePath $script:Config.log_file -Append -Encoding UTF8 -ErrorAction Stop } catch { Write-Host "[Error] Невозможно записать в лог '$($script:Config.log_file)': $($_.Exception.Message)" -ForegroundColor Red } } }

# --- Начало скрипта ---
$ScriptVersion = "3.6"
$script:Config = $null
$script:EffectiveLogLevel = "Info"
$script:ApiKey = $null

# --- Шаг 1: Чтение и валидация конфигурации ---
Write-Host "Загрузка конфигурации из файла: $ConfigFile"
if (-not (Test-Path $ConfigFile -PathType Leaf)) { Write-Error "Критическая ошибка: Файл конфигурации '$ConfigFile' не найден."; exit 1 }
try { $script:Config = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Error "Критическая ошибка: Ошибка чтения/парсинга JSON '$ConfigFile'. Ошибка: $($_.Exception.Message)"; exit 1 }
# Проверка всех ОБЯЗАТЕЛЬНЫХ полей
$requiredConfigFields = @("api_base_url", "api_key", "output_path_base", "delivery_path_base", "log_file", "log_level", "subdivision_ids_to_process", "output_filename_template", "delivery_subdir_template")
$missingFields = $requiredConfigFields | Where-Object { -not $script:Config.PSObject.Properties.Name.Contains($_) }
if ($missingFields) { Write-Error "Критическая ошибка: В '$ConfigFile' отсутствуют поля: $($missingFields -join ', ')"; exit 1 }
# Проверка типа subdivision_ids_to_process
if ($script:Config.subdivision_ids_to_process -isnot [array]) { Write-Error "Критическая ошибка: 'subdivision_ids_to_process' должен быть массивом."; exit 1 }
# Переопределение logFile и logLevel из параметров, если переданы
if ($ParamLogFile) { $script:Config.log_file = $ParamLogFile }
if ($ParamLogLevel) { $script:Config.log_level = $ParamLogLevel }
# Валидация LogLevel
$validLogLevelsMap = @{ "Debug" = 0; "Verbose" = 1; "Info" = 2; "Warn" = 3; "Error" = 4 }
if (-not $validLogLevelsMap.ContainsKey($script:Config.log_level)) { Write-Host "[WARN] Некорректный LogLevel '$($script:Config.log_level)'. Используется 'Info'." -F Yellow; $script:Config.log_level = "Info" }
$script:EffectiveLogLevel = $script:Config.log_level
$script:ApiKey = $script:Config.api_key

# --- Шаг 2: Инициализация и логирование ---
$logDir = Split-Path $script:Config.log_file -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { Write-Host "[INFO] Создание папки лога: '$logDir'..."; try { New-Item -Path $logDir -ItemType Directory -Force -EA Stop | Out-Null } catch { Write-Error "Критическая: Не удалось создать папку лога '$logDir': $($_.Exception.Message)"; exit 1 } }
Write-Log "Скрипт конфигуратора (v$ScriptVersion) запущен." "Info"
Write-Log "Конфигурация из '$ConfigFile'" "Verbose"
Write-Log "API URL: $($script:Config.api_base_url)" "Verbose"
$apiKeyPartial = "[Не задан]"; if($script:ApiKey){$len=$script:ApiKey.Length;$p=$script:ApiKey.Substring(0,[math]::Min(4,$len));$s=if($len -gt 8){$script:ApiKey.Substring($len-4,4)}else{""};$apiKeyPartial="$p....$s"}; Write-Log "API Key (частично): $apiKeyPartial" "Debug";
Write-Log "Папка вывода: $($script:Config.output_path_base)" "Verbose"
Write-Log "Папка доставки: $($script:Config.delivery_path_base | Get-OrElse '[Не задана]')" "Verbose"
Write-Log "Шаблон имени файла: $($script:Config.output_filename_template)" "Verbose" # Убрали .zrpu
Write-Log "Шаблон подпапки доставки: $($script:Config.delivery_subdir_template)" "Verbose"
Write-Log "Список ID для обработки: $($script:Config.subdivision_ids_to_process -join ', ' | Get-OrElse '[Авто (все с кодом ТС)]')" "Verbose"

# --- Шаг 3: Определение списка ObjectId для обработки ---
$objectIdsToProcess = @()
Write-Log "Анализ 'subdivision_ids_to_process'..." "Info"
if ($script:Config.subdivision_ids_to_process.Count -gt 0) {
    Write-Log "Обнаружен список ID в конфиге. Обработка для: $($script:Config.subdivision_ids_to_process -join ', ')" "Info"
    $objectIdsToProcess = $script:Config.subdivision_ids_to_process | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    if ($objectIdsToProcess.Count -ne $script:Config.subdivision_ids_to_process.Count) { Write-Log "Предупреждение: Нечисловые значения в 'subdivision_ids_to_process' проигнорированы." "Warn" }
} else {
    Write-Log "Список ID в конфиге пуст (`[]`). Запрашиваем все подразделения с кодом ТС из API..." "Info"
    $apiUrlSubdivisions = "$($script:Config.api_base_url.TrimEnd('/'))/v1/subdivisions?limit=1000" # Запрос всех
    $headers = @{ 'X-API-Key' = $script:ApiKey }
    try {
        Write-Log "Запрос: GET $apiUrlSubdivisions" "Verbose"
        $response = Invoke-RestMethod -Uri $apiUrlSubdivisions -Method Get -Headers $headers -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse 60) -ErrorAction Stop
        if ($response -and $response.items -is [array]) {
            $subdivisions = $response.items
            # Фильтруем по наличию transport_system_code и object_id
            $objectIdsToProcess = $subdivisions | Where-Object { $_.transport_system_code -and $_.object_id } | Select-Object -ExpandProperty object_id
            Write-Log "Получено $($subdivisions.Count) подразделений. Найдено для обработки (с кодом ТС): $($objectIdsToProcess.Count)" "Info"
            if ($objectIdsToProcess.Count -eq 0 -and $subdivisions.Count -gt 0) { Write-Log "Предупреждение: Ни у одного подразделения из API не задан transport_system_code." "Warn" }
        } else { Write-Log "Ответ API /subdivisions не содержит ожидаемый массив 'items'." "Warn" }
    } catch {
        $rawErrorMessage = $_.Exception.Message; $responseBody="[N/A]"; $statusCode=$null; if($_.Exception.Response){try{$statusCode=$_.Exception.Response.StatusCode}catch{}; try{$stream=[System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream());$responseBody=$stream.ReadToEnd();$stream.Close()}catch{$responseBody="[Read Error]"}};
        $cleanErrorMessage = Sanitize-String -InputString $rawErrorMessage; $cleanResponseBody = Sanitize-String -InputString $responseBody; $finalLogMessage = "${cleanErrorMessage} - Code: $($statusCode|Get-OrElse 'N/A') - Resp: ${cleanResponseBody}"
        Write-Log "Критическая ошибка получения списка подразделений из API ($apiUrlSubdivisions): $finalLogMessage" "Error"
        Write-Log "Проверьте доступность API, API ключ и права доступа. Завершение работы." "Error"
        exit 1
    }
}

if ($objectIdsToProcess.Count -eq 0) { Write-Log "Нет ObjectId для обработки. Завершение." "Info"; exit 0 }

# --- Шаг 4: Цикл обработки каждого ObjectId ---
Write-Log "Начало цикла обработки для $($objectIdsToProcess.Count) подразделений: $($objectIdsToProcess -join ', ')" "Info"
foreach ($currentObjectId in $objectIdsToProcess) {
    Write-Log "--- Обработка ObjectId: $currentObjectId ---" "Info"
    # 1. Запрос конфигурации
    $apiUrlConfig = "$($script:Config.api_base_url.TrimEnd('/'))/v1/objects/${currentObjectId}/offline_config"
    $apiResponse = $null
    $headersConfig = @{ 'X-API-Key' = $script:ApiKey }
    Write-Log "Запрос конфигурации: GET $apiUrlConfig" "Verbose"
    try {
        $apiResponse = Invoke-RestMethod -Uri $apiUrlConfig -Method Get -Headers $headersConfig -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse 60) -ErrorAction Stop

        # <<< Проверка ответа API на наличие ОБЯЗАТЕЛЬНЫХ полей >>>
        if (-not ($apiResponse -is [PSCustomObject]) -or
            (-not $apiResponse.PSObject.Properties.Name.Contains('assignment_config_version')) -or
            (-not $apiResponse.PSObject.Properties.Name.Contains('transport_system_code')) -or
            (-not $apiResponse.PSObject.Properties.Name.Contains('assignments')) -or
            ($apiResponse.assignments -isnot [array]))
        {
            # Если структура не та, но есть поле error от API
            if($apiResponse -is [PSCustomObject] -and $apiResponse.error -and $apiResponse.message){
                throw "API вернул ошибку: Код '$($apiResponse.error)', Сообщение '$($apiResponse.message)'"
            } else {
                throw "Некорректная структура ответа API /offline_config или отсутствуют обязательные поля (assignment_config_version, transport_system_code, assignments) для ObjectId ${currentObjectId}."
            }
        }

        # <<< Извлекаем данные после проверки >>>
        $versionTag = $apiResponse.assignment_config_version
        $transportCode = $apiResponse.transport_system_code
        $assignmentCount = $apiResponse.assignments.Count
        Write-Log "Конфигурация получена. Версия: ${versionTag}. Заданий: ${assignmentCount}. Код ТС: ${transportCode}." "Info"

    } catch {
        $exceptionMessage = $_.Exception.Message; $responseBody = "[Нет тела ответа]"; $statusCode = $null;
        if ($_.Exception.Response) { try {$statusCode = $_.Exception.Response.StatusCode} catch {}; try {$errorStream = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $responseBody = $errorStream.ReadToEnd(); $errorStream.Close()} catch {$responseBody = "[Ошибка чтения тела ответа]"} };
        $logErrorMessage = "Ошибка получения конфигурации от API для ObjectId ${currentObjectId}: $($exceptionMessage)";
        if ($statusCode -eq 401 -or $statusCode -eq 403) { $logErrorMessage += " (Проверьте API ключ и права доступа 'configurator'!)"; }
        else { $logErrorMessage += " - Code: $($statusCode | Get-OrElse 'N/A') - Resp: $responseBody"; };
        Write-Log $logErrorMessage "Error";
        continue # Пропускаем этот ID и переходим к следующему
    }

    # 2. Формирование имени файла (БЕЗ .zrpu)
    $outputFileNameBase = $script:Config.output_filename_template -replace "{version_tag}", $versionTag -replace "{transport_code}", $transportCode
    # Убираем недопустимые символы из ИМЕНИ файла
    $outputFileName = $outputFileNameBase -replace '[\\/:*?"<>|]', '_'
    # Собираем полный путь
    $outputFilePath = Join-Path -Path $script:Config.output_path_base -ChildPath $outputFileName
    $outputDir = Split-Path $outputFilePath -Parent

    # 3. Создание папки вывода, если её нет
    if (-not (Test-Path $outputDir -PathType Container)) {
        Write-Log "Создание папки вывода '$outputDir'" "Verbose"
        try { New-Item -Path $outputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        catch { Write-Log "Ошибка создания папки вывода '$outputDir'. Пропуск ${currentObjectId}. Error: $($_.Exception.Message)" "Error"; continue }
    }

    # 4. Сохранение ПОЛНОГО JSON ответа API в файл
    Write-Log "Сохранение полной конфигурации в файл: $outputFilePath" "Verbose"
    try {
        # Преобразуем объект PowerShell в красивую JSON строку
        $jsonToSave = $apiResponse | ConvertTo-Json -Depth 10 -WarningAction SilentlyContinue
        # Используем WriteAllText для записи строки в UTF-8 без BOM
        $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($outputFilePath, $jsonToSave, $Utf8NoBomEncoding)
        Write-Log "Файл конфигурации '$outputFileName' сохранен в '$outputDir'." "Info"
    } catch {
        Write-Log "Ошибка сохранения файла '$outputFilePath'. Пропуск ${currentObjectId}. Error: $($_.Exception.Message)" "Error"
        continue
    }

    # 5. Доставка файла (если delivery_path_base задан)
    if ($script:Config.delivery_path_base) {
        $deliverySubDir = $script:Config.delivery_subdir_template -replace "{transport_code}", $transportCode
        $deliveryPath = Join-Path -Path $script:Config.delivery_path_base -ChildPath $deliverySubDir
        $deliveryFileName = $outputFileName # Имя файла уже сформировано правильно
        $deliveryFilePath = Join-Path -Path $deliveryPath -ChildPath $deliveryFileName
        Write-Log "Проверка пути доставки: $deliveryFilePath" "Info"

        # Создаем папку доставки, если ее нет
        if (-not (Test-Path $deliveryPath -PathType Container)) {
            Write-Log "Папка доставки '$deliveryPath' не найдена. Создание..." "Warn"
            try { New-Item -Path $deliveryPath -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "Папка '$deliveryPath' создана." "Verbose" }
            catch { Write-Log "Ошибка создания папки доставки '$deliveryPath'. Пропуск доставки. Error: $($_.Exception.Message)" "Error"; }
        }

        # Копируем файл, если папка доставки существует
        if (Test-Path $deliveryPath -PathType Container) {
            Write-Log "Копирование '$outputFilePath' -> '$deliveryFilePath'" "Verbose"
            try { Copy-Item -Path $outputFilePath -Destination $deliveryFilePath -Force -ErrorAction Stop; Write-Log "Файл '$outputFileName' доставлен в '$deliveryPath'." "Info" }
            catch { Write-Log "Ошибка копирования в '$deliveryFilePath'. Error: $($_.Exception.Message)" "Error"; }
        }
    } else { Write-Log "delivery_path_base не задан. Пропуск доставки." "Info" }

    Write-Log "--- Обработка ObjectId: $currentObjectId завершена ---" "Info"
} # --- Конец цикла foreach ---

Write-Log "Работа скрипта конфигуратора успешно завершена." "Info"