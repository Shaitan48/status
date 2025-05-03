# powershell\offline-agent\offline-agent.ps1
# Оффлайн-агент мониторинга v3.1.
# Исправлено добавление assignment_id к результатам.
<#
.SYNOPSIS
    Оффлайн-агент системы мониторинга Status Monitor v3.1.
.DESCRIPTION
    Предназначен для работы в изолированных сетях без доступа к API.
    1. Читает локальную конфигурацию агента ('config.json').
    2. Периодически проверяет наличие файла с заданиями
       в папке 'assignments_file_path'.
    3. При обнаружении нового файла заданий:
       - Читает JSON-содержимое.
       - Извлекает список 'assignments' и 'assignment_config_version'.
       - Сохраняет их для выполнения.
    4. В цикле выполняет ВСЕ активные задания с помощью
       Invoke-StatusMonitorCheck из модуля StatusMonitorAgentUtils.
    5. Собирает стандартизированные результаты всех проверок.
    6. **Создает новый объект для каждого результата, объединяя
       стандартный результат и 'assignment_id'.**
    7. Формирует итоговый JSON-файл (*.zrpu) в папке 'output_path',
       включая метаданные (версии агента и конфига) и массив 'results'.
    8. Этот *.zrpu файл затем передается и загружается на сервер.
.NOTES
    Версия: 3.1
    Дата: 2024-05-20
    Изменения v3.1:
        - Исправлен способ добавления 'assignment_id' к результатам. Вместо
          Add-Member теперь создается новый объект путем слияния хэш-таблиц.
    Изменения v3.0:
        - Попытка добавить поле 'assignment_id' к каждому элементу в массиве 'results'.
    Зависимости: PowerShell 5.1+, модуль StatusMonitorAgentUtils, наличие файла конфигурации заданий.
#>

param (
    # Путь к файлу конфигурации агента.
    [string]$configFile = "$PSScriptRoot\config.json",

    # Параметры для переопределения лог-файла и уровня логирования из командной строки.
    [string]$paramLogFile = $null,
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
    [string]$paramLogLevel = $null
)

# --- Загрузка модуля Utils ---
$ErrorActionPreference = "Stop"
try {
    $ModuleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1"
    Write-Host "[INFO] Загрузка модуля '$ModuleManifestPath'..."
    Import-Module $ModuleManifestPath -Force -ErrorAction Stop
    Write-Host "[INFO] Модуль Utils загружен."
} catch {
    Write-Host "[CRITICAL] Критическая ошибка загрузки модуля '$ModuleManifestPath': $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    $ErrorActionPreference = "Continue"
}
# --- Конец загрузки модуля ---

# --- Глобальные переменные ---
# Версия текущего скрипта оффлайн-агента
$AgentScriptVersion = "agent_script_v3.1" # Обновили версию

# Имя компьютера
$script:ComputerName = $env:COMPUTERNAME
# Текущий список заданий (массив объектов PSCustomObject из файла конфигурации)
$script:currentAssignments = $null
# Текущая версия файла конфигурации заданий (строка из файла)
$script:currentAssignmentVersion = $null
# Путь к последнему обработанному файлу конфигурации заданий
$script:lastProcessedConfigFile = $null
# Объект с конфигурацией самого агента (из config.json)
$script:localConfig = $null
# Путь к лог-файлу агента
$script:logFile = $null
# Установленный уровень логирования
$script:LogLevel = "Info"
# Допустимые уровни логирования
$ValidLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error")


# --- Функции ---

#region Функции

