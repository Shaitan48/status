# status/app/db_connection.py
"""
Модуль для управления пулом соединений с PostgreSQL.
Версия 5.0.3: Убран ненужный экспорт RealDictCursor.
"""
import os
import psycopg2 # Основной модуль
import psycopg2.pool # Для пула соединений
import psycopg2.extras # Для RealDictCursor, если он будет использоваться ЗДЕСЬ
from urllib.parse import urlparse
import logging
import contextlib
from typing import Optional

logger = logging.getLogger(__name__)

try:
    import dateutil.parser
    HAS_DATEUTIL = True
    logger.info("Модуль 'python-dateutil' найден.")
except ImportError:
    HAS_DATEUTIL = False
    logger.warning("Модуль 'python-dateutil' не найден.")

DATABASE_URL = os.getenv('DATABASE_URL')
DB_USER: Optional[str] = None; DB_PASSWORD: Optional[str] = None; DB_HOST: Optional[str] = None
DB_PORT: Optional[int] = None; DB_NAME: Optional[str] = None

if DATABASE_URL:
    parsed_url = urlparse(DATABASE_URL)
    loggable_netloc = parsed_url.hostname or ""
    if parsed_url.port: loggable_netloc += f":{parsed_url.port}"
    if parsed_url.username: loggable_netloc = f"{parsed_url.username}:*****@{loggable_netloc}"
    url_to_log = parsed_url._replace(netloc=loggable_netloc).geturl()
    logger.info(f"Используется DATABASE_URL: {url_to_log}")
    
    DB_USER = parsed_url.username; DB_PASSWORD = parsed_url.password; DB_HOST = parsed_url.hostname
    DB_PORT = parsed_url.port if parsed_url.port else 5432
    DB_NAME = parsed_url.path[1:] if parsed_url.path and len(parsed_url.path) > 1 else None
    if not DB_NAME: logger.critical(...); DB_NAME = "pu_db"; logger.warning(...)
else:
    logger.warning("DATABASE_URL не установлена."); DB_HOST = os.getenv('DB_HOST', 'localhost')
    DB_PORT = int(os.getenv('DB_PORT', 5432)); DB_NAME = os.getenv('DB_NAME', 'pu_db')
    DB_USER = os.getenv('DB_USER', 'pu_user'); DB_PASSWORD = os.getenv('DB_PASSWORD', 'pu_password')

logger.info(f"Параметры БД: HOST={DB_HOST}, PORT={DB_PORT}, USER={DB_USER}, DB_NAME={DB_NAME}")

db_pool: Optional[psycopg2.pool.SimpleConnectionPool] = None
try:
    if not all([DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD is not None]):
        logger.critical("Параметры БД не определены!")
    else:
        db_pool = psycopg2.pool.SimpleConnectionPool(1, 10, host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
                                                    user=DB_USER, password=DB_PASSWORD, connect_timeout=5)
        logger.info(f"Пул соединений psycopg2 инициализирован для {DB_USER}@{DB_HOST}:{DB_PORT}/{DB_NAME}")
except psycopg2.Error as e: logger.critical(f"Ошибка инициализации пула psycopg2: {e}", exc_info=True)
except Exception as e: logger.critical(f"Неожиданная ошибка инициализации пула: {e}", exc_info=True)

@contextlib.contextmanager
def get_connection() -> psycopg2.extensions.connection:
    if db_pool is None: raise Exception("Пул соединений БД не инициализирован.")
    _conn = None
    try:
        _conn = db_pool.getconn()
        logger.debug(f"Контекст: получено соединение (ID: {id(_conn)}, autocommit: {_conn.autocommit}).")
        yield _conn
    except psycopg2.Error as e: logger.error(f"Контекст: ошибка получения соединения: {e}", exc_info=True); raise
    finally:
        if _conn:
            try:
                db_pool.putconn(_conn)
                logger.debug(f"Контекст: соединение (ID: {id(_conn)}) возвращено в пул.")
            except Exception as e: logger.error(f"Контекст: ошибка возврата соединения (ID: {id(_conn)}): {e}", exc_info=True)

def close_db_pool():
    if db_pool:
        logger.info("Закрытие соединений в пуле psycopg2..."); db_pool.closeall(); logger.info("Пул закрыт.")
    else: logger.warning("Пул db_pool не инициализирован, закрытие не требуется.")