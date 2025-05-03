# Check-PING.ps1

**Назначение:**

Этот скрипт выполняет проверку доступности сетевого узла с помощью ICMP эхо-запросов (пинг), используя стандартный командлет `Test-Connection`.

**Принцип работы:**

1.  Получает целевой IP-адрес или имя хоста (`TargetIP`) и опциональные параметры (`Parameters`) от диспетчера.
2.  Извлекает параметры для `Test-Connection` из `$Parameters`:
    *   `count` (количество запросов, по умолчанию 1).
    *   `buffer_size` (размер буфера, по умолчанию 32).
    *   `timeout_ms` (используется для расчета TTL в PowerShell 5.1, по умолчанию 1000).
3.  Выполняет `Test-Connection` к `$TargetIP`.
4.  **Если пинг успешен:**
    *   Устанавливает `IsAvailable = $true`.
    *   Извлекает время ответа (RTT) и фактический IP-адрес ответившего хоста.
    *   Заполняет `$Details` значениями `response_time_ms`, `ip_address` (ответивший), `target_ip` (запрошенный), `ping_count`.
    *   Проверяет `SuccessCriteria`: если задан `max_rtt_ms` и RTT превышает его, устанавливает `CheckSuccess = $false` и добавляет `ErrorMessage`. Иначе `CheckSuccess = $true`.
5.  **Если пинг не прошел (ошибка `Test-Connection`):**
    *   Устанавливает `IsAvailable = $false`.
    *   Записывает сообщение об ошибке в `ErrorMessage` и `Details`.
    *   `CheckSuccess` остается `$null`.
6.  Возвращает стандартизированный объект результата с помощью `New-CheckResultObject`.

**Параметры скрипта:**

*   `$TargetIP` ([string], Обязательный): IP-адрес или имя хоста для пинга.
*   `$Parameters` ([hashtable], Необязательный): Хэш-таблица с параметрами для `Test-Connection`.
*   `$SuccessCriteria` ([hashtable], Необязательный): Хэш-таблица с критериями успеха.
*   `$NodeName` ([string], Необязательный): Имя узла для логирования.

**Параметры задания (`$Parameters`)**:

*   `count` ([int], Необязательный, по умолч. 1): Количество ICMP-запросов.
*   `buffer_size` ([int], Необязательный, по умолч. 32): Размер буфера ICMP в байтах.
*   `timeout_ms` ([int], Необязательный, по умолч. 1000): Используется для расчета TTL в PS 5.1. Не является прямым таймаутом `Test-Connection`.

**Критерии успеха (`$SuccessCriteria`)**:

*   `max_rtt_ms` ([int], Необязательный): Максимально допустимое среднее время ответа (RTT) в миллисекундах. Если фактическое RTT больше этого значения, `CheckSuccess` будет `$false`.

**Возвращаемый результат:**

*   Стандартный объект (`IsAvailable`, `CheckSuccess`, `Timestamp`, `Details`, `ErrorMessage`).
*   `$Details` содержит:
    *   `response_time_ms` (int): Время ответа в мс (если пинг успешен).
    *   `ip_address` (string): Фактический IP-адрес, ответивший на пинг.
    *   `target_ip` (string): IP-адрес или имя хоста, которое пинговали.
    *   `ping_count` (int): Количество отправленных пакетов.
    *   `success_criteria_failed` (string): (Опционально) Причина неудачи по критерию `max_rtt_ms`.
    *   `error` (string): (Опционально) Сообщение об ошибке, если `IsAvailable = $false`.

**Пример конфигурации Задания (Assignment):**

```json
// Пример 1: Простой пинг
{
  "node_id": 15,
  "method_id": 1, // ID для PING
  "is_enabled": true,
  "parameters": {
    "count": 3 // Отправить 3 пакета
  },
  "success_criteria": null, // Критериев нет
  "description": "Пинг сервера SRV-DB (3 пакета)"
}

// Пример 2: Пинг с проверкой RTT
{
  "node_id": 22,
  "method_id": 1, // ID для PING
  "is_enabled": true,
  "parameters": null, // Параметры по умолчанию
  "success_criteria": {
    "max_rtt_ms": 100 // RTT должен быть не более 100 мс
  },
  "description": "Пинг удаленного офиса (RTT < 100ms)"
}


Возможные ошибки и замечания:

    Брандмауэр: Проверьте настройки брандмауэра на целевой машине и промежуточных устройствах (ICMP Echo Request/Reply должны быть разрешены).

    Разрешение имен: Если в качестве TargetIP используется имя хоста, машина, где выполняется скрипт, должна уметь его разрешать в IP-адрес.

    PowerShell Core vs 5.1: Командлет Test-Connection имеет разные параметры в разных версиях. Скрипт пытается это учесть, но поведение может немного отличаться. Параметры BufferSize и TimeToLive используются только в PS 5.1.

    Таймаут: Стандартный таймаут Test-Connection может быть не очень гибким. Для более точного контроля таймаута может потребоваться использование .NET классов (System.Net.NetworkInformation.Ping).

Зависимости:

    Функция New-CheckResultObject из StatusMonitorAgentUtils.psm1.