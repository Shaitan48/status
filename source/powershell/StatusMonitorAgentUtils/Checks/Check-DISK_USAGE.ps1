# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-DISK_USAGE.ps1
# --- Версия 2.0 ---
# Изменения:
# - Логика проверки SuccessCriteria вынесена в универсальную функцию Test-SuccessCriteria.
# - Стандартизирован формат $Details.
# - Убран прямой расчет CheckSuccess на основе min_percent_free.
# - Добавлен вызов Test-SuccessCriteria.

<#
.SYNOPSIS
    Скрипт проверки использования дискового пространства. (v2.0)
.DESCRIPTION
    Получает информацию о локальных дисках типа 'Fixed' с помощью Get-Volume.
    Позволяет фильтровать диски по букве.
    Формирует стандартизированный объект $Details с массивом 'disks', содержащим
    детальную информацию о каждом проверенном диске.
    Для определения итогового CheckSuccess использует универсальную функцию
    Test-SuccessCriteria, сравнивающую $Details с переданным $SuccessCriteria.
    Ожидаемый формат SuccessCriteria для проверки дисков:
    @{ disks = @{ _condition_ = 'all'; _where_ = @{ drive_letter='C' }; percent_free = @{ '>' = 10 } } }
    (Пример: для всех дисков, где буква 'C', % свободного места должен быть > 10).
.PARAMETER TargetIP
    [string] Обязательный. IP или имя хоста. Используется для логирования,
             скрипт выполняется локально.
.PARAMETER Parameters
    [hashtable] Опциональный. Параметры проверки:
    - drives ([string[]]): Массив букв дисков для проверки (регистр не важен).
                           Если не указан, проверяются все локальные диски типа 'Fixed'.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха. Ожидается структура для проверки
                массива 'disks' в $Details (см. пример выше). Обрабатывается
                функцией Test-SuccessCriteria.
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
                Поле Details (hashtable) содержит:
                - disks (List<object>): Массив хэш-таблиц с информацией о дисках
                  (drive_letter, label, filesystem, size_bytes, free_bytes,
                  used_bytes, size_gb, free_gb, used_gb, percent_free, percent_used).
                - message (string): Опциональное сообщение (напр., если диски не найдены).
                - error (string): Опциональное сообщение об ошибке выполнения.
                - ErrorRecord (string): Опционально, полный текст исключения.
.NOTES
    Версия: 2.0.1 (Добавлены комментарии, форматирование, улучшена обработка 0 размера диска).
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria из StatusMonitorAgentUtils.psm1.
    Требует ОС Windows 8 / Server 2012 или новее для Get-Volume.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIP,

    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},

    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,

    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node"
)

# --- Инициализация переменных ---
$isAvailable = $false
$checkSuccess = $null
$errorMessage = $null
$finalResult = $null
# Инициализируем $Details с пустым списком дисков
$details = @{
    disks = [System.Collections.Generic.List[object]]::new()
    # message будет добавлено при необходимости
}

Write-Verbose "[$NodeName] Check-DISK_USAGE (v2.0.1): Начало проверки дисков на $TargetIP (локально на $env:COMPUTERNAME)"

