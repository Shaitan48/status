# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-DISK_USAGE.ps1
# --- Версия 2.0.2 --- Интеграция Test-SuccessCriteria
<#
.SYNOPSIS
    Скрипт проверки использования дискового пространства. (v2.0.2)
.DESCRIPTION
    Использует Get-Volume для получения информации о дисках.
    Формирует $Details с массивом 'disks'.
    Вызывает Test-SuccessCriteria для определения CheckSuccess.
    ...
#>
param(
    [Parameter(Mandatory = $false)] # <--- TargetIP обязательный
    [string]$TargetIP,
    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node"
)

# --- Инициализация ---
$isAvailable = $false; $checkSuccess = $null; $errorMessage = $null; $finalResult = $null
$details = @{ disks = [System.Collections.Generic.List[object]]::new() }

Write-Verbose "[$NodeName] Check-DISK_USAGE (v2.0.2): Начало проверки дисков на $TargetIP (локально)"

# --- Основной Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>

    # --- 1. Выполнение Get-Volume ---
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Вызов Get-Volume..."
    $volumes = Get-Volume -ErrorAction Stop # <--- Get-Volume выполняется локально
    $isAvailable = $true 
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Get-Volume выполнен. Найдено томов: $($volumes.Count)"

    # --- 2. Фильтрация томов ---
    $targetDriveLetters = @(); 
    if ($Parameters.ContainsKey('drives') -and $Parameters.drives -is [array]) { 
        $targetDriveLetters = $Parameters.drives | ForEach-Object { $_.ToString().Trim().ToUpper() } # Добавил ToString()
    }
    $filteredVolumes = $volumes | Where-Object { 
        $_.DriveType -eq 'Fixed' -and 
        $_.DriveLetter -ne $null -and 
        (($targetDriveLetters.Count -eq 0) -or ($targetDriveLetters -contains $_.DriveLetter.ToString().ToUpper())) 
    }
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Найдено Fixed дисков после фильтрации: $($filteredVolumes.Count)"

    # --- 3. Обработка томов и формирование $details.disks ---
    if ($filteredVolumes.Count -eq 0) {
        if ($targetDriveLetters.Count -gt 0) {
            $details.message = "Нет локальных Fixed дисков (фильтр: $($targetDriveLetters -join ','))."
        } else {
            $details.message = "Нет локальных Fixed дисков."
        }
    } else {
        foreach ($vol in $filteredVolumes) {
            $driveLetter = $vol.DriveLetter.ToString().ToUpper() # Уже ToUpper()
            $diskInfo = [ordered]@{ # Используется ordered
                drive_letter=$driveLetter; 
                label=$vol.FileSystemLabel; 
                filesystem=$vol.FileSystem; 
                size_bytes=$vol.Size; 
                free_bytes=$vol.SizeRemaining; 
                used_bytes=($vol.Size - $vol.SizeRemaining); 
                size_gb=$null; free_gb=$null; used_gb=$null; 
                percent_free=$null; percent_used=$null 
            }
            if ($diskInfo.size_bytes -gt 0) {
                $diskInfo.size_gb = [math]::Round($diskInfo.size_bytes / 1GB, 2); 
                $diskInfo.free_gb = [math]::Round($diskInfo.free_bytes / 1GB, 2); 
                $diskInfo.used_gb = [math]::Round($diskInfo.used_bytes / 1GB, 2)
                $diskInfo.percent_free = [math]::Round(($diskInfo.free_bytes / $diskInfo.size_bytes) * 100, 1); 
                $diskInfo.percent_used = [math]::Round(($diskInfo.used_bytes / $diskInfo.size_bytes) * 100, 1)
            } else { 
                $diskInfo.percent_free = 0.0; # Явно double
                $diskInfo.percent_used = 0.0  # Явно double, если размер 0, то занято 0%
                # Если размер 0 и свободно 0, то % использования тоже 0 (или 100, если считать, что нет свободного места)
                # Для диска 0 байт, percent_used скорее 0, чем 100.
                # Если free_bytes = 0 и size_bytes > 0, то percent_used = 100
                if ($diskInfo.size_bytes -eq 0) { $diskInfo.percent_used = 0.0 } 
                elseif ($diskInfo.free_bytes -eq 0) { $diskInfo.percent_used = 100.0} # Занято 100%
            }
            $details.disks.Add($diskInfo)
        }
    }

    # --- 4. Проверка критериев успеха ---
    $failReason = $null
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.PSObject.Properties.Count -gt 0) { # Для Hashtable лучше .Keys.Count
            Write-Verbose "[$NodeName] Check-DISK_USAGE: Вызов Test-SuccessCriteria..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details' # Добавлен Path
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason
            if ($checkSuccess -ne $true) { 
                # Используем if/else вместо Get-OrElse
                if (-not [string]::IsNullOrEmpty($failReason)) { $errorMessage = $failReason }
                else { $errorMessage = "Критерии успеха для дисков не пройдены (CheckSuccess: $($checkSuccess | ForEach-Object {if ($_ -eq $null) {'[null]'} else {$_}}))." }
                Write-Verbose "[$NodeName] ... SuccessCriteria НЕ пройдены/ошибка: $errorMessage" 
            }
            else { $errorMessage = $null; Write-Verbose "[$NodeName] ... SuccessCriteria пройдены." }
        } else {
            $checkSuccess = $true; $errorMessage = $null
            Write-Verbose "[$NodeName] Check-DISK_USAGE: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = "Ошибка выполнения Get-Volume (IsAvailable=false)." }
    }

    # --- 5. Формирование результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch { # <<< ОСНОВНОЙ CATCH >>>
    $isAvailable = $false; $checkSuccess = $null
    $critErrorMessage = "Критическая ошибка Check-DISK_USAGE: $($_.Exception.Message)"
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString() }
    # $finalResult создается через New-CheckResultObject для единообразия
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $detailsError ` # Передаем детали ошибки
                                         -ErrorMessage $critErrorMessage
    Write-Error "[$NodeName] Check-DISK_USAGE: Критическая ошибка: $critErrorMessage"
} # <<< КОНЕЦ ОСНОВНОГО CATCH >>>

# --- Отладка перед возвратом ---
# (оставляем ваш отладочный блок без изменений, если он вам полезен)
Write-Host "DEBUG (Check-DISK_USAGE): --- Начало отладки finalResult.Details ---" -ForegroundColor Green
# ...

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStrForLog = if ($finalResult) { if ($null -eq $finalResult.CheckSuccess) {'[null]'} else {$finalResult.CheckSuccess} } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-DISK_USAGE (v2.1.0): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStrForLog"

return $finalResult