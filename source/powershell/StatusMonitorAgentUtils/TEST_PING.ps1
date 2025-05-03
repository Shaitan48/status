# Убедись, что модуль загружен
Import-Module .\StatusMonitorAgentUtils.psd1 -Force -ErrorAction Stop

# 1. Пинг существующего локального адреса (успех)
$pingAssignment1 = @{
    assignment_id = 201; method_name = 'PING'; node_name = 'Localhost Ping'
    ip_address = '127.0.0.1'; parameters = @{ count = 2 }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$pingAssignment1) | ConvertTo-Json -Depth 3

# 2. Пинг несуществующего адреса (ошибка доступности)
$pingAssignment2 = @{
    assignment_id = 202; method_name = 'PING'; node_name = 'Non-existent Ping'
    ip_address = '192.168.254.254'; parameters = @{ timeout_ms = 500 }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$pingAssignment2) | ConvertTo-Json -Depth 3

# 3. Пинг существующего адреса с критерием RTT (успех по критерию)
$pingAssignment3 = @{
    assignment_id = 203; method_name = 'PING'; node_name = 'Gateway Ping OK'
    ip_address = 'ya.ru'; parameters = @{ count = 1 } # Укажи IP своего шлюза
    success_criteria = @{ max_rtt_ms = 500 } # Критерий RTT < 500ms
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$pingAssignment3) | ConvertTo-Json -Depth 3

# 4. Пинг существующего адреса с критерием RTT (неуспех по критерию)
$pingAssignment4 = @{
    assignment_id = 204; method_name = 'PING'; node_name = 'Gateway Ping Fail RTT'
    ip_address = 'ya.ru'; parameters = @{ count = 1 }
    success_criteria = @{ max_rtt_ms = 1 } # Заведомо невыполнимый критерий
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$pingAssignment4) | ConvertTo-Json -Depth 3