
---
**6. `Checks\README-Check-SQL_QUERY_EXECUTE.md` (Обновленный)**
---
```markdown
# Check-SQL_QUERY_EXECUTE.ps1 (v2.1.1+)

**Назначение:**

Этот скрипт выполняет произвольный SQL-запрос к Microsoft SQL Server и возвращает результат в заданном формате.

**Принцип работы:**

1.  Получает параметры (`TargetIP` как имя SQL Server Instance, `Parameters`, `SuccessCriteria`, `NodeName`) от диспетчера.
2.  Извлекает и валидирует обязательные параметры из `$Parameters`: `sql_database`, `sql_query`.
3.  Извлекает опциональные параметры: `return_format` (по умолч. 'first_row'), `sql_username`, `sql_password`, `query_timeout_sec` (по умолч. 30). Проверяет их корректность.
4.  Проверяет наличие модуля `SqlServer`. Если отсутствует или не импортируется, генерирует ошибку (`IsAvailable = $false`).
5.  Формирует параметры для `Invoke-Sqlcmd`, включая учетные данные и `OutputSqlErrors = $true`.
6.  Вызывает `Invoke-Sqlcmd`. Если возникает ошибка (подключения или выполнения SQL), устанавливает `IsAvailable = $false` и записывает ошибку.
7.  Если запрос выполнен успешно:
    *   Устанавливает `IsAvailable = $true`.
    *   Обрабатывает результат `$queryResultData` в соответствии с `return_format`:
        *   `first_row`: Записывает первую строку (как `Hashtable`) в `Details.query_result` и количество строк в `Details.rows_returned`.
        *   `all_rows`: Записывает все строки (как `List<object>` из `Hashtable`) в `Details.query_result` и количество в `Details.rows_returned`.
        *   `row_count`: Записывает количество строк в `Details.row_count`.
        *   `scalar`: Записывает значение первого столбца первой строки в `Details.scalar_value`.
        *   `non_query`: Записывает `$true` в `Details.non_query_success`.
    *   Заполняет другие поля `$Details` (server_instance, database_name и т.д.).
8.  Если `$isAvailable = $true` и `$SuccessCriteria` предоставлены, вызывает `Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria`.
    *   Критерии могут применяться к полям `row_count`, `scalar_value`, `non_query_success`, `query_result` (если это хэш) или к массиву `query_result` (если `all_rows`).
9.  Устанавливает `CheckSuccess` в `$true`, `$false` или `$null`.
10. Формирует `ErrorMessage`.
11. Возвращает стандартизированный объект результата с помощью `New-CheckResultObject`.

**Параметры скрипта:**

*   `$TargetIP` ([string], **Обязательный**): Имя или IP-адрес SQL Server instance.
*   `$Parameters` ([hashtable], Обязательный): Хэш-таблица с параметрами SQL.
*   `$SuccessCriteria` ([hashtable], Необязательный): Критерии успеха.
*   `$NodeName` ([string], Необязательный): Имя узла для логирования.

**Параметры задания (`$Parameters`)**:

*   `sql_database` ([string], **Обязательный**): Имя базы данных.
*   `sql_query` ([string], **Обязательный**): SQL-запрос для выполнения.
*   `return_format` ([string], Необязательный, по умолч. `'first_row'`): Формат результата (`first_row`, `all_rows`, `row_count`, `scalar`, `non_query`).
*   `sql_username` ([string], Необязательный): Имя пользователя SQL Auth.
*   `sql_password` ([string], Необязательный): Пароль SQL Auth (обязателен при `sql_username`). **Небезопасно.**
*   `query_timeout_sec` ([int], Необязательный, по умолч. 30): Таймаут запроса.

**Критерии успеха (`$SuccessCriteria`)**:

*   Применяются к объекту `$details`. Примеры:
    *   `@{ row_count = @{'>='=1} }`
    *   `@{ scalar_value = "OK" }`
    *   `@{ non_query_success = $true }`
    *   `@{ query_result = @{ Status = "Completed" } }` (для `first_row`)
    *   `@{ query_result = @{ _condition_="all"; _criteria_=@{ Value = @{">"=0} } } }` (для `all_rows`)

**Возвращаемый результат (`$Details`)**:

*   `server_instance` (string)
*   `database_name` (string)
*   `query_executed` (string)
*   `return_format_used` (string)
*   *В зависимости от `return_format`*:
    *   `query_result` (hashtable или List<object>)
    *   `rows_returned` (int)
    *   `row_count` (int)
    *   `scalar_value` (any)
    *   `non_query_success` (bool)
*   `error` (string, опционально)
*   `ErrorRecord` (string, опционально)

**Пример конфигурации Задания (Assignment):**

```json
// Получить количество строк в таблице Logs за последний час
{
  "node_id": 61,
  "method_id": 9, // ID для SQL_QUERY_EXECUTE
  "is_enabled": true,
  "parameters": {
    "sql_database": "AppLogs",
    "sql_query": "SELECT COUNT(*) FROM dbo.Logs WHERE LogTime >= DATEADD(hour, -1, GETUTCDATE())",
    "return_format": "scalar" 
  },
  "success_criteria": {
    // Провал, если за час было > 1000 логов (аномалия)
    "scalar_value": { "<": 1000 } 
  },
  "description": "Количество логов за последний час < 1000"
}

Возможные ошибки и замечания:

    Модуль SqlServer: Требуется Install-Module SqlServer.

    Права доступа к SQL: Необходимы права на подключение и выполнение запроса.

    Безопасность пароля: Избегайте использования SQL Auth с паролем в параметрах.

    all_rows: Используйте с осторожностью для больших таблиц.

Зависимости:

    Функции New-CheckResultObject, Test-SuccessCriteria из модуля StatusMonitorAgentUtils.psm1.

    Модуль PowerShell SqlServer.

    Доступ к MS SQL Server.