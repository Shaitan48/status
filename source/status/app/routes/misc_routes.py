# status/app/routes/misc_routes.py
"""
Прочие маршруты API, не относящиеся к конкретным сущностям.
На данный момент содержит только эндпоинт для проверки состояния сервиса.
"""
import logging
from flask import Blueprint, jsonify, Response # Добавлен Response для явного указания типа
import psycopg2
from .. import db_connection # Для get_connection из текущего пакета
from flask import g # Для доступа к g.db_conn, если он устанавливается в before_request

logger = logging.getLogger(__name__)
bp = Blueprint('misc', __name__) # Префикс URL не задается здесь, будет '/health'

@bp.route('/health', methods=['GET'])
def health_check() -> Response:
    """
    Проверяет доступность веб-сервиса и его соединения с базой данных.

    Returns:
        JSON: Объект со статусом:
              {"status": "ok", "database_connected": true} - если все в порядке.
              {"status": "error", "database_connected": false} - если БД недоступна.
        HTTP Status:
              200 OK - если сервис и БД доступны.
              503 Service Unavailable - если БД недоступна.
    """
    logger.debug("Misc Route: Запрос GET /health (проверка состояния)")
    db_ok = False
    # Пытаемся получить соединение и выполнить простой запрос к БД
    # Соединение должно быть получено через g.db_conn, если оно устанавливается
    # в обработчике before_request, или напрямую через db_connection.get_connection().
    # В данном случае, предполагаем, что g.db_conn доступен.
    conn = None # Инициализируем conn
    try:
        # Пытаемся получить соединение через g.db_conn, если оно есть (например, из @app.before_request)
        # Если нет, то через db_connection.get_connection()
        if hasattr(g, 'db_conn') and g.db_conn:
            conn = g.db_conn
            # Если autocommit=False, простой SELECT 1 не требует явного cursor.execute() внутри with
            # Но для явности и совместимости лучше использовать курсор.
            with conn.cursor() as cur:
                cur.execute("SELECT 1;")
                cur.fetchone() # Убедимся, что запрос выполнен
            db_ok = True
            logger.debug("Health check: Проверка БД через g.db_conn прошла успешно.")
        else: # Если g.db_conn нет, пробуем получить соединение напрямую
            with db_connection.get_connection() as direct_conn: # Используем with для управления соединением
                with direct_conn.cursor() as cur:
                    cur.execute("SELECT 1;")
                    cur.fetchone()
                db_ok = True
                logger.debug("Health check: Проверка БД через db_connection.get_connection() прошла успешно.")
    except psycopg2.Error as db_err: # Ловим специфичные ошибки psycopg2
        logger.error(f"Health check: Ошибка соединения/запроса к БД: {db_err}", exc_info=False) # exc_info=False, т.к. это ожидаемая ошибка
        db_ok = False
    except Exception as e: # Ловим другие возможные ошибки (например, если g.db_conn нет)
        logger.error(f"Health check: Неожиданная ошибка при проверке БД: {e}", exc_info=True)
        db_ok = False
    # Соединение, полученное через g.db_conn, должно закрываться/возвращаться в пул
    # в обработчике after_request (teardown_appcontext).
    # Соединение, полученное через with db_connection.get_connection(), закроется автоматически.

    response_status_code = 200 if db_ok else 503 # HTTP 503 Service Unavailable, если БД недоступна
    response_json = {"status": "ok" if db_ok else "error", "database_connected": db_ok}
    logger.info(f"Health check завершен. Статус: {response_json['status']}, БД: {response_json['database_connected']}. HTTP-код: {response_status_code}")
    return jsonify(response_json), response_status_code