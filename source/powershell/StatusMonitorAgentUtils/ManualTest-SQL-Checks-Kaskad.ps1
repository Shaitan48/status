# F:\status\source\powershell\StatusMonitorAgentUtils\ManualTest-SQL-Checks-Kaskad.ps1
# --- Скрипт для ручного тестирования SQL-проверок на базе testDB_kaskad ---

# --- 1. Загрузка модуля Utils ---
$ErrorActionPreference = "Stop" # Прерывать выполнение при ошибке
try {
    # Путь к манифесту модуля относительно ЭТОГО скрипта
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "StatusMonitorAgentUtils.psd1"
    Write-Host "INFO: Загрузка модуля из '$modulePath'..." -ForegroundColor Cyan
    Import-Module $modulePath -Force
    Write-Host "INFO: Модуль StatusMonitorAgentUtils загружен." -ForegroundColor Green
} catch {
    Write-Error "КРИТИЧЕСКАЯ ОШИБКА: Не удалось загрузить модуль Utils: $($_.Exception.Message)"
    exit 1
} finally {
    $ErrorActionPreference = "Continue" # Возвращаем стандартное поведение
}
Write-Host "INFO: Проверка наличия команды Invoke-StatusMonitorCheck:"
Get-Command Invoke-StatusMonitorCheck -ErrorAction SilentlyContinue | Format-Table Name, ModuleName -AutoSize
Write-Host "INFO: Проверка наличия команды Invoke-Sqlcmd:"
Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue | Format-Table Name, ModuleName -AutoSize
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Warning "Модуль SqlServer не найден или не загружен. SQL-проверки не будут работать."
    # Можно добавить: Install-Module SqlServer -Force -Scope CurrentUser; Import-Module SqlServer
    # exit 1 # Или прервать выполнение
}
Write-Host $('-'*80)

# --- 2. Параметры подключения к тестовой БД ---
# Имя инстанса SQL Server с нестандартным портом
$TestSqlServerInstance = "localhost,48010"
$TestDatabaseName = "kaskad"
# Для SQL аутентификации (раскомментировать и использовать при необходимости)
$TestSqlUsername = "sa"
$TestSqlPassword = "escort123"

Write-Host "ПАРАМЕТРЫ ТЕСТОВОЙ БД:"
Write-Host "  Сервер: $TestSqlServerInstance"
Write-Host "  База:   $TestDatabaseName"
# if ($TestSqlUsername) { Write-Host "  Режим:  SQL Auth ($TestSqlUsername)" }
# else { Write-Host "  Режим:  Windows Auth" }
Write-Host $('-'*80)

# --- 3. Базовый объект Задания (для копирования) ---
$baseAssignment = @{
    assignment_id = 9000 # Начальный ID
    method_name   = ''     # Будет заменен
    node_name     = "Kaskad DB Test"
    ip_address    = $TestSqlServerInstance # Сервер передаем как IP/Host
    parameters    = @{}  # Будут добавлены
    success_criteria = $null # Будет добавлен при необходимости
}

# ==============================================================================
# === ТЕСТЫ ДЛЯ Check-SQL_QUERY_EXECUTE.ps1 ===
# ==============================================================================
Write-Host "НАЧАЛО ТЕСТОВ: Check-SQL_QUERY_EXECUTE" -ForegroundColor Yellow
Write-Host $('-'*80)

# --- Тест 1: first_row (успех) ---
$assignment1 = $baseAssignment.PSObject.Copy()
$assignment1.assignment_id += 1
$assignment1.method_name = 'SQL_QUERY_EXECUTE'
$assignment1.node_name = "SQL Execute: First Row (Success)"
$assignment1.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT TOP 1 id, CreationDate, Revise FROM dbo.ReviseData WHERE id = 1115" # Запрос существующей записи
    return_format = 'first_row'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword

    
}
Write-Host "ЗАПУСК: $($assignment1.node_name)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment1) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 2: all_rows (успех, ожидаем 1 строку) ---
$assignment2 = $baseAssignment.PSObject.Copy()
$assignment2.assignment_id += 2
$assignment2.method_name = 'SQL_QUERY_EXECUTE'
$assignment2.node_name = "SQL Execute: All Rows (Success, 1 row)"
$assignment2.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT id, CreationDate FROM dbo.ReviseData WHERE id = 1115" # Только 2 столбца
    return_format = 'all_rows'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword

}
Write-Host "ЗАПУСК: $($assignment2.node_name)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment2) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 3: row_count (успех, ожидаем 1) ---
$assignment3 = $baseAssignment.PSObject.Copy()
$assignment3.assignment_id += 3
$assignment3.method_name = 'SQL_QUERY_EXECUTE'
$assignment3.node_name = "SQL Execute: Row Count (Success, expects 1)"
$assignment3.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT id FROM dbo.ReviseData" # Считаем все строки (должна быть 1)
    return_format = 'row_count'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment3.node_name)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment3) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 4: scalar (успех, получаем ID) ---
$assignment4 = $baseAssignment.PSObject.Copy()
$assignment4.assignment_id += 4
$assignment4.method_name = 'SQL_QUERY_EXECUTE'
$assignment4.node_name = "SQL Execute: Scalar (Success, get ID)"
$assignment4.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT TOP 1 id FROM dbo.ReviseData ORDER BY CreationDate DESC"
    return_format = 'scalar'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment4.node_name)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment4) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 5: non_query (успех, временная таблица) ---
$assignment5 = $baseAssignment.PSObject.Copy()
$assignment5.assignment_id += 5
$assignment5.method_name = 'SQL_QUERY_EXECUTE'
$assignment5.node_name = "SQL Execute: Non-Query (Success, temp table)"
$assignment5.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "IF OBJECT_ID('tempdb..#TempTestExec') IS NULL BEGIN CREATE TABLE #TempTestExec(col1 INT) END;"
    return_format = 'non_query'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment5.node_name)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment5) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 6: Ошибка SQL (неверное имя таблицы) ---
$assignment6 = $baseAssignment.PSObject.Copy()
$assignment6.assignment_id += 6
$assignment6.method_name = 'SQL_QUERY_EXECUTE'
$assignment6.node_name = "SQL Execute: SQL Error (Bad Table)"
$assignment6.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT * FROM dbo.NonExistentTable"
    return_format = 'first_row'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment6.node_name) (Ожидаем IsAvailable=false)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment6) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 7: Ошибка подключения (неверное имя БД) ---
$assignment7 = $baseAssignment.PSObject.Copy()
$assignment7.assignment_id += 7
$assignment7.method_name = 'SQL_QUERY_EXECUTE'
$assignment7.node_name = "SQL Execute: Connection Error (Bad DB)"
$assignment7.parameters = @{
    sql_database = "NonExistentKaskadDB" # Неверная БД
    sql_query = "SELECT 1"
    return_format = 'scalar'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment7.node_name) (Ожидаем IsAvailable=false)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment7) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 8: row_count с критерием (успех) ---
$assignment8 = $baseAssignment.PSObject.Copy()
$assignment8.assignment_id += 8
$assignment8.method_name = 'SQL_QUERY_EXECUTE'
$assignment8.node_name = "SQL Execute: Row Count with Criteria (Success)"
$assignment8.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT id FROM dbo.ReviseData WHERE id = 1115" # 1 строка
    return_format = 'row_count'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
# Критерий: количество строк должно быть равно 1
$assignment8.success_criteria = @{ row_count = @{ '==' = 1 } }
Write-Host "ЗАПУСК: $($assignment8.node_name) (Ожидаем CheckSuccess=true)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment8) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 9: row_count с критерием (неуспех) ---
$assignment9 = $baseAssignment.PSObject.Copy()
$assignment9.assignment_id += 9
$assignment9.method_name = 'SQL_QUERY_EXECUTE'
$assignment9.node_name = "SQL Execute: Row Count with Criteria (Fail)"
$assignment9.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT id FROM dbo.ReviseData" # 1 строка
    return_format = 'row_count'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
# Критерий: количество строк должно быть БОЛЬШЕ 5
$assignment9.success_criteria = @{ row_count = @{ '>' = 5 } }
Write-Host "ЗАПУСК: $($assignment9.node_name) (Ожидаем CheckSuccess=false)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment9) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 10: scalar с критерием (успех) ---
$assignment10 = $baseAssignment.PSObject.Copy()
$assignment10.assignment_id += 10
$assignment10.method_name = 'SQL_QUERY_EXECUTE'
$assignment10.node_name = "SQL Execute: Scalar with Criteria (Success)"
$assignment10.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT COUNT(*) FROM dbo.ReviseData" # Получаем кол-во
    return_format = 'scalar'
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
# Критерий: скалярное значение (кол-во) должно быть >= 1
$assignment10.success_criteria = @{ scalar_value = @{ '>=' = 1 } }
Write-Host "ЗАПУСК: $($assignment10.node_name) (Ожидаем CheckSuccess=true)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment10) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

Write-Host "КОНЕЦ ТЕСТОВ: Check-SQL_QUERY_EXECUTE" -ForegroundColor Green
Write-Host $('='*80)
Write-Host ""

# ==============================================================================
# === ТЕСТЫ ДЛЯ Check-SQL_XML_QUERY.ps1 ===
# ==============================================================================
Write-Host "НАЧАЛО ТЕСТОВ: Check-SQL_XML_QUERY" -ForegroundColor Yellow
Write-Host $('-'*80)

