<#
.SYNOPSIS
    Проверяет статус указанной системной службы.
.DESCRIPTION
    Обращается к службе локально или на удаленном узле, используя Get-Service для получения
    текущего статуса. Сравнивает статус с ожидаемым в SuccessCriteria.
    Возвращает стандартизированный объект результата проверки.
.PARAMETER TargetIP
    [string] IP или имя хоста для проверки (игнорируется локально).
    Используется диспетчером для потенциального удаленного вызова.
.PARAMETER Parameters
    [hashtable] Обязательный. Должен содержать ключ 'service_name'.
    Пример: @{ service_name = "Spooler" }
.PARAMETER SuccessCriteria
    [hashtable] Необязательный. Может содержать ключ 'status'.
    Пример: @{ status = "Running" } (ожидаемый статус, по умолчанию 'Running').
            @{ status = "Stopped" } (ожидаемый статус 'Stopped').
.PARAMETER NodeName
    [string] Необязательный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP, # Реально используется только диспетчером для Invoke-Command

    [Parameter(Mandatory=$true)]
    [hashtable]$Parameters,

    [Parameter(Mandatory=$false)]
    [hashtable]$SuccessCriteria = $null,

    [Parameter(Mandatory=$false)]
    [string]$NodeName = "Unknown Node" # Для логов
)

