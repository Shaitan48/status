# ManualTest-SQL-Checks-Kaskad.ps1 (v2.1)
# --- Скрипт для ручного тестирования SQL-проверок на базе testDB_kaskad через диспетчер ---

# --- 1. Загрузка модуля Utils ---
$ErrorActionPreference = "Stop"
try { $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "StatusMonitorAgentUtils.psd1"; Import-Module $modulePath -Force } catch { Write-Error "..."; exit 1 } finally { $ErrorActionPreference = "Continue" }
# Проверка модуля SqlServer
if (-not (Get-Command Invoke-Sqlcmd -EA SilentlyContinue)) { Write-Warning "Модуль SqlServer не найден!" }
Write-Host "Модуль Utils загружен." -FG Green; Write-Host $('-'*80)

# --- 2. Параметры ТЕСТОВОЙ БД Kaskad (из testDB_kaskad/docker-compose.yml) ---
$TestSqlServerInstance = "localhost,48010" # Порт из docker-compose
$TestDatabaseName = "kaskad"
$TestSqlUsername = "sa"
$TestSqlPassword = "escort123" # Пароль из docker-compose

Write-Host "ПАРАМЕТРЫ ТЕСТОВОЙ БД Kaskad:"; Write-Host "  Сервер: $TestSqlServerInstance"; Write-Host "  База:   $TestDatabaseName"; Write-Host "  Режим:  SQL Auth ($TestSqlUsername)"; Write-Host $('-'*80)

# --- 3. Базовый объект Задания ---
$baseAssignment = @{
    assignment_id = 9000; node_name = "Kaskad DB Test"; ip_address = $TestSqlServerInstance
    parameters = @{ sql_database = $TestDatabaseName; sql_username = $TestSqlUsername; sql_password = $TestSqlPassword }; success_criteria = $null
}

# --- Функция для выполнения и вывода теста ---
function Run-ManualSqlTest {
    param([Parameter(Mandatory=$true)]$Assignment, [string]$ExpectedResult = "")
    Write-Host "ЗАПУСК: $($Assignment.node_name)" -ForegroundColor Yellow
    Write-Host "  Method: $($Assignment.method_name)"
    Write-Host "  Parameters: $($Assignment.parameters | ConvertTo-Json -Depth 3 -Compress)"
    Write-Host "  SuccessCriteria: $($Assignment.success_criteria | ConvertTo-Json -Depth 4 -Compress)"
    $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$Assignment)
    Write-Host "РЕЗУЛЬТАТ:"; Write-Host ($result | ConvertTo-Json -Depth 5) -FG Gray
    if ($result.IsAvailable) { Write-Host "  Доступность: OK" -FG Green } else { Write-Host "  Доступность: FAIL" -FG Red }
    if ($result.CheckSuccess) { Write-Host "  Критерии: PASS $ExpectedResult" -FG Green } elseif ($result.CheckSuccess -eq $false) { Write-Host "  Критерии: FAIL $ExpectedResult" -FG Red } else { Write-Host "  Критерии: N/A $ExpectedResult" -FG Yellow }
    if ($result.ErrorMessage) { Write-Host "  Ошибка: $($result.ErrorMessage)" -FG Magenta }
    Write-Host ("-"*40)
}

# =================================================
# === ТЕСТЫ Check-SQL_QUERY_EXECUTE ===
# =================================================
Write-Host "ТЕСТЫ: Check-SQL_QUERY_EXECUTE" -FG Yellow

$execBase = $baseAssignment.PSObject.Copy(); $execBase.method_name = 'SQL_QUERY_EXECUTE'
$execId = $execBase.assignment_id

# --- first_row ---
$assign = $execBase.PSObject.Copy(); $assign.assignment_id = ++$execId; $assign.node_name += " - First Row"; $assign.parameters.sql_query = "SELECT TOP 1 * FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.return_format = 'first_row'
Run-ManualSqlTest -Assignment $assign

# --- row_count ---
$assign = $execBase.PSObject.Copy(); $assign.assignment_id = ++$execId; $assign.node_name += " - Row Count (1)"; $assign.parameters.sql_query = "SELECT id FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.return_format = 'row_count'
Run-ManualSqlTest -Assignment $assign

# --- row_count с критерием (PASS) ---
$assign = $execBase.PSObject.Copy(); $assign.assignment_id = ++$execId; $assign.node_name += " - Row Count Criteria OK"; $assign.parameters.sql_query = "SELECT id FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.return_format = 'row_count'; $assign.success_criteria = @{ row_count = @{ '==' = 1 } }
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем PASS)"

# --- row_count с критерием (FAIL) ---
$assign = $execBase.PSObject.Copy(); $assign.assignment_id = ++$execId; $assign.node_name += " - Row Count Criteria FAIL"; $assign.parameters.sql_query = "SELECT id FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.return_format = 'row_count'; $assign.success_criteria = @{ row_count = @{ '>' = 5 } }
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем FAIL)"

# --- scalar ---
$assign = $execBase.PSObject.Copy(); $assign.assignment_id = ++$execId; $assign.node_name += " - Scalar (Get ID)"; $assign.parameters.sql_query = "SELECT TOP 1 id FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.return_format = 'scalar'
Run-ManualSqlTest -Assignment $assign

