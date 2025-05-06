# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-DISK_USAGE.ps1
# --- Версия 2.0.2 --- Интеграция Test-SuccessCriteria
<#
.SYNOPSIS
    Скрипт проверки использования дискового пространства. (v2.0.2)
.DESCRIPTION
    Использует Get-Volume для получения информации о дисках.
    Формирует $Details с массивом 'disks'.
    Вызывает Test-SuccessCriteria для определения CheckSuccess.
.PARAMETER TargetIP
    [string] Обязательный. IP или имя хоста (для логирования).
.PARAMETER Parameters
    [hashtable] Опциональный. Параметры: drives ([string[]]).
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха для массива 'disks' в $Details
                (напр., @{ disks = @{ _condition_='all'; _criteria_=@{percent_free=@{'>'=10}}} }).
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
.NOTES
    Версия: 2.0.2 (Интеграция Test-SuccessCriteria).
    Зависит от New-CheckResultObject, Test-SuccessCriteria.
    Требует Windows 8 / Server 2012+.
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

# --- Инициализация ---
$isAvailable = $false; $checkSuccess = $null; $errorMessage = $null; $finalResult = $null
$details = @{ disks = [System.Collections.Generic.List[object]]::new() }

Write-Verbose "[$NodeName] Check-DISK_USAGE (v2.0.2): Начало проверки дисков на $TargetIP (локально)"

# --- Основной Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>

    # --- 1. Выполнение Get-Volume ---
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Вызов Get-Volume..."
    $volumes = Get-Volume -ErrorAction Stop
    $isAvailable = $true # Успех, если нет исключения
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Get-Volume выполнен. Найдено томов: $($volumes.Count)"

    # --- 2. Фильтрация томов ---
    $targetDriveLetters = @(); if ($Parameters.ContainsKey('drives') -and $Parameters.drives -is [array]) { $targetDriveLetters = $Parameters.drives | ForEach-Object { $_.Trim().ToUpper() } }
    $filteredVolumes = $volumes | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -ne $null -and (($targetDriveLetters.Count -eq 0) -or ($targetDriveLetters -contains $_.DriveLetter.ToString().ToUpper())) }
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Найдено Fixed дисков после фильтрации: $($filteredVolumes.Count)"

    # --- 3. Обработка томов и формирование $details.disks ---
    if ($filteredVolumes.Count -eq 0) {
        $details.message = "Нет локальных Fixed дисков" + ($targetDriveLetters.Count -gt 0 ? " (фильтр: $($targetDriveLetters -join ','))" : "") + "."
    } else {
        foreach ($vol in $filteredVolumes) {
            $driveLetter = $vol.DriveLetter.ToString().ToUpper()
            $diskInfo = [ordered]@{ drive_letter=$driveLetter; label=$vol.FileSystemLabel; filesystem=$vol.FileSystem; size_bytes=$vol.Size; free_bytes=$vol.SizeRemaining; used_bytes=($vol.Size - $vol.SizeRemaining); size_gb=$null; free_gb=$null; used_gb=$null; percent_free=$null; percent_used=$null }
            if ($diskInfo.size_bytes -gt 0) {
                $diskInfo.size_gb = [math]::Round($diskInfo.size_bytes / 1GB, 2); $diskInfo.free_gb = [math]::Round($diskInfo.free_bytes / 1GB, 2); $diskInfo.used_gb = [math]::Round($diskInfo.used_bytes / 1GB, 2)
                $diskInfo.percent_free = [math]::Round(($diskInfo.free_bytes / $diskInfo.size_bytes) * 100, 1); $diskInfo.percent_used = [math]::Round(($diskInfo.used_bytes / $diskInfo.size_bytes) * 100, 1)
            } else { $diskInfo.percent_free = 0; $diskInfo.percent_used = 0 } # Диск нулевого размера
            $details.disks.Add($diskInfo)
        }
    }

    # --- 4. Проверка критериев успеха ---
    $failReason = $null
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.PSObject.Properties.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-DISK_USAGE: Вызов Test-SuccessCriteria..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason
            if ($checkSuccess -ne $true) { $errorMessage = $failReason | Get-OrElse "Критерии успеха для дисков не пройдены."; Write-Verbose "[$NodeName] ... SuccessCriteria НЕ пройдены/ошибка: $errorMessage" }
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
    $finalResult = @{ IsAvailable=$isAvailable; CheckSuccess=$checkSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$detailsError; ErrorMessage=$critErrorMessage }
    Write-Error "[$NodeName] Check-DISK_USAGE: Критическая ошибка: $critErrorMessage"
} # <<< КОНЕЦ ОСНОВНОГО CATCH >>>

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-DISK_USAGE (v2.0.2): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult