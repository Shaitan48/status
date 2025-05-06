
---

### 4. README для Модуля Утилит

**Файл:** `powershell/StatusMonitorAgentUtils/README.md` (Обновленный)

```markdown
# Модуль PowerShell: StatusMonitorAgentUtils (v1.1.0+)

Этот модуль PowerShell (`StatusMonitorAgentUtils.psm1` и папка `Checks/`) предоставляет общую функциональность для **Гибридного Агента Мониторинга** системы Status Monitor.

## Назначение

*   **Инкапсуляция логики проверок:** Содержит код для выполнения различных типов проверок (PING, статус службы, использование диска, SQL-запросы, проверка сертификатов и т.д.).
*   **Диспетчеризация:** Предоставляет единую точку входа (`Invoke-StatusMonitorCheck`) для Гибридного Агента, которая определяет нужный метод проверки и запускает соответствующий скрипт.
*   **Стандартизация результатов:** Обеспечивает возврат результатов проверок в едином формате (стандартная хэш-таблица).
*   **Проверка Критериев Успеха:** Содержит универсальную функцию `Test-SuccessCriteria` (и вспомогательные `Compare-Values`, `Test-ArrayCriteria`) для гибкой проверки результатов на соответствие заданным критериям (`success_criteria` в задании).
*   **Переиспользование кода:** Содержит общие вспомогательные функции.

## Ключевые компоненты

1.  **`StatusMonitorAgentUtils.psm1`**: Основной файл модуля. Содержит:
    *   **`Invoke-StatusMonitorCheck` (Экспортируемая):**
        *   **Роль:** Диспетчер проверок. Вызывается Гибридным Агентом.
        *   **Вход:** Объект задания (`$Assignment`).
        *   **Логика:** Определяет метод, находит скрипт `Checks/Check-*.ps1`, подготавливает параметры (включая `$SuccessCriteria`), запускает скрипт локально, возвращает результат.
    *   **`New-CheckResultObject` (Экспортируемая):**
        *   **Роль:** Формирование стандартного объекта результата. Используется скриптами `Checks/*.ps1`.
        *   **Вход:** `$IsAvailable`, `$CheckSuccess`, `$Details`, `$ErrorMessage`.
        *   **Выход:** Стандартная хэш-таблица результата.
    *   **`Test-SuccessCriteria` (Экспортируемая):**
        *   **Роль:** Универсальная рекурсивная проверка соответствия объекта `$Details` заданным `$SuccessCriteria`.
        *   **Вход:** `$DetailsObject`, `$CriteriaObject`.
        *   **Логика:** Рекурсивно обходит структуру критериев, использует `Compare-Values` для сравнения значений и `Test-ArrayCriteria` для обработки массивов (с ключами `_condition_`, `_where_`, `_criteria_`, `_count_`).
        *   **Выход:** `@
{ Passed = $true/$false/$null; FailReason = "..."/$null }`.
    *   **`Compare-Values` (Экспортируемая):** Сравнивает два значения с помощью указанного оператора (`==`, `>`, `contains` и т.д.).
    *   **`Test-ArrayCriteria` (Приватная):** Обрабатывает критерии для массивов в `$Details`.

2.  **Папка `Checks/`**: Содержит отдельные `.ps1` файлы для **каждого** метода проверки.
    *   **Именование:** `Check-METHOD_NAME.ps1`.
    *   **Назначение:** Реализация логики конкретной проверки.
    *   **Вход:** Параметры `$TargetIP`, `$Parameters`, `$SuccessCriteria`, `$NodeName`.
    *   **Логика:** Выполнить проверку, сформировать `$details`, определить `$isAvailable`, вызвать `Test-SuccessCriteria` для определения `$checkSuccess` (если нужно), сформировать `$errorMessage`, вернуть результат через `New-CheckResultObject`.

## Стандартный Формат Результата Проверки

(Описание формата результата без изменений)

```powershell
@{
    IsAvailable = [bool] # УДАЛОСЬ ли выполнить проверку?
    CheckSuccess = [nullable[bool]] # Соответствует ли результат КРИТЕРИЯМ? (null если IsAvailable=false или ошибка критериев)
    Timestamp = [string] # UTC ISO 8601
    Details = [hashtable] # Детали проверки (зависят от метода)
    ErrorMessage = [string] # Описание ошибки (если IsAvailable=false ИЛИ CheckSuccess=false/null)
}

Добавление Новых Методов Проверки

(Процесс без изменений)

    Добавить запись в таблицу check_methods БД.

    Создать файл Checks/Check-METHOD_NAME.ps1.

    Реализовать логику:

        Получить параметры.

        Выполнить проверку.

        Сформировать $details.

        Определить $isAvailable.

        Вызвать Test-SuccessCriteria, если нужно.

        Сформировать $errorMessage.

        Вернуть New-CheckResultObject.

    Протестировать через Invoke-StatusMonitorCheck.

    Создать Задание в UI.

Установка и Использование

Модуль копируется вместе с Гибридным Агентом.

    Структура папок:

          
    <Папка_Агента>/
    ├── hybrid-agent/
    │   ├── hybrid-agent.ps1
    │   └── config.json
    └── StatusMonitorAgentUtils/  <-- Модуль здесь
        ├── Checks/
        │   ├── Check-PING.ps1
        │   └── ...
        ├── StatusMonitorAgentUtils.psd1
        └── StatusMonitorAgentUtils.psm1
        └── README.md (этот файл)

        

    IGNORE_WHEN_COPYING_START

    Use code with caution.
    IGNORE_WHEN_COPYING_END

    Скрипт hybrid-agent.ps1 импортирует модуль из ..\StatusMonitorAgentUtils.

      
---

Эти README файлы отражают последние изменения в ТЗ v5.2, включая переход на Гибридный Агент, унификацию API, атомарные операции и папку DLQ для Загрузчика.

    