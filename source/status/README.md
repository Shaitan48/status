# Бэкенд Приложение Status Monitor (Flask v5.x - Гибридная Архитектура)

Эта папка содержит исходный код веб-приложения Flask, которое является ядром системы мониторинга Status Monitor. Оно отвечает за предоставление RESTful API, рендеринг пользовательского веб-интерфейса и взаимодействие с базой данных PostgreSQL в контексте **гибридного агента** и **pipeline-заданий**.

## Назначение

*   **API Сервер:** Предоставляет эндпоинты (`/api/v1/...`) для:
    *   **Гибридных Агентов** (получение pipeline-заданий, отправка результатов их выполнения).
    *   Вспомогательных скриптов (`configurator` для генерации оффлайн-конфигураций с pipeline, `result_loader` для загрузки результатов оффлайн-агентов, запись системных событий).
    *   Фронтенда (получение данных для дашбордов, таблиц, истории, управление сущностями: подразделения, узлы, типы, **pipeline-задания**, API-ключи).
*   **Веб-интерфейс:** Динамически отображает состояние IT-инфраструктуры, историю событий и предоставляет интерфейсы для управления системой.
*   **Бизнес-логика:** Содержит логику обработки данных (например, вычисление статуса узла на основе результатов выполнения **pipeline** в `services/node_service.py`), взаимодействия с БД через слой `repositories/`.
*   **Аутентификация/Авторизация:**
    *   Управляет доступом к веб-интерфейсу через систему логина/пароля (Flask-Login, модель `User`).
    *   Управляет доступом к API через API-ключи (проверка хешей ключей и ролей через декоратор `api_key_required`).

## Технологии

*   Python 3.11
*   Flask (веб-фреймворк)
*   Gunicorn (WSGI-сервер для production)
*   Nginx (обратный прокси, раздача статики)
*   Psycopg2 (`psycopg2-binary`) (драйвер PostgreSQL)
*   Jinja2 (шаблонизатор HTML)
*   Flask-Login (управление сессиями пользователей UI)
*   Flask-SocketIO (для real-time обновлений UI, используется `eventlet`)

## Структура Папки `status`

*   `app/`: Основной код приложения (подробное описание см. в `status/app/readme.txt`).
    *   `app.py`: Фабрика приложения `create_app`.
    *   `wsgi.py`: Точка входа Gunicorn.
    *   `db_connection.py`: Управление пулом соединений к PostgreSQL.
    *   `errors.py`: Кастомные исключения API и обработчики ошибок.
    *   `auth_utils.py`: Утилиты аутентификации и авторизации.
    *   `commands.py`: Команды Flask CLI.
    *   `models/`: Модели данных (например, `User`).
    *   `repositories/`: Слой доступа к данным (SQL-запросы).
    *   `routes/`: Blueprints с маршрутами API и UI.
    *   `services/`: Слой бизнес-logic (например, `node_service.py`).
    *   `static/`: Статические файлы (CSS, JS, иконки).
    *   `templates/`: HTML-шаблоны Jinja2.
*   `nginx/`: Конфигурация Nginx (`nginx.conf`).
*   `tests/`: Модульные и интеграционные тесты для бэкенда (Pytest).
*   `.env` / `.env.example`: Файл(ы) с переменными окружения.
*   `Dockerfile`: Для сборки Docker-образа Flask-приложения.
*   `entrypoint.sh`: Скрипт точки входа для Docker-контейнера.
*   `requirements.txt`, `requirements-dev.txt`: Зависимости Python.

## Конфигурация

Основные параметры конфигурации задаются через **переменные окружения**, которые загружаются из файла `.env` в корне папки `status/`.

*   `DATABASE_URL`: (Обязательно) Строка подключения к PostgreSQL.
*   `SECRET_KEY`: (Обязательно!) Секретный ключ для подписи сессий Flask. **Сгенерируйте свой уникальный ключ!**
*   `FLASK_ENV`: Режим работы Flask (`production` или `development`).
*   `TZ`: Временная зона для контейнера (например, `Europe/Moscow`).

## Запуск с Docker Compose

1.  Убедитесь, что Docker и Docker Compose установлены.
2.  Убедитесь, что база данных PostgreSQL запущена (например, из `postgres/docker-compose.yaml`).
3.  Создайте файл `.env` в папке `status/` (можно скопировать из `.env.example` и изменить).
4.  Запустите сервисы бэкенда (Flask/Gunicorn + Nginx):
    ```bash
    docker-compose up -d --build web nginx
    ```
    (Флаг `--build` нужен при первом запуске или изменениях в `Dockerfile`/`requirements.txt`)
5.  Веб-интерфейс будет доступен по адресу `http://localhost:48030`.

## Команды Flask CLI

Выполняются внутри контейнера `web` (из папки `status`):
`docker-compose exec web flask <команда>`
Например:
*   `docker-compose exec web flask create-user admin_user strong_password`
*   `docker-compose exec web flask create-api-key --description "Hybrid Agent Key" --role agent --object-id 123`
    (Пользователь `adm` с паролем `123` создается автоматически скриптом `entrypoint.sh`).

## Зависимости Python

Перечислены в `requirements.txt` (для production) и `requirements-dev.txt` (для разработки и тестов).