# --- Тест 11: Успешное извлечение XML и ключей ---
$assignment11 = $baseAssignment.PSObject.Copy()
$assignment11.assignment_id += 11
$assignment11.method_name = 'SQL_XML_QUERY'
$assignment11.node_name = "SQL XML Query: Success"
$assignment11.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT TOP 1 Revise FROM dbo.ReviseData WHERE id = 1115"
    xml_column_name = 'Revise'
    keys_to_extract = @('VersionStat', 'ArrivalStationID', 'TS_Version', 'NonExistentKey')
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment11.node_name) (Ожидаем извлеченные значения и null для NonExistentKey)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment11) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 12: Успешное извлечение с критерием ---
$assignment12 = $baseAssignment.PSObject.Copy()
$assignment12.assignment_id += 12
$assignment12.method_name = 'SQL_XML_QUERY'
$assignment12.node_name = "SQL XML Query: Criteria Success"
$assignment12.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT TOP 1 Revise FROM dbo.ReviseData WHERE id = 1115"
    xml_column_name = 'Revise'
    keys_to_extract = @('VersionStat', 'TS_Version')
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
# Критерий: VersionStat должен быть равен '20221206' И TS_Version > 100
$assignment12.success_criteria = @{
    extracted_data = @{
        VersionStat = @{ '==' = '20221206' }
        TS_Version = @{ '>' = 100 }
    }
}
Write-Host "ЗАПУСК: $($assignment12.node_name) (Ожидаем CheckSuccess=true)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment12) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 13: Неуспех по критерию ---
$assignment13 = $baseAssignment.PSObject.Copy()
$assignment13.assignment_id += 13
$assignment13.method_name = 'SQL_XML_QUERY'
$assignment13.node_name = "SQL XML Query: Criteria Fail (TS_Version)"
$assignment13.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT TOP 1 Revise FROM dbo.ReviseData WHERE id = 1115"
    xml_column_name = 'Revise'
    keys_to_extract = @('TS_Version')
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
# Критерий: TS_Version должен быть МЕНЬШЕ 100
$assignment13.success_criteria = @{ extracted_data = @{ TS_Version = @{ '<' = 100 } } }
Write-Host "ЗАПУСК: $($assignment13.node_name) (Ожидаем CheckSuccess=false)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment13) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 14: Ошибка - неверное имя столбца XML ---
$assignment14 = $baseAssignment.PSObject.Copy()
$assignment14.assignment_id += 14
$assignment14.method_name = 'SQL_XML_QUERY'
$assignment14.node_name = "SQL XML Query: Error (Bad XML Column)"
$assignment14.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT TOP 1 id, Revise FROM dbo.ReviseData WHERE id = 1115"
    xml_column_name = 'InvalidXmlColumnName' # Неверное имя
    keys_to_extract = @('VersionStat')
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment14.node_name) (Ожидаем IsAvailable=false)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment14) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 15: Ошибка - столбец не XML ---
$assignment15 = $baseAssignment.PSObject.Copy()
$assignment15.assignment_id += 15
$assignment15.method_name = 'SQL_XML_QUERY'
$assignment15.node_name = "SQL XML Query: Error (Column Not XML)"
$assignment15.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT TOP 1 id, CreationDate FROM dbo.ReviseData WHERE id = 1115"
    xml_column_name = 'CreationDate' # Это DATETIME, а не XML
    keys_to_extract = @('Year') # Не важно, что извлекать
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment15.node_name) (Ожидаем IsAvailable=false, ошибка парсинга XML)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment15) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 16: Ошибка - SQL запрос не вернул строк ---
$assignment16 = $baseAssignment.PSObject.Copy()
$assignment16.assignment_id += 16
$assignment16.method_name = 'SQL_XML_QUERY'
$assignment16.node_name = "SQL XML Query: Error (No Rows)"
$assignment16.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT Revise FROM dbo.ReviseData WHERE id = 99999" # Несуществующий ID
    xml_column_name = 'Revise'
    keys_to_extract = @('VersionStat')
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment16.node_name) (Ожидаем IsAvailable=true, Details.message, CheckSuccess=true)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment16) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)

# --- Тест 17: Ошибка SQL (как в тесте 6) ---
$assignment17 = $baseAssignment.PSObject.Copy()
$assignment17.assignment_id += 17
$assignment17.method_name = 'SQL_XML_QUERY'
$assignment17.node_name = "SQL XML Query: SQL Error (Bad Table)"
$assignment17.parameters = @{
    sql_database = $TestDatabaseName
    sql_query = "SELECT Revise FROM dbo.NonExistentTable"
    xml_column_name = 'Revise'
    keys_to_extract = @('AnyKey')
    sql_username = $TestSqlUsername
    sql_password = $TestSqlPassword
}
Write-Host "ЗАПУСК: $($assignment17.node_name) (Ожидаем IsAvailable=false)"
Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment17) | ConvertTo-Json -Depth 5
Write-Host $('-'*40)


Write-Host "КОНЕЦ ТЕСТОВ: Check-SQL_XML_QUERY" -ForegroundColor Green
Write-Host $('='*80)