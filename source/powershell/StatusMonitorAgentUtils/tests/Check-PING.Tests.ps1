# Check-PING.Tests.ps1 (v2.1 - Тесты для Check-PING v2.3.1 с моками)
# --- Версия 2.1 ---
# Изменения:
# - Мокируем System.Net.NetworkInformation.Ping и его метод Send.
# - Мокируем Test-SuccessCriteria для изоляции логики проверки критериев.
# - Добавлены тесты для проверки передачи правильных данных в Test-SuccessCriteria.
# - Добавлены тесты для проверки обработки разных статусов ответа .NET Ping.

# Требуется Pester v5+
# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

# Определяем New-CheckResultObject локально (v1.3), т.к. будем мокать его в Utils
function New-CheckResultObject {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][bool]$IsAvailable, [Parameter(Mandatory=$false)][nullable[bool]]$CheckSuccess=$null, [Parameter(Mandatory=$false)][hashtable]$Details=$null, [Parameter(Mandatory=$false)][string]$ErrorMessage=$null)
    $result = [ordered]@{ IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage }; if ($result.IsAvailable) { if ($result.CheckSuccess -eq $null) { $result.CheckSuccess = $true } } else { $result.CheckSuccess = $null }; if ([string]::IsNullOrEmpty($result.ErrorMessage)) { if (-not $result.IsAvailable) { $result.ErrorMessage = "Ошибка выполнения проверки (IsAvailable=false)." } }; return $result
}

