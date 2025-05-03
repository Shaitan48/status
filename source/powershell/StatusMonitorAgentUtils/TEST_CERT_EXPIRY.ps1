Import-Module .\StatusMonitorAgentUtils.psd1 -Force -ErrorAction Stop

# 1. Найти все SSL-сертификаты сервера в LocalMachine\My и проверить, что осталось > 14 дней
$certAssignment1 = @{
    assignment_id = 501; method_name = 'CERT_EXPIRY'; node_name = 'Local SSL Certs (>14d)'
    ip_address = $null
    parameters = @{
        store_location = 'LocalMachine'
        store_name = 'My'
        eku_oid = @('1.3.6.1.5.5.7.3.1') # Server Authentication OID
        require_private_key = $true
        min_days_warning = 30 # Предупреждать за 30 дней
    }
    success_criteria = @{
        min_days_left = 14 # Должно оставаться > 14 дней
    }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$certAssignment1) | ConvertTo-Json -Depth 4

# 2. Найти конкретный сертификат по отпечатку и проверить, что осталось > 60 дней
# ЗАМЕНИ 'YOUR_CERT_THUMBPRINT_HERE' на реальный отпечаток существующего сертификата
$thumbprintToTest = 'YOUR_CERT_THUMBPRINT_HERE'
$certAssignment2 = @{
    assignment_id = 502; method_name = 'CERT_EXPIRY'; node_name = "Cert by Thumbprint ($($thumbprintToTest.Substring(0,8))... >60d)"
    ip_address = $null
    parameters = @{
        store_location = 'LocalMachine'
        store_name = 'My'
        thumbprint = $thumbprintToTest
    }
    success_criteria = @{
        min_days_left = 60
    }
}
if ($thumbprintToTest -ne 'YOUR_CERT_THUMBPRINT_HERE') {
    Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$certAssignment2) | ConvertTo-Json -Depth 4
} else { Write-Warning "Тест 2 пропущен: Замените YOUR_CERT_THUMBPRINT_HERE на реальный отпечаток." }


# 3. Найти сертификаты, выданные определенным CA (например, внутренним)
$issuerPattern = "*MyInternalCA*" # Замените на часть имени вашего CA
$certAssignment3 = @{
    assignment_id = 503; method_name = 'CERT_EXPIRY'; node_name = "Certs from $issuerPattern (>3d)"
    ip_address = $null
    parameters = @{
        store_location = 'LocalMachine'
        store_name = 'My'
        issuer_like = $issuerPattern
    }
    success_criteria = @{
        min_days_left = 3
    }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$certAssignment3) | ConvertTo-Json -Depth 4

# 4. Тест с ошибкой: Неверное хранилище
$certAssignment4 = @{
    assignment_id = 504; method_name = 'CERT_EXPIRY'; node_name = 'Invalid Store'
    ip_address = $null
    parameters = @{ store_location = 'InvalidPlace'; store_name = 'My' }
    success_criteria = @{ min_days_left = 1 }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$certAssignment4) | ConvertTo-Json -Depth 4

# 5. Тест с ошибкой: Отсутствует обязательный критерий
$certAssignment5 = @{
    assignment_id = 505; method_name = 'CERT_EXPIRY'; node_name = 'Missing Criteria'
    ip_address = $null
    parameters = @{ thumbprint = $thumbprintToTest }
    success_criteria = @{ } # Пустой критерий
}
if ($thumbprintToTest -ne 'YOUR_CERT_THUMBPRINT_HERE') {
    Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$certAssignment5) | ConvertTo-Json -Depth 4
} else { Write-Warning "Тест 5 пропущен: Замените YOUR_CERT_THUMBPRINT_HERE." }