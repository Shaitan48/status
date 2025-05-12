# Check-PROCESS_LIST.Tests.ps1 (v2.1.0+ Refactored for PS 5.1)

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' } # Pester 5 должен работать и с PS 5.1

function New-CheckResultObject {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][bool]$IsAvailable, [Parameter(Mandatory = $false)][nullable[bool]]$CheckSuccess = $null, [Parameter(Mandatory = $false)][hashtable]$Details = $null, [Parameter(Mandatory = $false)][string]$ErrorMessage = $null)
    $result = [ordered]@{ IsAvailable = $IsAvailable; CheckSuccess = $CheckSuccess; Timestamp = (Get-Date).ToUniversalTime().ToString("o"); Details = $Details; ErrorMessage = $ErrorMessage };
    if ($result.IsAvailable) { if ($result.CheckSuccess -eq $null) { $result.CheckSuccess = $true } } else { $result.CheckSuccess = $null };
    if ([string]::IsNullOrEmpty($result.ErrorMessage)) { if (-not $result.IsAvailable) { $result.ErrorMessage = "Ошибка выполнения проверки (IsAvailable=false)." } };
    return $result
}

Describe 'Check-PROCESS_LIST.ps1 (v2.1.0+ PS 5.1 Tests)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils'
    $script:mockProcesses = @() # Инициализируем здесь

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-PROCESS_LIST.ps1') -EA Stop
        Write-Host "INFO: Тестируемый скрипт: $($script:scriptPath)" -FC Cyan
        try {
            Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop
            Write-Host "INFO: Модуль '$($script:utilsModuleName)' успешно загружен для тестов." -FC Green
        } catch {
            throw "КРИТИЧЕСКАЯ ОШИБКА: Не удалось загрузить модуль '$($script:utilsModuleName)'. Тесты не могут быть выполнены. Ошибка: $($_.Exception.Message)"
        }

        # Определяем $script:mockProcesses один раз
        $script:mockProcesses = @(
            [PSCustomObject]@{ Id = 101; ProcessName = 'powershell'; CPU = 10.5; WS = 200MB; StartTime = (Get-Date).AddHours(-1); Path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
            [PSCustomObject]@{ Id = 102; ProcessName = 'explorer'; CPU = 5.2; WS = 150MB; StartTime = (Get-Date).AddHours(-5); Path = 'C:\Windows\explorer.exe' }
            [PSCustomObject]@{ Id = 103; ProcessName = 'svchost'; CPU = 0.1; WS = 10MB; StartTime = (Get-Date).AddDays(-1); Path = 'C:\Windows\System32\svchost.exe' }
            [PSCustomObject]@{ Id = 104; ProcessName = 'svchost'; CPU = 0.5; WS = 15MB; StartTime = (Get-Date).AddDays(-1).AddHours(1); Path = 'C:\Windows\System32\svchost.exe' }
            [PSCustomObject]@{ Id = 201; ProcessName = 'notepad'; CPU = 1.0; WS = 20MB; StartTime = (Get-Date).AddMinutes(-30); Path = 'C:\Windows\System32\notepad.exe' }
        )
    }

    $baseAssignment = @{
        method_name      = 'PROCESS_LIST'
        node_name        = 'TestNode-Proc'
        ip_address       = $null # Проверка всегда локальная
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

        # --- Мок Get-Process ---
        Mock Get-Process {
            param(
                [string[]]$Name,
                [string]$ComputerName, # Хотя мы его не используем, он может быть передан
                [switch]$IncludeUserName, # Get-Process не имеет этого, но SUT может передавать
                [string]$ErrorAction = 'Continue' # Значение по умолчанию для Get-Process
            )
            Write-Verbose "MOCK Get-Process CALLED. Name Filter: '$($Name -join ', ')', ErrorAction: $ErrorAction"
            $processesToReturn = $script:mockProcesses # Используем общую переменную

            if ($Name) {
                $filteredByName = [System.Collections.Generic.List[object]]::new()
                foreach ($pattern in $Name) {
                    $processesToReturn | Where-Object { $_.ProcessName -like $pattern } | ForEach-Object { $filteredByName.Add($_) }
                }
                $processesToReturn = $filteredByName.ToArray() | Select-Object -Unique # Убираем дубликаты, если паттерны пересекаются
            }

            if ($processesToReturn.Count -eq 0 -and $Name -and $ErrorAction -ne 'Stop') {
                # Имитируем ошибку, если процесс не найден и ErrorAction не Stop
                # Для ProcessNotFoundException нужно больше информации, которую сложно корректно мокнуть
                # Проще вернуть пустой массив и проверить логику SUT (System Under Test)
                Write-Warning "MOCK Get-Process: Process(es) matching '$($Name -join ', ')' not found."
                # Эта ошибка будет очищена в SUT, если это ProcessNotFoundException
                $exceptionMessage = "Cannot find a process with the name ""$($Name -join ', ')"". Verify the process name and call the cmdlet again."
                $exception = [System.Management.Automation.ProcessCommandException]::new($exceptionMessage)
                $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, "ProcessNotFound", [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Name)
                $PSCmdlet.WriteError($errorRecord) # Это правильно для генерации ошибки, которую SUT может поймать
                return @() # Возвращаем пустой массив, т.к. ошибка была обработана (не Stop)
            }
            return $processesToReturn
        } -ModuleName Microsoft.PowerShell.Management # Модуль, где живет Get-Process

        # --- Мок Get-CimInstance для Win32_Process (получение Username) ---
        Mock Get-CimInstance {
            param(
                [string]$ClassName,
                [string]$Filter,
                [string]$ComputerName,
                [string]$ErrorAction = 'Continue'
            )
            Write-Verbose "MOCK Get-CimInstance CALLED. ClassName: $ClassName, Filter: $Filter"
            if ($ClassName -ne 'Win32_Process' -or -not $Filter -match 'ProcessId = (\d+)') {
                if ($ErrorAction -eq 'Stop') { throw "MOCK Get-CimInstance: Invalid ClassName or Filter for Win32_Process mock." }
                return $null
            }
            $procId = [int]$Matches[1]
            switch ($procId) {
                101 { return [PSCustomObject]@{Domain = 'MOCKDOMAIN'; User = 'UserPS'} } # Для powershell
                102 { return [PSCustomObject]@{Domain = $env:USERDOMAIN; User = $env:USERNAME} } # Для explorer
                103 { return [PSCustomObject]@{User = 'SYSTEM'} } # Для svchost 1
                201 { return $null } # Имитация отсутствия данных для notepad
                default {
                    # Для других ProcessId возвращаем $null или имитируем ошибку, если ErrorAction='Stop'
                    if ($ErrorAction -eq 'Stop') { throw "MOCK Get-CimInstance: No CIM data for ProcessId $procId" }
                    return $null
                }
            }
        } -ModuleName CimCmdlets # Модуль, где живет Get-CimInstance
    }

    Context 'Получение списка процессов' {
        It 'Должен вернуть все 5 процессов без фильтров и с базовыми полями (username/path null)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            # Параметры по умолчанию: include_username=$false, include_path=$false
            $result = & $script:scriptPath @assignment

            Should -Invoke Get-Process -Times 1 -Exactly -ModuleName Microsoft.PowerShell.Management -ParameterFilter { $Name -eq $null }
            Should -Invoke Get-CimInstance -Times 0 -ModuleName CimCmdlets # Не должен вызываться, т.к. include_username=false

            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $M_IsAvailable -eq $true -and $M_CheckSuccess -eq $true -and
                ($M_Details.processes.Count -eq 5) -and # В моке 5 процессов
                ($M_Details.processes | Where-Object { $_.name -eq 'powershell' } | ForEach-Object { $_.username -eq $null -and $_.path -eq $null }) -and
                ($M_Details.processes | Where-Object { $_.name -eq 'notepad' } | ForEach-Object { $_.username -eq $null -and $_.path -eq $null })
            }
        }

        It 'Должен вернуть процессы PowerShell (1 шт) с Username и Path при include_username/path=true' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ process_names = @('powershell'); include_username = $true; include_path = $true }
            $result = & $script:scriptPath @assignment

            Should -Invoke Get-Process -Times 1 -Exactly -ModuleName Microsoft.PowerShell.Management -ParameterFilter { $Name -contains 'powershell' }
            Should -Invoke Get-CimInstance -Times 1 -Exactly -ModuleName CimCmdlets -ParameterFilter { $Filter -match '101' } # Вызов для powershell (ID 101)

            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $M_Details.processes.Count -eq 1 -and
                $M_Details.processes[0].name -eq 'powershell' -and
                $M_Details.processes[0].username -eq 'MOCKDOMAIN\UserPS' -and
                $M_Details.processes[0].path -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' # Path из мока $script:mockProcesses
            }
        }

        It 'Должен вернуть отсортированный список по CPU (убывание)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ sort_by = 'cpu'; sort_descending = $true }
            $result = & $script:scriptPath @assignment

            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $M_Details.processes.Count -eq 5 -and
                $M_Details.processes[0].name -eq 'powershell' -and # 10.5 CPU
                $M_Details.processes[1].name -eq 'explorer' -and   # 5.2 CPU
                $M_Details.processes[2].name -eq 'notepad' -and    # 1.0 CPU
                $M_Details.processes[3].name -eq 'svchost' -and    # 0.5 CPU (ID 104)
                $M_Details.processes[4].name -eq 'svchost'         # 0.1 CPU (ID 103)
            }
        }

        It 'Должен вернуть топ 2 процесса по памяти (убывание)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ sort_by = 'memory'; sort_descending = $true; top_n = 2 }
            $result = & $script:scriptPath @assignment

            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $M_Details.processes.Count -eq 2 -and
                 $M_Details.processes[0].name -eq 'powershell' -and # 200MB
                 $M_Details.processes[1].name -eq 'explorer'        # 150MB
            }
        }

        It 'Должен вернуть пустой список и сообщение, если процесс по фильтру "nonexistent" не найден' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ process_names = @('nonexistent') }
            # Мок Get-Process вернет ошибку ProcessNotFound, которая будет обработана в SUT
            $result = & $script:scriptPath @assignment

            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $M_IsAvailable -eq $true -and # Сама проверка отработала
                 $M_CheckSuccess -eq $true -and # Критериев нет, ProcessNotFound - не ошибка доступности SUT
                 ($M_Details.processes.Count -eq 0) -and
                 ($M_Details.message -match 'не найдены') -and ($M_Details.message -match 'nonexistent')
            }
        }
    }

    Context 'Проверка Критериев Успеха' {
        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=true, если критерий пройден (мок Test-SuccessCriteria = true)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ processes = @{ _condition_ = 'count'; _where_ = @{ name = 'svchost' }; _count_ = @{ '>=' = 1 } } } # Ожидаем хотя бы один svchost
            # Мок Test-SuccessCriteria по умолчанию возвращает true
            $result = & $script:scriptPath @assignment

            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $M_CheckSuccess -eq $true }
        }

        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=false, если критерий НЕ пройден (мок Test-SuccessCriteria = false)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.success_criteria = @{ processes = @{ _condition_ = 'none'; _where_ = @{ name = 'explorer.exe' } } } # Не должно быть explorer.exe
            $failReasonMock = "Найден запрещенный процесс explorer.exe (мок)"
            Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It
            $result = & $script:scriptPath @assignment

            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $M_CheckSuccess -eq $false -and $M_ErrorMessage -eq $using:failReasonMock }
        }
    }

    Context 'Ошибка Get-Process (кроме ProcessNotFound)' {
        BeforeEach {
            # Мокируем Get-Process так, чтобы он выбрасывал критическую ошибку
            Mock Get-Process {
                param($Name, $ErrorAction='Continue')
                Write-Verbose "MOCK Get-Process (CRITICAL ERROR CONTEXT)"
                if ($ErrorAction -eq 'Stop') {
                    throw "Критическая ошибка доступа к Get-Process (мок)"
                } else {
                    # Для ErrorAction='SilentlyContinue' или 'Continue'
                    $exception = [System.Management.Automation.RuntimeException]::new("Критическая ошибка доступа к Get-Process (мок)")
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, "GetProcessCriticalError", [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
                    $PSCmdlet.WriteError($errorRecord)
                    return $null # или @()
                }
            } -ModuleName Microsoft.PowerShell.Management
        }
        It 'Должен вернуть IsAvailable=false и сообщение об ошибке, если Get-Process выбрасывает критическую ошибку' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            # SUT Check-PROCESS_LIST.ps1 вызывает Get-Process с ErrorAction = SilentlyContinue или Stop
            # Если SUT ставит ErrorAction='Stop' в своем вызове, наш мок это обработает и кинет throw
            # Если SUT ставит ErrorAction='SilentlyContinue', то наш мок вернет $null и запишет ошибку, SUT должен это обработать.
            # В Check-PROCESS_LIST.ps1 (v2.1.0) ErrorAction устанавливается в Stop, если нет фильтра по имени.
            $result = & $script:scriptPath @assignment # Без фильтра по имени, SUT поставит ErrorAction='Stop'

            # Ожидаем, что SUT поймает исключение и вернет результат через New-CheckResultObject
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $M_IsAvailable -eq $false -and
                $M_CheckSuccess -eq $null -and
                $M_ErrorMessage -match 'Критическая ошибка в Check-PROCESS_LIST' -and $M_ErrorMessage -match 'Критическая ошибка доступа к Get-Process \(мок\)'
            }
            Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
        }
    }
}