# --- Настройка перед тестами ---
Describe 'Check-PING.ps1 (v2.3.1 - .NET Ping)' {

    $script:scriptPath = $null # Путь к тестируемому скрипту
    $script:utilsModuleName = 'StatusMonitorAgentUtils' # Имя модуля для моков

    BeforeAll {
        # Получаем путь к скрипту
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-PING.ps1') -EA Stop
        Write-Host "INFO: Тестируемый скрипт: $($script:scriptPath)" -FC Cyan
        # Загружаем модуль Utils, чтобы мокать его функции
        try { Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop } catch { throw "Не удалось загрузить модуль $($script:utilsModuleName)" }
    }

    # --- Базовый объект задания ---
    $baseAssignment = @{ method_name = 'PING'; node_name = 'TestNode-PING'; ip_address = '8.8.8.8'; parameters = @{}; success_criteria = $null }

    # --- Общие моки ---
    BeforeEach {
        # --- Мок для New-CheckResultObject ---
        # Мокируем функцию из НАШЕГО модуля Utils
        Mock New-CheckResultObject {
            param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage)
            # Возвращаем объект с маркером, чтобы тесты видели, что мок сработал
            # и могли проверить переданные параметры
            return @{ Mocked = $true; M_IsAvailable = $IsAvailable; M_CheckSuccess = $CheckSuccess; M_Details = $Details; M_ErrorMessage = $ErrorMessage }
        } -ModuleName $script:utilsModuleName

        # --- Мок для Test-SuccessCriteria ---
        # По умолчанию считаем, что критерии пройдены
        Mock Test-SuccessCriteria {
            param($DetailsObject, $CriteriaObject)
            Write-Verbose "Mock Test-SuccessCriteria: CriteriaObject = $($CriteriaObject | ConvertTo-Json -Depth 1 -Compress)"
            return @{ Passed = $true; FailReason = $null }
        } -ModuleName $script:utilsModuleName

        # --- Мок для System.Net.NetworkInformation.Ping ---
        # Мокируем конструктор и метод Send
        # ПРИМЕЧАНИЕ: Мокирование .NET напрямую может быть нестабильно в PS 5.1.
        # Если будут проблемы, альтернатива - мокать Invoke-Expression или обернуть .NET вызов в функцию внутри скрипта и мокать её.
        # Но попробуем так:
        Mock New-Object {
             param($TypeName)
             if ($TypeName -eq 'System.Net.NetworkInformation.Ping') {
                 # Возвращаем мок-объект Ping с моком метода Send
                 $mockPing = [PSCustomObject]@{ Send = { Mock Ping.Send @PSBoundParameters } }
                 return $mockPing
             }
             # Для других вызовов New-Object возвращаем реальный объект
             return New-Object @PSBoundParameters
        }

        # Мок для метода Send (будет вызван из мока New-Object выше)
        # По умолчанию имитируем успешный пинг
        Mock Ping.Send {
            param($hostname, $timeout, $buffer, $options)
            Write-Verbose "Mock Ping.Send: Host=$hostname, Timeout=$timeout"
            # Возвращаем мок-объект PingReply
            return [PSCustomObject]@{
                Status        = [System.Net.NetworkInformation.IPStatus]::Success
                Address       = [System.Net.IPAddress]::Parse('8.8.8.8')
                RoundtripTime = 15L # Возвращаем long
            }
        }
    }

    # --- Контексты и тесты ---

    Context 'Успешный Пинг (.NET Send возвращает Success)' {

        It 'Должен вернуть IsAvailable=true, CheckSuccess=true без критериев' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $result = & $script:scriptPath @assignment # Используем splatting
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                ($Details -is [hashtable] -and $Details.rtt_ms -eq 15 -and $Details.packet_loss_percent -eq 0) -and
                [string]::IsNullOrEmpty($ErrorMessage)
            }
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
        }

        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=true, если критерии переданы и мок=true' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ rtt_ms = @{ '<=' = 100 } }
            Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName -Scope It # Переопределяем мок для теста

            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 ($DetailsObject.rtt_ms -eq 15) -and ($CriteriaObject.rtt_ms.'<=' -eq 100)
            }
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and [string]::IsNullOrEmpty($ErrorMessage)
            }
        }

        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=false, если критерии переданы и мок=false' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ packet_loss_percent = @{ '==' = 0 } }
            $failReasonMock = "Потери не 0%"
            Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It

            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $false -and $ErrorMessage -eq $using:failReasonMock
            }
        }
        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=null, если критерии переданы и мок=null' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.success_criteria = @{ rtt_ms = @{ '==' = "not number" } }
             $failReasonMock = "Ошибка сравнения"
             Mock Test-SuccessCriteria { return @{ Passed = $null; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It

             $result = & $script:scriptPath @assignment
             Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $IsAvailable -eq $true -and $CheckSuccess -eq $null -and $ErrorMessage -eq $using:failReasonMock
             }
        }
    } # Конец Context 'Успешный Пинг'

    Context 'Неуспешный Пинг (.NET Send НЕ возвращает Success)' {
        BeforeEach {
            # Мок для Ping.Send, имитирующий таймаут
             Mock Ping.Send { return [PSCustomObject]@{ Status = [System.Net.NetworkInformation.IPStatus]::TimedOut; Address = $null; RoundtripTime = 0L } }
        }
        It 'Должен вернуть IsAvailable=false, CheckSuccess=$null и НЕ вызывать Test-SuccessCriteria' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ rtt_ms = @{ '<=' = 100 } } # Критерии есть, но не должны проверяться

            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $false -and $CheckSuccess -eq $null -and
                ($Details -is [hashtable] -and $Details.status_string -eq 'TimedOut') -and
                $ErrorMessage -match 'Нет успешных ответов' -and $ErrorMessage -match 'TimedOut'
            }
        }
    } # Конец Context 'Неуспешный Пинг'

    Context 'Критическая ошибка PingException' {
         BeforeEach {
             # Мок для Ping.Send, который выбрасывает исключение
             Mock Ping.Send { throw [System.Net.NetworkInformation.PingException]::new("Хост не найден (Mock)") }
         }
         It 'Должен вернуть IsAvailable=false, CheckSuccess=$null и содержать ошибку в Details/ErrorMessage' {
            $assignment = $script:baseAssignment.PSObject.Copy()

            $result = & $script:scriptPath @assignment
            # Проверяем РЕАЛЬНЫЙ результат, т.к. New-CheckResultObject НЕ вызывался в основном потоке
            $result | Should -Not -BeNull
            $result.Mocked | Should -BeNullOr ( ($result.PSObject.Properties.Name -notcontains 'Mocked') -or (-not $result.Mocked)) # Проверяем, что это не мок New-CheckResultObject
            $result.IsAvailable | Should -BeFalse
            $result.CheckSuccess | Should -BeNull
            $result.ErrorMessage | Should -Match 'Критическая ошибка'
            $result.ErrorMessage | Should -Match 'PingException'
            $result.Details | Should -Not -BeNull
            $result.Details.error | Should -Match 'PingException'
            $result.Details.ErrorRecord | Should -Not -BeNullOrEmpty
            # Test-SuccessCriteria не должен был вызываться
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
         }
    } # Конец Context 'Критическая ошибка'
} # Конец Describe