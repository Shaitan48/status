# status/app/repositories/method_repository.py
"""
method_repository.py — Операции CRUD и бизнес-логика для методов проверки (check_methods).
Версия 5.0.1: Функции теперь принимают курсор, удалены commit.
"""
import logging
import psycopg2 # Для типизации курсора и обработки ошибок psycopg2.Error
from typing import List, Dict, Any, Optional

# Импортируем get_connection для общей консистентности, хотя функции ожидают курсор.
from ..db_connection import get_connection

logger = logging.getLogger(__name__)

# ================================
# Получить список всех методов проверки
# ================================
def fetch_check_methods(cursor: psycopg2.extensions.cursor) -> List[Dict[str, Any]]: # Изменил имя для единообразия
    """
    Получить все методы проверки (check_methods), отсортированные по ID.
    Возвращает список словарей: [{id, method_name, description}, ...]
    """
    sql = "SELECT id, method_name, description FROM check_methods ORDER BY id;"
    logger.debug("Репозиторий: Запрос всех методов проверки.")
    try:
        cursor.execute(sql)
        methods = cursor.fetchall() # Ожидаем список словарей от RealDictCursor
        logger.info(f"Репозиторий fetch_check_methods: Получено {len(methods)} методов проверки.")
        return methods
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении списка методов проверки: {e}", exc_info=True)
        raise

# ================================
# Получить метод проверки по ID
# ================================
def get_check_method_by_id(cursor: psycopg2.extensions.cursor, method_id: int) -> Optional[Dict[str, Any]]:
    """ Получить метод проверки по его id. """
    sql = "SELECT id, method_name, description FROM check_methods WHERE id = %s;"
    logger.debug(f"Репозиторий: Запрос метода проверки по ID={method_id}")
    try:
        cursor.execute(sql, (method_id,))
        method_data = cursor.fetchone()
        if not method_data:
            logger.warning(f"Репозиторий: Метод проверки ID={method_id} не найден.")
        return method_data
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении метода проверки ID {method_id}: {e}", exc_info=True)
        raise

# ================================
# Создать новый метод проверки
# ================================
def create_check_method(
    cursor: psycopg2.extensions.cursor,
    method_name: str,
    description: Optional[str] = None
) -> Optional[int]:
    """
    Создать новый метод проверки (check_methods).
    Args:
        cursor: Активный курсор базы данных.
        method_name: Уникальное имя метода.
        description: Описание метода (опционально).
    Returns:
        ID созданного метода или None при ошибке.
    """
    sql = "INSERT INTO check_methods (method_name, description) VALUES (%s, %s) RETURNING id;"
    logger.debug(f"Репозиторий: Попытка создания метода проверки с именем '{method_name}'.")
    try:
        cursor.execute(sql, (method_name, description))
        result = cursor.fetchone()
        new_id = result['id'] if result else None
        if new_id:
            logger.info(f"Репозиторий: Создан метод проверки ID={new_id}, Имя='{method_name}'.")
        else:
            logger.error("Репозиторий create_check_method: Не удалось получить ID после вставки метода.")
        return new_id # Коммит на вызывающей стороне
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при создании метода проверки '{method_name}': {e}", exc_info=True)
        if e.pgcode == '23505': # UniqueViolation
            raise ValueError(f"Метод проверки с именем '{method_name}' уже существует.")
        raise

# ================================
# Обновить существующий метод проверки
# ================================
def update_check_method(
    cursor: psycopg2.extensions.cursor,
    method_id: int,
    update_data: Dict[str, Any]
) -> Optional[Dict[str, Any]]:
    """
    Обновить существующий метод проверки.
    Args:
        cursor: Активный курсор.
        method_id: ID метода для обновления.
        update_data: Словарь с полями для обновления (например, 'method_name', 'description').
    Returns:
        Обновленный объект метода или None, если метод не найден.
    """
    if not update_data:
        logger.warning(f"Репозиторий update_check_method: Нет данных для обновления метода ID={method_id}.")
        return get_check_method_by_id(cursor, method_id)

    allowed_fields = ['method_name', 'description']
    set_parts: List[str] = []
    params_for_update: Dict[str, Any] = {}

    for field, value in update_data.items():
        if field in allowed_fields:
            set_parts.append(f"{field} = %({field}_val)s")
            params_for_update[f"{field}_val"] = value
    
    if not set_parts:
        logger.warning(f"Репозиторий update_check_method: Нет допустимых полей для обновления метода ID={method_id}.")
        return get_check_method_by_id(cursor, method_id)

    params_for_update['method_id_val'] = method_id
    sql_update = f"UPDATE check_methods SET {', '.join(set_parts)} WHERE id = %(method_id_val)s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка обновления метода ID={method_id} с полями {list(params_for_update.keys())}")
    try:
        cursor.execute(sql_update, params_for_update)
        updated_row = cursor.fetchone()
        if updated_row:
            logger.info(f"Репозиторий: Успешно обновлен метод проверки ID={method_id}.")
            return get_check_method_by_id(cursor, method_id) # Возвращаем полный обновленный объект
        else:
            logger.warning(f"Репозиторий update_check_method: Метод ID={method_id} не найден для обновления.")
            return None
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при обновлении метода ID {method_id}: {e}", exc_info=True)
        if e.pgcode == '23505' and 'check_methods_method_name_key' in str(e):
            raise ValueError(f"Метод проверки с именем '{update_data.get('method_name')}' уже существует.")
        raise

# ================================
# Удалить метод проверки
# ================================
def delete_check_method(cursor: psycopg2.extensions.cursor, method_id: int) -> bool:
    """ Удалить метод проверки по его id. """
    sql = "DELETE FROM check_methods WHERE id = %s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка удаления метода проверки ID={method_id}")
    try:
        cursor.execute(sql, (method_id,))
        deleted_row = cursor.fetchone()
        if deleted_row:
            logger.info(f"Репозиторий: Успешно удален метод проверки ID={method_id}.")
            return True
        else:
            logger.warning(f"Репозиторий delete_check_method: Метод ID={method_id} не найден для удаления.")
            return False
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при удалении метода ID {method_id}: {e}", exc_info=True)
        # ForeignKeyViolation (23503) будет обработана в роуте (вернет 409 Conflict)
        raise

# ================================
# Конец файла
# ================================