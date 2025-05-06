# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SERVICE_STATUS.ps1
# --- Версия 2.0.1 --- Интеграция Test-SuccessCriteria
<#
.SYNOPSIS
    Проверяет статус указанной системной службы. (v2.0.1)
.DESCRIPTION
    Использует Get-Service для получения статуса службы.
    Формирует $Details с информацией о службе.
    Вызывает Test-SuccessCriteria для определения CheckSuccess.
.PARAMETER TargetIP
    [string] Обязательный. IP или имя хоста (для логирования).
.PARAMETER Parameters
    [hashtable] Обязательный. Должен содержать 'service_name'.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха для полей в $Details
                (напр., @{ status = 'Running'; start_type = 'Automatic' }).
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
.NOTES
    Версия: 2.0.1 (Интеграция Test-SuccessCriteria).
    Зависит от New-CheckResultObject, Test-SuccessCriteria.
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
$details = @{ service_name = $null } # Базовые детали

Write-Verbose "[$NodeName] Check-SERVICE_STATUS (v2.0.1): Начало проверки для $TargetIP (локально)"

# --- Основной Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>
    # 1. Валидация параметра service_name
    $serviceName = $Parameters.service_name
    if (-not $serviceName -or $serviceName -isnot [string] -or $serviceName.Trim() -eq '') {
        throw "Параметр 'service_name' отсутствует или пуст."
    }
    $serviceName = $serviceName.Trim()
    $details.service_name = $serviceName
    Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Проверяемая служба '$serviceName'"

    # 2. Выполнение Get-Service (локально)
    $service = $null
    try {
        Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Вызов Get-Service -Name '$serviceName'..."
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        # --- УСПЕХ Get-Service ---
        $isAvailable = $true # Проверка выполнена
        $currentStatus = $service.Status.ToString()
        Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Служба найдена. Статус: $currentStatus"
        # Заполняем $Details
        $details.status = $currentStatus
        $details.display_name = $service.DisplayName
        $details.start_type = $service.StartType.ToString()
        $details.can_stop = $service.CanStop
        # Добавьте другие нужные свойства, если необходимо
        # $details.can_pause_and_continue = $service.CanPauseAndContinue

    } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
        # --- ОШИБКА: Служба не найдена ---
        $isAvailable = $false
        $errorMessage = "Служба '$serviceName' не найдена на '$($env:COMPUTERNAME)'."
        $details.error = $errorMessage
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: $errorMessage"
        # CheckSuccess остается $null
    } catch {
        # --- ОШИБКА: Другая ошибка Get-Service ---
        $isAvailable = $false
        $errorMessage = "Ошибка Get-Service для '$serviceName': $($_.Exception.Message)"
        $details.error = $errorMessage; $details.ErrorRecord = $_.ToString()
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: $errorMessage"
        # CheckSuccess остается $null
    }

    # --- 3. Проверка критериев успеха (вызов универсальной функции) ---
    $failReason = $null
    if ($isAvailable -eq $true) { # Проверяем критерии только если Get-Service успешен
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.PSObject.Properties.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Вызов Test-SuccessCriteria..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason
            if ($checkSuccess -ne $true) { # Если $false или $null (ошибка критерия)
                $errorMessage = $failReason | Get-OrElse "Критерии успеха не пройдены."
                Write-Verbose "[$NodeName] Check-SERVICE_STATUS: SuccessCriteria НЕ пройдены/ошибка: $errorMessage"
            } else {
                 Write-Verbose "[$NodeName] Check-SERVICE_STATUS: SuccessCriteria пройдены."
                 # Если критерии пройдены, убедимся, что сообщение об ошибке пустое
                 $errorMessage = $null
            }
        } else {
            # Критерии не заданы
            $checkSuccess = $true
            $errorMessage = $null
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        # Get-Service не удался ($isAvailable = $false) -> CheckSuccess остается $null
        $checkSuccess = $null
        # $errorMessage уже установлен в блоках catch выше
        if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = "Ошибка проверки статуса службы (IsAvailable=false)." }
    }

    # --- 4. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

# <<< Закрываем основной try >>>
} catch {
    # --- Обработка КРИТИЧЕСКИХ ошибок (например, валидация параметра) ---
    $isAvailable = $false; $checkSuccess = $null
    $critErrorMessage = "Критическая ошибка Check-SERVICE_STATUS: $($_.Exception.Message)"
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString() }
    if ($details.service_name) { $detailsError.service_name = $details.service_name }
    $finalResult = @{ IsAvailable=$isAvailable; CheckSuccess=$checkSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$detailsError; ErrorMessage=$critErrorMessage }
    Write-Error "[$NodeName] Check-SERVICE_STATUS: Критическая ошибка: $critErrorMessage"
} # <<< Закрываем основной catch >>>

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-SERVICE_STATUS (v2.0.1): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult