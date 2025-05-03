
---

**7. `powershell/StatusMonitorAgentUtils/Checks/README-Check-SQL_QUERY_EXECUTE.md`**

```markdown
# Check-SQL_QUERY_EXECUTE.ps1

**Назначение:**

Этот скрипт выполняет произвольный SQL-запрос к Microsoft SQL Server и возвращает результат в заданном формате.

**Принцип работы:**

1.  Получает параметры (`TargetIP`, `Parameters`, `SuccessCriteria`, `NodeName`) от диспетчера. `$TargetIP` используется как имя SQL Server instance.
2.  Извлекает и валидирует обязательные параметры из `$Parameters`: `sql_database`, `sql_query`.
3.  Извлекает опциональный параметр `return_format` (по умолчанию `'first_row'`) и валидирует его значение.
4.  Извлекает опциональные параметры для SQL-аутентификации (`sql_username`, `sql_password`) и таймаут запроса (`query_timeout_sec`).
5.  Проверяет наличие модуля `SqlServer`. Если отсутствует, генерирует ошибку (`IsAvailable = $false`).
6.  Формирует параметры для `Invoke-Sqlcmd`, включая учетные данные.
7.  Выполняет SQL-запрос с помощью `Invoke-Sqlcmd`. Если произошла ошибка, устанавливает `IsAvailable = $false` и записывает ошибку.
8.  Если запрос выполнен успешно:
    *   Устанавливает `IsAvailable = $true` и `CheckSuccess = $true` (критерии пока не реализованы).
    *   Обрабатывает результат `$queryResultData` в соответствии с указанным `return_format`:
        *   `first_row`: Преобразует первую строку `DataRow` в хэш-таблицу и записывает в `Details.query_result`.
        *   `all_rows`: Преобразует все строки `DataRow` в массив хэш-таблиц и записывает в `Details.query_result`.
        *   `row_count`: Записывает количество строк в `Details.row_count`.
        *   `scalar`: Извлекает значение из первого столбца первой строки и записывает в `Details.scalar_value`.
        *   `non_query`: Записывает `$true` в `Details.non_query_success`.
    *   Записывает количество возвращенных строк (если применимо) в `Details.rows_returned`.
9.  Возвращает стандартизированный объект результата с помощью `New-CheckResultObject`.

**Параметры скрипта:**

*   `$TargetIP` ([string], Обязательный): Имя или IP-адрес SQL Server instance.
*   `$Parameters` ([hashtable], Обязательный): Хэш-таблица с параметрами.
*   `$SuccessCriteria` ([hashtable], Необязательный): Хэш-таблица с критериями успеха (пока не используется).
*   `$NodeName` ([string], Необязательный): Имя узла для логирования.

**Параметры задания (`$Parameters`)**:

*   `sql_database` ([string], **Обязательный**): Имя базы данных.
*   `sql_query` ([string], **Обязательный**): SQL-запрос для выполнения.
*   `return_format` ([string], Необязательный, по умолч. `'first_row'`): Как интерпретировать и вернуть результат запроса. Допустимые значения:
    *   `'first_row'`: Вернуть первую строку как хэш-таблицу (`Details.query_result`).
    *   `'all_rows'`: Вернуть все строки как массив хэш-таблиц (`Details.query_result`). **Осторожно с большими результатами!**
    *   `'row_count'`: Вернуть только количество строк (`Details.row_count`).
    *   `'scalar'`: Вернуть значение первого столбца первой строки (`Details.scalar_value`).
    *   `'non_query'`: Для запросов, не возвращающих данные (INSERT, UPDATE, DELETE, DDL). Возвращает `Details.non_query_success = $true` при успехе.
*   `sql_username` ([string], Необязательный): Имя пользователя для SQL Server аутентификации.
*   `sql_password` ([string], Необязательный): Пароль для SQL Server аутентификации. **(Небезопасно)**.
*   `query_timeout_sec` ([int], Необязательный, по умолч. 30): Таймаут выполнения SQL-запроса.

**Критерии успеха (`$SuccessCriteria`)**:

*   **Пока не реализованы.** Можно будет добавить проверку возвращенных данных, например:
    *   Для `row_count`: `{ "expected_count": 5 }`, `{ "min_count": 1 }`, `{ "max_count": 10 }`
    *   Для `scalar`: `{ "expected_value": "OK" }`, `{ "value_less_than": 100 }`
    *   Для `first_row`/`all_rows`: Проверка значений в конкретных столбцах.

**Возвращаемый результат:**

*   Стандартный объект (`IsAvailable`, `CheckSuccess`, `Timestamp`, `Details`, `ErrorMessage`).
*   `$Details` содержит:
    *   `server_instance` (string)
    *   `database_name` (string)
    *   `query_executed` (string)
    *   `return_format_used` (string)
    *   В зависимости от `return_format`:
        *   `query_result` (hashtable или List<object>): Результат для `first_row` или `all_rows`.
        *   `rows_returned` (int): Количество строк (для `first_row`, `all_rows`).
        *   `row_count` (int): Количество строк (для `row_count`).
        *   `scalar_value` (any): Скалярное значение (для `scalar`).
        *   `non_query_success` (bool): Результат выполнения (для `non_query`).
    *   `error` (string): (Опционально) Сообщение об ошибке, если `IsAvailable = $false`.

**Пример конфигурации Задания (Assignment):**

```json
// Пример 1: Получить количество активных сессий
{
  "node_id": 61,
  "method_id": 9, // ID для SQL_QUERY_EXECUTE
  "is_enabled": true,
  "parameters": {
    "sql_database": "master",
    "sql_query": "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1;",
    "return_format": "scalar" // Вернуть одно значение
  },
  "success_criteria": null, // Можно добавить { "value_less_than": 50 }
  "description": "Количество активных SQL сессий"
}

// Пример 2: Проверить статус задачи в таблице
{
  "node_id": 61,
  "method_id": 9,
  "is_enabled": true,
  "parameters": {
    "sql_database": "ApplicationDB",
    "sql_query": "SELECT Status, LastRunTime FROM dbo.BackgroundTasks WHERE TaskName = 'DailyCleanup'",
    "return_format": "first_row" // Вернуть первую (и единственную?) строку
  },
  "success_criteria": null, // Можно добавить { "expected_Status": "Completed" }
  "description": "Статус задачи DailyCleanup"
}

// Пример 3: Выполнить процедуру очистки (non-query)
{
  "node_id": 61,
  "method_id": 9,
  "is_enabled": true,
  "parameters": {
    "sql_database": "ApplicationDB",
    "sql_query": "EXEC dbo.sp_CleanupOldLogs;",
    "return_format": "non_query" // Ожидаем просто успешное выполнение
  },
  "success_criteria": null,
  "description": "Запуск процедуры очистки логов"
}

Возможные ошибки и замечания:

    Модуль SqlServer: Требуется установка Install-Module SqlServer.

    Права доступа к SQL: Права на подключение, доступ к БД, выполнение запроса.

    Безопасность пароля: Избегайте хранения паролей в параметрах.

    all_rows: Используйте с осторожностью, если запрос может вернуть очень много строк, так как это может потребить много памяти и времени.

    non_query: CheckSuccess=true означает только, что запрос выполнен без синтаксических ошибок или ошибок доступа. Он не гарантирует, что запрос сделал то, что ожидалось (например, UPDATE мог не затронуть ни одной строки). Для этого нужны SuccessCriteria.

Зависимости:

    Функция New-CheckResultObject из StatusMonitorAgentUtils.psm1.

    Модуль PowerShell SqlServer.

    Доступ к MS SQL Server.