# Check-DISK_USAGE.Tests.ps1
# Тесты для Check-DISK_USAGE.ps1 v2.0.2 с моками

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

# Определяем New-CheckResultObject локально
function New-CheckResultObject { [CmdletBinding()] param([bool]$IsAvailable,[nullable[bool]]$CheckSuccess=$null,[hashtable]$Details=$null,[string]$ErrorMessage=$null); $r=[ordered]@{IsAvailable=$IsAvailable;CheckSuccess=$CheckSuccess;Timestamp=(Get-Date).ToUniversalTime().ToString("o");Details=$Details;ErrorMessage=$ErrorMessage}; if($r.IsAvailable){if($r.CheckSuccess-eq$null){$r.CheckSuccess=$true}}else{$r.CheckSuccess=$null}; if([string]::IsNullOrEmpty($r.ErrorMessage)){if(-not $r.IsAvailable){$r.ErrorMessage="Ошибка выполнения проверки (IsAvailable=false)."}}; return $r }

Describe 'Check-DISK_USAGE.ps1 (v2.0.2)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils'

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-DISK_USAGE.ps1') -EA Stop
        try { Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop } catch { throw "Не удалось загрузить модуль $($script:utilsModuleName)" }
    }

    # Базовое задание
    $baseAssignment = @{ method_name = 'DISK_USAGE'; node_name = 'TestNode-Disk'; ip_address = $null; parameters = $null; success_criteria = $null }

    # Общие моки
    BeforeEach {
        Mock New-CheckResultObject { param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage); return @{ Mocked=$true; M_IsAvailable=$IsAvailable; M_CheckSuccess=$CheckSuccess; M_Details=$Details; M_ErrorMessage=$ErrorMessage } } -ModuleName $script:utilsModuleName
        Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName
        # Мок Get-Volume (модуль Storage)
        # Возвращаем массив объектов, имитирующих вывод Get-Volume
        Mock Get-Volume {
             Write-Verbose "Mock Get-Volume called"
             return @(
                 [PSCustomObject]@{ DriveLetter = 'C'; FileSystemLabel = 'System'; FileSystem = 'NTFS'; DriveType = 'Fixed'; Size = 500GB; SizeRemaining = 100GB }
                 [PSCustomObject]@{ DriveLetter = 'D'; FileSystemLabel = 'Data'; FileSystem = 'NTFS'; DriveType = 'Fixed'; Size = 1000GB; SizeRemaining = 50GB } # Меньше 10% свободно
                 [PSCustomObject]@{ DriveLetter = 'E'; FileSystemLabel = ''; FileSystem = 'CDFS'; DriveType = 'CD-ROM'; Size = 0; SizeRemaining = 0 } # Не Fixed
                 [PSCustomObject]@{ DriveLetter = $null; FileSystemLabel = 'Recovery'; FileSystem = 'NTFS'; DriveType = 'Fixed'; Size = 1GB; SizeRemaining = 0.5GB } # Без буквы
             )
        } -ModuleName Storage
    }

    Context 'Получение данных о дисках' {
        It 'Должен вернуть IsAvailable=true и данные для дисков C и D без фильтров' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $result = & $script:scriptPath @assignment
            Should -Invoke Get-Volume -Times 1 -Exactly -ModuleName Storage
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                ($Details -is [hashtable] -and $Details.disks -is [System.Collections.Generic.List[object]] -and $Details.disks.Count -eq 2) -and
                ($Details.disks[0].drive_letter -eq 'C' -and $Details.disks[0].percent_free -eq 20.0) -and # 100GB / 500GB
                ($Details.disks[1].drive_letter -eq 'D' -and $Details.disks[1].percent_free -eq 5.0) -and # 50GB / 1000GB
                [string]::IsNullOrEmpty($ErrorMessage)
            }
             Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
        }

        It 'Должен вернуть только диск C при фильтре parameters.drives = @("C")' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ drives = @('C', 'c') } # Проверяем регистр
            $result = & $script:scriptPath @assignment
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                ($Details.disks.Count -eq 1 -and $Details.disks[0].drive_letter -eq 'C')
            }
        }

        It 'Должен вернуть пустой список и сообщение, если фильтр не находит дисков' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ drives = @('Z') } # Несуществующий диск
            $result = & $script:scriptPath @assignment
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                ($Details.disks.Count -eq 0) -and $Details.message -match 'не найдены'
            }
        }
    } # Конец Context 'Получение данных'

    Context 'Проверка Критериев Успеха' {
        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=true, если критерии пройдены (mock=true)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            # Критерий: на всех дисках должно быть > 1% свободно
            $assignment.success_criteria = @{ disks=@{_condition_='all';_criteria_=@{percent_free=@{'>'=1}}} }
            Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName -Scope It

            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CriteriaObject -ne $null }
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $true -and [string]::IsNullOrEmpty($ErrorMessage) }
        }

        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=false, если критерии НЕ пройдены (mock=false)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
             # Критерий: на диске D должно быть > 10% свободно (в моке 5%)
            $assignment.success_criteria = @{ disks=@{_condition_='all';_where_=@{drive_letter='D'};_criteria_=@{percent_free=@{'>'=10}}} }
            $failReasonMock = "Диск D: процент свободного места 5.0 меньше или равен порогу 10"
            Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It

            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $false -and $ErrorMessage -eq $using:failReasonMock }
        }
    } # Конец Context 'Проверка Критериев'

    Context 'Ошибка Get-Volume' {
        BeforeEach {
            # Мок Get-Volume, который выдает ошибку
            Mock Get-Volume { throw "Ошибка доступа к WMI (Mock Error)" } -ModuleName Storage
        }
        It 'Должен вернуть IsAvailable=false и сообщение об ошибке' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $result = & $script:scriptPath @assignment
            $result.Mocked | Should -BeNullOr $false # Проверяем реальный результат из catch
            $result.IsAvailable | Should -BeFalse
            $result.CheckSuccess | Should -BeNull
            $result.ErrorMessage | Should -Match 'Критическая ошибка'
            $result.ErrorMessage | Should -Match 'Get-Volume'
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
        }
    } # Конец Context 'Ошибка Get-Volume'

} # Конец Describe