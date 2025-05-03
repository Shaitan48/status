# status/app/app.py
import os
import logging
from flask import Flask, g, request
from flask_socketio import SocketIO
from flask_login import LoginManager

# Используем ОТНОСИТЕЛЬНЫЕ импорты из текущего пакета 'app'
from .routes import init_routes
from . import errors
from . import db_connection
from .models.user import User
from .commands import create_user_command, create_api_key_command

# --- Инициализация расширений ---
# Инициализируем объекты расширений БЕЗ привязки к конкретному app
# и БЕЗ указания async_mode здесь. Это будет сделано внутри create_app.
socketio = SocketIO()
login_manager = LoginManager()

# --- Конфигурация Flask-Login ---

# Функция загрузки пользователя, вызывается Flask-Login при каждом запросе
# для получения объекта текущего пользователя из сессии.
@login_manager.user_loader
def load_user(user_id):
    """Загружает пользователя по ID для Flask-Login."""
    # Здесь мы должны получить пользователя из БД по ID.
    # В реальном приложении лучше использовать UserRepository.
    # Важно обрабатывать исключения и возвращать None, если пользователь не найден.
    try:
        # Получаем соединение БД из контекста запроса 'g'
        conn = db_connection.get_connection()
        cursor = conn.cursor()
        # Выполняем запрос к таблице users
        cursor.execute("SELECT id, username, password_hash, is_active FROM users WHERE id = %s", (int(user_id),))
        user_data = cursor.fetchone()
        # Если пользователь найден в БД
        if user_data:
            # Создаем объект User из модели
            user = User(
                id=user_data['id'],
                username=user_data['username'],
                password_hash=user_data['password_hash'],
                is_active=user_data['is_active'] # Передаем статус активности
            )
            # Проверяем, активен ли пользователь (дополнительная проверка)
            if user.is_active:
                return user # Возвращаем объект User, если он активен
            else:
                # Пользователь найден, но неактивен
                logging.getLogger(__name__).warning(f"Попытка загрузить неактивного пользователя ID: {user_id}")
                return None
        # Пользователь не найден в БД
        return None
    except Exception as e:
        # Логируем ошибку при загрузке пользователя
        logging.getLogger(__name__).error(f"Ошибка в user_loader для ID {user_id}: {e}", exc_info=True)
        return None
    # Соединение будет возвращено в пул автоматически через teardown_appcontext

# Указываем эндпоинт (маршрут) для страницы входа.
# Flask-Login будет перенаправлять сюда неаутентифицированных пользователей,
# пытающихся получить доступ к защищенным через @login_required страницам.
# 'auth.login' означает: функция 'login' в Blueprint с именем 'auth'.
login_manager.login_view = 'auth.login'
# Сообщение, которое будет показано пользователю при перенаправлении на логин.
login_manager.login_message = "Пожалуйста, войдите для доступа к этой странице."
# Категория flash-сообщения (используется, если вы показываете flash-сообщения в шаблоне).
login_manager.login_message_category = "warning"

