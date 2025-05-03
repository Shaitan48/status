# Убедись, что модуль загружен
Import-Module .\StatusMonitorAgentUtils.psd1 -Force -ErrorAction Stop

# 1. Проверка всех локальных дисков без критериев
$diskAssignment1 = @{ assignment_id = 301; method_name = 'DISK_USAGE'; node_name = 'Local Disk Usage'; ip_address = $null; parameters = $null; success_criteria = $null }
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$diskAssignment1) | ConvertTo-Json -Depth 5

# 2. Проверка только диска C: без критериев
$diskAssignment2 = @{ assignment_id = 302; method_name = 'DISK_USAGE'; node_name = 'Local Disk C Usage'; ip_address = $null; parameters = @{ drives = @('C') }; success_criteria = $null }
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$diskAssignment2) | ConvertTo-Json -Depth 5

# 3. Проверка диска C: с критерием > 5% свободно (скорее всего, пройдет)
$diskAssignment3 = @{ assignment_id = 303; method_name = 'DISK_USAGE'; node_name = 'Local Disk C OK'; ip_address = $null; parameters = @{ drives = @('C') }; success_criteria = @{ C = @{ min_percent_free = 5 } } }
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$diskAssignment3) | ConvertTo-Json -Depth 5

# 4. Проверка диска C: с заведомо невыполнимым критерием (> 99% свободно)
$diskAssignment4 = @{ assignment_id = 304; method_name = 'DISK_USAGE'; node_name = 'Local Disk C Fail'; ip_address = $null; parameters = @{ drives = @('C') }; success_criteria = @{ C = @{ min_percent_free = 99 } } }
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$diskAssignment4) | ConvertTo-Json -Depth 5

# 5. Проверка всех дисков с дефолтным критерием > 1%
$diskAssignment5 = @{ assignment_id = 305; method_name = 'DISK_USAGE'; node_name = 'Local All Disks Default OK'; ip_address = $null; parameters = $null; success_criteria = @{ _default_ = @{ min_percent_free = 1 } } }
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$diskAssignment5) | ConvertTo-Json -Depth 5

# 6. Проверка всех дисков, где для C: >99%, для остальных >1% (C: провалится)
$diskAssignment6 = @{ assignment_id = 306; method_name = 'DISK_USAGE'; node_name = 'Local All Disks C Fail Rest OK'; ip_address = $null; parameters = $null; success_criteria = @{ C = @{ min_percent_free = 99 }; _default_ = @{ min_percent_free = 1 } } }
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$diskAssignment6) | ConvertTo-Json -Depth 5

# 7. Тест с некорректным критерием
$diskAssignment7 = @{ assignment_id = 307; method_name = 'DISK_USAGE'; node_name = 'Invalid Criteria'; ip_address = $null; parameters = @{ drives = @('C') }; success_criteria = @{ C = @{ min_percent_free = 'десять' } } }
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$diskAssignment7) | ConvertTo-Json -Depth 5