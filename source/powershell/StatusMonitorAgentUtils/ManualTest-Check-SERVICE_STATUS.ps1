# ManualTest-Check-SERVICE_STATUS.ps1 (v2.1)
# Скрипт для ручного тестирования Check-SERVICE_STATUS.ps1 через диспетчер

# --- 1. Загрузка модуля Utils ---
# (Код загрузки модуля без изменений)
$ErrorActionPreference = "Stop"; try { $mp=Join-Path $PSScriptRoot "StatusMonitorAgentUtils.psd1"; Import-Module $mp -Force } catch { Write-Error "..."; exit 1 } finally { $ErrorActionPreference = "Continue" }; Write-Host "..."; Write-Host $('-'*50)

# --- 2. Определение тестовых сценариев ---
$baseServiceAssignment = @{
    assignment_id = 100; method_name = 'SERVICE_STATUS'; node_name = 'Service Test'; ip_address = $null
    parameters = @{}; success_criteria = $null
}

# *** ВАЖНО: Убедитесь, что службы Spooler и wuauserv существуют на машине, где запускается тест! ***
# *** Состояние служб (Running/Stopped) может влиять на результат тестов с критериями. ***
$testCases = @(
    @{ Name = "Spooler - Без критериев (ожидаем CheckSuccess=true если доступна)"; Service = 'Spooler' }
    @{ Name = "Spooler - Критерий: status = Running"; Service = 'Spooler'; Criteria = @{ status = 'Running' } }
    @{ Name = "Spooler - Критерий: status = Stopped (ожидаем FAIL если работает)"; Service = 'Spooler'; Criteria = @{ status = 'Stopped' } }
    @{ Name = "Spooler - Критерий: status != Stopped (ожидаем OK если работает)"; Service = 'Spooler'; Criteria = @{ status = @{'!=' = 'Stopped'} } }
    @{ Name = "Несуществующая служба (ожидаем IsAvailable=false)"; Service = '__NonExistentService__'; Criteria = $null }
    @{ Name = "wuauserv - Критерий: start_type = Manual"; Service = 'wuauserv'; Criteria = @{ start_type = 'Manual' } } # Проверяем тип запуска
    @{ Name = "wuauserv - Критерий: can_stop = true"; Service = 'wuauserv'; Criteria = @{ can_stop = $true } } # Проверяем булево поле
    @{ Name = "Ошибка: Неверный критерий"; Service = 'Spooler'; Criteria = @{ status = @{'invalid_op' = 1} } } # Ожидаем CheckSuccess=null
)

# --- 3. Выполнение тестов ---
# (Код цикла выполнения без изменений)
$testIdCounter = $baseServiceAssignment.assignment_id
foreach ($testCase in $testCases) {
    $testIdCounter++; $currentAssignment = $baseServiceAssignment.PSObject.Copy()
    $currentAssignment.assignment_id = $testIdCounter; $currentAssignment.node_name = $testCase.Name
    $currentAssignment.parameters = @{ service_name = $testCase.Service }
    if ($testCase.Criteria) { $currentAssignment.success_criteria = $testCase.Criteria }
    Write-Host "ЗАПУСК: $($currentAssignment.node_name)" -FG Yellow; Write-Host "  Service: $($currentAssignment.parameters.service_name)"; Write-Host "  SuccessCriteria: $($currentAssignment.success_criteria | ConvertTo-Json -Depth 2 -Compress)"
    $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$currentAssignment)
    Write-Host "РЕЗУЛЬТАТ:"; Write-Host ($result | ConvertTo-Json -Depth 4) -FG Gray
    if ($result.IsAvailable) { Write-Host "  Доступность: OK" -FG Green } else { Write-Host "  Доступность: FAIL" -FG Red }
    if ($result.CheckSuccess) { Write-Host "  Критерии: PASS" -FG Green } elseif ($result.CheckSuccess -eq $false) { Write-Host "  Критерии: FAIL" -FG Red } else { Write-Host "  Критерии: N/A" -FG Yellow }
    if ($result.ErrorMessage) { Write-Host "  Ошибка: $($result.ErrorMessage)" -FG Magenta }
    Write-Host ("-"*50); Start-Sleep -Seconds 1
}
Write-Host "Ручное тестирование SERVICE_STATUS завершено."