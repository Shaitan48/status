# Check-SERVICE_STATUS.Tests.ps1
# Тесты для Check-SERVICE_STATUS.ps1 v2.0.1 с моками

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

# Определяем New-CheckResultObject локально (v1.3)
function New-CheckResultObject { [CmdletBinding()] param([bool]$IsAvailable,[nullable[bool]]$CheckSuccess=$null,[hashtable]$Details=$null,[string]$ErrorMessage=$null); $r=[ordered]@{IsAvailable=$IsAvailable;CheckSuccess=$CheckSuccess;Timestamp=(Get-Date).ToUniversalTime().ToString("o");Details=$Details;ErrorMessage=$ErrorMessage}; if($r.IsAvailable){if($r.CheckSuccess-eq$null){$r.CheckSuccess=$true}}else{$r.CheckSuccess=$null}; if([string]::IsNullOrEmpty($r.ErrorMessage)){if(-not $r.IsAvailable){$r.ErrorMessage="Ошибка выполнения проверки (IsAvailable=false)."}}; return $r }

Describe 'Check-SERVICE_STATUS.ps1 (v2.0.1)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils'

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-SERVICE_STATUS.ps1') -EA Stop
        try { Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop } catch { throw "Не удалось загрузить модуль $($script:utilsModuleName)" }
    }

    # Базовое задание
    $baseAssignment = @{ method_name = 'SERVICE_STATUS'; node_name = 'TestNode-Service'; ip_address = $null; parameters = @{}; success_criteria = $null }

    # Общие моки
    BeforeEach {
        Mock New-CheckResultObject { param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage); return @{ Mocked=$true; M_IsAvailable=$IsAvailable; M_CheckSuccess=$CheckSuccess; M_Details=$Details; M_ErrorMessage=$ErrorMessage } } -ModuleName $script:utilsModuleName
        Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName
        # Мок Get-Service по умолчанию возвращает "Running"
        Mock Get-Service { param($Name) Write-Verbose "Mock Get-Service called for $Name"; return [PSCustomObject]@{Name=$Name; Status='Running'; DisplayName="Mock $Name"; StartType='Automatic'; CanStop=$true} } -ModuleName Microsoft.PowerShell.Management
    }

    Context 'Служба Найдена (Get-Service успешен)' {

        It 'Должен вернуть IsAvailable=true, CheckSuccess=true, если статус Running и нет критериев' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ service_name = 'Spooler' }
            $result = & $script:scriptPath @assignment
            Should -Invoke Get-Service -Times 1 -Exactly -ModuleName Microsoft.PowerShell.Management -ParameterFilter { $Name -eq 'Spooler' }
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName # Критериев нет
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                ($Details -is [hashtable] -and $Details.status -eq 'Running') -and
                [string]::IsNullOrEmpty($ErrorMessage)
            }
        }

        It 'Должен вернуть CheckSuccess=true, если статус Running и критерий status=Running' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ service_name = 'Spooler' }
            $assignment.success_criteria = @{ status = 'Running' }
            Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName -Scope It
            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CriteriaObject.status -eq 'Running' }
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $true -and [string]::IsNullOrEmpty($ErrorMessage) }
        }

        It 'Должен вернуть CheckSuccess=false, если статус Running и критерий status=Stopped (mock=false)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ service_name = 'Spooler' }
            $assignment.success_criteria = @{ status = 'Stopped' }
            $failReasonMock = "Статус 'Running' не равен 'Stopped'"
            Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It
            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $false -and $ErrorMessage -eq $using:failReasonMock }
        }

        It 'Должен вернуть CheckSuccess=null, если произошла ошибка в Test-SuccessCriteria (mock=null)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters = @{ service_name = 'Spooler' }
             $assignment.success_criteria = @{ status = @{'invalid_op'=1} } # Неверный критерий
             $failReasonMock = "Ошибка обработки критерия"
             Mock Test-SuccessCriteria { return @{ Passed = $null; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It
             $result = & $script:scriptPath @assignment
             Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $null -and $ErrorMessage -eq $using:failReasonMock }
        }

         It 'Должен вернуть CheckSuccess=true, если статус Stopped и критериев нет' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ service_name = 'BITS' }
            # Мокируем Get-Service для этого теста, чтобы вернуть Stopped
            Mock Get-Service { return [PSCustomObject]@{Name='BITS'; Status='Stopped'; DisplayName='Mock BITS'; StartType='Manual'; CanStop=$true} } -ModuleName Microsoft.PowerShell.Management -Scope It
            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                 ($Details.status -eq 'Stopped') -and [string]::IsNullOrEmpty($ErrorMessage)
            }
         }

    } # Конец Context 'Служба Найдена'

    Context 'Служба Не Найдена (Get-Service выдает ServiceCommandException)' {
        BeforeEach {
            # Мокируем Get-Service, чтобы он выбрасывал ошибку
            Mock Get-Service { param($Name) throw [Microsoft.PowerShell.Commands.ServiceCommandException]::new("Служба $Name не найдена (Mock)") } -ModuleName Microsoft.PowerShell.Management
        }
        It 'Должен вернуть IsAvailable=false, CheckSuccess=$null и не вызывать Test-SuccessCriteria' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ service_name = 'NonExistentSvc' }
            $assignment.success_criteria = @{ status = 'Running' } # Критерий есть, но не должен проверяться

            $result = & $script:scriptPath @assignment
            Should -Invoke Get-Service -Times 1 -Exactly -ModuleName Microsoft.PowerShell.Management
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $false -and $CheckSuccess -eq $null -and
                ($Details -is [hashtable] -and $Details.error -match 'не найдена') -and
                $ErrorMessage -match 'не найдена'
            }
        }
    } # Конец Context 'Служба Не Найдена'

    Context 'Ошибка Валидации Параметра service_name' {
         It 'Должен вернуть IsAvailable=false, если service_name не передан' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             # $assignment.parameters не содержит service_name
             $result = & $script:scriptPath @assignment
             # Проверяем реальный результат из catch блока
             $result.Mocked | Should -BeNullOr $false # Это не мок
             $result.IsAvailable | Should -BeFalse
             $result.CheckSuccess | Should -BeNull
             $result.ErrorMessage | Should -Contain 'service_name'
         }
    } # Конец Context 'Ошибка Валидации'
} # Конец Describe