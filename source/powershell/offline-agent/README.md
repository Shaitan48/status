
---

**6. `powershell/offline-agent/README.md` (Обновление)**

```markdown
# PowerShell Offline Агент (offline-agent) v3.1

Этот скрипт (`offline-agent.ps1`) выполняет роль агента мониторинга для узлов, работающих в **изолированных сетевых сегментах** без прямого доступа к центральному API системы Status Monitor.

## Назначение

*   Периодически проверять наличие/обновление локального файла с заданиями мониторинга (`*.json.status.*`).
*   Читать и выполнять задания из этого файла с помощью `Invoke-StatusMonitorCheck` из модуля `StatusMonitorAgentUtils`.
*   Собирать **стандартизированные результаты** каждой проверки (включая `IsAvailable`, `CheckSuccess`, `Details`, `ErrorMessage`, `Timestamp`).
*   **Добавлять `assignment_id`** к каждому полученному результату.
*   Сохранять массив этих дополненных результатов в единый JSON-файл (`*.zrpu`) вместе с метаданными (версии скрипта и конфига) в указанную папку для последующей передачи и загрузки в центральную систему.

## Принцип работы

1.  Администратор с помощью скрипта **Конфигуратора** генерирует файл конфигурации заданий (`{version_tag}_assignments.json.status.{transport_code}`) для данного объекта.
2.  Этот файл доставляется на машину агента (например, с помощью Транспортной Системы) в папку, указанную в параметре `assignments_file_path` в локальном `config.json` оффлайн-агента.
3.  Скрипт `offline-agent.ps1` запускается (например, через Планировщик Задач Windows).
4.  Читает параметры из своего локального файла `config.json`.
5.  Импортирует модуль `StatusMonitorAgentUtils`.
6.  В бесконечном цикле (с интервалом `check_interval_seconds`):
    *   Ищет самый новый файл конфигурации заданий в папке `assignments_file_path`.
    *   Если найден новый или измененный файл:
        *   Читает JSON, извлекает массив `assignments` и `assignment_config_version`.
        *   Сохраняет их в памяти (`$script:currentAssignments`, `$script:currentAssignmentVersion`).
    *   Если список `$script:currentAssignments` не пуст:
        *   Для **каждого** задания:
            *   Вызывает **локально** `Invoke-StatusMonitorCheck`, передавая объект задания.
            *   Получает стандартизированный результат (`$checkResult`).
            *   **Создает новый объект**, объединяя `$checkResult` и `assignment_id`.
            *   Добавляет этот новый объект в массив `$cycleCheckResultsList`.
            *   Обрабатывает ошибки выполнения, также добавляя `assignment_id` к записи об ошибке.
    *   Если `$cycleCheckResultsList` не пуст:
        *   Формирует итоговый JSON (`$finalPayload`), включающий `agent_script_version`, `assignment_config_version` и массив `results` (содержащий дополненные результаты).
        *   Сохраняет `$finalPayload` в файл `.zrpu` в папку `output_path`.
    *   Ожидает интервал `check_interval_seconds` перед следующим циклом.
    *   Логирует свою работу.
7.  Файлы `*.zrpu` из папки `output_path` затем забираются и доставляются для обработки Загрузчиком Результатов.

## Конфигурация (`config.json`)

Необходимо создать и настроить файл `config.json` в той же папке, что и `offline-agent.ps1`:

```json
{
    "object_id": 1060,
    "config_type": "offline_multi_check_agent_v3.1",
    "check_interval_seconds": 60,
    "output_path": "C:\\StatusMonitor\\Results",
    "output_name_template": "{ddMMyy_HHmmss}_{object_id}_OfflineChecks.json.status.zrpu",
    "logFile": "C:\\Logs\\StatusMonitor\\offline_agent.log",
    "LogLevel": "Info",
    "assignments_file_path": "C:\\StatusMonitor\\Config"
}

Поля конфигурации:

    object_id: (Число, Обязательно) Внешний ID подразделения (subdivisions.object_id), которому соответствует этот агент. Используется для поиска файла конфигурации.

    config_type: (Строка, Информационно) Тип и версия агента.

    check_interval_seconds: (Число, Опционально, По умолчанию 60) Как часто (в секундах) агент будет выполнять весь цикл проверок и генерировать файл результатов.

    output_path: (Строка, Обязательно) Папка, куда будут сохраняться файлы с результатами (*.zrpu). Папка должна существовать и быть доступна для записи.

    output_name_template: (Строка, Обязательно) Шаблон имени файла результатов. Плейсхолдеры: {ddMMyy_HHmmss}, {object_id}. Расширение должно быть .zrpu.

    logFile: (Строка, Обязательно) Полный путь к лог-файлу агента.

    LogLevel: (Строка, Опционально, По умолчанию "Info") Уровень детализации логов (Debug, Verbose, Info, Warn, Error).

    assignments_file_path: (Строка, Обязательно) Папка, где агент ищет самый новый файл конфигурации, соответствующий его object_id и шаблону (*_<object_id>_*_assignments.json.status.*).

Формат файла результатов (*.zrpu)

Файл представляет собой JSON-объект со следующей структурой:

{
  "agent_script_version": "agent_script_v3.1", // Версия скрипта offline-agent.ps1
  "assignment_config_version": "20240520120000_1060_abc...", // Версия файла с заданиями
  "results": [ // Массив результатов проверок
    {
      // Стандартизированный результат от Invoke-StatusMonitorCheck
      "IsAvailable": true,
      "CheckSuccess": true,
      "Timestamp": "2024-05-20T12:05:30.1234567Z",
      "Details": {
        "disk_letter": "C",
        "percent_free": 25.5,
        "execution_mode": "local_agent",
        // ... другие детали ...
      },
      "ErrorMessage": null,
      // Добавленное поле:
      "assignment_id": 101
    },
    {
      "IsAvailable": false,
      "CheckSuccess": null,
      "Timestamp": "2024-05-20T12:05:35.9876543Z",
      "Details": {
        "error": "Служба 'MyService' не найдена.",
        // ... другие детали ...
      },
      "ErrorMessage": "Служба 'MyService' не найдена.",
      "assignment_id": 102
    }
    // ... другие результаты ...
  ]
}

Запуск и Требования

    PowerShell: Версия 5.1 или выше.

    Модуль StatusMonitorAgentUtils: Папка StatusMonitorAgentUtils должна находиться рядом с папкой offline-agent или в путях $env:PSModulePath.

    Конфиг Заданий: Необходим файл конфигурации заданий (*.json.status.*), сгенерированный Конфигуратором и доставленный в assignments_file_path.

    Права: Права на чтение из assignments_file_path, запись в output_path и logFile. Права для выполнения конкретных проверок.

    Запуск: Рекомендуется запускать через Планировщик Задач Windows или как Службу Windows.

Замечания

    Агент не требует прямого доступа к API.

    Логика конкретных проверок находится в скриптах Checks/Check-*.ps1 модуля StatusMonitorAgentUtils.

    Убедитесь, что Транспортная Система корректно доставляет файлы конфигурации и забирает файлы результатов (*.zrpu).