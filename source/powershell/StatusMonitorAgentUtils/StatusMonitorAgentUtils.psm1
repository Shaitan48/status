# powershell/StatusMonitorAgentUtils/StatusMonitorAgentUtils.psm1
# Модуль содержит диспетчер проверок и общие вспомогательные функции
# для агентов мониторинга Status Monitor.
# Версия с исправленными ошибками парсинга в Invoke-RemoteCheck (через -f).

#region Вспомогательные функции

#region Функция New-CheckResultObject
<#
.SYNOPSIS
    Создает стандартизированный объект результата проверки.
# ... (остальная документация New-CheckResultObject без изменений) ...
#>
function New-CheckResultObject {
    param(
        [Parameter(Mandatory=$true)]
        [bool]$IsAvailable,
        [Parameter(Mandatory=$false)]
        [nullable[bool]]$CheckSuccess = $null,
        [Parameter(Mandatory=$false)]
        [hashtable]$Details = $null,
        [Parameter(Mandatory=$false)]
        [string]$ErrorMessage = $null
    )
    # ... (код функции New-CheckResultObject без изменений) ...
    # Создаем базовую структуру
    $result = @{
        IsAvailable    = $IsAvailable
        CheckSuccess   = $null # Инициализируем null
        # --- ИЗМЕНЕНИЕ: Сразу сохраняем строку ISO 8601 (UTC) ---
        Timestamp      = (Get-Date).ToUniversalTime().ToString("o")
        Details        = $Details
        ErrorMessage   = $ErrorMessage
    }
    if ($IsAvailable) { $result.CheckSuccess = $CheckSuccess }
    if (-not $IsAvailable -and -not $result.ErrorMessage) { $result.ErrorMessage = "..."}
    if ($IsAvailable -and ($result.CheckSuccess -ne $null) -and (-not $result.CheckSuccess) -and (-not $result.ErrorMessage) ) { $result.ErrorMessage = "..."}

    return $result
}
#endregion

#region Функция Invoke-RemoteCheck
<#
.SYNOPSIS
    Выполняет скрипт проверки на удаленном узле.
# ... (остальная документация Invoke-RemoteCheck без изменений) ...
#>
function Invoke-RemoteCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$TargetIP,

        [Parameter(Mandatory=$true)]
        [string]$CheckScriptPath,

        [Parameter(Mandatory=$true)]
        [hashtable]$checkParams,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential = $null
    )

    Write-Verbose "Вызов Invoke-RemoteCheck для $TargetIP, скрипт: $CheckScriptPath"

    try {
        # --- Начало Реализации Удаленного Вызова ---
        if (-not (Test-Path $CheckScriptPath -PathType Leaf)) {
            throw "Локальный скрипт проверки '$CheckScriptPath' не найден для удаленного выполнения."
        }
        $ScriptContent = Get-Content -Path $CheckScriptPath -Raw -Encoding UTF8
        $RemoteScriptBlock = [ScriptBlock]::Create($ScriptContent)
        $invokeParams = @{ ComputerName = $TargetIP; ScriptBlock  = $RemoteScriptBlock; ErrorAction  = 'Stop'; ArgumentList = @($checkParams) }
        if ($Credential) { $invokeParams.Credential = $Credential }

        Write-Verbose "Попытка Invoke-Command на $TargetIP..."
        $remoteResultRaw = Invoke-Command @invokeParams
        $remoteResult = $null
        if ($remoteResultRaw) { $remoteResult = $remoteResultRaw | Select-Object -Last 1 }

        if ($remoteResult -is [hashtable] -and $remoteResult.ContainsKey('IsAvailable')) {
            Write-Verbose "Invoke-Command на $TargetIP успешно вернул стандартизированный результат."
            if (-not $remoteResult.ContainsKey('Details') -or $remoteResult.Details -eq $null) { $remoteResult.Details = @{} }
            elseif ($remoteResult.Details -isnot [hashtable]) { $remoteResult.Details = @{ OriginalDetails = $remoteResult.Details } }
            $remoteResult.Details.execution_target = $TargetIP
            $remoteResult.Details.execution_mode = 'remote'
            return $remoteResult
        } else {
             Write-Warning ("Удаленный скрипт на {0} не вернул ожидаемую хэш-таблицу. Результат: {1}" -f $TargetIP, ($remoteResultRaw | Out-String -Width 200))
             return New-CheckResultObject -IsAvailable $false -ErrorMessage "Удаленный скрипт на $TargetIP вернул некорректный результат." -Details @{ RemoteOutput = ($remoteResultRaw | Out-String -Width 200) }
        }
        # --- Конец Реализации Удаленного Вызова ---

    } catch {
        # Ловим ошибки Invoke-Command
        # --- ИЗМЕНЕНО: Используем оператор -f ---
        $exceptionMessage = $_.Exception.Message
        Write-Warning ("Ошибка Invoke-Command при выполнении '{0}' на {1}: {2}" -f $CheckScriptPath, $TargetIP, $exceptionMessage)
        $errorMessage = "Ошибка удаленного выполнения на {0}: {1}" -f $TargetIP, $exceptionMessage

        $errorDetails = @{ ErrorRecord = $_.ToString(); ErrorCategory = $_.CategoryInfo.Category.ToString(); ErrorReason = $_.CategoryInfo.Reason; ErrorTarget = $_.TargetObject }

        if ($_.CategoryInfo.Category -in ('ResourceUnavailable', 'AuthenticationError', 'SecurityError', 'OpenError', 'ConnectionError')) {
             # --- ИЗМЕНЕНО: Используем оператор -f ---
             $errorMessage = "Ошибка подключения/доступа к {0}: {1}" -f $TargetIP, $exceptionMessage
        }
        # --- КОНЕЦ ИЗМЕНЕНИЙ В CATCH ---

        return New-CheckResultObject -IsAvailable $false -ErrorMessage $errorMessage -Details $errorDetails
    }
}
#endregion

