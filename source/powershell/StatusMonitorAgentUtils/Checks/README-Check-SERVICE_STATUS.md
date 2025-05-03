
---

**2. `powershell/StatusMonitorAgentUtils/Checks/README-Check-SERVICE_STATUS.md`**

```markdown
# Check-SERVICE_STATUS.ps1

**Назначение:**

Этот скрипт проверяет статус указанной системной службы Windows с помощью командлета `Get-Service`.

**Принцип работы:**

1.  Получает параметры (`TargetIP`, `Parameters`, `SuccessCriteria`, `NodeName`) от диспетчера.
2.  Извлекает обязательное имя службы из `$Parameters.service_name`.
3.  Определяет, является ли `$TargetIP` удаленным хостом. Если да, будет использовать параметр `-ComputerName` для `Get-Service` (при вызове через `Invoke-Command`).
4.  Вызывает `Get-Service` с указанным именем и (если нужно) `-ComputerName`.
5.  **Если `Get-Service` вернул объект службы:**
    *   Устанавливает `IsAvailable = $true`.
    *   Извлекает текущий статус (`Running`, `Stopped`, `Paused`, etc.), отображаемое имя, тип запуска.
    *   Заполняет `$Details` этой информацией.
    *   Проверяет `$SuccessCriteria`: если задан ключ `status`, сравнивает текущий статус с требуемым. Если `SuccessCriteria.status` не задан, по умолчанию ожидает статус `'Running'`. Устанавливает `CheckSuccess` в `$true` или `$false` и `ErrorMessage`, если статус не соответствует.
6.  **Если `Get-Service` выдал ошибку `ServiceCommandException` (служба не найдена):**
    *   Устанавливает `IsAvailable = $false`.
    *   `CheckSuccess` остается `$null`.
    *   Записывает сообщение "Служба не найдена" в `ErrorMessage` и `Details`.
7.  **Если `Get-Service` выдал другую ошибку (нет доступа, RPC недоступен и т.д.):**
    *   Устанавливает `IsAvailable = $false`.
    *   `CheckSuccess` остается `$null`.
    *   Записывает сообщение об ошибке в `ErrorMessage` и `Details`.
8.  Возвращает стандартизированный объект результата с помощью `New-CheckResultObject`.

**Параметры скрипта:**

*   `$TargetIP` ([string], Обязательный): IP-адрес или имя хоста. Используется диспетчером для `Invoke-Command`.
*   `$Parameters` ([hashtable], Обязательный): Хэш-таблица с параметрами.
*   `$SuccessCriteria` ([hashtable], Необязательный): Хэш-таблица с критериями успеха.
*   `$NodeName` ([string], Необязательный): Имя узла для логирования.

**Параметры задания (`$Parameters`)**:

*   `service_name` ([string], **Обязательный**): Имя службы Windows (короткое, например, 'Spooler', 'wuauserv').

**Критерии успеха (`$SuccessCriteria`)**:

*   `status` ([string], Необязательный, по умолч. `'Running'`): Ожидаемый статус службы. `CheckSuccess` будет `$true`, только если текущий статус службы равен этому значению. Допустимые значения зависят от `Get-Service` (обычно 'Running', 'Stopped', 'Paused').

**Возвращаемый результат:**

*   Стандартный объект (`IsAvailable`, `CheckSuccess`, `Timestamp`, `Details`, `ErrorMessage`).
*   `$Details` содержит:
    *   `service_name` (string): Имя проверенной службы.
    *   `status` (string): Текущий статус службы (если удалось получить).
    *   `display_name` (string): Отображаемое имя службы.
    *   `start_type` (string): Тип запуска службы.
    *   `can_stop` (bool): Может ли служба быть остановлена.
    *   `success_criteria_failed` (string): (Опционально) Причина несоответствия критерию `status`.
    *   `error` (string): (Опционально) Сообщение об ошибке, если `IsAvailable = $false`.

**Пример конфигурации Задания (Assignment):**

```json
// Пример 1: Проверить, что служба 'wuauserv' запущена
{
  "node_id": 55,
  "method_id": 4, // ID для SERVICE_STATUS
  "is_enabled": true,
  "parameters": {
    "service_name": "wuauserv"
  },
  "success_criteria": null, // Используется критерий по умолчанию (status = 'Running')
  "description": "Проверка службы Windows Update"
}

// Пример 2: Проверить, что служба 'BITS' остановлена
{
  "node_id": 55,
  "method_id": 4, // ID для SERVICE_STATUS
  "is_enabled": true,
  "parameters": {
    "service_name": "BITS"
  },
  "success_criteria": {
    "status": "Stopped" // Явно указываем ожидаемый статус
  },
  "description": "Проверка, что служба BITS остановлена"
}

Возможные ошибки и замечания:

    Права доступа: Для проверки служб на удаленной машине с помощью Get-Service -ComputerName (через Invoke-Command) требуются соответствующие права (обычно административные) и настроенный WinRM.

    Имя службы: Убедитесь, что service_name указано правильно (короткое имя, а не отображаемое).

    WinRM: При удаленных проверках необходима корректная настройка WinRM на целевой машине и, возможно, на машине агента (TrustedHosts или Kerberos/HTTPS).

Зависимости:

    Функция New-CheckResultObject из StatusMonitorAgentUtils.psm1.