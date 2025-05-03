
---

**8. `powershell/configurator/README.md` (Обновление)**

(Замени существующий README.md на этот)

```markdown
# PowerShell Конфигуратор Оффлайн-Агентов (configurator) v3.6

Этот скрипт (`generate_and_deliver_config.ps1`) предназначен для автоматической генерации и (опционально) доставки файлов конфигурации с заданиями для **оффлайн-агентов** системы мониторинга Status Monitor.

## Назначение

*   Подключаться к центральному API системы мониторинга.
*   Запрашивать актуальную конфигурацию заданий для одного или нескольких подразделений (объектов), идентифицируемых по их `ObjectId`.
*   Сохранять полученную конфигурацию (включая метаданные и список заданий) в **JSON файлы** специального формата (`{version_tag}_assignments.json.status.{transport_code}`).
*   Опционально доставлять (копировать) сгенерированные файлы в указанные папки (например, общие сетевые ресурсы, откуда их заберет Транспортная Система или напрямую оффлайн-агент).

## Принцип Работы

1.  Скрипт запускается (вручную или по расписанию).
2.  Читает параметры из файла `config.json`.
3.  Определяет, для каких подразделений (`ObjectId`) нужно сгенерировать конфигурацию:
    *   Если массив `subdivision_ids_to_process` в `config.json` не пуст, обрабатываются только эти ID.
    *   Если массив пуст (`[]`), скрипт запрашивает у API список *всех* подразделений (`GET /api/v1/subdivisions`) и выбирает те, у которых задан `transport_system_code`.
4.  Для каждого выбранного `ObjectId`:
    *   Выполняет GET-запрос к эндпоинту `/api/v1/objects/{ObjectId}/offline_config`, используя API-ключ (с ролью `configurator`).
    *   API (через функцию БД `generate_offline_config`) формирует и возвращает JSON-объект конфигурации, который включает:
        *   `object_id`, `config_type`, `generated_at`
        *   `assignment_config_version`: Уникальный тег версии этой конфигурации (используется оффлайн-агентом).
        *   `transport_system_code`: Код ТС подразделения.
        *   `default_check_interval_seconds`
        *   `assignments`: Массив актуальных заданий для этого объекта.
    *   Скрипт проверяет корректность ответа API.
    *   Формирует имя файла на основе шаблона `output_filename_template`, подставляя `version_tag` и `transport_code`. Пример: `20240520123000_1060_a1b2c3d4_assignments.json.status.TSP`.
    *   Сохраняет полученный JSON от API в файл с этим именем в папку `output_path_base` (в кодировке UTF-8 без BOM).
    *   Если в `config.json` задан `delivery_path_base`:
        *   Формирует путь к целевой подпапке на основе `delivery_subdir_template` и `transport_code`.
        *   Создает целевую папку, если ее нет.
        *   Копирует сгенерированный файл конфигурации в эту целевую папку.
5.  Логирует свою работу в файл, указанный в `config.json`.

## Конфигурация (`config.json`)

Необходимо создать и настроить файл `config.json` в той же папке:

```json
{
  "api_base_url": "http://localhost:48030/api",
  "api_key": "ВАШ_API_КЛЮЧ_С_РОЛЬЮ_CONFIGURATOR",
  "output_path_base": "F:\\status\\builds\\configs\\Generated",
  "delivery_path_base": "F:\\status\\builds\\delivery_conf",
  "log_file": "F:\\status\\builds\\Logs\\configurator.log",
  "log_level": "Info",
  "subdivision_ids_to_process": [],
  "output_filename_template": "{version_tag}_assignments.json.status.{transport_code}",
  "delivery_subdir_template": "{transport_code}",
  "api_timeout_sec": 60
}

Поля конфигурации:

    api_base_url: (Строка, Обязательно) Базовый URL API сервера Status Monitor.

    api_key: (Строка, Обязательно) API ключ с ролью configurator.

    output_path_base: (Строка, Обязательно) Папка для локального сохранения сгенерированных *.json.status.* файлов.

    delivery_path_base: (Строка, Обязательно) Базовый путь для доставки файлов (например, корень общих папок ТС). Скрипт создаст подпапки внутри этого пути.

    log_file: (Строка, Обязательно) Полный путь к лог-файлу конфигуратора.

    log_level: (Строка, Опционально, По умолчанию "Info") Уровень логирования (Debug, Verbose, Info, Warn, Error).

    subdivision_ids_to_process: (Массив Чисел, Обязательно) Определяет, какие подразделения обрабатывать:

        [] (пустой массив): Обработать все с transport_system_code.

        [1516, 1060]: Обработать только указанные ObjectId.

    output_filename_template: (Строка, Обязательно) Шаблон имени файла. Плейсхолдеры: {version_tag}, {transport_code}. Расширение должно быть .json.status.{transport_code}.

    delivery_subdir_template: (Строка, Обязательно) Шаблон имени подпапки в delivery_path_base. Обычно {transport_code}.

    api_timeout_sec: (Число, Опционально, По умолчанию 60) Таймаут ожидания ответа от API в секундах.


# Использовать config.json по умолчанию
.\generate_and_deliver_config.ps1

# Указать другой файл конфигурации
.\generate_and_deliver_config.ps1 -ConfigFile "C:\configs\monitor_cfg.json"

Требования

    PowerShell 5.1+.

    Сетевой доступ к API (api_base_url).

    Права на запись в output_path_base и delivery_path_base.

    Права на запись в log_file.

    Действительный API ключ с ролью configurator.