# --- Фабрика приложения Flask ---
def create_app():
    """
    Создает и конфигурирует экземпляр приложения Flask.
    Это основной паттерн "Application Factory".
    """
    # Создаем сам объект Flask.
    # __name__ используется Flask для определения пути к шаблонам и статике.
    # template_folder и static_folder указывают на папки относительно 'app'.
    app = Flask(__name__, template_folder='templates', static_folder='static')
    app.logger.info('Создание экземпляра Flask приложения...')

    # --- Конфигурация приложения ---
    # Загрузка SECRET_KEY из переменных окружения. КРИТИЧЕСКИ ВАЖНО для безопасности сессий!
    app.config['SECRET_KEY'] = os.getenv('SECRET_KEY')
    if not app.config['SECRET_KEY']:
        app.logger.critical("Критическая ошибка: Переменная окружения SECRET_KEY не установлена!")
        # Прерываем запуск, если ключ не задан.
        raise ValueError("Необходимо установить SECRET_KEY в переменных окружения")

    # Установка флага TESTING из переменной окружения или значения по умолчанию
    # Это значение будет использоваться в conftest.py для настройки тестов.
    app.config['TESTING'] = os.environ.get('FLASK_ENV') == 'testing'

    # --- Настройка Логирования ---
    # Определяем, как будет работать логирование в зависимости от режима.
    if os.environ.get('FLASK_ENV') == 'production' or not app.debug:
        # В production используем логгер WSGI-сервера (Gunicorn).
        gunicorn_logger = logging.getLogger('gunicorn.error')
        app.logger.handlers = gunicorn_logger.handlers
        app.logger.setLevel(gunicorn_logger.level)
        app.logger.info('Логирование настроено на использование логгера Gunicorn.')
    else:
        # В development или testing используем базовую конфигурацию с выводом в консоль.
        log_level = logging.DEBUG if app.config['TESTING'] else logging.INFO
        logging.basicConfig(level=log_level, format='%(asctime)s %(levelname)s %(name)s:%(lineno)d - %(message)s')
        app.logger.info(f'Логирование настроено для разработки/тестирования (Уровень: {logging.getLevelName(log_level)}).')

    # --- Регистрация Команд CLI ---
    # Добавляем кастомные команды, которые можно будет вызывать через `flask <имя_команды>`.
    app.cli.add_command(create_user_command)
    app.logger.info('Flask CLI команда create-user зарегистрирована.')
    app.cli.add_command(create_api_key_command)
    app.logger.info('Flask CLI команда create-api-key зарегистрирована.')

    # --- Инициализация Пула Соединений с БД ---
    # Используем контекст приложения, чтобы убедиться, что конфиг загружен.
    try:
        with app.app_context():
             db_connection.init_pool() # Вызываем функцию инициализации пула
    except Exception as e:
         # Если пул не создался - это критическая ошибка, приложение не сможет работать.
         app.logger.critical(f"Не удалось инициализировать пул БД при старте приложения: {e}", exc_info=True)
         raise # Прерываем запуск

    # --- Регистрация обработчиков для управления соединением БД ---
    # Эти функции будут вызываться Flask автоматически для каждого запроса.
    @app.before_request
    def before_request_func():
        """Получает соединение из пула перед обработкой запроса."""
        try:
            # Попытка получить соединение и сохранить его в контексте запроса 'g'.
            # 'g' - это специальный объект Flask, доступный только во время обработки одного запроса.
            db_connection.get_connection()
        except RuntimeError as e:
            # Логируем ошибку, если не удалось получить соединение.
            # Можно раскомментировать abort, чтобы прерывать запрос с ошибкой 503 Service Unavailable.
            app.logger.error(f"Не удалось получить соединение с БД для запроса {request.path}: {e}")
            # import flask; flask.abort(503, description="Database connection failed.")

    @app.teardown_appcontext
    def teardown_db(exception=None):
        """Возвращает соединение обратно в пул после завершения обработки запроса."""
        # Эта функция вызывается всегда, даже если во время запроса произошла ошибка.
        db_connection.close_connection(exception)

    # --- Инициализация Расширений с приложением 'app' ---

    # <<< ИЗМЕНЕНИЕ: Условная инициализация SocketIO в зависимости от режима TESTING >>>
    testing = app.config.get('TESTING', False) # Получаем флаг TESTING
    if testing:
        # Для тестов используем 'threading'. Он не требует eventlet/gevent
        # и лучше работает в разных окружениях, включая Windows.
        # Это важно, чтобы тесты могли запускаться локально без Docker.
        socketio_async_mode = 'threading'
        app.logger.info("Инициализация SocketIO в режиме 'threading' для тестов.")
    else:
        # Для обычного запуска (в Docker) используем 'eventlet',
        # т.к. он установлен в Dockerfile и указан в CMD для Gunicorn.
        socketio_async_mode = 'eventlet'
        app.logger.info("Инициализация SocketIO в режиме 'eventlet'.")

    # Инициализируем SocketIO с приложением и выбранным async_mode.
    # cors_allowed_origins="*" разрешает подключения с любого источника (для простоты).
    # В production лучше указать конкретный домен фронтенда.
    socketio.init_app(app, async_mode=socketio_async_mode, cors_allowed_origins="*")
    # <<< КОНЕЦ ИЗМЕНЕНИЯ >>>

    # Инициализируем Flask-Login с приложением 'app'.
    login_manager.init_app(app)
    app.logger.info('Flask-Login инициализирован.')

    # --- Регистрация Маршрутов (Blueprints) и Обработчиков Ошибок ---
    # Вызываем функцию из routes/__init__.py, которая зарегистрирует все наши Blueprints.
    init_routes(app)
    # Регистрируем глобальные обработчики ошибок из errors.py.
    errors.register_error_handlers(app)

    app.logger.info("Flask приложение создано и сконфигурировано.")
    # Возвращаем готовый экземпляр приложения.
    return app

# --- Точка входа для прямого запуска (не используется Gunicorn) ---
# Этот блок выполняется, только если скрипт запущен напрямую (python app/app.py).
# Полезно для локальной отладки БЕЗ Docker или Gunicorn.
# if __name__ == '__main__':
#     # Создаем приложение через фабрику
#     app = create_app()
#     # Запускаем сервер разработки Flask + SocketIO
#     # host='0.0.0.0' делает сервер доступным по сети (не только localhost)
#     # debug=True включает режим отладки Flask
#     # use_reloader=True автоматически перезапускает сервер при изменении кода
#     # ВАЖНО: Не используйте debug=True и use_reloader=True в production!
#     socketio.run(app, host='0.0.0.0', port=5000, debug=True, use_reloader=True)