# --- scalar с критерием (PASS) ---
$assign = $execBase.PSObject.Copy(); $assign.assignment_id = ++$execId; $assign.node_name += " - Scalar Criteria OK"; $assign.parameters.sql_query = "SELECT COUNT(*) FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.return_format = 'scalar'; $assign.success_criteria = @{ scalar_value = @{ '>=' = 1 } }
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем PASS)"

# --- non_query ---
$assign = $execBase.PSObject.Copy(); $assign.assignment_id = ++$execId; $assign.node_name += " - Non-Query (Temp)"; $assign.parameters.sql_query = "IF OBJECT_ID('tempdb..#TempTestExec') IS NULL CREATE TABLE #TempTestExec(col1 INT);"; $assign.parameters.return_format = 'non_query'
Run-ManualSqlTest -Assignment $assign

# --- Ошибка SQL (Bad Table) ---
$assign = $execBase.PSObject.Copy(); $assign.assignment_id = ++$execId; $assign.node_name += " - SQL Error (Bad Table)"; $assign.parameters.sql_query = "SELECT * FROM dbo.NonExistentTable"; $assign.parameters.return_format = 'first_row'
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем Доступность: FAIL)"

# --- Ошибка подключения (Bad DB) ---
$assign = $execBase.PSObject.Copy(); $assign.assignment_id = ++$execId; $assign.node_name += " - Connect Error (Bad DB)"; $assign.parameters.sql_database = "NonExistentDB"; $assign.parameters.sql_query = "SELECT 1"; $assign.parameters.return_format = 'scalar'
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем Доступность: FAIL)"

Write-Host "КОНЕЦ ТЕСТОВ: Check-SQL_QUERY_EXECUTE" -FG Green; Write-Host $('='*80); Write-Host ""

# =================================================
# === ТЕСТЫ Check-SQL_XML_QUERY ===
# =================================================
Write-Host "ТЕСТЫ: Check-SQL_XML_QUERY" -FG Yellow

$xmlBase = $baseAssignment.PSObject.Copy(); $xmlBase.method_name = 'SQL_XML_QUERY'
$xmlId = $xmlBase.assignment_id + 10 # Смещаем ID

# --- Успешное извлечение ---
$assign = $xmlBase.PSObject.Copy(); $assign.assignment_id = ++$xmlId; $assign.node_name += " - XML Extract OK"; $assign.parameters.sql_query = "SELECT TOP 1 Revise FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.xml_column_name = 'Revise'; $assign.parameters.keys_to_extract = @('VersionStat', 'TS_Version', 'NonExistentKey')
Run-ManualSqlTest -Assignment $assign

# --- Успех с критерием ---
$assign = $xmlBase.PSObject.Copy(); $assign.assignment_id = ++$xmlId; $assign.node_name += " - XML Criteria OK"; $assign.parameters.sql_query = "SELECT TOP 1 Revise FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.xml_column_name = 'Revise'; $assign.parameters.keys_to_extract = @('VersionStat', 'TS_Version'); $assign.success_criteria = @{ extracted_data = @{ VersionStat = @{ '==' = '20221206' }; TS_Version = @{ '>' = 100 } } }
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем PASS)"

# --- Неуспех по критерию ---
$assign = $xmlBase.PSObject.Copy(); $assign.assignment_id = ++$xmlId; $assign.node_name += " - XML Criteria FAIL"; $assign.parameters.sql_query = "SELECT TOP 1 Revise FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.xml_column_name = 'Revise'; $assign.parameters.keys_to_extract = @('TS_Version'); $assign.success_criteria = @{ extracted_data = @{ TS_Version = @{ '<' = 100 } } }
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем FAIL)"

# --- Ошибка (Bad XML Column) ---
$assign = $xmlBase.PSObject.Copy(); $assign.assignment_id = ++$xmlId; $assign.node_name += " - XML Error (Bad Column)"; $assign.parameters.sql_query = "SELECT TOP 1 id, Revise FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.xml_column_name = 'InvalidXmlColumn'; $assign.parameters.keys_to_extract = @('VersionStat')
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем Доступность: FAIL)"

# --- Ошибка (Column Not XML) ---
$assign = $xmlBase.PSObject.Copy(); $assign.assignment_id = ++$xmlId; $assign.node_name += " - XML Error (Not XML)"; $assign.parameters.sql_query = "SELECT TOP 1 CreationDate FROM dbo.ReviseData WHERE id = 1115"; $assign.parameters.xml_column_name = 'CreationDate'; $assign.parameters.keys_to_extract = @('Year')
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем Доступность: FAIL)"

# --- Ошибка (No Rows) ---
$assign = $xmlBase.PSObject.Copy(); $assign.assignment_id = ++$xmlId; $assign.node_name += " - XML Error (No Rows)"; $assign.parameters.sql_query = "SELECT Revise FROM dbo.ReviseData WHERE id = 99999"; $assign.parameters.xml_column_name = 'Revise'; $assign.parameters.keys_to_extract = @('VersionStat')
Run-ManualSqlTest -Assignment $assign -ExpectedResult "(Ожидаем Доступность: OK, но нет данных)" # IsAvailable=true, т.к. SQL запрос выполнился

Write-Host "КОНЕЦ ТЕСТОВ: Check-SQL_XML_QUERY" -FG Green; Write-Host $('='*80)