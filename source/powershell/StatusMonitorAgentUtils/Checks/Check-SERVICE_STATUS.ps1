# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SERVICE_STATUS.ps1
# --- Версия 2.0.2 (или 2.1.0, если следовать общей нумерации) --- Исправлен параметр TargetIP
<#
.SYNOPSIS
    Проверяет статус указанной системной службы. (v2.0.2)
.DESCRIPTION
    Использует Get-Service.
    Формирует $Details с информацией о службе.
    Вызывает Test-SuccessCriteria для определения CheckSuccess.
.PARAMETER TargetIP
    [string] Опциональный. IP или имя хоста (для логирования и контекста). Get-Service выполняется локально.
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
    Версия: 2.0.2
    Зависит от New-CheckResultObject, Test-SuccessCriteria.
#>
param(
    [Parameter(Mandatory = $false)] # <--- ИЗМЕНЕНО: Сделан не обязательным
    [string]$TargetIP,             # Тип [string] по умолчанию допускает $null, если Mandatory=$false
    [Parameter(Mandatory = $false)] # Был Mandatory=$true, но service_name важнее, его проверяем ниже
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node (SERVICE_STATUS)"
)

# --- Инициализация ---
$isAvailable = $false
$checkSuccess = $null
$errorMessage = $null
$finalResult = $null
$details = @{ service_name = $null } # Базовые детали

$logTargetDisplay = if (-not [string]::IsNullOrWhiteSpace($TargetIP)) { $TargetIP } else { $env:COMPUTERNAME + " (локально)" }
Write-Verbose "[$NodeName] Check-SERVICE_STATUS (v2.0.2): Начало проверки службы. Цель (контекст): $logTargetDisplay"

# --- Основной Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>
    # 1. Валидация ОБЯЗАТЕЛЬНОГО параметра service_name из $Parameters
    if (-not $Parameters.ContainsKey('service_name') -or [string]::IsNullOrWhiteSpace($Parameters.service_name)) {
        throw "Параметр 'service_name' отсутствует, пуст или не указан в хэш-таблице Parameters."
    }
    $serviceName = $Parameters.service_name.Trim()
    $details.service_name = $serviceName
    Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Проверяемая служба '$serviceName'"

    # 2. Выполнение Get-Service (локально)
    # $TargetIP в Get-Service -ComputerName здесь не используется, т.к. проверка локальная.
    # Если бы была удаленная, то: $getServiceParams = @{ Name = $serviceName; ErrorAction = 'Stop' }
    # if ($TargetIP -and $TargetIP -ne $env:COMPUTERNAME) { $getServiceParams.ComputerName = $TargetIP }
    # $service = Get-Service @getServiceParams
    
    $service = $null
    try {
        Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Вызов Get-Service -Name '$serviceName'..."
        $service = Get-Service -Name $serviceName -ErrorAction Stop # Ошибка, если служба не найдена
        
        $isAvailable = $true # Если команда выполнилась без ошибки, проверка считается доступной
        $currentServiceStatus = $service.Status.ToString()
        Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Служба '$serviceName' найдена. Статус: $currentServiceStatus"
        
        # Заполняем $Details информацией о службе
        $details.status = $currentServiceStatus
        $details.display_name = $service.DisplayName
        $details.start_type = $service.StartType.ToString()
        $details.can_stop = $service.CanStop
        # Дополнительные полезные свойства (опционально)
        # $details.can_pause_and_continue = $service.CanPauseAndContinue
        # $details.dependent_services = @($service.DependentServices | ForEach-Object {$_.Name})
        # $details.services_depended_on = @($service.ServicesDependedOn | ForEach-Object {$_.Name})

    } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
        # ОШИБКА: Служба не найдена (это не ошибка доступности самой проверки, а результат)
        $isAvailable = $true # Сама проверка (попытка получить статус) была выполнена
        $checkSuccess = $false # Но результат - служба не найдена, что обычно провал, если критерий был на статус
        $errorMessage = "Служба '$serviceName' не найдена на хосте '$($env:COMPUTERNAME)'."
        $details.error = $errorMessage
        $details.status = "NotFound" # Добавляем специальный статус
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: $errorMessage"
        # Не прерываем выполнение, Test-SuccessCriteria может это учесть, если критерий был на отсутствие
    } catch {
        # ОШИБКА: Другая, более серьезная ошибка Get-Service (например, служба RPC недоступна)
        $isAvailable = $false # Сама проверка не удалась
        $errorMessage = "Ошибка при вызове Get-Service для '$serviceName': $($_.Exception.Message)"
        $details.error = $errorMessage
        $details.ErrorRecord = $_.ToString()
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: $errorMessage"
        # $checkSuccess остается $null, т.к. проверка не была полностью выполнена
        # Перебрасываем ошибку, чтобы она была поймана основным catch и корректно обработана как критическая для этой проверки
        throw 
    }

    # --- 3. Проверка критериев успеха ---
    if ($isAvailable -eq $true) { 
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Вызов Test-SuccessCriteria..."
            $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
            
            $checkSuccess = $criteriaProcessingResult.Passed 
            $failReasonFromCriteria = $criteriaProcessingResult.FailReason

            if ($checkSuccess -ne $true) { 
                if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) {
                    $errorMessage = $failReasonFromCriteria # Перезаписываем errorMessage, если он был от "NotFound"
                } else {
                    $errorMessage = "Критерии успеха для службы '$serviceName' не пройдены (CheckSuccess: $($checkSuccess | ForEach-Object {if ($_ -eq $null) { '[null]' } else { $_ }}))."
                }
                Write-Verbose "[$NodeName] Check-SERVICE_STATUS: SuccessCriteria НЕ пройдены или ошибка оценки. ErrorMessage: $errorMessage"
            } else {
                # Если критерии пройдены, но ранее была ошибка "NotFound", она должна остаться в ErrorMessage
                if ($details.status -ne "NotFound") {
                    $errorMessage = $null 
                }
                Write-Verbose "[$NodeName] Check-SERVICE_STATUS: SuccessCriteria пройдены."
            }
        } else {
            # Критерии не заданы. Если служба найдена (status не "NotFound"), то успех.
            if ($details.status -ne "NotFound") {
                $checkSuccess = $true
                $errorMessage = $null
            } else {
                # Если критериев нет, а служба не найдена, то это $checkSuccess = $false
                # $errorMessage уже содержит "Служба ... не найдена"
                # $checkSuccess уже был установлен в $false выше
            }
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: SuccessCriteria не заданы. CheckSuccess: $checkSuccess."
        }
    } else {
        # $isAvailable = $false (была критическая ошибка Get-Service)
        $checkSuccess = $null # Критерии не оценивались
        if ([string]::IsNullOrEmpty($errorMessage)) { 
            $errorMessage = "Ошибка проверки статуса службы '$serviceName' (IsAvailable=false), критерии не проверялись."
        }
    }

    # --- 4. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch { # <<< ОСНОВНОЙ CATCH для критических ошибок (например, валидация $Parameters или throw из блока Get-Service) >>>
    $isAvailable = $false 
    $checkSuccess = $null   
    
    $critErrorMessage = "Критическая ошибка в Check-SERVICE_STATUS для службы '$($Parameters.service_name | Get-OrElse "[неизвестно]")': $($_.Exception.Message)"
    Write-Error "[$NodeName] Check-SERVICE_STATUS: $critErrorMessage ScriptStackTrace: $($_.ScriptStackTrace)"
    
    if ($null -eq $details) { $details = @{} }
    if (-not $details.ContainsKey('service_name') -and $Parameters.ContainsKey('service_name')) { $details.service_name = $Parameters.service_name }
    $details.error = $critErrorMessage
    $details.ErrorRecord = $_.ToString()
    
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $critErrorMessage
} # <<< КОНЕЦ ОСНОВНОГО CATCH >>>

