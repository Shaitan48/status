# status/app/routes/misc_routes.py
import logging
from flask import Blueprint, jsonify, g
import psycopg2
from .. import db_connection # Для get_connection

logger = logging.getLogger(__name__)
bp = Blueprint('misc', __name__) # Без префикса

@bp.route('/health', methods=['GET'])
def health_check():
    """Проверка доступности сервиса и БД."""
    db_ok = False
    conn = None
    try:
        conn = db_connection.get_connection()
        with conn.cursor() as cur:
             cur.execute("SELECT 1;")
             cur.fetchone()
        db_ok = True
        logger.debug("Health check: DB connection successful.")
    except Exception as e:
        logger.error(f"Health check failed: DB connection error: {e}", exc_info=False)
        db_ok = False
    # Соединение вернется в пул через teardown_appcontext

    status_code = 200 if db_ok else 503
    return jsonify({"status": "ok" if db_ok else "error", "database_connected": db_ok}), status_code
