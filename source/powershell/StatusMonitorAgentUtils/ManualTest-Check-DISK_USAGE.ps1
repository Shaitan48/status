# ManualTest-Check-DISK_USAGE.ps1 (v2.1)
# Скрипт для ручного тестирования Check-DISK_USAGE.ps1 через диспетчер

# --- 1. Загрузка модуля Utils ---
# (Код загрузки модуля без изменений)
$ErrorActionPreference = "Stop"; try { $mp=Join-Path $PSScriptRoot "StatusMonitorAgentUtils.psd1"; Import-Module $mp -Force } catch { Write-Error "..."; exit 1 } finally { $ErrorActionPreference = "Continue" }; Write-Host "..."; Write-Host $('-'*50)

# --- 2. Определение тестовых сценариев ---
$baseDiskAssignment = @{
    assignment_id = 300; method_name = 'DISK_USAGE'; node_name = 'Disk Test'; ip_address = $null
    parameters = $null; success_criteria = $null
}

# *** ВАЖНО: Результаты зависят от состояния дисков на машине, где запускается тест! ***
$testCases = @(
    @{ Name = "Все диски (без критериев)"; Params = $null; Criteria = $null }
    @{ Name = "Только диск C: (без критериев)"; Params = @{ drives = @('C') }; Criteria = $null }
    @{ Name = "Диск C: > 5% свободно (OK?)"; Params = @{ drives = @('C') };
       # Критерий: Для массива 'disks', где drive_letter='C', поле percent_free должно быть >= 5
       Criteria = @{ disks=@{_condition_='all'; _where_=@{drive_letter='C'}; _criteria_=@{percent_free=@{'>='=5}}} } }
    @{ Name = "Диск C: > 99% свободно (FAIL?)"; Params = @{ drives = @('C') };
       # Критерий: Для C: % свободно > 99 (скорее всего не пройдет)
       Criteria = @{ disks=@{_condition_='all'; _where_=@{drive_letter='C'}; _criteria_=@{percent_free=@{'>'=99}}} } }
    @{ Name = "Все диски: > 1% свободно (OK?)"; Params = $null;
       # Критерий: Для ВСЕХ дисков в массиве 'disks', % свободно > 1
       Criteria = @{ disks=@{_condition_='all'; _criteria_=@{percent_free=@{'>'=1}}} } }
    @{ Name = "Хотя бы один диск < 10% свободно (ANY + <)"; Params = $null;
        # Критерий: Найти ХОТЯ БЫ ОДИН диск, где % свободно < 10
       Criteria = @{ disks=@{_condition_='any'; _criteria_=@{percent_free=@{'<'=10}}} } }
    @{ Name = "Все диски > 0 байт свободно"; Params = $null;
       # Критерий: Проверить, что у всех free_bytes > 0
       Criteria = @{ disks=@{_condition_='all'; _criteria_=@{free_bytes=@{'>'=1}}} } } # Используем >=1, т.к. 0 может быть валидным
    @{ Name = "Ошибка: Некорректный оператор в критерии"; Params = @{drives=@('C')};
       Criteria = @{ disks=@{_condition_='all'; _where_=@{drive_letter='C'}; _criteria_=@{percent_free=@{'bad_op'=10}}} } }
)

# --- 3. Выполнение тестов ---
# (Код цикла выполнения без изменений)
$testIdCounter = $baseDiskAssignment.assignment_id
foreach ($testCase in $testCases) {
    $testIdCounter++; $currentAssignment = $baseDiskAssignment.PSObject.Copy()
    $currentAssignment.assignment_id = $testIdCounter; $currentAssignment.node_name = $testCase.Name
    if ($testCase.Params) { $currentAssignment.parameters = $testCase.Params }
    if ($testCase.Criteria) { $currentAssignment.success_criteria = $testCase.Criteria }
    Write-Host "ЗАПУСК: $($currentAssignment.node_name)" -FG Yellow; Write-Host "  Parameters: $($currentAssignment.parameters | ConvertTo-Json -Depth 2 -Compress)"; Write-Host "  SuccessCriteria: $($currentAssignment.success_criteria | ConvertTo-Json -Depth 4 -Compress)"
    $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$currentAssignment)
    Write-Host "РЕЗУЛЬТАТ:"; Write-Host ($result | ConvertTo-Json -Depth 5) -FG Gray
    if ($result.IsAvailable) { Write-Host "  Доступность: OK" -FG Green } else { Write-Host "  Доступность: FAIL" -FG Red }
    if ($result.CheckSuccess) { Write-Host "  Критерии: PASS" -FG Green } elseif ($result.CheckSuccess -eq $false) { Write-Host "  Критерии: FAIL" -FG Red } else { Write-Host "  Критерии: N/A" -FG Yellow }
    if ($result.ErrorMessage) { Write-Host "  Ошибка: $($result.ErrorMessage)" -FG Magenta }
    Write-Host ("-"*50); Start-Sleep -Seconds 1
}
Write-Host "Ручное тестирование DISK_USAGE завершено."