# Check-PING.Tests.ps1 (v2.2.1 - Исправлены ошибки парсинга)
# --- Версия 2.2.1 ---
# Изменения:
# - Исправлены синтаксические ошибки в моках Ping.Send (комментарии внутри PSCustomObject).

# Требуется Pester v5+
# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

function New-CheckResultObject {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][bool]$IsAvailable, [Parameter(Mandatory=$false)][nullable[bool]]$CheckSuccess=$null, [Parameter(Mandatory=$false)][hashtable]$Details=$null, [Parameter(Mandatory=$false)][string]$ErrorMessage=$null)
    $result = [ordered]@{ IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage }; if ($result.IsAvailable) { if ($result.CheckSuccess -eq $null) { $result.CheckSuccess = $true } } else { $result.CheckSuccess = $null }; if ([string]::IsNullOrEmpty($result.ErrorMessage)) { if (-not $result.IsAvailable) { $result.ErrorMessage = "Ошибка выполнения проверки (IsAvailable=false)." } }; return $result
}

Describe 'Check-PING.ps1 (v2.3.2 .NET Ping Refactored Tests)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils'
    $script:pingSendMockBehavior = $null

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-PING.ps1') -EA Stop
        Write-Host "INFO: Тестируемый скрипт: $($script:scriptPath)" -FC Cyan
        try {
            Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop
            Write-Host "INFO: Модуль '$($script:utilsModuleName)' успешно загружен для тестов." -FC Green
        } catch {
            throw "КРИТИЧЕСКАЯ ОШИБКА: Не удалось загрузить модуль '$($script:utilsModuleName)'. Тесты не могут быть выполнены. Ошибка: $($_.Exception.Message)"
        }
    }

    $baseAssignment = @{
        method_name      = 'PING'
        node_name        = 'TestNode-PING'
        ip_address       = '8.8.8.8'
        parameters       = @{}
        success_criteria = $null
    }

    BeforeEach {
        Mock New-CheckResultObject {
            param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage)
            Write-Verbose "MOCK New-CheckResultObject CALLED with: IsAvailable=$IsAvailable, CheckSuccess=$CheckSuccess, ErrorMessage='$ErrorMessage'"
            return @{ Mocked = $true; M_IsAvailable = $IsAvailable; M_CheckSuccess = $CheckSuccess; M_Details = $Details; M_ErrorMessage = $ErrorMessage }
        } -ModuleName $script:utilsModuleName

        Mock Test-SuccessCriteria {
            param($DetailsObject, $CriteriaObject, $Path)
            Write-Verbose "MOCK Test-SuccessCriteria CALLED. CriteriaObject: $($CriteriaObject | ConvertTo-Json -Depth 2 -Compress). Path: $Path"
            return @{ Passed = $true; FailReason = $null }
        } -ModuleName $script:utilsModuleName

        $script:pingSendMockBehavior = {
            param($hostnameOrAddress, $timeout, $buffer, $options)
            Write-Verbose "MOCK Ping.Send (default behavior): Simulating SUCCESS Ping to '$hostnameOrAddress' with timeout $timeout"
            # Исправлено: Безопасный fallback и комментарий ВНЕ объекта
            $parsedAddress = try { [System.Net.IPAddress]::Parse($hostnameOrAddress) } catch { [System.Net.IPAddress]::Parse('127.0.0.1') }
            return [PSCustomObject]@{
                Status        = [System.Net.NetworkInformation.IPStatus]::Success
                Address       = $parsedAddress
                RoundtripTime = (Get-Random -Minimum 10 -Maximum 50) # long
            }
        }

        Mock New-Object {
            param ($TypeName)
            if ($TypeName -eq 'System.Net.NetworkInformation.Ping') {
                Write-Verbose "MOCK New-Object: Intercepted 'System.Net.NetworkInformation.Ping'. Returning custom mock object."
                return [PSCustomObject]@{
                    Send    = $script:pingSendMockBehavior
                    Dispose = { Write-Verbose "MOCK Ping.Dispose() called." }
                }
            }
            Write-Verbose "MOCK New-Object: Passing call for '$TypeName' to original."
            Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
        }
    }

    Context 'Успешный Пинг (.NET Send возвращает Success)' {
        BeforeEach {
            $script:pingSendMockBehavior = {
                param($hostnameOrAddress, $timeout, $buffer, $options)
                Write-Verbose "MOCK Ping.Send (Success Context): Host='$hostnameOrAddress', Timeout=$timeout"
                $parsedAddress = try { [System.Net.IPAddress]::Parse($hostnameOrAddress) } catch { [System.Net.IPAddress]::Parse('8.8.8.8') }
                return [PSCustomObject]@{
                    Status        = [System.Net.NetworkInformation.IPStatus]::Success
                    Address       = $parsedAddress
                    RoundtripTime = 15L # Конкретное значение для теста
                }
            }
        }

        It 'Должен вернуть IsAvailable=true, CheckSuccess=true без критериев' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $result = & $script:scriptPath @assignment

            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and
                $CheckSuccess -eq $true -and
                ($Details -is [hashtable] -and $Details.rtt_ms -eq 15 -and $Details.packet_loss_percent -eq 0) -and
                [string]::IsNullOrEmpty($ErrorMessage)
            }
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
        }

        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=true, если критерии переданы и мок Test-SuccessCriteria возвращает true' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ rtt_ms = @{ '<=' = 100 } }

            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 ($DetailsObject.rtt_ms -eq 15) -and ($CriteriaObject.rtt_ms.'<=' -eq 100)
            }
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and [string]::IsNullOrEmpty($ErrorMessage)
            }
        }

        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=false, если критерии переданы и мок Test-SuccessCriteria возвращает false' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ packet_loss_percent = @{ '==' = 0 } }
            $failReasonMock = "Потери не 0% (мок)"
            Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It

            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $false -and $ErrorMessage -eq $using:failReasonMock
            }
        }
        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=null, если критерии переданы и мок Test-SuccessCriteria возвращает Passed=$null (ошибка критерия)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.success_criteria = @{ rtt_ms = @{ '==' = "not a number" } }
             $failReasonMock = "Ошибка сравнения в Test-SuccessCriteria (мок)"
             Mock Test-SuccessCriteria { return @{ Passed = $null; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It

             $result = & $script:scriptPath @assignment
             Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $IsAvailable -eq $true -and $CheckSuccess -eq $null -and $ErrorMessage -eq $using:failReasonMock
             }
        }
    }

    Context 'Неуспешный Пинг (.NET Send НЕ возвращает Success)' {
        BeforeEach {
             $script:pingSendMockBehavior = {
                param($hostnameOrAddress, $timeout, $buffer, $options)
                Write-Verbose "MOCK Ping.Send (Failure Context): Simulating TIMEOUT Ping to '$hostnameOrAddress'"
                return [PSCustomObject]@{
                    Status        = [System.Net.NetworkInformation.IPStatus]::TimedOut
                    Address       = $null
                    RoundtripTime = 0L
                }
            }
        }
        It 'Должен вернуть IsAvailable=false, CheckSuccess=$null и НЕ вызывать Test-SuccessCriteria' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ rtt_ms = @{ '<=' = 100 } }

            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $false -and
                $CheckSuccess -eq $null -and
                ($Details -is [hashtable] -and $Details.status_string -eq 'TimedOut' -and $Details.packet_loss_percent -eq 100) -and
                $ErrorMessage -match 'Нет успешных ответов' -and $ErrorMessage -match 'TimedOut'
            }
        }
    }

    Context 'Критическая ошибка PingException' {
         BeforeEach {
             $script:pingSendMockBehavior = {
                param($hostnameOrAddress, $timeout, $buffer, $options)
                Write-Verbose "MOCK Ping.Send (Exception Context): Simulating PingException for '$hostnameOrAddress'"
                throw [System.Net.NetworkInformation.PingException]::new("Мок: Хост не найден (PingException).")
            }
         }
         It 'Должен вернуть IsAvailable=false, CheckSuccess=$null и содержать ошибку в Details/ErrorMessage' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.ip_address = 'invalid-host-for-exception'

            $result = & $script:scriptPath @assignment

            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $M_IsAvailable -eq $false -and
                $M_CheckSuccess -eq $null -and
                $M_ErrorMessage -match 'Критическая ошибка PingException' -and $M_ErrorMessage -match 'invalid-host-for-exception' -and
                ($M_Details -is [hashtable] -and $M_Details.error -match 'PingException' -and $M_Details.ErrorRecord -match 'PingException')
            }
         }
    }
}