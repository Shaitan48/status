# status/app/app.py
"""
Основной файл Flask-приложения для Status Monitor.
Версия 5.0.1: Исправлен импорт и регистрация CLI-команд.
"""
import os
import logging
import logging.config
from typing import Optional, Dict, Any

from flask import Flask, g, request, jsonify # jsonify может понадобиться
from flask_cors import CORS
from flask_socketio import SocketIO
from flask_login import LoginManager

# --- Импорт компонентов приложения ---
from .db_connection import get_connection, close_db_pool, db_pool, psycopg2 # Добавил psycopg2 для user_loader
from .models.user import User
from .repositories import user_repository # Теперь user_repository используется
from .errors import register_error_handlers
from .commands import user_cli, api_key_cli # <<< ИЗМЕНЕНО: Импортируем группы команд
from .routes import init_routes

# --- Инициализация расширений Flask ---
cors: Optional[CORS] = None
socketio: Optional[SocketIO] = None
login_manager: Optional[LoginManager] = None

module_logger = logging.getLogger(__name__)

# --- Фабрика приложения Flask ---
def create_app(config_name: Optional[str] = None, test_config: Optional[Dict[str, Any]] = None) -> Flask:
    global cors, socketio, login_manager

    app = Flask(__name__, instance_relative_config=True)
    module_logger.info(f"Создание экземпляра Flask-приложения (PID: {os.getpid()}). Имя модуля: {app.name}")

    # --- Загрузка конфигурации ---
    app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', 'default-super-secret-key-for-dev-only')
    if app.config['SECRET_KEY'] == 'default-super-secret-key-for-dev-only' and os.getenv('FLASK_ENV') == 'production':
        module_logger.warning("КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ: Используется SECRET_KEY по умолчанию в production-режиме!")
    app.config['DATABASE_URL'] = os.getenv('DATABASE_URL')
    app.config['FLASK_ENV'] = os.getenv('FLASK_ENV', 'production')
    #app.config['DEBUG'] = app.config['FLASK_ENV'] == 'development'

    app.config['DEBUG'] = os.getenv('FLASK_DEBUG', False)
    if app.config['DEBUG']: # Которое должно быть True при FLASK_ENV=development
        logging.basicConfig(level=logging.DEBUG) 
        app.logger.setLevel(logging.DEBUG)
        module_logger.setLevel(logging.DEBUG) # <<< ДОБАВЬ ЭТО ЯВНО ДЛЯ module_logger
        module_logger.info("Уровень логирования app.app (module_logger) установлен в DEBUG.") # Проверка

    if test_config:
        app.config.from_mapping(test_config)
        module_logger.info("Загружена тестовая конфигурация.")
    module_logger.info(f"Режим работы Flask: {app.config['FLASK_ENV']}. DEBUG: {app.config['DEBUG']}")

    # --- Настройка логирования Flask ---
    if app.config['DEBUG']:
        logging.basicConfig(level=logging.DEBUG)
        app.logger.setLevel(logging.DEBUG)
        module_logger.info("Уровень логирования Flask установлен в DEBUG.")
    else:
        logging.basicConfig(level=logging.INFO)
        app.logger.setLevel(logging.INFO)
        module_logger.info("Уровень логирования Flask установлен в INFO.")

    # --- Инициализация расширений Flask ---
    cors = CORS(app, resources={r"/api/*": {"origins": "*"}})
    module_logger.info("Flask-CORS инициализирован.")
    socketio = SocketIO(app, async_mode='eventlet', manage_session=True, cors_allowed_origins="*")
    module_logger.info("Flask-SocketIO инициализирован с async_mode='eventlet'.")
    login_manager = LoginManager()
    login_manager.init_app(app)
    login_manager.login_view = 'auth.login'
    login_manager.login_message = "Пожалуйста, войдите в систему для доступа к этой странице."
    login_manager.login_message_category = "info"
    module_logger.info(f"Flask-Login инициализирован. Страница входа: '{login_manager.login_view}'.")

    @login_manager.user_loader
    def load_user_from_db(user_id_str: str) -> Optional[User]:
        if not user_id_str: return None
        try:
            user_id = int(user_id_str)
            # Используем соединение из g или новое, если нужно
            conn_for_loader = getattr(g, 'db_conn', None)
            needs_new_conn = conn_for_loader is None or conn_for_loader.closed
            
            actual_conn_source = None
            if needs_new_conn:
                module_logger.debug(f"load_user_from_db: g.db_conn отсутствует/закрыто. Получаем новое соединение.")
                actual_conn_source = get_connection() # Это контекстный менеджер
            else:
                actual_conn_source = conn_for_loader # Используем существующее (без with)

            # Логика работы с соединением
            user_data_dict: Optional[Dict] = None
            if needs_new_conn:
                with actual_conn_source as new_conn_ctx: # Используем with для нового соединения
                    cursor = new_conn_ctx.cursor() # Предполагаем RealDictCursor из get_connection
                    user_data_dict = user_repository.get_user_by_id(cursor, user_id)
            else: # Используем существующее соединение из g (без with)
                # Важно: курсор g.db_cursor должен быть уже создан в before_request
                if hasattr(g, 'db_cursor') and g.db_cursor and not g.db_cursor.closed:
                    user_data_dict = user_repository.get_user_by_id(g.db_cursor, user_id)
                else: # Если курсора нет, создаем временный из g.db_conn
                    module_logger.warning("load_user_from_db: g.db_cursor отсутствует или закрыт, создаем временный.")
                    with conn_for_loader.cursor() as temp_cursor: # Временный курсор
                         user_data_dict = user_repository.get_user_by_id(temp_cursor, user_id)

            if user_data_dict:
                module_logger .debug(f"load_user_from_db: Пользователь ID {user_id} найден (данные: {user_data_dict.get('username')}).")
                return User(id=user_data_dict['id'], username=user_data_dict['username'],
                            password_hash=user_data_dict['password_hash'], is_active=user_data_dict['is_active'])
            else:
                module_logger .debug(f"load_user_from_db: Пользователь ID {user_id} не найден.")
                return None
        except ValueError:
            module_logger.warning(f"load_user_from_db: Неверный формат user_id: '{user_id_str}'.")
            return None
        except psycopg2.Error as e_load_user_db:
            module_logger.error(f"load_user_from_db: Ошибка БД при загрузке user ID {user_id_str}: {e_load_user_db}", exc_info=True)
            return None
        except Exception as e_load_user:
            module_logger.error(f"load_user_from_db: Неожиданная ошибка при загрузке user ID {user_id_str}: {e_load_user}", exc_info=True)
            return None

    # --- Регистрация обработчиков запросов ---
    @app.before_request
    def before_request_setup_db():
        if not hasattr(g, 'db_conn') or g.db_conn is None or g.db_conn.closed:
            try:
                if db_pool is None:
                    module_logger.critical("Пул db_pool не инициализирован в db_connection.py!")
                    g.db_conn = None; g.db_cursor = None; return
                
                # Получаем соединение из пула. get_connection() теперь контекстный менеджер,
                # но здесь нам нужно сохранить соединение в g на время запроса.
                # Поэтому напрямую используем db_pool.getconn().
                # Контекстный менеджер get_connection() сам вернет его в пул.
                # Для before_request/teardown_appcontext лучше управлять соединением явно.
                g.db_conn = db_pool.getconn()
                g.db_cursor = g.db_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) # Используем RealDictCursor
                module_logger.debug(f"Соединение с БД (ID: {id(g.db_conn)}) получено из пула и установлено в g.db_conn.")
            except psycopg2.Error as e_getconn_before:
                module_logger.error(f"Ошибка получения соединения из пула в before_request: {e_getconn_before}", exc_info=True)
                g.db_conn = None; g.db_cursor = None
            except Exception as e_setup_g: # Ловим другие возможные ошибки, если get_connection() изменился
                module_logger.error(f"Неожиданная ошибка при установке g.db_conn в before_request: {e_setup_g}", exc_info=True)
                g.db_conn = None; g.db_cursor = None


    @app.teardown_appcontext
    def teardown_db_connection(exception=None):
        cursor = g.pop('db_cursor', None)
        if cursor is not None:
            try:
                if not cursor.closed: cursor.close()
                module_logger.debug("Курсор БД успешно закрыт в teardown_appcontext.")
            except psycopg2.Error as e_close_cur_tear:
                module_logger.error(f"Ошибка при закрытии курсора БД в teardown: {e_close_cur_tear}", exc_info=True)

        conn = g.pop('db_conn', None)
        if conn is not None:
            if db_pool is None:
                module_logger.warning("Пул db_pool не был инициализирован, не могу вернуть соединение из g.db_conn в teardown.")
                try:
                    if not conn.closed: conn.close()
                except psycopg2.Error: pass
                return
            try:
                # Если была ошибка, psycopg2 мог пометить соединение как "broken".
                # putconn сам разберется с этим (не вернет сломанное соединение в пул или закроет его).
                db_pool.putconn(conn)
                module_logger.debug(f"Соединение с БД (ID: {id(conn)}) возвращено в пул в teardown_appcontext.")
            except psycopg2.Error as e_putconn_tear:
                module_logger.error(f"Ошибка при возврате соединения (ID: {id(conn)}) в пул в teardown: {e_putconn_tear}", exc_info=True)

    # --- Регистрация кастомных обработчиков ошибок API ---
    register_error_handlers(app)
    module_logger.info("Кастомные обработчики ошибок API зарегистрированы.")

    # --- Регистрация Blueprints (маршрутов) ---
    init_routes(app)
    module_logger.info("Blueprints (маршруты) успешно инициализированы и зарегистрированы.")

    # --- Регистрация кастомных CLI-команд ---
    if hasattr(app, 'cli'):
        app.cli.add_command(user_cli) # <<< ИЗМЕНЕНО: Регистрируем группу user_cli
        app.cli.add_command(api_key_cli) # <<< ИЗМЕНЕНО: Регистрируем группу api_key_cli
        module_logger.info("Кастомные CLI-команды (группы: user, apikey) зарегистрированы.")
    else:
        module_logger.warning("Объект app.cli не найден, CLI-команды не будут зарегистрированы.")

    # --- Регистрация функции закрытия пула при завершении приложения ---
    import atexit
    atexit.register(close_db_pool)
    module_logger.info("Функция close_db_pool зарегистрирована для выполнения при завершении приложения.")

    module_logger.info("Экземпляр Flask-приложения успешно создан и сконфигурирован.")
    return app

# --- Блок для прямого запуска (для отладки) ---
if __name__ == '__main__':
    logging.basicConfig(level=logging.DEBUG, format='%(asctime)s %(levelname)s %(name)s %(threadName)s: %(message)s')
    flask_app = create_app()
    if socketio:
        module_logger.info("Запуск Flask-приложения с Flask-SocketIO (eventlet) для разработки...")
        socketio.run(flask_app, host='0.0.0.0', port=int(os.getenv('FLASK_RUN_PORT', 5000)), debug=flask_app.config['DEBUG'])
    else:
        module_logger.warning("Flask-SocketIO не инициализирован. Запуск стандартного сервера Flask.")
        flask_app.run(host='0.0.0.0', port=int(os.getenv('FLASK_RUN_PORT', 5000)), debug=flask_app.config['DEBUG'])