# status/app/repositories/method_repository.py
import logging
import psycopg2
from typing import List, Dict, Any

logger = logging.getLogger(__name__)

def fetch_check_methods(cursor) -> List[Dict[str, Any]]:
    query = "SELECT id, method_name, description FROM check_methods ORDER BY method_name;"
    cursor.execute(query); methods = cursor.fetchall()
    logger.info(f"Получено методов проверки: {len(methods)} строк.")
    return methods
