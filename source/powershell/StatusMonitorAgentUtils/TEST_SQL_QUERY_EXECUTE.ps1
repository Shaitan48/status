Import-Module .\StatusMonitorAgentUtils.psd1 -Force -ErrorAction Stop

# Замени на свои значения
$server = "YOUR_SERVER\YOUR_INSTANCE"
$db = "YourDatabaseName"
$tableName = "YourTableName" # Таблица с какими-нибудь данными

# 1. Получить первую строку
$sqlAssignment1 = @{
    assignment_id = 701; method_name = 'SQL_QUERY_EXECUTE'; node_name = "SQL First Row Test"
    ip_address = $server
    parameters = @{
        sql_database = $db
        sql_query = "SELECT TOP 1 * FROM $tableName"
        return_format = 'first_row'
    }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$sqlAssignment1) | ConvertTo-Json -Depth 4

# 2. Получить все строки (ОСТОРОЖНО, если строк много!)
$sqlAssignment2 = @{
    assignment_id = 702; method_name = 'SQL_QUERY_EXECUTE'; node_name = "SQL All Rows Test"
    ip_address = $server
    parameters = @{
        sql_database = $db
        sql_query = "SELECT Id, Name FROM $tableName WHERE Id < 10" # Пример с WHERE
        return_format = 'all_rows'
    }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$sqlAssignment2) | ConvertTo-Json -Depth 4

# 3. Получить количество строк
$sqlAssignment3 = @{
    assignment_id = 703; method_name = 'SQL_QUERY_EXECUTE'; node_name = "SQL Row Count Test"
    ip_address = $server
    parameters = @{
        sql_database = $db
        sql_query = "SELECT Id FROM $tableName" # Достаточно одного столбца для подсчета
        return_format = 'row_count'
    }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$sqlAssignment3) | ConvertTo-Json -Depth 4

# 4. Получить скалярное значение (имя первой записи)
$sqlAssignment4 = @{
    assignment_id = 704; method_name = 'SQL_QUERY_EXECUTE'; node_name = "SQL Scalar Test"
    ip_address = $server
    parameters = @{
        sql_database = $db
        sql_query = "SELECT TOP 1 Name FROM $tableName ORDER BY Id"
        return_format = 'scalar'
    }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$sqlAssignment4) | ConvertTo-Json -Depth 4

# 5. Выполнить Non-Query (например, создать временную таблицу) - ОСТОРОЖНО!
$sqlAssignment5 = @{
    assignment_id = 705; method_name = 'SQL_QUERY_EXECUTE'; node_name = "SQL Non-Query Test"
    ip_address = $server
    parameters = @{
        sql_database = $db
        sql_query = "IF OBJECT_ID('tempdb..#TestTempTable') IS NULL CREATE TABLE #TestTempTable (Id INT);" # Пример безопасного non-query
        return_format = 'non_query'
    }
}
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$sqlAssignment5) | ConvertTo-Json -Depth 4

# 6. Ошибка - неверная БД
$sqlAssignment6 = $sqlAssignment1.PSObject.Copy()
$sqlAssignment6.assignment_id = 706
$sqlAssignment6.node_name = "SQL Error - Bad DB"
$sqlAssignment6.parameters.sql_database = "NonExistentDatabase"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$sqlAssignment6) | ConvertTo-Json -Depth 4