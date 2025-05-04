# F:\status\source\powershell\StatusMonitorAgentUtils\tests\Check-PING.Tests.ps1
# --- Версия 2.0 ---
# Тесты для Check-PING.ps1 v2.0 с мокированием Test-SuccessCriteria

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

# --- Определяем New-CheckResultObject Inline (можно вынести в общий файл) ---
# Версия 1.3 (без авто-сообщения для CheckSuccess=false)
function New-CheckResultObject {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][bool]$IsAvailable, [Parameter(Mandatory=$false)][nullable[bool]]$CheckSuccess=$null, [Parameter(Mandatory=$false)][hashtable]$Details=$null, [Parameter(Mandatory=$false)][string]$ErrorMessage=$null)
    $result = [ordered]@{ IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage }
    if ($result.IsAvailable) { if ($result.CheckSuccess -eq $null) { $result.CheckSuccess = $true } }
    else { $result.CheckSuccess = $null }
    if ([string]::IsNullOrEmpty($result.ErrorMessage)) { if (-not $result.IsAvailable) { $result.ErrorMessage = "Ошибка выполнения проверки (IsAvailable=false)." } }
    return $result
}
Write-Host "INFO: Inline New-CheckResultObject v1.3 defined..." -ForegroundColor Yellow

# --- Настройка перед тестами ---
Describe 'Check-PING.ps1 (v2.0)' {

    $script:scriptPath = $null
    BeforeAll {
        # Получаем путь к скрипту проверки
        try {
            $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-PING.ps1') -EA Stop
            Write-Host "INFO: Script path: $($script:scriptPath)" -FC Cyan
        } catch {
            Write-Error "FATAL: Cannot resolve script path. Error: $($_.Exception.Message)"; throw "..."
        }
        # Убедимся, что сам модуль Utils загружен (для доступа к Test-SuccessCriteria, которую будем мокать)
        try {
            Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop
        } catch {
            Write-Error "FATAL: Failed to import StatusMonitorAgentUtils module for mocking its functions."; throw "..."
        }
    }

    # --- Базовый объект задания ---
    $baseAssignment = @{
        assignment_id = 200 # Базовый ID
        method_name = 'PING'
        node_name = 'TestNode-PING'
        ip_address = '192.168.1.1' # Используется в моках
        parameters = @{}
        success_criteria = $null
    }

    # --- Общие моки ---
    BeforeEach {
        # Мокируем New-CheckResultObject, чтобы проверять параметры вызова
        # ВАЖНО: Мок должен быть определен для модуля, где находится тестируемая функция!
        # Но так как Check-PING.ps1 НЕ входит в модуль, мы мокируем её ГЛОБАЛЬНО
        # или предполагаем, что Check-PING будет её вызывать из импортированного модуля.
        # Правильнее мокать для модуля Utils.
        Mock New-CheckResultObject {
            param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage)
            # Возвращаем объект с маркером, чтобы тесты видели, что мок сработал
            return @{ MockedNewCheckResult = $true; IsAvailable = $IsAvailable; CheckSuccess = $CheckSuccess; Details = $Details; ErrorMessage = $ErrorMessage }
        } -ModuleName StatusMonitorAgentUtils # Мокируем функцию из модуля

        # Мокируем Test-SuccessCriteria, по умолчанию возвращает успех
        Mock Test-SuccessCriteria {
            param($DetailsObject, $CriteriaObject)
            Write-Verbose "Mock Test-SuccessCriteria: CriteriaObject received: $($CriteriaObject | ConvertTo-Json -Depth 1 -Compress)"
            # По умолчанию считаем, что критерии пройдены
            return @{ Passed = $true; FailReason = $null }
        } -ModuleName StatusMonitorAgentUtils # Мокируем функцию из модуля
    }

    # --- Контексты и тесты ---

    Context 'Успешный Пинг (StatusCode=0)' {
        BeforeEach {
            # Мок Test-Connection для успешного пинга
            $mockSuccessResultObject = [PSCustomObject]@{
                ResponseTime = 15; Latency = 15 # RTT
                IPV4Address  = [System.Net.IPAddress]::Parse('192.168.1.1')
                Address      = '192.168.1.1'
                StatusCode   = 0
            }
            Mock Test-Connection { return ,$using:mockSuccessResultObject } -ModuleName Microsoft.PowerShell.Management
        }

        It 'Должен вернуть IsAvailable=true, CheckSuccess=true без критериев' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            # $assignment.success_criteria = $null # Уже null по умолчанию

            # --- Act ---
            $result = & $script:scriptPath -TargetIP $assignment.ip_address `
                                          -Parameters $assignment.parameters `
                                          -SuccessCriteria $assignment.success_criteria `
                                          -NodeName $assignment.node_name

            # --- Assert ---
            # 1. Проверяем вызов New-CheckResultObject
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName StatusMonitorAgentUtils -ParameterFilter {
                $IsAvailable -eq $true -and
                $CheckSuccess -eq $true -and # Ожидаем $true, т.к. IsAvailable и нет критериев
                ($Details -is [hashtable] -and $Details.ContainsKey('rtt_ms') -and $Details.rtt_ms -eq 15) -and
                [string]::IsNullOrEmpty($ErrorMessage)
            }
            # 2. Проверяем, что Test-SuccessCriteria НЕ вызывался
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName StatusMonitorAgentUtils
        }

        It 'Должен вернуть CheckSuccess=true, если критерии пройдены (Test-SuccessCriteria mock = true)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ rtt_ms = @{ '<=' = 100 } } # Задаем критерий

            # Мокируем Test-SuccessCriteria, чтобы он вернул УСПЕХ
            Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName StatusMonitorAgentUtils -Scope It

            # --- Act ---
            $result = & $script:scriptPath -TargetIP $assignment.ip_address `
                                          -Parameters $assignment.parameters `
                                          -SuccessCriteria $assignment.success_criteria `
                                          -NodeName $assignment.node_name

            # --- Assert ---
            # 1. Проверяем вызов Test-SuccessCriteria (должен был быть вызван)
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName StatusMonitorAgentUtils -ParameterFilter {
                 ($DetailsObject -is [hashtable] -and $DetailsObject.rtt_ms -eq 15) -and
                 ($CriteriaObject -is [hashtable] -and $CriteriaObject.rtt_ms -is [hashtable] -and $CriteriaObject.rtt_ms.'<=' -eq 100)
            }
            # 2. Проверяем вызов New-CheckResultObject
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName StatusMonitorAgentUtils -ParameterFilter {
                $IsAvailable -eq $true -and
                $CheckSuccess -eq $true -and # Ожидаем $true, т.к. Test-SuccessCriteria вернул $true
                ($Details.rtt_ms -eq 15) -and
                [string]::IsNullOrEmpty($ErrorMessage)
            }
        }

        It 'Должен вернуть CheckSuccess=false, если критерии НЕ пройдены (Test-SuccessCriteria mock = false)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ rtt_ms = @{ '<=' = 10 } } # Критерий, который не пройдет
            $failReasonMock = "RTT 15ms больше чем порог 10ms"

            # Мокируем Test-SuccessCriteria, чтобы он вернул НЕУСПЕХ
            Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName StatusMonitorAgentUtils -Scope It

            # --- Act ---
            $result = & $script:scriptPath -TargetIP $assignment.ip_address `
                                          -Parameters $assignment.parameters `
                                          -SuccessCriteria $assignment.success_criteria `
                                          -NodeName $assignment.node_name

            # --- Assert ---
            # 1. Проверяем вызов Test-SuccessCriteria
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName StatusMonitorAgentUtils # Проверка параметров не обязательна, т.к. выше проверяли

            # 2. Проверяем вызов New-CheckResultObject
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName StatusMonitorAgentUtils -ParameterFilter {
                $IsAvailable -eq $true -and
                $CheckSuccess -eq $false -and # Ожидаем $false, т.к. Test-SuccessCriteria вернул $false
                ($Details.rtt_ms -eq 15) -and
                $ErrorMessage -eq $using:failReasonMock # Ожидаем причину провала
            }
        }

         It 'Должен вернуть CheckSuccess=$null и ErrorMessage, если Test-SuccessCriteria вернул ошибку (Passed=$null)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ rtt_ms = @{ '<=' = "not a number" } } # Некорректный критерий
            $failReasonMock = "Ошибка сравнения: не число"

            # Мокируем Test-SuccessCriteria, чтобы он вернул ОШИБКУ КРИТЕРИЯ
            Mock Test-SuccessCriteria { return @{ Passed = $null; FailReason = $using:failReasonMock } } -ModuleName StatusMonitorAgentUtils -Scope It

            # --- Act ---
            $result = & $script:scriptPath -TargetIP $assignment.ip_address `
                                          -Parameters $assignment.parameters `
                                          -SuccessCriteria $assignment.success_criteria `
                                          -NodeName $assignment.node_name

            # --- Assert ---
            # 1. Проверяем вызов Test-SuccessCriteria
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName StatusMonitorAgentUtils

            # 2. Проверяем вызов New-CheckResultObject
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName StatusMonitorAgentUtils -ParameterFilter {
                $IsAvailable -eq $true -and
                $CheckSuccess -eq $null -and # Ожидаем $null, т.к. Test-SuccessCriteria вернул $null
                ($Details.rtt_ms -eq 15) -and
                $ErrorMessage -eq $using:failReasonMock # Ожидаем причину ошибки критерия
            }
        }

    } # Конец Context 'Успешный Пинг'

    Context 'Неуспешный Пинг (ошибка StatusCode или нет ответа)' {
        BeforeEach {
            # Мок Test-Connection для ошибки "TimedOut"
             $mockFailureResultObject = [PSCustomObject]@{ StatusCode = 11010; Status = 'TimedOut' }
             Mock Test-Connection { return ,$using:mockFailureResultObject } -ModuleName Microsoft.PowerShell.Management
        }

        It 'Должен вернуть IsAvailable=false, CheckSuccess=$null и не вызывать Test-SuccessCriteria' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ rtt_ms = @{ '<=' = 100 } } # Критерии есть, но не должны проверяться

            # --- Act ---
            $result = & $script:scriptPath -TargetIP $assignment.ip_address `
                                          -Parameters $assignment.parameters `
                                          -SuccessCriteria $assignment.success_criteria `
                                          -NodeName $assignment.node_name

            # --- Assert ---
            # 1. Проверяем, что Test-SuccessCriteria НЕ вызывался
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName StatusMonitorAgentUtils

            # 2. Проверяем вызов New-CheckResultObject
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName StatusMonitorAgentUtils -ParameterFilter {
                $IsAvailable -eq $false -and
                $CheckSuccess -eq $null -and # CheckSuccess должен быть $null при IsAvailable=false
                ($Details -is [hashtable] -and $Details.ContainsKey('error')) -and
                $ErrorMessage -match 'StatusCode=11010' # Сообщение об ошибке пинга
            }
        }
    } # Конец Context 'Неуспешный Пинг'

    Context 'Критическая ошибка выполнения Test-Connection' {
         BeforeEach {
             # Мок Test-Connection, который выбрасывает исключение
             Mock Test-Connection { throw "Сбой RPC сервера (Mock Critical Error)." } -ModuleName Microsoft.PowerShell.Management
         }

         It 'Должен вернуть IsAvailable=false, CheckSuccess=$null и не вызывать Test-SuccessCriteria' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            # Критерии не важны

            # --- Act ---
            $result = & $script:scriptPath -TargetIP $assignment.ip_address `
                                          -Parameters $assignment.parameters `
                                          -SuccessCriteria $assignment.success_criteria `
                                          -NodeName $assignment.node_name

            # --- Assert ---
            # 1. Проверяем, что Test-SuccessCriteria НЕ вызывался
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName StatusMonitorAgentUtils

            # 2. Проверяем вызов New-CheckResultObject (он не должен вызываться, т.к. ошибка в catch)
            #    Вместо этого проверяем итоговый $result, сформированный в catch блоке
            # Should -Invoke New-CheckResultObject -Times 0 # НЕПРАВИЛЬНО, он будет вызван в конце

            # Проверяем сам результат
            $result | Should -Not -BeNull
            $result.MockedNewCheckResult | Should -BeNullOr ($result.ContainsKey('MockedNewCheckResult') -eq $false) # Убедимся, что это НЕ мок New-CheckResultObject
            $result.IsAvailable | Should -BeFalse
            $result.CheckSuccess | Should -BeNull
            $result.ErrorMessage | Should -Match 'Критическая ошибка'
            $result.ErrorMessage | Should -Match 'Сбой RPC сервера'
            $result.Details | Should -Not -BeNull
            $result.Details.error | Should -Match 'Критическая ошибка'
            $result.Details.ErrorRecord | Should -Not -BeNullOrEmpty
        }
    } # Конец Context 'Критическая ошибка'

} # Конец Describe
# --- Конец тестов ---