<#
.SYNOPSIS Записывает сообщение в лог.
#>
function Write-Log{
    param( [Parameter(Mandatory=$true)][string]$Message, [ValidateSet("Debug","Verbose","Info","Warn","Error",IgnoreCase=$true)] [string]$Level="Info" ); if (-not $script:localConfig -or -not $script:logFile) { Write-Host "[$Level] $Message"; return }; $logLevels=@{"Debug"=4;"Verbose"=3;"Info"=2;"Warn"=1;"Error"=0}; $effectiveLogLevel = $script:LogLevel; if(-not $logLevels.ContainsKey($effectiveLogLevel)){ $effectiveLogLevel="Info" }; $currentLevelValue = $logLevels[$effectiveLogLevel]; $messageLevelValue = $logLevels[$Level]; if($null -eq $messageLevelValue){ $messageLevelValue=$logLevels["Info"] }; if($messageLevelValue -le $currentLevelValue){ $timestamp=Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage="[$timestamp] [$Level] [$script:ComputerName] - $Message"; $consoleColor = switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}; Write-Host $logMessage -ForegroundColor $consoleColor; if($script:logFile){ try { $logDir = Split-Path $script:logFile -Parent; if($logDir -and (-not(Test-Path $logDir -PathType Container))){ Write-Host "[INFO] Создание папки логов: '$logDir'."; New-Item -Path $logDir -ItemType Directory -Force -EA Stop | Out-Null }; Add-Content -Path $script:logFile -Value $logMessage -Encoding UTF8 -Force -EA Stop } catch { Write-Host "[CRITICAL] Ошибка записи в лог '$script:logFile': $($_.Exception.Message)" -ForegroundColor Red; try { $fallbackLog = "$PSScriptRoot\offline_agent_fallback.log"; Add-Content -Path $fallbackLog -Value $logMessage -Encoding UTF8 -Force -EA SilentlyContinue; Add-Content -Path $fallbackLog -Value "[CRITICAL] Ошибка записи в '$script:logFile': $($_.Exception.Message)" -Encoding UTF8 -Force -EA SilentlyContinue } catch {} } } }
}

<#
.SYNOPSIS Возвращает значение по умолчанию, если входное значение ложно.
#>
filter Get-OrElse_Internal{ param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }

#endregion Функции

# --- Основной код агента ---

# 1. Чтение и валидация конфигурации агента
# ... (код чтения и валидации конфига без изменений) ...
Write-Host "Оффлайн-агент мониторинга v$AgentScriptVersion"; Write-Host "Чтение конфигурации агента: $configFile"
if(-not(Test-Path $configFile -PathType Leaf)){ Write-Error "Критическая ошибка: Файл конфигурации '$configFile' не найден."; exit 1 }
try { $script:localConfig = Get-Content -Path $configFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Error "Критическая ошибка: Ошибка чтения/парсинга JSON из '$configFile': $($_.Exception.Message)"; exit 1 }
$requiredLocalConfigFields = @("object_id","output_path","output_name_template","assignments_file_path","logFile","LogLevel","check_interval_seconds"); $missingFields = $requiredLocalConfigFields | Where-Object { -not ($script:localConfig.PSObject.Properties.Name.Contains($_)) -or $null -eq $script:localConfig.$_ -or ($script:localConfig.$_ -is [string] -and [string]::IsNullOrWhiteSpace($script:localConfig.$_))}; if($missingFields){ Write-Error "Критическая ошибка: Отсутствуют/пусты обязательные поля в '$configFile': $($missingFields -join ', ')"; exit 1 }
$script:logFile = if($PSBoundParameters.ContainsKey('paramLogFile') -and $paramLogFile){ $paramLogFile } else { $script:localConfig.logFile }; $script:LogLevel = if($PSBoundParameters.ContainsKey('paramLogLevel') -and $paramLogLevel){ $paramLogLevel } else { $script:localConfig.LogLevel }; if(-not $ValidLogLevels.Contains($script:LogLevel)){ Write-Host "[WARN] Некорректный LogLevel '$($script:LogLevel)'. Используется 'Info'." -ForegroundColor Yellow; $script:LogLevel = "Info" }; $checkInterval = 60; if($script:localConfig.check_interval_seconds -and [int]::TryParse($script:localConfig.check_interval_seconds,[ref]$null) -and $script:localConfig.check_interval_seconds -ge 5){ $checkInterval = $script:localConfig.check_interval_seconds } else { Write-Log "Некорректное значение check_interval_seconds ('$($script:localConfig.check_interval_seconds)'). Используется $checkInterval сек." "Warn" }
$objectId = $script:localConfig.object_id; $outputPath = $script:localConfig.output_path; $outputNameTemplate = $script:localConfig.output_name_template; $assignmentsFolderPath = $script:localConfig.assignments_file_path