#endregion

# --- Основная функция-диспетчер ---

<#
.SYNOPSIS
    Выполняет проверку мониторинга согласно заданию.
.DESCRIPTION
    Функция-диспетчер. Определяет метод проверки из задания,
    находит соответствующий скрипт в папке 'Checks', подготавливает
    параметры и ЗАПУСКАЕТ СКРИПТ ЛОКАЛЬНО на машине агента.
    Возвращает стандартизированный результат проверки.
.PARAMETER Assignment
    [PSCustomObject] Обязательный. Объект задания.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
#>
function Invoke-StatusMonitorCheck {
    [CmdletBinding(SupportsShouldProcess=$false)]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Assignment
    )

    # Проверка базовой валидности задания
    if (-not $Assignment -or -not $Assignment.PSObject.Properties.Name.Contains('assignment_id') -or -not $Assignment.PSObject.Properties.Name.Contains('method_name')) {
        Write-Warning "Invoke-StatusMonitorCheck: Передан некорректный объект задания."
        # Формируем результат ошибки вручную (т.к. New-CheckResultObject может быть еще не загружен или быть частью проблемы)
        return @{ IsAvailable = $false; CheckSuccess = $null; Timestamp = (Get-Date).ToUniversalTime().ToString("o"); ErrorMessage = "Некорректный объект задания передан в Invoke-StatusMonitorCheck."; Details = $null }
    }

    # Извлекаем основные данные из задания
    $assignmentId = $Assignment.assignment_id
    $methodName = $Assignment.method_name
    $targetIP = $null
    if ($Assignment.PSObject.Properties.Name.Contains('ip_address')) {
        $targetIP = $Assignment.ip_address
    }
    $nodeName = $Assignment.node_name | Get-OrElse "Узел ID $($Assignment.node_id | Get-OrElse $assignmentId)"
    $parameters = $Assignment.parameters | Get-OrElse @{}
    $successCriteria = $Assignment.success_criteria | Get-OrElse $null

    Write-Verbose "[$($assignmentId)] Запуск диспетчера Invoke-StatusMonitorCheck для метода '$methodName' на '$nodeName' (TargetIP: $($targetIP | Get-OrElse 'Local'))"

    # Определяем путь к скрипту проверки
    $result = $null # Инициализируем переменную для результата
    try {
        # Получаем путь к текущему модулю, чтобы найти папку Checks
        # $MyInvocation.MyCommand.ModuleName может быть надежнее $PSScriptRoot внутри модуля
        $ModulePath = (Get-Module -Name $MyInvocation.MyCommand.ModuleName).Path
        $ModuleDir = Split-Path -Path $ModulePath -Parent
        $ChecksFolder = Join-Path -Path $ModuleDir -ChildPath "Checks"
        $CheckScriptFile = "Check-$($methodName).ps1"
        $CheckScriptPath = Join-Path -Path $ChecksFolder -ChildPath $CheckScriptFile

        # Проверяем существование скрипта
        if (-not (Test-Path $CheckScriptPath -PathType Leaf)) {
            $errorMessage = "Скрипт проверки '$CheckScriptFile' не найден в '$ChecksFolder'."
            Write-Warning "[$($assignmentId)] $errorMessage"
            # Используем New-CheckResultObject, предполагая, что он уже загружен на этом этапе
            return New-CheckResultObject -IsAvailable $false -ErrorMessage $errorMessage -Details @{ CheckedScriptPath = $CheckScriptPath }
        }

        # Подготавливаем параметры для передачи в скрипт проверки
        $checkParams = @{
            TargetIP        = $targetIP # Передаем IP из задания
            Parameters      = $parameters
            SuccessCriteria = $successCriteria
            NodeName        = $nodeName
        }

        # === ИЗМЕНЕНИЕ: ВСЕГДА ВЫПОЛНЯЕМ ЛОКАЛЬНО ===
        Write-Verbose "[$($assignmentId)] Запуск ЛОКАЛЬНОГО скрипта: $CheckScriptPath"
        # Используем блок try/catch для отлова ошибок ВНУТРИ скрипта Check-*.ps1
        try {
             # Запускаем скрипт через оператор вызова '&', передавая параметры через splatting (@)
             $result = & $CheckScriptPath @checkParams
        } catch {
             # Ошибка произошла ВНУТРИ скрипта Check-*.ps1
             throw # Перебрасываем ошибку, чтобы ее поймал внешний catch
        }
        # === КОНЕЦ ИЗМЕНЕНИЯ ===

        # Проверяем, что скрипт вернул ожидаемый результат
        if ($result -isnot [hashtable] -or -not $result.ContainsKey('IsAvailable')) {
            Write-Warning "[$($assignmentId)] Скрипт проверки '$CheckScriptFile' вернул неожиданный результат: $($result | Out-String -Width 200)"
            $result = New-CheckResultObject -IsAvailable $false `
                                            -ErrorMessage "Скрипт проверки '$CheckScriptFile' вернул некорректный результат." `
                                            -Details @{ ScriptOutput = ($result | Out-String -Width 200) }
        }
        # Добавляем информацию о выполнении (всегда локальное для агента)
        if ($result -is [hashtable]) {
            if (-not $result.ContainsKey('Details') -or $result.Details -eq $null) { $result.Details = @{} }
            elseif ($result.Details -isnot [hashtable]) { $result.Details = @{ OriginalDetails = $result.Details } }
            # Указываем, что выполнялось на машине агента ($env:COMPUTERNAME)
            $result.Details.execution_target = $env:COMPUTERNAME
            $result.Details.execution_mode = 'local_agent' # Новый статус
            $result.Details.check_target_ip = $targetIP # Указываем реальную цель проверки
        }

    } catch {
        # Ловим ошибки:
        # - Не найден модуль $MyInvocation.MyCommand.ModuleName
        # - Ошибки, переброшенные из внутреннего try/catch (ошибки скрипта Check-*.ps1)
        # - Другие ошибки диспетчера
        $errorMessage = "Ошибка выполнения проверки '$methodName' для '$nodeName': $($_.Exception.Message)"
        Write-Warning "[$($assignmentId)] $errorMessage"
        # Используем ручное формирование, так как ошибка могла быть до New-CheckResultObject
        $result = @{
            IsAvailable    = $false
            CheckSuccess   = $null
            Timestamp      = (Get-Date).ToUniversalTime().ToString("o")
            ErrorMessage   = $errorMessage
            Details        = @{ ErrorRecord = $_.ToString() }
        }
    }

    # Возвращаем стандартизированный результат
    Write-Verbose "[$($assignmentId)] Диспетчер завершил работу. IsAvailable: $($result.IsAvailable), CheckSuccess: $($result.CheckSuccess)"
    return $result
}
# --- Конец основной функции ---

# Вспомогательные функции New-CheckResultObject, Invoke-RemoteCheck (можно пока оставить, но она не используется агентом), Get-OrElse
# ... (код этих функций без изменений) ...


# --- Вспомогательная функция Get-OrElse ---
filter Get-OrElse { param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }

# --- Экспорт функций ---
Export-ModuleMember -Function Invoke-StatusMonitorCheck, New-CheckResultObject # Убрали Invoke-RemoteCheck из экспорта по умолчанию
