﻿**Пояснения к изменениям в `description API.txt`:**
*   Добавлен большой блок с предупреждением в самом начале файла о его неактуальности.
*   Указаны ссылки на актуальные файлы документации для v5.x.
*   Остальное содержимое файла оставлено без изменений, т.к. оно относится к v4.x.

---

**2. Файл `status/app/readme.txt`**

Этот файл описывает структуру и назначение бэкенд-приложения Flask. Обновляю его, чтобы он соответствовал архитектуре v5.x (Гибридный агент, pipeline-задания).

Вот обновленный файл:
`F:\status\source\status\app\readme.txt`
```text
# Папка status/app (v5.x - Архитектура с Гибридным Агентом и Pipeline)

Эта папка содержит основной код веб-приложения Flask, которое является ядром системы мониторинга Status Monitor версии 5.x.
Приложение отвечает за:
- Предоставление RESTful API для взаимодействия с Гибридным Агентом и другими компонентами.
- Отображение пользовательского веб-интерфейса (UI) для управления системой и просмотра статусов.
- Реализацию бизнес-логики, связанной с обработкой pipeline-заданий и результатов их выполнения.
- Взаимодействие с базой данных PostgreSQL.

## Основные Принципы Архитектуры v5.x (в контексте этого приложения):

*   **Единый Гибридный Агент:** Бэкенд теперь взаимодействует только с одним типом агента — Гибридным Агентом, который может работать в онлайн или оффлайн режиме. API-эндпоинты для агентов унифицированы.
*   **Pipeline-Задания:** Логика проверок определяется "pipeline" — последовательностью шагов, описанной в JSON-формате и хранящейся в базе данных (`node_check_assignments.pipeline`).
    *   Бэкенд отдает эти pipeline-задания агентам.
    *   Бэкенд принимает результаты выполнения всего pipeline (агрегированный результат или детализацию по шагам).
*   **Централизованное Управление:** Вся конфигурация (подразделения, узлы, типы узлов, методы/типы шагов pipeline, сами pipeline-задания, пользователи, API-ключи) и история хранятся в PostgreSQL.
*   **Модульная Структура:** Код организован с использованием Flask Blueprints для маршрутов, репозиториев для доступа к данным и сервисного слоя для бизнес-логики.

## Структура папки `app`:

-   **`app.py`**:
    *   **Фабрика приложения (`create_app`)**: Основная точка сборки приложения.
    *   Инициализирует Flask, расширения (Flask-Login для UI, Flask-SocketIO для real-time обновлений, Flask-CORS).
    *   Настраивает логирование.
    *   Устанавливает пул соединений к PostgreSQL (`db_connection.py`).
    *   Регистрирует все Blueprints (маршруты).
    *   Регистрирует кастомные CLI-команды (`commands.py`).
    *   Регистрирует обработчики ошибок (`errors.py`).

-   **`wsgi.py`**: Точка входа для WSGI-сервера (например, Gunicorn), используемого в production.

-   **`db_connection.py`**: Управляет пулом соединений к PostgreSQL (использует `psycopg2.pool`).

-   **`db_helpers.py`**:
    *   **[РЕВИЗИЯ/УДАЛЕНИЕ]** Содержит вспомогательные функции для работы с БД. В новой архитектуре большая часть этой функциональности должна быть инкапсулирована в соответствующих **репозиториях**. Необходимо провести ревизию: удалить устаревшие функции, а актуальные перенести в репозитории или убедиться, что они не дублируют логику репозиториев.

-   **`errors.py`**: Определяет кастомные классы исключений для API (например, `ApiNotFound`, `ApiBadRequest`) и регистрирует их обработчики для стандартизации JSON-ответов об ошибках.

-   **`auth_utils.py`**:
    *   Содержит утилиты для аутентификации пользователей UI (хеширование/проверка паролей).
    *   Содержит утилиты для аутентификации API-клиентов (проверка API-ключей).
    *   Включает декоратор `@api_key_required` для защиты API-эндпоинтов и, возможно, `@admin_required_ui` для защиты UI-маршрутов, требующих прав администратора (если используется).

-   **`commands.py`**:
    *   Определяет кастомные команды Flask CLI (например, `flask create-user`, `flask create-api-key`).
    *   Эти команды должны использовать слой **репозиториев** для взаимодействия с базой данных.

-   **`models/`**:
    *   `user.py`: Модель данных `User`, совместимая с Flask-Login, для аутентификации пользователей в веб-интерфейсе.
    *   (Могут быть и другие модели, если используются ORM или для структурирования данных).

-   **`repositories/`** (См. также `status/app/repositories/README.md`):
    *   Ключевой слой для инкапсуляции SQL-запросов и прямого взаимодействия с БД.
    *   Каждый модуль-репозиторий отвечает за одну бизнес-сущность (например, `node_repository.py`, `assignment_repository.py`).
    *   `assignment_repository.py` должен быть адаптирован для работы с полем `pipeline JSONB` в таблице `node_check_assignments`.
    *   `check_repository.py` должен корректно записывать и извлекать результаты выполнения pipeline-заданий, включая возможную детализацию по шагам.

-   **`routes/`**:
    *   Содержит модули, определяющие Flask Blueprints для различных групп маршрутов:
        *   API-эндпоинты для Гибридного Агента, Конфигуратора, Загрузчика (например, `agent_routes.py`, `check_routes.py`).
        *   API-эндпоинты для управления сущностями через UI (например, `node_routes.py`, `assignment_routes.py`).
        *   Маршруты для рендеринга HTML-страниц UI (например, `html_routes.py`).
    *   `__init__.py` в этой папке регистрирует все созданные Blueprints в приложении Flask.
    *   **`assignment_routes.py`**: Маршруты для управления заданиями должны поддерживать создание/редактирование поля `pipeline`.

-   **`services/`** (См. также `status/app/services/README.md`):
    *   Модули, содержащие бизнес-логику, не привязанную напрямую к HTTP-запросам.
    *   Например, `node_service.py` может отвечать за вычисление обобщенного статуса узла на основе результатов выполнения его pipeline-заданий (вместо простой PING-проверки, как было в v4). Это важный момент для адаптации.

-   **`static/`**: Статические файлы для веб-интерфейса (CSS-стили, JavaScript-код для UI, изображения, иконки).

-   **`templates/`**: HTML-шаблоны Jinja2, используемые для рендеринга веб-интерфейса.
    *   Шаблон `manage_assignments.html` должен предоставлять UI для конструирования или редактирования `pipeline` (например, через текстовый JSON-редактор или более продвинутый визуальный конструктор).

## Ключевые Изменения и Точки Внимания для v5.x:

1.  **API для агентов (`agent_routes.py`):**
    *   `GET /assignments`: Должен возвращать список заданий, где каждое задание содержит поле `pipeline` (JSONB, десериализованное в Python list/dict). Поля `parameters` и `success_criteria` (если они были на верхнем уровне задания) должны отсутствовать или быть частью каждого шага в `pipeline`.
    *   `GET /objects/{id}/offline_config`: Аналогично, должен генерировать конфигурацию, где задания содержат `pipeline`.

2.  **API для результатов проверок (`check_routes.py`):**
    *   `POST /checks` (одиночный результат): Принимает результат выполнения *всего pipeline-задания*. `detail_data` этого результата может содержать массив с результатами каждого отдельного шага pipeline, если такая детализация предусмотрена.
    *   `POST /checks/bulk` (пакетная загрузка): Аналогично для каждого элемента в пакете.

3.  **Репозиторий Заданий (`assignment_repository.py`):**
    *   Все CRUD-операции для заданий должны корректно работать с полем `pipeline JSONB`.
    *   Функции `create_assignment` и `update_assignment` должны принимать `pipeline` как Python list/dict и сериализовать его в JSON-строку перед записью в БД.
    *   Функции чтения заданий должны десериализовывать `pipeline` из JSON-строки обратно в Python list/dict.

4.  **Шаблон Управления Заданиями (`manage_assignments.html`):**
    *   Должен предоставлять пользователю интерфейс для определения и редактирования `pipeline` для каждого задания. Это может быть простой `textarea` для JSON или более сложный UI-конструктор.

5.  **Сервис Узлов (`node_service.py`):**
    *   Функция `get_processed_node_status` для вычисления отображаемого статуса узла, вероятно, потребует значительной переработки. Статус узла теперь может зависеть от результатов выполнения сложного pipeline (например, от успеха/провала определенных шагов), а не только от одной проверки (как PING в v4). Это может потребовать анализа `node_checks` и `node_check_details` для последнего выполненного "ключевого" задания узла.

## Запуск (в контексте всей системы):

Flask-приложение (`status_web_e2e_test` или аналогичное) запускается с помощью Gunicorn через `wsgi.py` в Docker-контейнере, как описано в основном `README.md` и `status/docker-compose.yaml`. Nginx (`status_nginx_e2e_test`) выступает в роли обратного прокси.