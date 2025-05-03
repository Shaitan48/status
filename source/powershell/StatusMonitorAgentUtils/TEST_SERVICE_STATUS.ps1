Remove-Module StatusMonitorAgentUtils -Force -ErrorAction SilentlyContinue
Import-Module .\StatusMonitorAgentUtils.psd1 -Force -Verbose

$testAssignment = [PSCustomObject]@{
    assignment_id = 123; method_name = 'SERVICE_STATUS'; ip_address = $null
    node_name = 'Локальный Тест'; parameters = @{ service_name = 'Spooler' }
    success_criteria = @{ status = 'Running' }
}
Invoke-StatusMonitorCheck -Assignment $testAssignment | ConvertTo-Json -Depth 4

$testAssignment.parameters.service_name = 'NonExistentService'
Invoke-StatusMonitorCheck -Assignment $testAssignment | ConvertTo-Json -Depth 4

$testAssignment.parameters.service_name = 'Spooler'
$testAssignment.success_criteria = @{ status = 'Stopped' }
Invoke-StatusMonitorCheck -Assignment $testAssignment | ConvertTo-Json -Depth 4