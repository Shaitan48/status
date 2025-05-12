
---
**3. `Checks\README-Check-DISK_USAGE.md` (Обновленный)**
---
```markdown
# Check-DISK_USAGE.ps1 (v2.1.0+)

**Назначение:**

Этот скрипт проверяет использование дискового пространства на локальных дисках, используя командлет `Get-Volume`.

**Принцип работы:**

1.  Получает параметры (`TargetIP`, `Parameters`, `SuccessCriteria`, `NodeName`) от диспетчера. `$TargetIP` используется только для логирования.
2.  Вызывает `Get-Volume` для получения информации обо всех томах локально. Если команда не выполняется, устанавливает `IsAvailable = $false`.
3.  Фильтрует полученные тома:
    *   Оставляет только диски с `DriveType = 'Fixed'`.
    *   Оставляет только диски, имеющие букву (`DriveLetter`).
    *   Если в `$Parameters.drives` передан массив букв, оставляет только диски из этого списка.
4.  Для каждого отфильтрованного диска:
    *   Рассчитывает общий размер, свободное/занятое место в байтах и ГБ, процент свободного/занятого места.
    *   Собирает информацию в хэш-таблицу.
    *   Добавляет эту хэш-таблицу в массив `$details.disks`.
5.  Если после фильтрации дисков не осталось, добавляет сообщение в `$details.message`.
6.  Если `$isAvailable` равен `$true` и `$SuccessCriteria` предоставлены, вызывает `Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria`.
    *   Критерии обычно применяются к массиву `$details.disks` с использованием `_condition_`, `_where_`, `_criteria_`.
7.  Устанавливает `CheckSuccess` в `$true`, `$false` или `$null` (при ошибке критерия).
8.  Формирует `ErrorMessage`, если `$isAvailable` или `$checkSuccess` равны `$false`, или если `$checkSuccess` равен `$null` при `$IsAvailable = $true`.
9.  Возвращает стандартизированный объект результата с помощью `New-CheckResultObject`.

**Параметры скрипта:**

*   `$TargetIP` ([string], Необязательный): IP-адрес или имя хоста (для логирования).
*   `$Parameters` ([hashtable], Необязательный): Хэш-таблица с параметрами.
*   `$SuccessCriteria` ([hashtable], Необязательный): Хэш-таблица с критериями успеха.
*   `$NodeName` ([string], Необязательный): Имя узла для логирования.

**Параметры задания (`$Parameters`)**:

*   `drives` ([string[]], Необязательный): Массив строк с буквами дисков для проверки (например, `@('C', 'D')`). Регистр не важен. Если не указан, проверяются все локальные Fixed-диски.

**Критерии успеха (`$SuccessCriteria`)**:

*   Применяются к объекту `$details`. Основное поле для проверки - массив `disks`.
*   **Структура для проверки массива `disks`:**
    ```json
    {
      "disks": {
        "_condition_": "all" / "any" / "none" / "count",
        "_where_": { <поле_диска>: <простой_критерий_или_операторный_блок> }, // Опционально
        "_criteria_": { <поле_диска>: <простой_критерий_или_операторный_блок> }, // Обязательно для all/any/none с элементами
        "_count_": { <оператор>: <число> } // Обязательно для count
      }
    }
    ```
*   **Поля диска для проверки (`<поле_диска>`):** `drive_letter`, `label`, `filesystem`, `size_bytes`, `free_bytes`, `used_bytes`, `size_gb`, `free_gb`, `used_gb`, `percent_free`, `percent_used`.
*   **Примеры:**
    *   Все диски > 10% свободного места: `@{ disks = @{ _condition_='all'; _criteria_=@{percent_free=@{'>'=10.0}}} }`
    *   Хотя бы один диск с буквой C или D имеет < 5% свободного места: `@{ disks = @{ _condition_='any'; _where_=@{drive_letter=@{'matches'}='^(C|D)$'}}; _criteria_=@{percent_free=@{'<'=5.0}}} }`
    *   Количество дисков с размером > 1 ТБ (в байтах) ровно 1: `@{ disks = @{ _condition_='count'; _where_=@{size_bytes=@{'>'=(1TB)}}; _count_=@{'=='=1}} }`

**Возвращаемый результат (`$Details`)**:

*   `disks` (object[]): Массив хэш-таблиц, по одной для каждого проверенного диска. Каждая содержит:
    *   `drive_letter` (string)
    *   `label` (string)
    *   `filesystem` (string)
    *   `size_bytes` (long), `free_bytes` (long), `used_bytes` (long)
    *   `size_gb` (double), `free_gb` (double), `used_gb` (double)
    *   `percent_free` (double), `percent_used` (double)
*   `message` (string, опционально): Сообщение, если диски не найдены.
*   `error` (string, опционально): Сообщение об ошибке `Get-Volume`.
*   `ErrorRecord` (string, опционально): Полная информация об исключении.

**Пример конфигурации Задания (Assignment):**

```json
// Проверить диск C (>15%) и все остальные (>5%)
{
  "node_id": 10,
  "method_id": 5, // ID для DISK_USAGE
  "is_enabled": true,
  "parameters": null, // Проверяем все диски
  "success_criteria": {
    "disks": [ // Можно передать массив критериев, которые будут проверяться ПО ОЧЕРЕДИ
        // Критерий 1: Диск C должен иметь >= 15%
        { "_condition_": "all", "_where_": {"drive_letter": "C"}, "_criteria_": { "percent_free": { ">=": 15 } } },
        // Критерий 2: Все ОСТАЛЬНЫЕ диски (не C) должны иметь > 5%
        { "_condition_": "all", "_where_": {"drive_letter": {"!=":"C"}}, "_criteria_": { "percent_free": { ">": 5 } } }
    ]
    // АЛЬТЕРНАТИВНО (если Test-SuccessCriteria поддерживает массив критериев для одного ключа):
    // "disks": { 
    //     "_condition_": "all", // Применяется к обоим критериям ниже? Или как? УТОЧНИТЬ работу TSC с массивом критериев. 
    //                            // Вероятно, лучше передавать один сложный объект criteria.
    //     "_criteria_": [
    //        {"_where_": {"drive_letter": "C"}, "_check_": {"percent_free": {">=":15}}}, 
    //        {"_where_": {"drive_letter": {"!=":"C"}}, "_check_": {"percent_free": {">":5}}}
    //      ]
    // }
    // ПОКА ЧТО Test-SuccessCriteria НЕ поддерживает массив критериев. Используйте отдельные проверки или более сложные _where_.
  },
  "description": "Проверка места: C>=15%, остальные >5%"
}

Примечание по массиву критериев: Текущая реализация Test-SuccessCriteria не поддерживает массив критериев для одного ключа. Если нужны сложные условия "И" для разных подмножеств массива, их нужно либо объединять в один критерий с более сложным _where_ (если возможно), либо создавать отдельные Задания мониторинга.

Возможные ошибки и замечания:

    Версия ОС: Требуется Windows 8 / Windows Server 2012+.

    Права доступа: Обычно не требует повышенных прав.

Зависимости:

    Функции New-CheckResultObject, Test-SuccessCriteria из модуля StatusMonitorAgentUtils.psm1.

    Командлет Get-Volume (модуль Storage).