# --- Основной блок Try/Catch ---
try {

    # --- 1. Выполнение Get-Volume ---
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Вызов Get-Volume..."
    # Выполняем команду, перехватывая критические ошибки (например, командлет не найден на старой ОС)
    $volumes = Get-Volume -ErrorAction Stop

    # Если команда выполнилась без исключения, считаем проверку доступной
    $isAvailable = $true
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Get-Volume выполнен. Получено томов: $($volumes.Count)"

    # --- 2. Фильтрация томов ---
    $targetDriveLetters = @() # Массив для целевых букв (Upper Case)
    # Проверяем параметр 'drives'
    if ($Parameters.ContainsKey('drives') -and $Parameters.drives -is [array] -and $Parameters.drives.Count -gt 0) {
        $targetDriveLetters = $Parameters.drives | ForEach-Object { $_.Trim().ToUpper() }
        Write-Verbose "[$NodeName] Check-DISK_USAGE: Фильтрация по указанным дискам: $($targetDriveLetters -join ', ')"
    } else {
        Write-Verbose "[$NodeName] Check-DISK_USAGE: Параметр 'drives' не указан, обрабатываем все диски типа 'Fixed'."
    }

    # Фильтруем тома по типу 'Fixed', наличию буквы и списку $targetDriveLetters (если он задан)
    $filteredVolumes = $volumes | Where-Object {
        $isFixed = $_.DriveType -eq 'Fixed'
        $currentDriveLetterChar = $_.DriveLetter
        $hasLetter = $null -ne $currentDriveLetterChar -and (-not [string]::IsNullOrWhiteSpace($currentDriveLetterChar))
        $currentDriveLetterString = $currentDriveLetterChar.ToString()
        $isInTargetList = ($targetDriveLetters.Count -eq 0) -or ($targetDriveLetters -contains $currentDriveLetterString.ToUpper())
        # Условие: Fixed И HasLetter И (Нет фильтра ИЛИ Входит в фильтр)
        $isFixed -and $hasLetter -and $isInTargetList
    }
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Количество томов после фильтрации: $($filteredVolumes.Count)"

    # --- 3. Обработка отфильтрованных томов и формирование $Details ---
    if ($filteredVolumes.Count -eq 0) {
        # Если дисков для проверки не осталось
        $details.message = "Нет локальных дисков типа 'Fixed'"
        if ($targetDriveLetters.Count -gt 0) {
            $details.message += ", соответствующих указанным буквам ($($targetDriveLetters -join ', '))"
        }
        $details.message += "."
        Write-Verbose "[$NodeName] Check-DISK_USAGE: $($details.message)"
        # CheckSuccess остается $null, будет установлен в $true ниже, если $isAvailable = $true
    } else {
        # Если есть диски для обработки
        foreach ($vol in $filteredVolumes) {
            $driveLetter = $vol.DriveLetter.ToString().ToUpper()
            Write-Verbose "[$NodeName] Check-DISK_USAGE: Обработка диска $driveLetter"

            # Собираем информацию о диске
            $diskInfo = [ordered]@{
                drive_letter = $driveLetter
                label        = $vol.FileSystemLabel
                filesystem   = $vol.FileSystem
                size_bytes   = $vol.Size
                free_bytes   = $vol.SizeRemaining
                used_bytes   = $vol.Size - $vol.SizeRemaining
                size_gb      = $null
                free_gb      = $null
                used_gb      = $null
                percent_free = $null
                percent_used = $null
                # <<< УБРАНЫ ПОЛЯ КРИТЕРИЕВ ИЗ Details >>>
                # criteria_applied = $null
                # criteria_passed  = $null
                # criteria_failed_reason = $null
            }

            # Рассчитываем производные значения (GB, %)
            if ($diskInfo.size_bytes -gt 0) {
                $diskInfo.size_gb = [math]::Round($diskInfo.size_bytes / 1GB, 2)
                $diskInfo.free_gb = [math]::Round($diskInfo.free_bytes / 1GB, 2)
                $diskInfo.used_gb = [math]::Round($diskInfo.used_bytes / 1GB, 2)
                $diskInfo.percent_free = [math]::Round(($diskInfo.free_bytes / $diskInfo.size_bytes) * 100, 1)
                $diskInfo.percent_used = [math]::Round(($diskInfo.used_bytes / $diskInfo.size_bytes) * 100, 1)
            } else {
                # Обработка дисков с нулевым размером
                Write-Warning "[$NodeName] Check-DISK_USAGE: Диск $driveLetter имеет размер 0 байт."
                $diskInfo.size_gb = 0; $diskInfo.free_gb = 0; $diskInfo.used_gb = 0
                $diskInfo.percent_free = 0; $diskInfo.percent_used = 0 # Условно 0% свободно, 0% занято
            }

            # Добавляем информацию о диске в список $Details.disks
            $details.disks.Add($diskInfo)

            # <<< УБРАНА ЛОГИКА ПРОВЕРКИ КРИТЕРИЕВ ЗДЕСЬ >>>

        } # Конец foreach ($vol in $filteredVolumes)
    } # Конец else (если были диски для проверки)

    # --- 4. Вызов универсальной функции проверки критериев ---
    $failReason = $null

    if ($isAvailable) { # Проверяем критерии ТОЛЬКО если проверка прошла
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-DISK_USAGE: Вызов Test-SuccessCriteria..."
            # Вызываем универсальную функцию
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed # $true, $false или $null
            $failReason = $criteriaResult.FailReason

            if ($checkSuccess -eq $null) {
                $errorMessage = "Ошибка при обработке SuccessCriteria: $failReason"
                Write-Warning "[$NodeName] $errorMessage"
            } elseif ($checkSuccess -eq $false) {
                $errorMessage = $failReason # Причина провала станет ErrorMessage
                Write-Verbose "[$NodeName] Check-DISK_USAGE: SuccessCriteria НЕ пройдены: $failReason"
            } else {
                $errorMessage = $null # Критерии пройдены
                Write-Verbose "[$NodeName] Check-DISK_USAGE: SuccessCriteria пройдены."
            }
        } else {
            # Критерии не заданы
            $checkSuccess = $true
            $errorMessage = $null
            Write-Verbose "[$NodeName] Check-DISK_USAGE: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        # Если IsAvailable = $false
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) {
            # $errorMessage должен был установиться в catch блоке ниже
            $errorMessage = "Ошибка выполнения проверки дисков (IsAvailable=false)."
        }
    }

    # --- 5. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

# <<< Закрываем основной try блок >>>
} catch {
    # --- Обработка КРИТИЧЕСКИХ ошибок скрипта ---
    # Например, Get-Volume не найден или другая ошибка PowerShell
    $isAvailable = $false
    $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $critErrorMessage = "Критическая ошибка при проверке дисков: {0}" -f $exceptionMessage

    # Формируем Details с ошибкой
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString() }

    # Создаем финальный результат ВРУЧНУЮ
    $finalResult = @{
        IsAvailable  = $isAvailable
        CheckSuccess = $checkSuccess
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        Details      = $detailsError
        ErrorMessage = $critErrorMessage
    }
    Write-Error "[$NodeName] Check-DISK_USAGE: Критическая ошибка: $critErrorMessage"
} # <<< Закрываем основной catch блок >>>

# --- Возврат результата ---
# Используем стандартный доступ к свойствам, проверив $finalResult
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-DISK_USAGE (v2.0.1): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult