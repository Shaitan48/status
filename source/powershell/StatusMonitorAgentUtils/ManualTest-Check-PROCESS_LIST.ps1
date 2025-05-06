# ManualTest-Check-PROCESS_LIST.ps1 (v2.1)
# Скрипт для ручного тестирования Check-PROCESS_LIST.ps1 через диспетчер

# --- 1. Загрузка модуля Utils ---
# (Код загрузки модуля без изменений)
$ErrorActionPreference = "Stop"; try { $mp=Join-Path $PSScriptRoot "StatusMonitorAgentUtils.psd1"; Import-Module $mp -Force } catch { Write-Error "..."; exit 1 } finally { $ErrorActionPreference = "Continue" }; Write-Host "..."; Write-Host $('-'*50)

# --- 2. Определение тестовых сценариев ---
$baseProcessAssignment = @{
    assignment_id = 400; method_name = 'PROCESS_LIST'; node_name = 'Process Test'; ip_address = $null
    parameters = @{}; success_criteria = $null
}

# *** Результаты зависят от запущенных процессов на машине теста! ***
$testCases = @(
    @{ Name = "Топ 5 по памяти (без критериев)"; Params = @{ sort_by = 'Memory'; sort_descending = $true; top_n = 5 } }
    @{ Name = "Процессы PowerShell (с деталями)"; Params = @{ process_names = @('*powershell*'); include_username = $true; include_path = $true } }
    @{ Name = "Найти svchost (ожидаем >=1)"; Params = @{ process_names = @('svchost') };
       # Критерий: Количество найденных процессов должно быть >= 1
       Criteria = @{ processes=@{_condition_='count';_count_=@{'>='=1}} } }
    @{ Name = "Найти notepad (ожидаем == 0, если не запущен)"; Params = @{ process_names = @('notepad') };
       # Критерий: Количество найденных == 0
       Criteria = @{ processes=@{_condition_='count';_count_=@{'=='=0}} } }
    @{ Name = "Проверить, что НЕТ процесса 'malware.exe'"; Params = $null;
       # Критерий: Ни один процесс не должен соответствовать _where_
       Criteria = @{ processes=@{_condition_='none';_where_=@{name='malware.exe'}} } }
    @{ Name = "Найти хотя бы один процесс с CPU > 10 сек (ANY)"; Params = @{ include_username=$true };
       # Критерий: Хотя бы один процесс (_condition_=any) имеет cpu_seconds > 10
       Criteria = @{ processes=@{_condition_='any';_criteria_=@{cpu_seconds=@{'>'=10.0}}} } }
    @{ Name = "ВСЕ процессы explorer.exe имеют память < 1000 MB (ALL + WHERE)"; Params = $null;
       # Критерий: Все (_condition_=all) процессы, где имя explorer.exe (_where_),
       # должны иметь память < 1000 (_criteria_)
       Criteria = @{ processes=@{_condition_='all'; _where_=@{name='explorer.exe'}; _criteria_=@{memory_ws_mb=@{'<'=1000}}} } }
    @{ Name = "Несуществующий процесс (ожидаем count=0)"; Params = @{ process_names = @('__NoSuchProcess__') };
       Criteria = @{ processes=@{_condition_='count';_count_=@{'=='=0}} } } # Этот критерий должен пройти
    @{ Name = "Ошибка: Неверное поле сортировки"; Params = @{ sort_by = 'InvalidField' } }
)

# --- 3. Выполнение тестов ---
# (Код цикла выполнения без изменений, но с урезанием вывода Details.processes)
$testIdCounter = $baseProcessAssignment.assignment_id
foreach ($testCase in $testCases) {
    $testIdCounter++; $currentAssignment = $baseProcessAssignment.PSObject.Copy()
    $currentAssignment.assignment_id = $testIdCounter; $currentAssignment.node_name = $testCase.Name
    if ($testCase.Params) { $currentAssignment.parameters = $testCase.Params }
    if ($testCase.Criteria) { $currentAssignment.success_criteria = $testCase.Criteria }
    Write-Host "ЗАПУСК: $($currentAssignment.node_name)" -FG Yellow; Write-Host "  Parameters: $($currentAssignment.parameters | ConvertTo-Json -Depth 2 -Compress)"; Write-Host "  SuccessCriteria: $($currentAssignment.success_criteria | ConvertTo-Json -Depth 4 -Compress)"
    $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$currentAssignment)
    Write-Host "РЕЗУЛЬТАТ:"
    $detailsCopy = $result.Details.PSObject.Copy(); if ($detailsCopy.processes -is [System.Collections.Generic.List[object]] -and $detailsCopy.processes.Count -gt 5) { $detailsCopy.processes = $detailsCopy.processes | Select -First 5; $detailsCopy.Add('processes_truncated', $true) }
    $resultOutput = $result.PSObject.Copy(); $resultOutput.Details = $detailsCopy
    Write-Host ($resultOutput | ConvertTo-Json -Depth 5) -FG Gray
    if ($result.IsAvailable) { Write-Host "  Доступность: OK" -FG Green } else { Write-Host "  Доступность: FAIL" -FG Red }
    if ($result.CheckSuccess) { Write-Host "  Критерии: PASS" -FG Green } elseif ($result.CheckSuccess -eq $false) { Write-Host "  Критерии: FAIL" -FG Red } else { Write-Host "  Критерии: N/A" -FG Yellow }
    if ($result.ErrorMessage) { Write-Host "  Ошибка: $($result.ErrorMessage)" -FG Magenta }
    Write-Host ("-"*50); Start-Sleep -Milliseconds 500
}
Write-Host "Ручное тестирование PROCESS_LIST завершено."