# --- Отладка перед возвратом ---
Write-Host "DEBUG (Check-SERVICE_STATUS): --- Начало отладки finalResult.Details ---" -ForegroundColor Green
if ($finalResult -and $finalResult.Details) {
    Write-Host "DEBUG (Check-SERVICE_STATUS): Тип finalResult.Details: $($finalResult.Details.GetType().FullName)" -ForegroundColor Green
    if ($finalResult.Details -is [hashtable]) {
        Write-Host "DEBUG (Check-SERVICE_STATUS): Ключи в finalResult.Details: $($finalResult.Details.Keys -join ', ')" -ForegroundColor Green
    }
    Write-Host "DEBUG (Check-SERVICE_STATUS): Полное содержимое finalResult.Details (JSON): $($finalResult.Details | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue)" -ForegroundColor DarkGreen
} elseif ($finalResult) {
    Write-Host "DEBUG (Check-SERVICE_STATUS): finalResult.Details является $null или отсутствует." -ForegroundColor Yellow
} else {
    Write-Host "DEBUG (Check-SERVICE_STATUS): finalResult сам по себе $null (ошибка до его формирования)." -ForegroundColor Red
}
Write-Host "DEBUG (Check-SERVICE_STATUS): --- Конец отладки finalResult.Details ---" -ForegroundColor Green

# --- Возврат результата ---
$isAvailableStrForLog = if ($finalResult) { $finalResult.IsAvailable } else { '[finalResult is null]' }
$checkSuccessStrForLog = if ($finalResult) { if ($null -eq $finalResult.CheckSuccess) {'[null]'} else {$finalResult.CheckSuccess} } else { '[finalResult is null]' }
Write-Verbose "[$NodeName] Check-SERVICE_STATUS (v2.0.2): Завершение. IsAvailable=$isAvailableStrForLog, CheckSuccess=$checkSuccessStrForLog"

return $finalResult