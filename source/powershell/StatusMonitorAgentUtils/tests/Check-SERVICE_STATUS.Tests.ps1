# Check-SERVICE_STATUS.Tests.ps1
# Тесты для Check-SERVICE_STATUS.ps1 v2.0.2+ с моками

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

Describe 'Check-SERVICE_STATUS.ps1 (v2.0.2+)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils'

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-SERVICE_STATUS.ps1') -EA Stop
        try {
            Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop
            Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue # For Get-Service
        } catch {
            throw "Не удалось загрузить модуль $($script:utilsModuleName) или Microsoft.PowerShell.Management. Ошибка: $($_.Exception.Message)"
        }
    }

    $baseAssignment = @{ method_name = 'SERVICE_STATUS'; node_name = 'TestNode-Service'; ip_address = $null; parameters = @{}; success_criteria = $null }

    BeforeEach {
        Mock New-CheckResultObject { param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage); return @{ Mocked=$true; M_IsAvailable=$IsAvailable; M_CheckSuccess=$CheckSuccess; M_Details=$Details; M_ErrorMessage=$ErrorMessage } } -ModuleName $script:utilsModuleName
        Mock Test-SuccessCriteria { param($DetailsObject, $CriteriaObject, $Path) return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName
        
        Mock Get-Service {
            param($Name)
            # Write-Verbose "Mock Get-Service called for $Name"
            if ($Name -eq 'NonExistentSvcMock') {
                # Имитируем ServiceCommandException для ненайденной службы
                $exception = [Microsoft.PowerShell.Commands.ServiceCommandException]::new("Cannot find any service with service name '$Name'.")
                $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, "ServiceNotFound", [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Name)
                # В Pester мок не может напрямую вызвать $PSCmdlet.WriteError так, чтобы это было поймано как обычная ошибка командлета.
                # Вместо этого мы должны *throw* исключение, чтобы SUT его поймал.
                throw $errorRecord # Используем $errorRecord, т.к. SUT ловит ServiceCommandException
            }
            # По умолчанию возвращаем работающую службу
            return [PSCustomObject]@{Name=$Name; Status='Running'; DisplayName="Mock $Name"; StartType='Automatic'; CanStop=$true}
        } -ModuleName Microsoft.PowerShell.Management
    }

    Context 'Служба Найдена (Get-Service успешен)' {
        It 'Должен вернуть IsAvailable=true, CheckSuccess=true, если статус Running и нет критериев' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ service_name = 'Spooler' }
            $result = & $script:scriptPath @assignment
            Should -Invoke Get-Service -Times 1 -Exactly -ModuleName Microsoft.PowerShell.Management -ParameterFilter { $Name -eq 'Spooler' }
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
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
            Mock Test-SuccessCriteria { param($DetailsObject,$CriteriaObject,$Path) return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName -Scope It
            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CriteriaObject.status -eq 'Running' }
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $true -and [string]::IsNullOrEmpty($ErrorMessage) }
        }
        # ... (остальные тесты из этого контекста)
    }

    Context 'Служба Не Найдена (Get-Service выбрасывает ServiceCommandException)' {
        It 'Должен вернуть IsAvailable=true, CheckSuccess=false и сообщение об ошибке (служба не найдена)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ service_name = 'NonExistentSvcMock' }
            # Нет SuccessCriteria, поэтому CheckSuccess должен быть false из-за NotFound
            
            $result = & $script:scriptPath @assignment
            Should -Invoke Get-Service -Times 1 -Exactly -ModuleName Microsoft.PowerShell.Management
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName # Критериев нет, но и не должны вызываться т.к. есть ошибка "NotFound"
            
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and # Проверка была выполнена, хоть и с результатом "не найдено"
                $CheckSuccess -eq $false -and # Ненайденная служба - это провал, если нет критериев, ожидающих NotFound
                ($Details -is [hashtable] -and $Details.status -eq 'NotFound' -and $Details.error -match 'не найдена') -and
                ($ErrorMessage -match 'не найдена')
            }
        }

        It 'Должен вернуть CheckSuccess=true, если критерий ожидает status=NotFound' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ service_name = 'NonExistentSvcMock' }
            $assignment.success_criteria = @{ status = 'NotFound' } # Ожидаем, что служба не найдена
            Mock Test-SuccessCriteria { param($DetailsObject,$CriteriaObject,$Path)
                # Имитируем, что Test-SuccessCriteria прошел, т.к. $Details.status будет 'NotFound'
                if ($DetailsObject.status -eq 'NotFound' -and $CriteriaObject.status -eq 'NotFound') {
                    return @{ Passed = $true; FailReason = $null }
                }
                return @{ Passed = $false; FailReason = "Ожидался NotFound" }
            } -ModuleName $script:utilsModuleName -Scope It

            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                ($Details.status -eq 'NotFound') -and
                ($ErrorMessage -match 'не найдена') # ErrorMessage все равно будет, т.к. служба не найдена, но критерий это учел
            }
        }
    }

    Context 'Ошибка Валидации Параметра service_name' {
         It 'Должен вернуть IsAvailable=false, если service_name не передан' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             # $assignment.parameters не содержит service_name
             $result = & $script:scriptPath @assignment
             
             $result | Should -Not -BeNull
             ($result.PSObject.Properties.Name -notcontains 'Mocked' -or (-not $result.Mocked)) | Should -BeTrue
             $result.IsAvailable | Should -BeFalse
             $result.CheckSuccess | Should -BeNull
             $result.ErrorMessage | Should -Match 'service_name отсутствует'
         }
    }
}