# Убеждаемся, что функция New-CheckResultObject доступна
# (Обычно она в .psm1, но для автономного тестирования может понадобиться загрузка)
if (-not (Get-Command New-CheckResultObject -ErrorAction SilentlyContinue)) {
    try {
        $commonFunctionsPath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils.psm1" # Путь к основному модулю
        if(Test-Path $commonFunctionsPath) {
            Write-Verbose "Check-SERVICE_STATUS: Загрузка функций из $commonFunctionsPath"
             # Используем dot-sourcing для загрузки функций в текущую область видимости
            . $commonFunctionsPath
        } else { throw "Не найден файл общего модуля: $commonFunctionsPath" }
    } catch {
        Write-Error "Check-SERVICE_STATUS: Критическая ошибка: Не удалось загрузить New-CheckResultObject! $($_.Exception.Message)"
        # Создаем заглушку, чтобы скрипт не упал полностью
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}

# --- Инициализация результата ---
$resultData = @{ # Стандартная структура для возврата
    IsAvailable = $false
    CheckSuccess = $null
    Details = $null
    ErrorMessage = $null
}

Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Начало проверки для $TargetIP"

try {
    # 1. Валидация обязательных параметров
    $serviceName = $Parameters.service_name
    if (-not $serviceName -or $serviceName -isnot [string] -or $serviceName.Trim() -eq '') {
        throw "Параметр 'service_name' отсутствует или пуст в Parameters."
    }
    $serviceName = $serviceName.Trim()
    Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Проверяемая служба '$serviceName'"

    # 2. Определение цели (локально или удаленно) - для Get-Service
    # В модели StatusMonitor агент выполняет проверку сам, поэтому ComputerName обычно не нужен.
    # Get-Service всегда выполняется локально в контексте агента.
    # TargetIP используется для логирования и диспетчером для выбора контекста.
    $ComputerNameParam = $null
    # if ($TargetIP -ne $env:COMPUTERNAME -and $TargetIP -ne 'localhost' -and $TargetIP -ne '127.0.0.1') {
    #     $ComputerNameParam = $TargetIP
    #     Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Цель удаленная: $ComputerNameParam"
    # } else {
         Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Цель локальная."
    # }

    # 3. Выполнение Get-Service
    $service = $null
    $getServiceParams = @{ Name = $serviceName; ErrorAction = 'Stop' } # Stop, чтобы поймать ошибку, если службы нет
    # if ($ComputerNameParam) { $getServiceParams.ComputerName = $ComputerNameParam } # Не добавляем ComputerName

    try { # Внутренний try/catch для Get-Service
        $service = Get-Service @getServiceParams
        # --- УСПЕШНО ПОЛУЧИЛИ СЛУЖБУ ---
        $resultData.IsAvailable = $true # Смогли выполнить проверку
        $currentStatus = $service.Status.ToString()
        Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Служба '$serviceName' найдена. Статус: $currentStatus"

        # Заполняем Details
        $resultData.Details = @{
            service_name = $serviceName
            status = $currentStatus
            display_name = $service.DisplayName
            start_type = $service.StartType.ToString()
            can_stop = $service.CanStop
            # Можно добавить другие свойства службы при необходимости
        }

        # 4. Проверка SuccessCriteria (CheckSuccess)
        $requiredStatus = 'Running' # Значение по умолчанию
        $criteriaSource = 'Default'
        $checkSuccessResult = $true # По умолчанию успешно, если доступно и нет критериев или критерии прошли
        $failReason = $null

        if ($SuccessCriteria -ne $null -and $SuccessCriteria.ContainsKey('status') -and -not [string]::IsNullOrWhiteSpace($SuccessCriteria.status)) {
            # --- >>> НАЧАЛО ОБРАБОТКИ КРИТЕРИЯ <<< ---
            $requiredStatus = $SuccessCriteria.status.ToString().Trim() # Приводим к строке и убираем пробелы
            $criteriaSource = 'Explicit'
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Применяется явный критерий: status = '$requiredStatus'"

            # Сравниваем текущий статус с требуемым (без учета регистра)
            if ($currentStatus -ne $requiredStatus) {
                $checkSuccessResult = $false # Критерий не пройден
                $failReason = "Текущий статус службы '$currentStatus' не соответствует требуемому '$requiredStatus'."
                Write-Verbose "[$NodeName] Check-SERVICE_STATUS: $failReason"
            } else {
                $checkSuccessResult = $true # Критерий пройден
                Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Статус '$currentStatus' соответствует критерию '$requiredStatus'."
            }
             # --- >>> КОНЕЦ ОБРАБОТКИ КРИТЕРИЯ <<< ---
        } else {
            # Критерии не заданы явно, используем стандартную логику (Running = OK)
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Явный критерий 'status' не задан. Считаем успешным, если статус '$requiredStatus' (по умолчанию)."
            if ($currentStatus -ne $requiredStatus) {
                 # Статус не соответствует дефолтному Running, но т.к. критерий не задан ЯВНО,
                 # считаем это успехом самой *проверки*, но не критерия.
                 # CheckSuccess должен отражать соответствие КРИТЕРИЯМ.
                 # Если критериев нет, CheckSuccess должен быть TRUE при IsAvailable = TRUE.
                 # Если критерий есть, но не пройден -> CheckSuccess = FALSE.
                 # $checkSuccessResult = $false # Неправильно, т.к. критерия не было
                 $checkSuccessResult = $true # Правильно, т.к. критерия не было
                 # $failReason = "Статус службы '$currentStatus', ожидался '$requiredStatus' (по умолчанию)." # Это сообщение не нужно в ErrorMessage, т.к. CheckSuccess=true
                 # Write-Verbose "[$NodeName] Check-SERVICE_STATUS: $failReason" # Этот Verbose тоже лишний
            } else {
                $checkSuccessResult = $true
            }
        }
        # Устанавливаем $resultData.CheckSuccess и $resultData.ErrorMessage
        $resultData.CheckSuccess = $checkSuccessResult
        # ErrorMessage заполняем ТОЛЬКО если CheckSuccess = false ИЛИ IsAvailable = false
        if ($checkSuccessResult -eq $false) {
             $resultData.ErrorMessage = $failReason
        }

    } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
        # --- ОШИБКА: Служба не найдена ---
        $resultData.IsAvailable = $false # Не смогли выполнить проверку, т.к. службы нет
        $resultData.CheckSuccess = $null
        $resultData.ErrorMessage = "Служба '$serviceName' не найдена на '$($env:COMPUTERNAME)'."
        $resultData.Details = @{ error = $resultData.ErrorMessage; service_name = $serviceName }
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: $($resultData.ErrorMessage)"
    } catch {
        # --- ОШИБКА: Другая ошибка Get-Service (RPC недоступен и т.п., хотя мы делаем локально) ---
        $resultData.IsAvailable = $false # Не смогли выполнить проверку
        $resultData.CheckSuccess = $null
        $errorMessage = "Ошибка получения статуса службы '$serviceName' на '$($env:COMPUTERNAME)': $($_.Exception.Message)"
        # Обрезаем слишком длинное сообщение
        if ($errorMessage.Length -gt 500) { $errorMessage = $errorMessage.Substring(0, 500) + "..." }
        $resultData.ErrorMessage = $errorMessage
        $resultData.Details = @{ error = $errorMessage; service_name = $serviceName; ErrorRecord = $_.ToString() }
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: Ошибка Get-Service: $($_.Exception.Message)"
    }

} catch {
    # --- ОШИБКА: Общая ошибка скрипта Check-SERVICE_STATUS (например, валидация параметров) ---
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $errorMessage = "Внутренняя ошибка скрипта Check-SERVICE_STATUS: $($_.Exception.Message)"
    if ($errorMessage.Length -gt 500) { $errorMessage = $errorMessage.Substring(0, 500) + "..." }
    $resultData.ErrorMessage = $errorMessage
    $resultData.Details = @{ error = $errorMessage; ErrorRecord = $_.ToString() }
    Write-Error "[$NodeName] Check-SERVICE_STATUS: Критическая ошибка скрипта: $($_.Exception.Message)"
}

# Вызываем New-CheckResultObject для стандартизации и добавления Timestamp
# Передаем рассчитанные значения
$finalResult = New-CheckResultObject -IsAvailable $resultData.IsAvailable `
                                     -CheckSuccess $resultData.CheckSuccess `
                                     -Details $resultData.Details `
                                     -ErrorMessage $resultData.ErrorMessage

Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Завершение проверки. IsAvailable=$($finalResult.IsAvailable), CheckSuccess=$($finalResult.CheckSuccess)"
return $finalResult