# 2. Инициализация и проверка путей
# ... (код инициализации и проверки путей без изменений) ...
Write-Log "Оффлайн-агент запущен. Версия: $AgentScriptVersion. Имя хоста: $script:ComputerName" "Info"; Write-Log ("Параметры: ObjectID={0}, Интервал={1} сек, Папка заданий='{2}', Папка результатов='{3}'" -f $objectId, $checkInterval, $assignmentsFolderPath, $outputPath) "Info"; Write-Log "Логирование в '$script:logFile' с уровнем '$script:LogLevel'" "Info"; if(-not(Test-Path $outputPath -PathType Container)){ Write-Log "Папка для результатов '$outputPath' не найдена. Попытка создать..." "Warn"; try { New-Item -Path $outputPath -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "Папка '$outputPath' успешно создана." "Info" } catch { Write-Log "Критическая ошибка: Не удалось создать папку для результатов '$outputPath': $($_.Exception.Message)" "Error"; exit 1 } }; if(-not(Test-Path $assignmentsFolderPath -PathType Container)){ Write-Log "Критическая ошибка: Папка для файлов заданий '$assignmentsFolderPath' не найдена." "Error"; exit 1 }


# --- 3. Основной цикл работы агента ---
Write-Log "Запуск основного цикла агента..." "Info"
while ($true) {
    $cycleStartTime = Get-Date
    Write-Log "Начало итерации цикла ($($cycleStartTime.ToString('s')))." "Verbose"

    # --- 3.1 Поиск и чтение файла конфигурации заданий ---
    # ... (код поиска и чтения файла конфига без изменений) ...
    $latestConfigFile = $null; $configError = $null; $configData = $null
    try { $configFileNamePattern = "*_${objectId}_*_assignments.json.status.*"; Write-Log "Поиск файла конфигурации в '$assignmentsFolderPath' по шаблону '$configFileNamePattern'..." "Debug"; $foundFiles = Get-ChildItem -Path $assignmentsFolderPath -Filter $configFileNamePattern -File -ErrorAction SilentlyContinue; if ($Error.Count -gt 0 -and $Error[0].CategoryInfo.Category -eq 'ReadError') { throw ("Ошибка доступа при поиске файла конфигурации в '$assignmentsFolderPath': " + $Error[0].Exception.Message); $Error.Clear() }; if ($foundFiles) { $latestConfigFile = $foundFiles | Sort-Object Name -Descending | Select-Object -First 1; Write-Log "Найден последний файл конфигурации: $($latestConfigFile.FullName)" "Verbose" } else { Write-Log "Файлы конфигурации для ObjectID $objectId в '$assignmentsFolderPath' не найдены." "Warn" } } catch { $configError = "Ошибка поиска файла конфигурации: $($_.Exception.Message)"; Write-Log $configError "Error" }
    if ($latestConfigFile -ne $null -and $configError -eq $null) { if ($latestConfigFile.FullName -ne $script:lastProcessedConfigFile) { Write-Log "Обнаружен новый/обновленный файл конфигурации: $($latestConfigFile.Name). Чтение..." "Info"; $tempAssignments = $null; $tempVersionTag = $null; try { $fileContent = Get-Content -Path $latestConfigFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop; $fileContentClean = $fileContent.TrimStart([char]0xFEFF); $configData = $fileContentClean | ConvertFrom-Json -ErrorAction Stop; if ($null -eq $configData -or (-not $configData.PSObject.Properties.Name.Contains('assignments')) -or ($configData.assignments -isnot [array]) -or (-not $configData.PSObject.Properties.Name.Contains('assignment_config_version')) -or (-not $configData.assignment_config_version) ) { throw ("Файл '$($latestConfigFile.Name)' имеет некорректную структуру JSON...") }; $tempVersionTag = $configData.assignment_config_version; $tempAssignments = $configData.assignments; Write-Log ("Файл '{0}' успешно прочитан..." -f $latestConfigFile.Name, $tempAssignments.Count, $tempVersionTag) "Info"; $script:currentAssignments = $tempAssignments; $script:currentAssignmentVersion = $tempVersionTag; $script:lastProcessedConfigFile = $latestConfigFile.FullName; Write-Log "Список заданий обновлен (версия: $tempVersionTag)..." "Info" } catch { $errorMsg = "Критическая ошибка обработки файла '$($latestConfigFile.Name)': $($_.Exception.Message)"; Write-Log $errorMsg "Error"; Write-Log ("Продолжаем использовать предыдущий список заданий (версия: {0})." -f ($script:currentAssignmentVersion | Get-OrElse_Internal '[неизвестно]')) "Warn" } } else { Write-Log "Файл конфигурации '$($latestConfigFile.Name)' не изменился." "Verbose" } } elseif ($configError -ne $null) { Write-Log "Продолжаем использовать предыдущий список заданий..." "Warn" } elseif ($script:lastProcessedConfigFile -ne $null) { Write-Log "Файлы конфигурации не найдены. Продолжаем использовать предыдущий список..." "Warn" } else { Write-Log "Файлы конфигурации не найдены..." "Info" }

    # --- 3.2 Выполнение текущего списка заданий ---
    $cycleCheckResultsList = [System.Collections.Generic.List[object]]::new()

    if ($script:currentAssignments -ne $null -and $script:currentAssignments.Count -gt 0) {
        $assignmentsCount = $script:currentAssignments.Count
        Write-Log "Начало выполнения $assignmentsCount заданий (Версия конфига: $($script:currentAssignmentVersion | Get-OrElse_Internal 'N/A'))..." "Info"
        $completedCount = 0

        foreach ($assignmentRaw in $script:currentAssignments) {
            $completedCount++
            $assignment = [PSCustomObject]$assignmentRaw
            Write-Log "Выполнение $completedCount/$assignmentsCount (ID: $($assignment.assignment_id))..." "Verbose"

            if ($null -eq $assignment -or $null -eq $assignment.assignment_id -or -not $assignment.method_name) {
                Write-Log "Пропущено некорректное задание в списке: $($assignment | Out-String)" "Warn"
                # --- ИЗМЕНЕНО: Создаем объект ошибки через слияние ---
                $errorDetails = @{ assignment_object = ($assignment | Out-String) }
                $errorResultBase = New-CheckResultObject -IsAvailable $false `
                                      -ErrorMessage "Некорректная структура задания в файле конфигурации." `
                                      -Details $errorDetails
                $idPart = @{ assignment_id = ($assignment.assignment_id | Get-OrElse_Internal $null) }
                $errorResultToSave = $idPart + $errorResultBase
                $cycleCheckResultsList.Add($errorResultToSave)
                # --- КОНЕЦ ИЗМЕНЕНИЯ ---
                continue
            }

            $checkResult = $null
            try {
                # Вызываем диспетчер проверок
                $checkResult = Invoke-StatusMonitorCheck -Assignment $assignment `
                                                        -Verbose:$VerbosePreference `
                                                        -Debug:$DebugPreference

                Write-Log ("Результат ID {0}: IsAvailable={1}, CheckSuccess={2}, Error='{3}'" -f `
                           $assignment.assignment_id, $checkResult.IsAvailable, $checkResult.CheckSuccess, $checkResult.ErrorMessage) "Verbose"

                # --- ИЗМЕНЕНО: Создаем НОВЫЙ объект результата с ID через слияние ---
                $idPart = @{ assignment_id = $assignment.assignment_id }
                $resultToSave = $idPart + $checkResult
                # --- КОНЕЦ ИЗМЕНЕНИЯ ---

                # Отладочный вывод (если включен Debug)
                Write-Debug ("Объект ДО добавления в список (ID: {0}): {1}" -f `
                             $assignment.assignment_id, ($resultToSave | ConvertTo-Json -Depth 4 -Compress))

                # Добавляем результат в список для файла
                $cycleCheckResultsList.Add($resultToSave)

            } catch {
                 # Обработка критической ошибки выполнения Invoke-StatusMonitorCheck
                 $errorMessage = "Критическая ошибка при выполнении задания ID $($assignment.assignment_id): $($_.Exception.Message)"
                 Write-Log $errorMessage "Error"
                 # Создаем запись об ошибке
                 $errorDetails = @{ ErrorRecord = $_.ToString() }
                 $errorResultBase = New-CheckResultObject -IsAvailable $false `
                                      -ErrorMessage $errorMessage `
                                      -Details $errorDetails
                 # --- ИЗМЕНЕНО: Создаем НОВЫЙ объект ошибки с ID через слияние ---
                 $idPart = @{ assignment_id = $assignment.assignment_id }
                 $errorResultToSave = $idPart + $errorResultBase
                 # --- КОНЕЦ ИЗМЕНЕНИЯ ---

                 # Отладочный вывод для ошибки
                 Write-Debug ("ОБЪЕКТ ОШИБКИ ДО добавления в список (ID: {0}): {1}" -f `
                              $assignment.assignment_id, ($errorResultToSave | ConvertTo-Json -Depth 4 -Compress))

                 # Добавляем результат с ошибкой в общий список
                 $cycleCheckResultsList.Add($errorResultToSave)
            }
        } # Конец foreach assignment

        Write-Log "Выполнение $assignmentsCount заданий завершено. Собрано результатов: $($cycleCheckResultsList.Count)." "Info"

    } else {
        Write-Log "Нет активных заданий для выполнения в этой итерации." "Verbose"
    }

    # --- 3.3 Формирование и сохранение файла результатов (*.zrpu) ---
    if ($cycleCheckResultsList.Count -gt 0) {
        # ... (код формирования $finalPayload и сохранения файла без изменений) ...
        $finalPayload = @{ agent_script_version = $AgentScriptVersion; assignment_config_version = $script:currentAssignmentVersion; results = $cycleCheckResultsList }
        $timestampForFile = Get-Date -Format "ddMMyy_HHmmss"; $outputFileName = $outputNameTemplate -replace "{object_id}", $objectId -replace "{ddMMyy_HHmmss}", $timestampForFile; $outputFileName = $outputFileName -replace '[\\/:*?"<>|]', '_'; $outputFileFullPath = Join-Path $outputPath $outputFileName
        Write-Log "Сохранение $($cycleCheckResultsList.Count) результатов в файл: '$outputFileFullPath'" "Info"; Write-Log ("Версия агента: {0}, Версия конфига заданий: {1}" -f $AgentScriptVersion, ($script:currentAssignmentVersion | Get-OrElse_Internal 'N/A')) "Verbose"
        try { $jsonToSave = $finalPayload | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue; $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllText($outputFileFullPath, $jsonToSave, $Utf8NoBomEncoding); Write-Log "Файл результатов '$outputFileName' успешно сохранен." "Info" }
        catch { Write-Log "Критическая ошибка сохранения файла результатов '$outputFileFullPath': $($_.Exception.Message)" "Error" }
    } else {
        Write-Log "Нет результатов для сохранения в файл в этой итерации." "Verbose"
    }

    # --- 3.4 Пауза перед следующей итерацией ---
    # ... (код расчета паузы и Start-Sleep без изменений) ...
    $cycleEndTime = Get-Date; $elapsedSeconds = ($cycleEndTime - $cycleStartTime).TotalSeconds; $sleepSeconds = $checkInterval - $elapsedSeconds; if ($sleepSeconds -lt 1) { $sleepSeconds = 1 }
    Write-Log ("Итерация заняла {0:N2} сек. Пауза {1:N2} сек до следующего цикла..." -f $elapsedSeconds, $sleepSeconds) "Verbose"; Start-Sleep -Seconds $sleepSeconds

} # --- Конец while ($true) ---

Write-Log "Оффлайн-агент завершает работу (неожиданный выход из основного цикла)." "Error"
exit 1