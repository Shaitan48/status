# Check-PROCESS_LIST.Tests.ps1
# Тесты для Check-PROCESS_LIST.ps1 v2.0.2 с моками

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

# Определяем New-CheckResultObject локально
function New-CheckResultObject { [CmdletBinding()] param([bool]$IsAvailable,[nullable[bool]]$CheckSuccess=$null,[hashtable]$Details=$null,[string]$ErrorMessage=$null); $r=[ordered]@{IsAvailable=$IsAvailable;CheckSuccess=$CheckSuccess;Timestamp=(Get-Date).ToUniversalTime().ToString("o");Details=$Details;ErrorMessage=$ErrorMessage}; if($r.IsAvailable){if($r.CheckSuccess-eq$null){$r.CheckSuccess=$true}}else{$r.CheckSuccess=$null}; if([string]::IsNullOrEmpty($r.ErrorMessage)){if(-not $r.IsAvailable){$r.ErrorMessage="Ошибка выполнения проверки (IsAvailable=false)."}}; return $r }

Describe 'Check-PROCESS_LIST.ps1 (v2.0.2)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils'

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-PROCESS_LIST.ps1') -EA Stop
        try { Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop } catch { throw "Не удалось загрузить модуль $($script:utilsModuleName)" }
    }

    # Базовое задание
    $baseAssignment = @{ method_name = 'PROCESS_LIST'; node_name = 'TestNode-Proc'; ip_address = $null; parameters = @{}; success_criteria = $null }

    # --- Общие моки ---
    BeforeEach {
        Mock New-CheckResultObject { param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage); return @{ Mocked=$true; M_IsAvailable=$IsAvailable; M_CheckSuccess=$CheckSuccess; M_Details=$Details; M_ErrorMessage=$ErrorMessage } } -ModuleName $script:utilsModuleName
        Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName

        # --- Мок Get-Process ---
        # Возвращаем набор тестовых процессов
        $mockProcesses = @(
            [PSCustomObject]@{ Id = 101; ProcessName = 'powershell'; CPU = 10.5; WS = 200MB; StartTime = (Get-Date).AddHours(-1) }
            [PSCustomObject]@{ Id = 102; ProcessName = 'explorer'; CPU = 5.2; WS = 150MB; StartTime = (Get-Date).AddHours(-5) }
            [PSCustomObject]@{ Id = 103; ProcessName = 'svchost'; CPU = 0.1; WS = 10MB; StartTime = (Get-Date).AddDays(-1) }
            [PSCustomObject]@{ Id = 104; ProcessName = 'svchost'; CPU = 0.5; WS = 15MB; StartTime = (Get-Date).AddDays(-1).AddHours(1) }
        )
        Mock Get-Process {
            param($Name)
            Write-Verbose "Mock Get-Process called. Filter Name: '$($Name -join ',')'"
            if ($Name) { return $using:mockProcesses | Where-Object { $proc = $_; $Name | ForEach-Object { $pattern = $_; if ($proc.ProcessName -like $pattern) { return $true } }; return $false } }
            else { return $using:mockProcesses }
        } -ModuleName Microsoft.PowerShell.Management

        # --- Мок Get-CimInstance для Win32_Process (получение Username) ---
        # Возвращаем разные данные в зависимости от ProcessId
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            Write-Verbose "Mock Get-CimInstance Win32_Process called. Filter: $Filter"
            if ($ClassName -ne 'Win32_Process' -or -not $Filter -match 'ProcessId = (\d+)') { return $null }
            $procId = [int]$Matches[1]
            switch ($procId) {
                101 { return [PSCustomObject]@{Owner = [PSCustomObject]@{Domain='DOMAIN'; User='UserPS'}} }
                102 { return [PSCustomObject]@{Owner = [PSCustomObject]@{Domain=$env:USERDOMAIN; User=$env:USERNAME}} } # Текущий пользователь
                103 { return [PSCustomObject]@{Owner = [PSCustomObject]@{User='SYSTEM'}} } # Без домена
                default { return $null } # Для остальных возвращаем null
            }
        } -ModuleName CimCmdlets
    }

    Context 'Получение списка процессов' {
        It 'Должен вернуть все 4 процесса без фильтров и с базовыми полями' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $result = & $script:scriptPath @assignment
            Should -Invoke Get-Process -Times 1 -Exactly -ModuleName Microsoft.PowerShell.Management -ParameterFilter { $Name -eq $null }
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                ($Details.processes.Count -eq 4) -and
                ($Details.processes[0].name -eq 'powershell' -and $Details.processes[0].username -eq $null -and $Details.processes[0].path -eq $null)
            }
        }
        It 'Должен вернуть процессы PowerShell с Username и Path при include=true' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ process_names = @('*powershell*'); include_username = $true; include_path = $true }
            $result = & $script:scriptPath @assignment
            Should -Invoke Get-Process -Times 1 -Exactly -ModuleName Microsoft.PowerShell.Management -ParameterFilter { $Name -ne $null }
            Should -Invoke Get-CimInstance -Times 1 -Exactly -ModuleName CimCmdlets -ParameterFilter { $Filter -match '101' } # Вызов для powershell
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $Details.processes.Count -eq 1 -and
                $Details.processes[0].name -eq 'powershell' -and
                $Details.processes[0].username -eq 'DOMAIN\UserPS' -and
                # Path мокнуть сложнее, т.к. $proc.Path зависит от реального процесса
                ($Details.processes[0].path -eq $null -or $Details.processes[0].path -eq '[Access Error]') # Ожидаем null или ошибку, т.к. мок Get-Process не имеет реального пути
            }
        }
         It 'Должен вернуть отсортированный список по CPU (убывание)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters = @{ sort_by = 'cpu'; sort_descending = $true }
             $result = & $script:scriptPath @assignment
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $Details.processes[0].name -eq 'powershell' -and # 10.5 CPU
                 $Details.processes[1].name -eq 'explorer' -and # 5.2 CPU
                 $Details.processes[2].name -eq 'svchost' -and # 0.5 CPU
                 $Details.processes[3].name -eq 'svchost' # 0.1 CPU
             }
         }
         It 'Должен вернуть топ 2 процесса по памяти (убывание)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters = @{ sort_by = 'memory'; sort_descending = $true; top_n = 2 }
             $result = & $script:scriptPath @assignment
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                  $Details.processes.Count -eq 2 -and
                  $Details.processes[0].name -eq 'powershell' -and # 200MB
                  $Details.processes[1].name -eq 'explorer' # 150MB
             }
         }
         It 'Должен вернуть пустой список и сообщение, если процесс по фильтру не найден' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters = @{ process_names = @('notepad') }
             Mock Get-Process { return $null } -ModuleName Microsoft.PowerShell.Management -Scope It # Мок возвращает null
             $result = & $script:scriptPath @assignment
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                  $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                  ($Details.processes.Count -eq 0) -and ($Details.message -match 'не найдены')
             }
         }
    } # Конец Context 'Получение списка'

    Context 'Проверка Критериев Успеха' {
         It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=true, если критерий пройден (mock=true)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             # Критерий: Должен быть хотя бы один svchost
             $assignment.success_criteria = @{ processes=@{_condition_='count';_where_=@{name='svchost'};_count_=@{'>='=1}} }
             Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName -Scope It
             $result = & $script:scriptPath @assignment
             Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $true }
         }
         It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=false, если критерий НЕ пройден (mock=false)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
              # Критерий: Не должно быть explorer.exe
             $assignment.success_criteria = @{ processes=@{_condition_='none';_where_=@{name='explorer.exe'}} }
             $failReasonMock = "Найден запрещенный процесс explorer.exe"
             Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It
             $result = & $script:scriptPath @assignment
             Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $false -and $ErrorMessage -eq $using:failReasonMock }
         }
    } # Конец Context 'Критерии Успеха'

    Context 'Ошибка Get-Process' {
         BeforeEach { Mock Get-Process { throw "Критическая ошибка доступа (Mock)" } -ModuleName Microsoft.PowerShell.Management }
         It 'Должен вернуть IsAvailable=false и сообщение об ошибке' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $result = & $script:scriptPath @assignment
             $result.Mocked | Should -BeNullOr $false # Реальный результат из catch
             $result.IsAvailable | Should -BeFalse
             $result.CheckSuccess | Should -BeNull
             $result.ErrorMessage | Should -Match 'Критическая ошибка'
             Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
         }
    } # Конец Context 'Ошибка Get-Process'

} # Конец Describe