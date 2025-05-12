
---
**2. `Checks\README-Check-SERVICE_STATUS.md` (Обновленный)**
---
```markdown
# Check-SERVICE_STATUS.ps1 (v2.0.2+)

**Назначение:**

Этот скрипт проверяет статус указанной системной службы Windows с помощью командлета `Get-Service`.

**Принцип работы:**

1.  Получает параметры (`TargetIP`, `Parameters`, `SuccessCriteria`, `NodeName`) от диспетчера. `$TargetIP` используется только для логирования, так как `Get-Service` выполняется локально.
2.  Извлекает **обязательное** имя службы из `$Parameters.service_name`. Если параметр отсутствует или пуст, генерирует ошибку.
3.  Вызывает `Get-Service -Name $serviceName`.
4.  **Если `Get-Service` вернул объект службы:**
    *   Устанавливает `IsAvailable = $true`.
    *   Извлекает текущий статус (`Running`, `Stopped`, `Paused`, etc.), отображаемое имя (`display_name`), тип запуска (`start_type`), возможность остановки (`can_stop`).
    *   Заполняет `$Details` этой информацией.
5.  **Если `Get-Service` выдал ошибку `ServiceCommandException` (служба не найдена):**
    *   Устанавливает `IsAvailable = $true` (так как проверка была выполнена).
    *   Устанавливает `CheckSuccess = $false` (по умолчанию ненайденная служба - это провал).
    *   Записывает сообщение "Служба не найдена" в `ErrorMessage` и `Details.error`.
    *   Устанавливает `Details.status = "NotFound"`.
6.  **Если `Get-Service` выдал другую ошибку (нет доступа, RPC недоступен и т.д.):**
    *   Выбрасывается исключение, которое ловится основным `catch`.
    *   Устанавливается `IsAvailable = $false`.
    *   `CheckSuccess` остается `$null`.
    *   Формируется `ErrorMessage` с деталями исключения.
7.  **Проверка критериев успеха:**
    *   Если `$isAvailable` равен `$true` и `$SuccessCriteria` предоставлены, вызывает `Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria`.
    *   Критерии обычно применяются к полям `status`, `start_type`, `can_stop` и т.д.
    *   Устанавливает `CheckSuccess` в `$true`, `$false` или `$null` (при ошибке критерия).
    *   Если критерии не заданы: `CheckSuccess` устанавливается в `$true`, если статус службы не "NotFound", иначе в `$false`.
8.  Формирует итоговый `ErrorMessage`, учитывая как ошибки выполнения, так и результаты проверки критериев.
9.  Возвращает стандартизированный объект результата с помощью `New-CheckResultObject`.

**Параметры скрипта:**

*   `$TargetIP` ([string], Необязательный): IP-адрес или имя хоста (для логирования).
*   `$Parameters` ([hashtable], Обязательный): Хэш-таблица с параметрами.
*   `$SuccessCriteria` ([hashtable], Необязательный): Хэш-таблица с критериями успеха.
*   `$NodeName` ([string], Необязательный): Имя узла для логирования.

**Параметры задания (`$Parameters`)**:

*   `service_name` ([string], **Обязательный**): Системное имя службы Windows (например, 'Spooler', 'wuauserv').

**Критерии успеха (`$SuccessCriteria`)**:

*   Применяются к объекту `$details`. Часто проверяются поля:
    *   `status` (string): Ожидаемый статус ('Running', 'Stopped', 'Paused'). Пример: `@{ status = 'Running' }` или `@{ status = @{ '!=' = 'Stopped' } }`
    *   `start_type` (string): Ожидаемый тип запуска ('Automatic', 'Manual', 'Disabled'). Пример: `@{ start_type = 'Automatic' }`
    *   `can_stop` (bool): Ожидаемая возможность остановки. Пример: `@{ can_stop = $true }`
    *   Можно проверять на отсутствие службы, используя статус 'NotFound': `@{ status = 'NotFound' }` (ожидаем, что служба не найдена).

**Возвращаемый результат (`$Details`)**:

*   `service_name` (string): Имя проверенной службы.
*   `status` (string): Текущий статус службы ('Running', 'Stopped', 'Paused', 'NotFound', etc.).
*   `display_name` (string/null): Отображаемое имя службы (если найдена).
*   `start_type` (string/null): Тип запуска службы (если найдена).
*   `can_stop` (bool/null): Может ли служба быть остановлена (если найдена).
*   `error` (string, опционально): Сообщение об ошибке, если служба не найдена или произошла другая ошибка.
*   `ErrorRecord` (string, опционально): Полная информация об исключении PowerShell, если произошла критическая ошибка.

**Пример конфигурации Задания (Assignment):**

```json
// Проверить, что служба 'Spooler' запущена И тип запуска 'Automatic'
{
  "node_id": 55,
  "method_id": 4, // ID для SERVICE_STATUS
  "is_enabled": true,
  "parameters": {
    "service_name": "Spooler"
  },
  "success_criteria": {
    "status": "Running", 
    "start_type": "Automatic"
  },
  "description": "Проверка службы печати (Spooler)"
}

IGNORE_WHEN_COPYING_END

Возможные ошибки и замечания:

    Права доступа: Обычно не требует повышенных прав для локальной проверки. Для удаленной (если бы была реализована через -ComputerName) потребуются права и WinRM.

    Имя службы: Убедитесь, что service_name указано правильно (системное имя).

Зависимости:

    Функции New-CheckResultObject, Test-SuccessCriteria из модуля StatusMonitorAgentUtils.psm1.