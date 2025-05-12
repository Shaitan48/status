
---
**5. `Checks\README-Check-CERT_EXPIRY.md` (Обновленный)**
---
```markdown
# Check-CERT_EXPIRY.ps1 (v2.1.0+)

**Назначение:**

Этот скрипт проверяет сроки действия локально установленных сертификатов Windows.

**Принцип работы:**

1.  Получает параметры (`TargetIP`, `Parameters`, `SuccessCriteria`, `NodeName`) от диспетчера. `$TargetIP` используется только для логирования.
2.  Извлекает параметры из `$Parameters`: `store_location`, `store_name`, `subject_like`, `issuer_like`, `thumbprint`, `require_private_key`, `eku_oid`, `min_days_warning`. Устанавливает значения по умолчанию, если параметры не переданы.
3.  Определяет список хранилищ для поиска: либо указанное в параметрах, либо стандартный список (`LocalMachine\My`, `LocalMachine\WebHosting`, `CurrentUser\My`).
4.  Итерирует по списку хранилищ:
    *   Проверяет доступность хранилища через `Test-Path`.
    *   Вызывает `Get-ChildItem` для получения сертификатов. Обрабатывает ошибки доступа.
    *   Собирает все найденные сертификаты в список.
5.  Устанавливает `IsAvailable = $true`, если удалось проверить хотя бы одно хранилище. Если нет - `$IsAvailable = $false`. Ошибки доступа к отдельным хранилищам записываются в `Details.store_access_errors`.
6.  Фильтрует собранный список сертификатов согласно параметрам (`Thumbprint` имеет приоритет над `SubjectLike`/`IssuerLike`, затем применяются `RequirePrivateKey` и `EkuOids`). Устанавливает флаг `Details.filter_applied`.
7.  Для каждого отфильтрованного сертификата:
    *   Рассчитывает количество дней до истечения (`days_left`).
    *   Определяет статус сертификата (`OK`, `Expired`, `ExpiringSoon`) на основе `days_left` и `min_days_warning`.
    *   Собирает информацию (`thumbprint`, `subject`, `issuer`, даты, `days_left`, `has_private_key`, `status`, `status_details`, `store_path`) в хэш-таблицу.
    *   Добавляет хэш-таблицу в массив `$details.certificates`.
8.  Сортирует `$details.certificates` по `days_left`.
9.  Если после фильтрации сертификатов не осталось, добавляет сообщение в `$details.message`.
10. Если `$isAvailable` равен `$true` и `$SuccessCriteria` предоставлены, вызывает `Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria`.
    *   Критерии обычно применяются к массиву `$details.certificates`.
11. Устанавливает `CheckSuccess` в `$true`, `$false` или `$null`.
12. Формирует `ErrorMessage`, учитывая результат критериев и ошибки доступа к хранилищам.
13. Возвращает стандартизированный объект результата с помощью `New-CheckResultObject`.

**Параметры скрипта:**

*   `$TargetIP` ([string], Необязательный): IP/Имя хоста (для логирования).
*   `$Parameters` ([hashtable], Необязательный): Параметры поиска и фильтрации.
*   `$SuccessCriteria` ([hashtable], Необязательный): Критерии успеха.
*   `$NodeName` ([string], Необязательный): Имя узла для логирования.

**Параметры задания (`$Parameters`)**:

*   `store_location` ([string], Необязательный): 'LocalMachine' или 'CurrentUser'. Если указан вместе с `store_name`, ищет только там.
*   `store_name` ([string], Необязательный): Имя хранилища ('My', 'WebHosting', etc.). Если указан вместе с `store_location`, ищет только там.
*   `subject_like` ([string], Необязательный): Фильтр по Subject (CN). Wildcard `*`.
*   `issuer_like` ([string], Необязательный): Фильтр по Issuer. Wildcard `*`.
*   `thumbprint` ([string], Необязательный): Точный отпечаток (приоритетный фильтр).
*   `require_private_key` ([bool], Необязательный, по умолч. `$false`): Искать только с приватным ключом.
*   `eku_oid` ([string[]], Необязательный): Массив OID'ов Enhanced Key Usage. Сертификат должен содержать хотя бы один из них.
*   `min_days_warning` ([int], Необязательный, по умолч. 30): Порог в днях для статуса 'ExpiringSoon' (не влияет на CheckSuccess).

**Критерии успеха (`$SuccessCriteria`)**:

*   Применяются к объекту `$details`. Основное поле для проверки - массив `certificates`.
*   **Структура для проверки массива `certificates`:**
    ```json
    {
      "certificates": {
        "_condition_": "all" / "any" / "none" / "count",
        "_where_": { <поле_сертификата>: <критерий> }, // Опционально
        "_criteria_": { <поле_сертификата>: <критерий> }, // Для all/any/none
        "_count_": { <оператор>: <число> } // Для count
      }
    }
    ```
*   **Поля сертификата для проверки (`<поле_сертификата>`):** `thumbprint`, `subject`, `issuer`, `days_left`, `has_private_key`, `status`.
*   **Примеры:**
    *   Все найденные сертификаты должны иметь `days_left > 30`: `@{ certificates = @{ _condition_='all'; _criteria_=@{days_left=@{'>'=30}}} }`
    *   Ни один сертификат не должен быть 'Expired': `@{ certificates = @{ _condition_='none'; _where_=@{status='Expired'}} }`
    *   Хотя бы один SSL-сертификат истекает менее чем через 15 дней: `@{ certificates = @{ _condition_='any'; _where_=@{eku_oid=@{'contains'='1.3.6.1.5.5.7.3.1'}}; _criteria_=@{days_left=@{'<'=15}}} }` (Примечание: EKU проверяется при фильтрации в `$Parameters`, а не через `_where_` здесь). Условие для ANY будет проще: `@{ certificates = @{ _condition_='any'; _criteria_=@{days_left=@{'<'=15}}} }` (применится ко всем отфильтрованным сертификатам).

**Возвращаемый результат (`$Details`)**:

*   `certificates` (object[]): Массив хэш-таблиц для каждого найденного и отфильтрованного сертификата. Каждая содержит:
    *   `thumbprint`, `subject`, `issuer` (string)
    *   `not_before_utc`, `not_after_utc` (string ISO 8601)
    *   `days_left` (int)
    *   `has_private_key` (bool)
    *   `status` (string): 'OK', 'Expired', 'ExpiringSoon'
    *   `status_details` (string)
    *   `store_path` (string)
*   `stores_checked` (string[]): Список проверенных хранилищ.
*   `parameters_used` (hashtable): Параметры, фактически использованные для поиска/фильтрации.
*   `filter_applied` (bool): Применялись ли фильтры?
*   `message` (string, опционально): Сообщение, если сертификаты не найдены.
*   `store_access_errors` (string[], опционально): Список ошибок доступа к хранилищам.
*   `error` (string, опционально): Сообщение об основной ошибке проверки.
*   `ErrorRecord` (string, опционально): Полная информация об исключении.

**Пример конфигурации Задания (Assignment):**

```json
// Проверить все сертификаты в LocalMachine\My, 
// у которых есть приватный ключ, 
// и убедиться, что все они действительны еще > 30 дней
{
  "node_id": 50,
  "method_id": 7, // ID для CERT_EXPIRY
  "is_enabled": true,
  "parameters": {
    "store_location": "LocalMachine",
    "store_name": "My",
    "require_private_key": true,
    "min_days_warning": 60 
  },
  "success_criteria": {
    "certificates": { 
        "_condition_": "all",
        "_criteria_": { "days_left": { ">": 30 } }
    }
  },
  "description": "Проверка сертификатов в LM\\My (>30 дней, с ключом)"
}

IGNORE_WHEN_COPYING_END

Возможные ошибки и замечания:

    Права доступа: Доступ к LocalMachine требует прав администратора.

    Отсутствие хранилищ: Скрипт обрабатывает отсутствие стандартных хранилищ (например, WebHosting).

    EKU Фильтрация: Проверяет наличие хотя бы одного из указанных OID в расширении EKU сертификата.

Зависимости:

    Функции New-CheckResultObject, Test-SuccessCriteria из модуля StatusMonitorAgentUtils.psm1.

    Доступ к хранилищам сертификатов Windows.