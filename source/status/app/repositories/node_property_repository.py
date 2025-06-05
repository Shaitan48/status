# status/app/repositories/node_property_repository.py
"""
node_property_repository.py — CRUD-операции для свойств типов узлов (node_property_types, node_properties).
Версия 5.0.1: Функции теперь принимают курсор, удалены commit.
"""
import logging
import psycopg2
from typing import List, Dict, Any, Optional

from ..db_connection import get_connection # Импорт для консистентности

logger = logging.getLogger(__name__)

# =======================================
# Типы свойств узлов (node_property_types)
# =======================================
def get_all_node_property_types(cursor: psycopg2.extensions.cursor) -> List[Dict[str, Any]]:
    sql = "SELECT id, name, description FROM node_property_types ORDER BY id;"
    logger.debug("Репозиторий: Запрос всех типов свойств узлов.")
    try:
        cursor.execute(sql)
        types = cursor.fetchall()
        logger.info(f"Репозиторий get_all_node_property_types: Получено {len(types)} типов свойств.")
        return types
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении типов свойств: {e}", exc_info=True)
        raise

def get_node_property_type_by_id(cursor: psycopg2.extensions.cursor, type_id: int) -> Optional[Dict[str, Any]]:
    sql = "SELECT id, name, description FROM node_property_types WHERE id = %s;"
    logger.debug(f"Репозиторий: Запрос типа свойства по ID={type_id}")
    try:
        cursor.execute(sql, (type_id,))
        type_data = cursor.fetchone()
        if not type_data: logger.warning(f"Репозиторий: Тип свойства ID={type_id} не найден.")
        return type_data
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении типа свойства ID {type_id}: {e}", exc_info=True)
        raise

def create_node_property_type(
    cursor: psycopg2.extensions.cursor,
    name: str,
    description: Optional[str] = None
) -> Optional[int]:
    sql = "INSERT INTO node_property_types (name, description) VALUES (%s, %s) RETURNING id;"
    logger.debug(f"Репозиторий: Попытка создания типа свойства с именем '{name}'.")
    try:
        cursor.execute(sql, (name, description))
        result = cursor.fetchone()
        new_id = result['id'] if result else None
        if new_id: logger.info(f"Репозиторий: Создан тип свойства ID={new_id}, Имя='{name}'.")
        else: logger.error("Репозиторий create_node_property_type: Не получен ID после вставки.")
        return new_id
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при создании типа свойства '{name}': {e}", exc_info=True)
        if e.pgcode == '23505': raise ValueError(f"Тип свойства с именем '{name}' уже существует.")
        raise

def update_node_property_type(
    cursor: psycopg2.extensions.cursor,
    type_id: int,
    update_data: Dict[str, Any]
) -> Optional[Dict[str, Any]]:
    # ... (аналогично update_check_method, возвращаем get_node_property_type_by_id) ...
    if not update_data: return get_node_property_type_by_id(cursor, type_id)
    allowed_fields = ['name', 'description']; set_parts: List[str] = []; params_update: Dict[str, Any] = {}
    for field, value in update_data.items():
        if field in allowed_fields: set_parts.append(f"{field} = %({field}_val)s"); params_update[f"{field}_val"] = value
    if not set_parts: return get_node_property_type_by_id(cursor, type_id)
    params_update['type_id_val'] = type_id
    sql_update = f"UPDATE node_property_types SET {', '.join(set_parts)} WHERE id = %(type_id_val)s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка обновления типа свойства ID={type_id}.")
    try:
        cursor.execute(sql_update, params_update); updated_row = cursor.fetchone()
        if updated_row: logger.info(f"Успешно обновлен тип свойства ID={type_id}."); return get_node_property_type_by_id(cursor, type_id)
        else: logger.warning(f"Тип свойства ID={type_id} не найден для обновления."); return None
    except psycopg2.Error as e: logger.error(f"Ошибка БД при обновлении типа свойства ID {type_id}: {e}", exc_info=True); raise

def delete_node_property_type(cursor: psycopg2.extensions.cursor, type_id: int) -> bool:
    # ... (аналогично delete_check_method) ...
    sql = "DELETE FROM node_property_types WHERE id = %s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка удаления типа свойства ID={type_id}")
    try:
        cursor.execute(sql, (type_id,)); deleted_row = cursor.fetchone()
        if deleted_row: logger.info(f"Успешно удален тип свойства ID={type_id}."); return True
        else: logger.warning(f"Тип свойства ID={type_id} не найден для удаления."); return False
    except psycopg2.Error as e: logger.error(f"Ошибка БД при удалении типа свойства ID {type_id}: {e}", exc_info=True); raise

