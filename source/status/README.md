# Бэкенд Приложение Status Monitor (Flask)

Эта папка содержит исходный код веб-приложения Flask, которое является ядром системы Status Monitor. Оно отвечает за предоставление RESTful API, рендеринг пользовательского веб-интерфейса и взаимодействие с базой данных PostgreSQL.

## Назначение

*   **API Сервер:** Предоставляет эндпоинты (`/api/v1/...`) для:
    *   Агентов мониторинга (получение заданий, отправка результатов).
    *   Вспомогательных скриптов (генерация конфигурации, загрузка результатов, запись событий).
    *   Фронтенда (получение данных для дашбордов, таблиц, истории, управление сущностями).
*   **Веб-интерфейс:** Динамически отображает состояние IT-инфраструктуры, историю событий и предоставляет интерфейсы для управления системой (подразделения, узлы, типы, задания, API-ключи).
*   **Бизнес-логика:** Содержит логику обработки данных (например, вычисление статуса узла в `services/`), взаимодействия с БД через `repositories/`.
*   **Аутентификация/Авторизация:**
    *   Управляет доступом к веб-интерфейсу через систему логина/пароля (используя Flask-Login и модель `User`).
    *   Управляет доступом к API через API-ключи (модель `APIKey`, проверка хешей ключей и ролей через декоратор `api_key_required`).

## Технологии

*   Python 3.11
*   Flask (веб-фреймворк)
*   Gunicorn (WSGI-сервер для production)
*   Nginx (обратный прокси, раздача статики)
*   Psycopg2 (`psycopg2-binary`) (драйвер PostgreSQL)
*   Jinja2 (шаблонизатор HTML)
*   Flask-Login (управление сессиями пользователей UI)
*   Flask-SocketIO (для будущих real-time обновлений UI, требует `eventlet` или `gevent`)

## Структура Папки `app`

Приложение использует структуру с фабрикой (`create_app`) и Blueprints.

*   `app.py`: **Фабрика приложения (`create_app`)**. Инициализирует Flask, расширения (LoginManager, SocketIO), регистрирует Blueprints, настраивает логирование и пул соединений БД.
*   `wsgi.py`: Точка входа для WSGI-сервера (Gunicorn). Импортирует `create_app`.
*   `db_connection.py`: Управление пулом соединений к PostgreSQL (`psycopg2.pool.ThreadedConnectionPool`). Предоставляет `get_connection()`, `close_connection()`.
*   `db_helpers.py`: Вспомогательные функции для работы с БД (например, `build_where_clause`, функции для работы с иерархией).
*   `errors.py`: Определяет кастомные классы исключений (`ApiException`) и регистрирует глобальные обработчики ошибок Flask для стандартизации ответов API.
*   `auth_utils.py`: Декоратор `api_key_required` для защиты API-эндпоинтов.
*   `commands.py`: Кастомные команды Flask CLI (`flask create-user`, `flask create-api-key`).
*   `models/`:
    *   `user.py`: Модель `User` для Flask-Login.
    *   `__init__.py`
*   `repositories/`: Модули для инкапсуляции SQL-запросов и взаимодействия с БД для каждой сущности (`node_repository.py`, `api_key_repository.py` и т.д.). Вызываются из маршрутов или сервисов.
*   `routes/`: Модули, определяющие Flask Blueprints для различных групп маршрутов (`node_routes.py`, `auth_routes.py`, `html_routes.py` и т.д.). Содержат логику обработки HTTP-запросов.
    *   `__init__.py`: Регистрирует все Blueprints в приложении с нужными префиксами (например, `/api/v1`).
*   `services/`: Модули для бизнес-логики, не привязанной напрямую к HTTP (например, `node_service.py` для вычисления комплексного статуса узла).
*   `static/`: Статические файлы (CSS, JS, иконки, изображения).
    *   `style.css`: Основные стили.
    *   `icons/`: SVG-иконки для типов узлов.
    *   `images/subdivisions/`: Иконки для подразделений.
    *   `favicon.png`: Иконка сайта.
*   `templates/`: HTML-шаблоны Jinja2 для веб-интерфейса (`base.html`, `dashboard.html`, страницы управления и т.д.).

## Конфигурация

Основные параметры конфигурации задаются через **переменные окружения**, которые загружаются из файла `.env` в корне папки `status/`.

*   `DATABASE_URL`: (Обязательно) Строка подключения к PostgreSQL.
    *   Пример для Docker Compose: `postgresql://pu_user:pu_password@postgres:5432/pu_db`
    *   Пример для Docker Desktop (доступ к хосту): `postgresql://pu_user:pu_password@host.docker.internal:48036/pu_db`
*   `SECRET_KEY`: (Обязательно!) Секретный ключ для подписи сессий Flask (Flask-Login). Должен быть длинным, случайным и храниться в секрете. **Сгенерируйте свой ключ!**
*   `FLASK_ENV`: Режим работы Flask (`production` или `development`). Влияет на логирование и режим отладки.
*   `TZ`: Временная зона для контейнера (например, `Europe/Moscow`).

## Запуск с Docker Compose

1.  Убедитесь, что Docker и Docker Compose установлены.
2.  Убедитесь, что база данных PostgreSQL запущена (например, с помощью `docker-compose up -d` в папке `postgres/`).
3.  Создайте файл `.env` в папке `status/` с необходимыми переменными окружения (`DATABASE_URL`, `SECRET_KEY`).
4.  (При первом запуске или изменении `requirements.txt`) Соберите образ:
    ```bash
    docker-compose build web
    ```
5.  Запустите сервисы бэкенда (Flask/Gunicorn + Nginx):
    ```bash
    docker-compose up -d
    ```
6.  Веб-интерфейс будет доступен по адресу `http://localhost:48030` (или другому порту, если настроено в `docker-compose.yaml`).
7.  Для остановки:
    ```bash
    docker-compose down
    ```

## Команды Flask CLI

Команды выполняются внутри контейнера `web` (из папки `status`):

*   **Создать пользователя UI:**
    ```bash
    docker-compose exec web flask create-user <имя_пользователя> <пароль>
    ```
    (Пользователь `adm` с паролем `123` создается автоматически при первом запуске).
*   **Создать API ключ:**
    ```bash
    # Пример ключа для агента объекта 1060
    docker-compose exec web flask create-api-key --description "Agent OTRPK" --role agent --object-id 1060
    # Пример ключа для загрузчика
    docker-compose exec web flask create-api-key --description "Result Loader" --role loader
    ```
    **ВАЖНО:** Сразу скопируйте ключ после генерации!

## Зависимости Python

Основные зависимости перечислены в `requirements.txt`. Устанавливаются автоматически при сборке Docker-образа.