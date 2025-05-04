# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SERVICE_STATUS.ps1
# --- Версия 2.0 ---
# Изменения:
# - Логика проверки SuccessCriteria вынесена в универсальную функцию Test-SuccessCriteria.
# - Стандартизирован формат $Details.
# - Убран прямой расчет CheckSuccess на основе сравнения статуса.
# - Добавлен вызов Test-SuccessCriteria.

<#
.SYNOPSIS
    Проверяет статус указанной системной службы. (v2.0)
.DESCRIPTION
    Обращается к службе локально с помощью Get-Service для получения
    текущего статуса и другой информации.
    Формирует стандартизированный объект $Details с данными службы.
    Для определения итогового CheckSuccess использует универсальную функцию
    Test-SuccessCriteria, сравнивающую $Details с переданным $SuccessCriteria.
    Ожидаемый формат SuccessCriteria для проверки статуса:
    @{ status = 'Running' } или @{ status = @{ '!=' = 'Stopped' } }
.PARAMETER TargetIP
    [string] Обязательный. IP или имя хоста. Используется для логирования,
             скрипт выполняется локально.
.PARAMETER Parameters
    [hashtable] Обязательный. Должен содержать ключ 'service_name'.
    Пример: @{ service_name = "Spooler" }
.PARAMETER SuccessCriteria
    [hashtable] Необязательный. Критерии успеха для сравнения с полями в $Details.
                Пример: @{ status = "Running"; start_type = "Automatic" }
                Обрабатывается функцией Test-SuccessCriteria.
.PARAMETER NodeName
    [string] Необязательный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
                Поле Details (hashtable) содержит (при успехе):
                - service_name (string): Имя службы.
                - status (string): Текущий статус ('Running', 'Stopped', ...).
                - display_name (string): Отображаемое имя.
                - start_type (string): Тип запуска ('Automatic', 'Manual', ...).
                - can_stop (bool): Может ли быть остановлена.
                А также (при ошибке):
                - error (string): Сообщение об ошибке.
                - ErrorRecord (string): Полный текст исключения.
.NOTES
    Версия: 2.0.1 (Добавлены комментарии, форматирование, улучшена обработка ошибок).
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIP, # Используется для логирования

    [Parameter(Mandatory = $true)]
    [hashtable]$Parameters,

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
# Details инициализируем базовыми данными, которые точно известны
$details = @{
    service_name = $null # Будет установлен из параметров
    # Остальные поля (status, display_name и т.д.) добавим после Get-Service
}

Write-Verbose "[$NodeName] Check-SERVICE_STATUS (v2.0.1): Начало проверки для $TargetIP (локально)"

# --- Основной блок Try/Catch ---
try {
    # --- 1. Валидация обязательных параметров ---
    $serviceName = $Parameters.service_name
    if (-not $serviceName -or $serviceName -isnot [string] -or $serviceName.Trim() -eq '') {
        throw "Параметр 'service_name' отсутствует или пуст в Parameters."
    }
    $serviceName = $serviceName.Trim()
    $details.service_name = $serviceName # Записываем имя службы в Details
    Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Проверяемая служба '$serviceName'"

    # --- 2. Выполнение Get-Service ---
    # Выполняем всегда локально в контексте агента
    $service = $null
    # Используем внутренний try/catch для отлова ошибки "служба не найдена"
    try {
        Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Вызов Get-Service -Name '$serviceName'..."
        # ErrorAction Stop, чтобы ошибка попала в catch
        $service = Get-Service -Name $serviceName -ErrorAction Stop

        # --- УСПЕШНО ПОЛУЧИЛИ СЛУЖБУ ---
        $isAvailable = $true # Сама проверка удалась
        $currentStatus = $service.Status.ToString()
        Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Служба '$serviceName' найдена. Статус: $currentStatus"

        # Заполняем $Details информацией о службе
        $details.status = $currentStatus
        $details.display_name = $service.DisplayName
        $details.start_type = $service.StartType.ToString()
        $details.can_stop = $service.CanStop
        # Добавьте другие нужные свойства $service в $Details, если требуется

        # <<< ЛОГИКА ПРОВЕРКИ КРИТЕРИЕВ УБРАНА ОТСЮДА >>>

    # Ловим конкретную ошибку "служба не найдена"
    } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
        # --- ОШИБКА: Служба не найдена ---
        $isAvailable = $false # Не смогли выполнить проверку
        $errorMessage = "Служба '$serviceName' не найдена на '$($env:COMPUTERNAME)'."
        # Добавляем ошибку в Details
        $details.error = $errorMessage
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: $errorMessage"
        # CheckSuccess остается $null

    # Ловим другие ошибки Get-Service (маловероятно при локальном вызове, но возможно)
    } catch {
        # --- ОШИБКА: Другая ошибка Get-Service ---
        $isAvailable = $false # Не смогли выполнить проверку
        $exceptionMessage = $_.Exception.Message
        if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
        $errorMessage = "Ошибка Get-Service для '$serviceName': $exceptionMessage"
        $details.error = $errorMessage
        $details.ErrorRecord = $_.ToString()
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: $errorMessage"
        # CheckSuccess остается $null
    }

    # --- 3. Вызов универсальной функции проверки критериев ---
    $failReason = $null

    # Проверяем критерии только если сама проверка удалась ($isAvailable = true)
    if ($isAvailable) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: Вызов Test-SuccessCriteria..."
            # Передаем $Details (со status, start_type и т.д.) и $SuccessCriteria
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason

            if ($checkSuccess -eq $null) {
                # Ошибка в самих критериях
                $errorMessage = "Ошибка при обработке SuccessCriteria: $failReason"
                Write-Warning "[$NodeName] $errorMessage"
            } elseif ($checkSuccess -eq $false) {
                # Критерии не пройдены
                $errorMessage = $failReason # Используем причину как сообщение
                Write-Verbose "[$NodeName] Check-SERVICE_STATUS: SuccessCriteria НЕ пройдены: $failReason"
            } else {
                # Критерии пройдены
                $errorMessage = $null # Ошибки нет
                Write-Verbose "[$NodeName] Check-SERVICE_STATUS: SuccessCriteria пройдены."
            }
        } else {
            # Критерии не заданы
            $checkSuccess = $true
            $errorMessage = $null
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        # Если IsAvailable = $false
        $checkSuccess = $null
        # $errorMessage уже был установлен в блоках catch выше
        if ([string]::IsNullOrEmpty($errorMessage)) {
            $errorMessage = "Ошибка выполнения проверки статуса службы (IsAvailable=false)."
        }
    }

    # --- 4. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

# <<< Закрываем основной try блок >>>
} catch {
    # --- Обработка КРИТИЧЕСКИХ ошибок скрипта ---
    # Например, ошибка валидации параметра service_name
    $isAvailable = $false
    $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $critErrorMessage = "Критическая ошибка скрипта Check-SERVICE_STATUS: {0}" -f $exceptionMessage

    # Формируем Details с ошибкой
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString() }
    # Добавляем имя службы, если успели его получить
    if ($details.service_name) { $detailsError.service_name = $details.service_name }

    # Создаем финальный результат ВРУЧНУЮ
    $finalResult = @{
        IsAvailable  = $isAvailable
        CheckSuccess = $checkSuccess
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        Details      = $detailsError
        ErrorMessage = $critErrorMessage
    }
    Write-Error "[$NodeName] Check-SERVICE_STATUS: Критическая ошибка: $critErrorMessage"
} # <<< Закрываем основной catch блок >>>

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-SERVICE_STATUS (v2.0.1): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult