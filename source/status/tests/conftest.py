# status/tests/conftest.py
import pytest
import os
import logging
# Импортируем фабрику и управление БД из вашего приложения
from app.app import create_app
from app import db_connection # Импортируем сам модуль
import psycopg2

# Настраиваем логгирование для тестов
logging.basicConfig(level=logging.DEBUG)
log = logging.getLogger('pytest_conftest')

@pytest.fixture(scope='session')
def app():
    """Создает экземпляр приложения Flask для тестовой сессии."""
    log.info("Создание тестового экземпляра Flask приложения (scope=session)...")

    # --- Конфигурация для тестов ---
    os.environ['FLASK_ENV'] = 'testing'
    test_db_url = os.getenv(
        'TEST_DATABASE_URL',
        'postgresql://pu_user:pu_password@localhost:48036/pu_db' # !!! ИСПОЛЬЗУЙТЕ ТЕСТОВУЮ БД !!!
    )
    if 'pu_db_test' not in test_db_url and ('localhost' in test_db_url or '127.0.0.1' in test_db_url): # Немного безопаснее проверка
        log.warning(f"ВНИМАНИЕ: Тесты будут выполняться на БД '{test_db_url}'. Убедитесь, что это НЕ production БД!")
    os.environ['DATABASE_URL'] = test_db_url
    os.environ['SECRET_KEY'] = 'pytest-secret-key-test'

    # Создаем приложение
    _app = create_app()

    # Дополнительные настройки для тестов
    _app.config.update({
        "TESTING": True,
        "LOGIN_DISABLED": False,
        "WTF_CSRF_ENABLED": False,
        "PRESERVE_CONTEXT_ON_EXCEPTION": False
    })
    log.info(f"Тестовое приложение сконфигурировано для БД: {test_db_url}")

    # --- Очистка БД (ОПАСНО, ОПЦИОНАЛЬНО) ---
    # Раскомментируйте и настройте, ТОЛЬКО если используете ОТДЕЛЬНУЮ тестовую БД
    # ... (код очистки, если нужен) ...

    yield _app # Предоставляем приложение тестам

    # --- Очистка после сессии ---
    log.info("Завершение тестовой сессии Flask приложения.")
    # Получаем доступ к пулу через модуль db_connection
    pool_to_close = db_connection.db_pool
    if pool_to_close:
        log.info("Закрытие пула соединений тестового приложения...")
        try:
            pool_to_close.closeall() # Используем метод closeall() пула
            log.info("Пул соединений тестового приложения успешно закрыт.")
        except Exception as e:
            log.error(f"Ошибка при закрытии пула соединений: {e}", exc_info=True)
    else:
        log.warning("Пул соединений (db_pool) не найден в db_connection для закрытия.")

# <<< ИЗМЕНЕНО: scope='session' >>>
@pytest.fixture(scope='session')
def client(app):
    """Тестовый клиент Flask для отправки запросов (сессионный)."""
    return app.test_client()

# <<< ИЗМЕНЕНО: scope='session' >>>
@pytest.fixture(scope='session')
def runner(app):
    """Тестовый runner для вызова Flask CLI команд (сессионный)."""
    return app.test_cli_runner()

# Оставляем db_conn с scope='function', т.к. соединение нужно для каждого теста
@pytest.fixture()
def db_conn(app):
    """Предоставляет соединение с БД для теста (в рамках контекста приложения)."""
    with app.app_context():
        conn = db_connection.get_connection()
        # Можно начать транзакцию здесь, если нужно откатывать изменения после каждого теста
        # conn.autocommit = False # Пример
        yield conn
        # И откатить ее здесь
        # conn.rollback() # Пример
        # Соединение вернется в пул автоматически через teardown_appcontext