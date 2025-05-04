# status/tests/conftest.py
import pytest
import os
import logging
from flask import session # <<< Добавлен импорт session
from app.app import create_app
from app import db_connection
import psycopg2

logging.basicConfig(level=logging.DEBUG)
log = logging.getLogger('pytest_conftest')

# --- ХЕЛПЕРНАЯ ФУНКЦИЯ ---
# Остается как обычная функция, вызывается из фикстур
def create_test_user_cli(runner, username='testuser', password='password'):
    """Вспомогательная функция для создания пользователя через CLI."""
    log.debug(f"[Helper] Вызов CLI: create-user {username} {password}")
    try:
        result = runner.invoke(args=['create-user', username, password])
        log.debug(f"[Helper] Вывод CLI create-user ({username}): {result.output}")
        if result.exception and 'уже существует' not in str(result.exception):
             raise result.exception
        elif 'Ошибка:' in result.output and 'уже существует' not in result.output:
             log.warning(f"[Helper] Команда create-user вернула ошибку: {result.output}")
        else:
             log.info(f"[Helper] Пользователь '{username}' создан или уже существовал.")
    except Exception as e:
        log.error(f"[Helper] Неожиданная ошибка при вызове create-user для {username}: {e}", exc_info=True)
        # Не прерываем, может пользователь уже есть

# --- ХЕЛПЕРНАЯ ФУНКЦИЯ (Перенесена) ---
# Используется внутри фикстуры logged_in_client
def login_test_user(client, username='testuser', password='password'):
    """Вспомогательная функция для выполнения логина через тестовый клиент."""
    log.debug(f"[Helper] Попытка логина пользователя: {username}")
    response = client.post('/login', data={'username': username, 'password': password}, follow_redirects=True)
    log.debug(f"[Helper] Ответ сервера на логин ({username}): {response.status_code}")
    response_text = response.get_data(as_text=True)
    # Мягкие проверки, чтобы не падать если юзер не залогинился (тест должен сам это проверить)
    if response.status_code != 200: log.warning(f"[Helper] Логин {username} не удался: статус {response.status_code}")
    if 'Неверное имя пользователя или пароль' in response_text: log.warning(f"[Helper] Логин {username} не удался: неверные данные")
    if 'Учетная запись неактивна' in response_text: log.warning(f"[Helper] Логин {username} не удался: неактивен")
    with client.session_transaction() as sess:
        if '_user_id' not in sess: log.warning(f"[Helper] User ID для {username} не найден в сессии после логина")
        else: log.info(f"[Helper] Пользователь '{username}' успешно залогинен (ID в сессии: {sess['_user_id']}).")
    return response


# --- ОБЩИЕ ФИКСТУРЫ (session scope) ---
@pytest.fixture(scope='session')
def app():
    """Создает экземпляр приложения Flask для тестовой сессии."""
    # ... (код без изменений) ...
    log.info("Создание тестового экземпляра Flask приложения (scope=session)...")
    os.environ['FLASK_ENV'] = 'testing'
    test_db_url = os.getenv('TEST_DATABASE_URL', 'postgresql://pu_user:pu_password@localhost:48036/pu_db')
    log.warning(f"Тесты будут выполняться на БД: {test_db_url}")
    os.environ['DATABASE_URL'] = test_db_url
    os.environ['SECRET_KEY'] = 'pytest-secret-key-test'
    _app = create_app()
    _app.config.update({"TESTING": True, "LOGIN_DISABLED": False, "WTF_CSRF_ENABLED": False, "PRESERVE_CONTEXT_ON_EXCEPTION": False})
    log.info(f"Тестовое приложение сконфигурировано.")
    yield _app
    log.info("Завершение тестовой сессии Flask приложения.")
    pool_to_close = db_connection.db_pool
    if pool_to_close:
        log.info("Закрытие пула соединений тестового приложения...")
        try: pool_to_close.closeall()
        except Exception as e: log.error(f"Ошибка при закрытии пула соединений: {e}", exc_info=True)
        else: log.info("Пул соединений тестового приложения успешно закрыт.")
    else: log.warning("Пул соединений (db_pool) не найден в db_connection для закрытия.")

@pytest.fixture(scope='function')
def client(app):
    """Тестовый клиент Flask (новый для каждого теста)."""
    return app.test_client()

# Фикстура runner остается сессионной
@pytest.fixture(scope='session')
def runner(app):
    """Тестовый runner для CLI команд (сессионный)."""
    return app.test_cli_runner()

# Фикстура для создания пользователей один раз за сессию
@pytest.fixture(scope='session', autouse=True)
def setup_session_users(runner):
    """Создает тестовых пользователей один раз для всей сессии."""
    log.info("\n--- Настройка пользователей для СЕССИИ тестов (autouse=True) ---")
    # Используем хелперную функцию, определенную выше
    create_test_user_cli(runner, username='key_admin', password='password')
    create_test_user_cli(runner, username='key_viewer', password='password')
    log.info("--- Пользователи для сессии настроены ---")

# <<< Фикстура logged_in_client ТЕПЕРЬ ТОЖЕ должна быть function scope >>>
# Так как она зависит от client, который теперь function scope
@pytest.fixture(scope='function')
def logged_in_client(client): # Теперь зависит от function-scoped client
    """Предоставляет тестовый клиент с уже выполненным входом пользователя 'key_admin'."""
    # ... (код логина без изменений) ...
    login_test_user(client, username='key_admin', password='password')
    with client.session_transaction() as sess:
        if '_user_id' not in sess:
            pytest.fail("Не удалось залогинить пользователя 'key_admin' в фикстуре logged_in_client")
    yield client


# --- ФИКСТＵРА ДЛЯ БД (function scope) ---
@pytest.fixture()
def db_conn(app):
    """Предоставляет соединение с БД для теста, обернутое в транзакцию."""
    # ... (код без изменений, с rollback) ...
    with app.app_context():
        conn = db_connection.get_connection()
        log.debug(f"[DB Fixture] Получено соединение ID: {conn.info.transaction_status if conn else 'N/A'}")
        original_autocommit = conn.autocommit
        conn.autocommit = False
        log.debug("[DB Fixture] Установлено autocommit=False")
        yield conn
        log.debug("[DB Fixture] Откат транзакции после теста...")
        try: conn.rollback()
        except Exception as rollback_err: log.error(f"[DB Fixture] Ошибка отката транзакции: {rollback_err}", exc_info=True)
        else: log.debug("[DB Fixture] Транзакция успешно отменена.")
        finally:
            try: conn.autocommit = original_autocommit
            except Exception as autocommit_err: log.error(f"[DB Fixture] Ошибка восстановления autocommit: {autocommit_err}")
            else: log.debug(f"[DB Fixture] Восстановлено autocommit={original_autocommit}")