# ========================================
# Значения свойств для типов узлов (node_properties)
# ========================================
def get_properties_for_node_type(cursor: psycopg2.extensions.cursor, node_type_id: int) -> List[Dict[str, Any]]:
    # SQL для получения свойств вместе с именем и описанием типа свойства
    sql = """
        SELECT p.id, p.node_type_id, p.property_type_id, pt.name as property_name,
               pt.description as property_description, p.property_value
        FROM node_properties p
        JOIN node_property_types pt ON p.property_type_id = pt.id
        WHERE p.node_type_id = %s
        ORDER BY pt.name;
    """
    logger.debug(f"Репозиторий: Запрос свойств для типа узла ID={node_type_id}")
    try:
        cursor.execute(sql, (node_type_id,))
        props = cursor.fetchall()
        logger.info(f"Репозиторий get_properties_for_node_type: Получено {len(props)} свойств для типа узла ID={node_type_id}.")
        return props
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении свойств для типа узла ID {node_type_id}: {e}", exc_info=True)
        raise

def set_node_property( # Переименовал для ясности (установка или обновление)
    cursor: psycopg2.extensions.cursor,
    node_type_id: int,
    property_type_id: int,
    property_value: str
) -> Optional[int]:
    """
    Устанавливает (INSERT) или обновляет (UPDATE) значение свойства для типа узла.
    Использует ON CONFLICT (node_type_id, property_type_id) DO UPDATE.
    Возвращает ID записи в node_properties.
    """
    sql = """
        INSERT INTO node_properties (node_type_id, property_type_id, property_value)
        VALUES (%s, %s, %s)
        ON CONFLICT (node_type_id, property_type_id) DO UPDATE SET
            property_value = EXCLUDED.property_value
        RETURNING id;
    """
    logger.debug(f"Репозиторий: Установка/обновление свойства для типа узла ID={node_type_id}, тип свойства ID={property_type_id}, значение='{property_value}'.")
    try:
        cursor.execute(sql, (node_type_id, property_type_id, property_value))
        result = cursor.fetchone()
        prop_id = result['id'] if result else None
        if prop_id:
            logger.info(f"Репозиторий: Свойство (ID={prop_id}) для типа узла ID={node_type_id}, тип свойства ID={property_type_id} установлено/обновлено.")
        else: # Это не должно происходить с ON CONFLICT ... RETURNING id
            logger.error("Репозиторий set_node_property: Не удалось получить ID после INSERT/UPDATE.")
        return prop_id
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при установке/обновлении свойства: {e}", exc_info=True)
        if e.pgcode == '23503': # ForeignKeyViolation
             if 'node_properties_node_type_id_fkey' in str(e): raise ValueError(f"Тип узла ID {node_type_id} не найден.")
             elif 'node_properties_property_type_id_fkey' in str(e): raise ValueError(f"Тип свойства ID {property_type_id} не найден.")
        raise

def delete_node_property(
    cursor: psycopg2.extensions.cursor,
    node_type_id: int, # Теперь принимаем node_type_id и property_type_id для удаления
    property_type_id: int
) -> bool:
    """ Удаляет значение свойства для типа узла по node_type_id и property_type_id. """
    sql = "DELETE FROM node_properties WHERE node_type_id = %s AND property_type_id = %s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка удаления свойства типа ID={property_type_id} у типа узла ID={node_type_id}.")
    try:
        cursor.execute(sql, (node_type_id, property_type_id))
        deleted_row = cursor.fetchone()
        if deleted_row:
            logger.info(f"Репозиторий: Успешно удалено свойство типа ID={property_type_id} у типа узла ID={node_type_id}.")
            return True
        else:
            logger.warning(f"Репозиторий delete_node_property: Свойство типа ID={property_type_id} у типа узла ID={node_type_id} не найдено для удаления.")
            return False
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при удалении свойства типа ID={property_type_id} у типа узла ID={node_type_id}: {e}", exc_info=True)
        raise

# ================================
# Конец файла
# ================================