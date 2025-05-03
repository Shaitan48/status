# status/app/db_connection.py
import os
import logging
import psycopg2
from psycopg2 import pool
from psycopg2.extras import RealDictCursor
from flask import g

# ===>>> ДОБАВЛЯЕМ ПРОВЕРКУ DATEUTIL И ФЛАГ <<<===
try:
    from dateutil import parser as dateutil_parser
    HAS_DATEUTIL = True
except ImportError:
    HAS_DATEUTIL = False
# ===>>> КОНЕЦ БЛОКА ПРОВЕРКИ <<<===

logger = logging.getLogger(__name__)

# Глобальная переменная для хранения пула
db_pool = None

MIN_CONNECTIONS = 1
MAX_CONNECTIONS = 10

def init_pool():
    """Инициализирует пул соединений PostgreSQL."""
    global db_pool
    db_url = os.getenv('DATABASE_URL')
    if not db_url:
        logger.critical("Переменная окружения DATABASE_URL не установлена!")
        raise ValueError("DATABASE_URL не установлена")

    if db_pool is None:
        try:
            logger.info(f"Инициализация пула соединений PostgreSQL (min:{MIN_CONNECTIONS}, max:{MAX_CONNECTIONS})...")
            # Используем ThreadedConnectionPool, подходящий для многопоточных веб-серверов (Gunicorn)
            db_pool = psycopg2.pool.ThreadedConnectionPool(
                MIN_CONNECTIONS,
                MAX_CONNECTIONS,
                dsn=db_url,
                cursor_factory=RealDictCursor # Используем RealDictCursor по умолчанию для всех соединений
            )
            # Пробное получение соединения для проверки
            conn = db_pool.getconn()
            logger.info(f"Пул соединений успешно инициализирован. Версия PostgreSQL: {conn.server_version}")
            db_pool.putconn(conn)
        except psycopg2.OperationalError as e:
            logger.critical(f"Критическая ошибка: Не удалось инициализировать пул соединений: {e}", exc_info=True)
            db_pool = None # Сбрасываем пул при ошибке
            raise # Передаем ошибку дальше, чтобы приложение не запустилось
        except Exception as e:
             logger.critical(f"Неожиданная критическая ошибка при инициализации пула: {e}", exc_info=True)
             db_pool = None
             raise

def get_connection():
    """Получает соединение из пула. Должна вызываться в контексте запроса Flask."""
    global db_pool
    if db_pool is None:
         logger.error("Попытка получить соединение до инициализации пула!")
         raise RuntimeError("Пул соединений не инициализирован.")

    if 'db_conn' not in g:
        try:
            g.db_conn = db_pool.getconn()
            # Отключаем autocommit на уровне соединения из пула
            # Транзакциями нужно будет управлять явно (commit/rollback) в репозиториях/сервисах
            # или использовать `with connection.cursor() as cursor:` внутри функций
            # g.db_conn.autocommit = False # <<< ВАЖНО: Решаем использовать явные транзакции
            g.db_conn.autocommit = True # <<< ОСТАВЛЯЕМ ПОКА autocommit для совместимости с текущим кодом CRUD
            logger.debug("Получено соединение из пула для текущего запроса.")
        except Exception as e:
            logger.error(f"Ошибка получения соединения из пула: {e}", exc_info=True)
            raise RuntimeError(f"Не удалось получить соединение из пула: {e}")
    return g.db_conn

def close_connection(e=None):
    """Возвращает соединение обратно в пул. Вызывается Flask после запроса."""
    conn = g.pop('db_conn', None)
    if conn is not None and db_pool is not None:
        try:
            # Если была ошибка во время запроса (e is not None) и мы не используем autocommit,
            # хорошей практикой было бы откатить транзакцию перед возвратом в пул.
            # if e and not conn.autocommit:
            #    conn.rollback()
            #    logger.warning("Откат транзакции из-за ошибки в запросе.")

            db_pool.putconn(conn)
            logger.debug("Соединение возвращено в пул.")
        except Exception as ex:
             logger.error(f"Ошибка при возврате соединения в пул: {ex}", exc_info=True)
             # Что делать здесь? Возможно, закрыть соединение принудительно?
             # conn.close() # Может потребоваться, если putconn не сработал

def get_cursor():
    """Вспомогательная функция для получения курсора из соединения в контексте g."""
    conn = get_connection()
    return conn.cursor() # Курсор уже будет RealDictCursor по умолчанию