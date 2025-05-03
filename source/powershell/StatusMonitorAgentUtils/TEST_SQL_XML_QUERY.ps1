Import-Module .\StatusMonitorAgentUtils.psd1 -Force -ErrorAction Stop

# Замени на свои значения
$server = "YOUR_SERVER\YOUR_INSTANCE" # Или просто "YOUR_SERVER"
$db = "YourDatabaseName"
$query = "SELECT TOP 1 CreationDate, Revise, id, UTCTime FROM YourTable WHERE id = 12345" # Пример запроса
$xmlCol = "Revise"
$keys = @("VersionStat", "ArrivalStationID", "TS_Version", "NonExistentKey")

$sqlAssignment = @{
    assignment_id = 601
    method_name   = 'SQL_XML_QUERY'
    node_name     = "SQL Query Test ($db)"
    ip_address    = $server # Передаем сервер как TargetIP
    parameters    = @{
        sql_database = $db
        sql_query = $query
        xml_column_name = $xmlCol
        keys_to_extract = $keys
        # sql_username = "your_sql_user" # Раскомментируй для SQL Auth
        # sql_password = "your_sql_password" # Раскомментируй для SQL Auth
    }
    success_criteria = $null # Пока не используем
}

Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$sqlAssignment) | ConvertTo-Json -Depth 5

# --- Тест с ошибкой (неверное имя столбца) ---
$sqlAssignmentError = $sqlAssignment.PSObject.Copy()
$sqlAssignmentError.parameters.xml_column_name = 'InvalidColumnName'
$sqlAssignmentError.assignment_id = 602
$sqlAssignmentError.node_name = "SQL Error Test (Bad Column)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$sqlAssignmentError) | ConvertTo-Json -Depth 5

# --- Тест с ошибкой (неверный SQL) ---
$sqlAssignmentError2 = $sqlAssignment.PSObject.Copy()
$sqlAssignmentError2.parameters.sql_query = 'SELECT * FRO Arom InvalidTable'
$sqlAssignmentError2.assignment_id = 603
$sqlAssignmentError2.node_name = "SQL Error Test (Bad Query)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$sqlAssignmentError2) | ConvertTo-Json -Depth 5