Import-Module .\StatusMonitorAgentUtils.psd1 -Force -ErrorAction Stop

# 1. Все процессы, сортировка по памяти (убывание), топ 5
$procAssignment1 = @{
    assignment_id = 401; method_name = 'PROCESS_LIST'; node_name = 'Local Top 5 Mem Proc'
    ip_address = $null
    parameters = @{ sort_by = 'Memory'; sort_descending = $true; top_n = 5; include_username=$false; include_path=$false }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$procAssignment1) | ConvertTo-Json -Depth 4

# 2. Процессы PowerShell с путем и пользователем
$procAssignment2 = @{
    assignment_id = 402; method_name = 'PROCESS_LIST'; node_name = 'Local PS Proc Details'
    ip_address = $null
    parameters = @{ process_names = @('*powershell*'); include_username = $true; include_path = $true }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$procAssignment2) | ConvertTo-Json -Depth 4

# 3. Несуществующий процесс (должен вернуть IsAvailable=true, CheckSuccess=true, пустой список)
$procAssignment3 = @{
    assignment_id = 403; method_name = 'PROCESS_LIST'; node_name = 'Local NonExistent Proc'
    ip_address = $null
    parameters = @{ process_names = @('__NonExistentProcess__') }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$procAssignment3) | ConvertTo-Json -Depth 4

# 4. Тест с некорректным полем сортировки
$procAssignment4 = @{
    assignment_id = 404; method_name = 'PROCESS_LIST'; node_name = 'Invalid Sort'
    ip_address = $null
    parameters = @{ sort_by = 'InvalidField' }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$procAssignment4) | ConvertTo-Json -Depth 4

# 5. Удаленный тест (ожидаем ошибку WinRM -> IsAvailable=false)
$procAssignment5 = @{
    assignment_id = 405; method_name = 'PROCESS_LIST'; node_name = 'Remote Proc Fail'
    ip_address = 'REMOTE_HOST_NAME_NO_WINRM' # Замените на имя хоста без доступа по WinRM
    parameters = @{ top_n = 5 }
}
# Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$procAssignment5) | ConvertTo-Json -Depth 4