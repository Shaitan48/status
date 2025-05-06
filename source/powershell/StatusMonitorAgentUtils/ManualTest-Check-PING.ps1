# ManualTest-Check-PING.ps1 (v2.1)
# Скрипт для ручного тестирования Check-PING.ps1 через диспетчер

    

# --- 1. Загрузка модуля Utils ---
$ErrorActionPreference = "Stop"
try {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "StatusMonitorAgentUtils.psd1"
    Write-Host "Загрузка модуля из '$modulePath'..." -ForegroundColor Cyan
    Import-Module $modulePath -Force
    Write-Host "Модуль загружен." -ForegroundColor Green
} catch { Write-Error "Критическая ошибка загрузки модуля Utils: $($_.Exception.Message)"; exit 1 } finally { $ErrorActionPreference = "Continue" }
Write-Host $('-'*50)

# --- 2. Определение тестовых сценариев ---
$basePingAssignment = @{
    assignment_id = 200; method_name = 'PING'; node_name = 'Ping Test'
    parameters = @{}; success_criteria = $null
}

$testCases = @(
    @{ Name = "Успешный пинг localhost (без критериев)"; Target = '127.0.0.1'; Params = @{ count = 1 } }
    @{ Name = "Неуспешный пинг (несущ. IP)"; Target = '192.0.2.1'; Params = @{ timeout_ms = 500; count = 1 } }
    @{ Name = "Успешный пинг ya.ru (RTT <= 1000ms)"; Target = 'ya.ru';
       # Критерий: RTT должен быть меньше или равен 1000
       Criteria = @{ rtt_ms = @{ '<=' = 1000 } } }
    @{ Name = "Успешный пинг ya.ru (RTT <= 1ms - НЕ пройдет)"; Target = 'ya.ru';
       # Критерий: RTT должен быть меньше или равен 1 (заведомо ложно)
       Criteria = @{ rtt_ms = @{ '<=' = 1 } } }
    @{ Name = "Успешный пинг ya.ru (Потери == 0%)"; Target = 'ya.ru';
       # Критерий: Процент потерь должен быть равен 0
       Criteria = @{ packet_loss_percent = @{ '==' = 0 } } }
    @{ Name = "Успешный пинг ya.ru (Потери < 50% - пройдет)"; Target = 'ya.ru'; Params = @{ count = 4 };
       # Критерий: Процент потерь должен быть меньше 50
       Criteria = @{ packet_loss_percent = @{ '<' = 50 } } }
    @{ Name = "Успешный пинг ya.ru (RTT > 10ms И Потери < 50%)"; Target = 'ya.ru'; Params = @{ count = 4 };
       # Критерий: Оба условия должны выполниться
       Criteria = @{ rtt_ms=@{'>'=10}; packet_loss_percent=@{'<'=50} } }
    @{ Name = "Ошибка: Некорректный критерий (не число)"; Target = 'ya.ru';
       # Критерий: Некорректное значение порога
       Criteria = @{ rtt_ms=@{'>'='abc'} } }
)

# --- 3. Выполнение тестов ---
# (Код цикла выполнения без изменений, как в предыдущем ответе)
$testIdCounter = $basePingAssignment.assignment_id
foreach ($testCase in $testCases) {
    $testIdCounter++
    $currentAssignment = $basePingAssignment.PSObject.Copy()
    $currentAssignment.assignment_id = $testIdCounter; $currentAssignment.node_name = $testCase.Name; $currentAssignment.ip_address = $testCase.Target
    if ($testCase.Params) { $currentAssignment.parameters = $testCase.Params }
    if ($testCase.Criteria) { $currentAssignment.success_criteria = $testCase.Criteria }

    Write-Host "ЗАПУСК: $($currentAssignment.node_name)" -ForegroundColor Yellow
    Write-Host "  Target: $($currentAssignment.ip_address)"
    Write-Host "  Parameters: $($currentAssignment.parameters | ConvertTo-Json -Depth 2 -Compress)"
    Write-Host "  SuccessCriteria: $($currentAssignment.success_criteria | ConvertTo-Json -Depth 3 -Compress)"

    $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$currentAssignment)
    Write-Host "РЕЗУЛЬТАТ:"; Write-Host ($result | ConvertTo-Json -Depth 4) -ForegroundColor Gray
    if ($result.IsAvailable) { Write-Host "  Доступность: OK" -FG Green } else { Write-Host "  Доступность: FAIL" -FG Red }
    if ($result.CheckSuccess) { Write-Host "  Критерии: PASS" -FG Green } elseif ($result.CheckSuccess -eq $false) { Write-Host "  Критерии: FAIL" -FG Red } else { Write-Host "  Критерии: N/A" -FG Yellow }
    if ($result.ErrorMessage) { Write-Host "  Ошибка: $($result.ErrorMessage)" -FG Magenta }
    Write-Host ("-"*50); Start-Sleep -Seconds 1
}
Write-Host "Ручное тестирование PING завершено."