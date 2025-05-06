# ManualTest-Check-CERT_EXPIRY.ps1 (v2.1)
# Скрипт для ручного тестирования Check-CERT_EXPIRY.ps1 через диспетчер

# --- 1. Загрузка модуля Utils ---
# (Код загрузки модуля без изменений)
$ErrorActionPreference = "Stop"; try { $mp=Join-Path $PSScriptRoot "StatusMonitorAgentUtils.psd1"; Import-Module $mp -Force } catch { Write-Error "..."; exit 1 } finally { $ErrorActionPreference = "Continue" }; Write-Host "..."; Write-Host $('-'*50)

# --- 2. Определение тестовых сценариев ---
$baseCertAssignment = @{
    assignment_id = 500; method_name = 'CERT_EXPIRY'; node_name = 'Cert Test'; ip_address = $null
    parameters = @{}; success_criteria = $null
}

# --- !!! ВАЖНО: Замените на реальный отпечаток для тестов !!! ---
$existingThumbprint = 'YOUR_CERT_THUMBPRINT_HERE' # Найдите отпечаток в certlm.msc -> Личное -> Сертификаты

$testCases = @(
    @{ Name = "Все SSL серт. сервера (>14 дней)";
       Params = @{ eku_oid = @('1.3.6.1.5.5.7.3.1'); require_private_key = $true; min_days_warning = 30 };
       # Критерий: Для ВСЕХ сертификатов в результате, поле days_left > 14
       Criteria = @{ certificates=@{_condition_='all';_criteria_=@{days_left=@{'>'=14}}} } }
    @{ Name = "Конкретный отпечаток (>60 дней)";
       Params = @{ thumbprint = $existingThumbprint };
       # Критерий: Для ВСЕХ сертификатов, где thumbprint совпадает, поле days_left > 60
       Criteria = @{ certificates=@{_condition_='all';_where_=@{thumbprint=$existingThumbprint};_criteria_=@{days_left=@{'>'=60}}} } }
    @{ Name = "Конкретный отпечаток (Fail < 10000 дней)";
       Params = @{ thumbprint = $existingThumbprint };
       # Критерий: Для ВСЕХ сертификатов, где thumbprint совпадает, поле days_left < 10000 (должен НЕ пройти)
       Criteria = @{ certificates=@{_condition_='all';_where_=@{thumbprint=$existingThumbprint};_criteria_=@{days_left=@{'<'=10000}}} } }
    @{ Name = "Сертификаты от Let's Encrypt (>0 дней)";
       Params = @{ issuer_like = "*Let's Encrypt*" };
       # Критерий: Для ВСЕХ сертификатов от LE, поле days_left > 0
       Criteria = @{ certificates=@{_condition_='all';_where_=@{issuer=@{'contains'="Let's Encrypt"}};_criteria_=@{days_left=@{'>'=0}}} } } # Используем contains
    @{ Name = "Хотя бы один сертификат истекает менее чем через 90 дней (ANY)";
       Params = @{ require_private_key = $true };
       # Критерий: Найти ХОТЯ БЫ ОДИН сертификат, где days_left < 90
       Criteria = @{ certificates=@{_condition_='any';_criteria_=@{days_left=@{'<'=90}}} } }
    @{ Name = "Ошибка: Неверное хранилище";
       Params = @{ store_location = 'InvalidPlace'; store_name = 'My' }; Criteria = $null }
    @{ Name = "Ошибка: Неверный OID";
       Params = @{ eku_oid = @('invalid-oid') }; Criteria = $null }
)

# --- 3. Выполнение тестов ---
# (Код цикла выполнения без изменений, но с проверкой плейсхолдера)
$testIdCounter = $baseCertAssignment.assignment_id
foreach ($testCase in $testCases) {
    if (($testCase.Params.thumbprint -eq 'YOUR_CERT_THUMBPRINT_HERE') -or ($testCase.Criteria -and $testCase.Criteria.certificates -and $testCase.Criteria.certificates._where_ -and $testCase.Criteria.certificates._where_.thumbprint -eq 'YOUR_CERT_THUMBPRINT_HERE')) { Write-Warning "...Пропуск..."; Write-Host ("-"*50); continue }
    $testIdCounter++; $currentAssignment = $baseCertAssignment.PSObject.Copy()
    $currentAssignment.assignment_id = $testIdCounter; $currentAssignment.node_name = $testCase.Name
    if ($testCase.Params) { $currentAssignment.parameters = $testCase.Params }
    if ($testCase.Criteria) { $currentAssignment.success_criteria = $testCase.Criteria }
    Write-Host "ЗАПУСК: $($currentAssignment.node_name)" -FG Yellow; Write-Host "  Parameters: $($currentAssignment.parameters | ConvertTo-Json -Depth 3 -Compress)"; Write-Host "  SuccessCriteria: $($currentAssignment.success_criteria | ConvertTo-Json -Depth 4 -Compress)"
    $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$currentAssignment)
    Write-Host "РЕЗУЛЬТАТ:"
    $detailsCopy = $result.Details.PSObject.Copy(); if ($detailsCopy.certificates -is [System.Collections.Generic.List[object]] -and $detailsCopy.certificates.Count -gt 3) { $detailsCopy.certificates = $detailsCopy.certificates | Select-Object -First 3; $detailsCopy.Add('certificates_truncated', $true) }
    $resultOutput = $result.PSObject.Copy(); $resultOutput.Details = $detailsCopy
    Write-Host ($resultOutput | ConvertTo-Json -Depth 5) -FG Gray
    if ($result.IsAvailable) { Write-Host "  Доступность: OK" -FG Green } else { Write-Host "  Доступность: FAIL" -FG Red }
    if ($result.CheckSuccess) { Write-Host "  Критерии: PASS" -FG Green } elseif ($result.CheckSuccess -eq $false) { Write-Host "  Критерии: FAIL" -FG Red } else { Write-Host "  Критерии: N/A" -FG Yellow }
    if ($result.ErrorMessage) { Write-Host "  Ошибка: $($result.ErrorMessage)" -FG Magenta }
    Write-Host ("-"*50); Start-Sleep -Milliseconds 500
}
Write-Host "Ручное тестирование CERT_EXPIRY завершено."