
---
**7. `Checks\README-Check-SQL_XML_QUERY.md` (Обновленный)**
---
```markdown
# Check-SQL_XML_QUERY.ps1 (v2.1.1+)

**Назначение:**

Этот скрипт выполняет SQL-запрос к Microsoft SQL Server, извлекает XML-данные из указанного столбца первой строки результата, парсит этот XML и извлекает значения по заданному списку ключей (имен элементов).

**Принцип работы:**

1.  Получает параметры (`TargetIP` как имя SQL Server Instance, `Parameters`, `SuccessCriteria`, `NodeName`).
2.  Извлекает и валидирует обязательные параметры из `$Parameters`: `sql_database`, `sql_query`, `xml_column_name`, `keys_to_extract`.
3.  Извлекает опциональные параметры: `sql_username`, `sql_password`, `query_timeout_sec`.
4.  Проверяет наличие и импортирует модуль `SqlServer`.
5.  Формирует параметры для `Invoke-Sqlcmd`.
6.  Выполняет SQL-запрос. Ошибки подключения/выполнения устанавливают `IsAvailable = $false`.
7.  Если SQL-запрос успешен (`$isAvailable = $true`):
    *   Проверяет результат: наличие строк, наличие столбца `xml_column_name`, непустое ли значение в нем. Если данные для XML не найдены или некорректны, устанавливает `$errorMessage`, но `$isAvailable` может остаться `$true`.
    *   Если XML-строка получена:
        *   Пытается распарсить XML (удаляя BOM).
        *   Если парсинг неудачен, устанавливает `$isAvailable = $false` и `$errorMessage`.
        *   Если XML распарсен успешно:
            *   Итерирует по `$keys_to_extract`.
            *   Извлекает текстовое содержимое элементов (используя `SelectSingleNode` и `local-name()` для игнорирования namespace).
            *   Записывает извлеченные пары ключ-значение в `$details.extracted_data`.
8.  Если `$isAvailable` равен `$true` и `$SuccessCriteria` предоставлены, вызывает `Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria`.
    *   Критерии обычно применяются к хэш-таблице `$details.extracted_data`.
9.  Устанавливает `CheckSuccess` в `$true`, `$false` или `$null`.
10. Формирует `ErrorMessage`.
11. Возвращает стандартизированный объект результата с помощью `New-CheckResultObject`.

**Параметры скрипта:**

*   `$TargetIP` ([string], **Обязательный**): Имя SQL Server instance.
*   `$Parameters` ([hashtable], Обязательный): Параметры SQL и XML.
*   `$SuccessCriteria` ([hashtable], Необязательный): Критерии успеха.
*   `$NodeName` ([string], Необязательный): Имя узла.

**Параметры задания (`$Parameters`)**:

*   `sql_database` ([string], **Обязательный**): Имя базы данных.
*   `sql_query` ([string], **Обязательный**): SQL-запрос, возвращающий XML.
*   `xml_column_name` ([string], **Обязательный**): Имя столбца с XML.
*   `keys_to_extract` ([string[]], **Обязательный**): Массив имен XML-элементов для извлечения (прямые потомки корневого элемента).
*   `sql_username` ([string], Необязательный): Имя пользователя SQL Auth.
*   `sql_password` ([string], Необязательный): Пароль SQL Auth. **Небезопасно.**
*   `query_timeout_sec` ([int], Необязательный, по умолч. 30): Таймаут SQL.

**Критерии успеха (`$SuccessCriteria`)**:

*   Применяются к объекту `$details`. Чаще всего используется для проверки `$details.extracted_data`:
    ```json
    {
      "extracted_data": {
        "KeyName1": "ExpectedValue", // Простое равенство
        "KeyName2": { ">": 100 },     // С оператором
        "OptionalKey": { "exists": false } // Проверка отсутствия
      }
    }
    ```

**Возвращаемый результат (`$Details`)**:

*   `server_instance` (string)
*   `database_name` (string)
*   `query_executed` (string)
*   `xml_source_column` (string)
*   `rows_returned` (int)
*   `extracted_data` (hashtable): Извлеченные данные {ключ=значение}. Значение `$null`, если ключ не найден.
*   `xml_content_sample` (string, опционально): Начало XML при ошибке парсинга.
*   `message` (string, опционально): Сообщение (например, если нет строк).
*   `error` (string, опционально): Сообщение об ошибке SQL, поиска столбца или парсинга XML.
*   `ErrorRecord` (string, опционально): Полная информация об исключении.

**Пример конфигурации Задания (Assignment):**

```json
// Получить статус и версию из XML в таблице Config
{
  "node_id": 65, 
  "method_id": 8, // ID для SQL_XML_QUERY
  "is_enabled": true,
  "parameters": {
    "sql_database": "Configuration",
    "sql_query": "SELECT ConfigXml FROM dbo.SystemConfig WHERE ConfigKey = 'Processing'",
    "xml_column_name": "ConfigXml",
    "keys_to_extract": ["IsEnabled", "Version", "LastCheckUTC"]
  },
  "success_criteria": {
    "extracted_data": { 
        "IsEnabled": "true", // Сравнение строк
        "Version": { "matches": "^\\d+\\.\\d+$" } // Проверка формата версии regex
    }
  },
  "description": "Проверка конфигурации обработки из XML"
}

IGNORE_WHEN_COPYING_END

Возможные ошибки и замечания:

    Модуль SqlServer: Требуется.

    Права доступа к SQL: Необходимы.

    Безопасность пароля: Используйте Windows Auth.

    Структура XML: Скрипт ожидает плоскую структуру (ключи - прямые потомки корня).

    Пространства имен XML: Игнорируются благодаря local-name().

Зависимости:

    Функции New-CheckResultObject, Test-SuccessCriteria из модуля StatusMonitorAgentUtils.psm1.

    Модуль PowerShell SqlServer.

    Доступ к MS SQL Server.