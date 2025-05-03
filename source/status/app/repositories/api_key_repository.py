# status/app/repositories/api_key_repository.py
import logging
import psycopg2
from typing import List, Dict, Any, Optional, Tuple

logger = logging.getLogger(__name__)

def create_api_key(cursor, key_hash: str, description: str, role: str, object_id: Optional[int] = None) -> Optional[int]:
    """
    Сохраняет хеш API ключа и его метаданные в базу данных.

    :param cursor: Курсор базы данных.
    :param key_hash: SHA-256 хеш от API ключа.
    :param description: Описание ключа.
    :param role: Роль ключа ('agent', 'loader', 'configurator', 'admin').
    :param object_id: Опциональный ID объекта (subdivisions.object_id).
    :return: ID созданного ключа или None при ошибке.
    :raises ValueError: Если роль недопустима (хотя DB CHECK должен это ловить).
    :raises psycopg2.Error: При ошибках базы данных (например, дубликат хеша).
    """
    # Проверка роли (дополнительно к DB CHECK)
    allowed_roles = ['agent', 'loader', 'configurator', 'admin']
    if role not in allowed_roles:
        raise ValueError(f"Недопустимая роль API ключа: {role}. Допустимые: {allowed_roles}")

    sql = """
        INSERT INTO api_keys (key_hash, description, role, object_id, is_active)
        VALUES (%s, %s, %s, %s, %s)
        RETURNING id;
    """
    try:
        cursor.execute(sql, (key_hash, description, role, object_id, True))
        result = cursor.fetchone()
        if result and 'id' in result:
            new_id = result['id']
            logger.info(f"Создан API ключ ID: {new_id}, Роль: {role}, Описание: {description}")
            return new_id
        else:
            logger.error("Не удалось получить ID после вставки API ключа.")
            return None
    except psycopg2.Error as e:
        logger.error(f"Ошибка БД при создании API ключа: {e}", exc_info=True)
        raise # Передаем ошибку дальше

def fetch_api_keys(cursor, limit: Optional[int] = None, offset: int = 0,
                    role: Optional[str] = None, object_id: Optional[int] = None,
                    is_active: Optional[bool] = None
                    ) -> Tuple[List[Dict[str, Any]], int]:
    """
    Получает список API ключей (без хешей) с пагинацией и фильтрацией.

    :param cursor: Курсор базы данных.
    :param limit: Максимальное количество записей.
    :param offset: Смещение для пагинации.
    :param role: Фильтр по роли.
    :param object_id: Фильтр по object_id.
    :param is_active: Фильтр по статусу активности (True/False).
    :return: Кортеж (список ключей, общее количество).
    """
    select_clause = """
        SELECT id, description, role, object_id, is_active, created_at, last_used_at
        FROM api_keys
    """
    count_clause = "SELECT COUNT(*) FROM api_keys"
    where_clauses = []
    params = {}

    if role:
        where_clauses.append("role = %(role)s")
        params['role'] = role.lower()
    if object_id is not None: # 0 может быть валидным ID? Пока считаем >0
        where_clauses.append("object_id = %(object_id)s")
        params['object_id'] = object_id
    if is_active is not None:
        where_clauses.append("is_active = %(is_active)s")
        params['is_active'] = is_active

    where_sql = ""
    if where_clauses:
        where_sql = " WHERE " + " AND ".join(where_clauses)

    # Получаем общее количество
    total_count = 0
    try:
        cursor.execute(count_clause + where_sql, params)
        count_result = cursor.fetchone()
        total_count = count_result['count'] if count_result else 0
    except psycopg2.Error as e:
        logger.error(f"Ошибка БД при подсчете API ключей: {e}", exc_info=True)
        raise

    # Получаем саму страницу
    items = []
    if total_count > 0 and (limit is None or offset < total_count):
        order_by_sql = " ORDER BY created_at DESC"
        limit_offset_sql = ""
        if limit is not None:
            limit_offset_sql = " LIMIT %(limit)s OFFSET %(offset)s"
            params['limit'] = limit
            params['offset'] = offset

        query = select_clause + where_sql + order_by_sql + limit_offset_sql
        try:
            cursor.execute(query, params)
            items = cursor.fetchall()
            logger.info(f"Получено API ключей: {len(items)} (Offset: {offset}, Limit: {limit})")
        except psycopg2.Error as e:
            logger.error(f"Ошибка БД при получении страницы API ключей: {e}", exc_info=True)
            raise
    else:
         logger.info(f"Нет API ключей для отображения (Total: {total_count}, Offset: {offset}, Limit: {limit})")

    return items, total_count

def get_api_key_by_id(cursor, key_id: int) -> Optional[Dict[str, Any]]:
    """
    Получает метаданные API ключа по его ID (без хеша).

    :param cursor: Курсор базы данных.
    :param key_id: ID ключа.
    :return: Словарь с данными ключа или None, если не найден.
    """
    sql = """
        SELECT id, description, role, object_id, is_active, created_at, last_used_at
        FROM api_keys
        WHERE id = %s;
    """
    try:
        cursor.execute(sql, (key_id,))
        key_data = cursor.fetchone()
        if not key_data:
            logger.warning(f"API ключ с ID {key_id} не найден.")
        return key_data
    except psycopg2.Error as e:
        logger.error(f"Ошибка БД при получении API ключа ID {key_id}: {e}", exc_info=True)
        raise

def update_api_key(cursor, key_id: int, data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """
    Обновляет метаданные API ключа (description, role, object_id, is_active).

    :param cursor: Курсор базы данных.
    :param key_id: ID ключа для обновления.
    :param data: Словарь с полями для обновления.
    :return: Обновленный словарь с данными ключа (без хеша) или None, если ключ не найден.
    :raises ValueError: Если переданы недопустимые поля или значения.
    :raises psycopg2.Error: При ошибках базы данных.
    """
    allowed_fields = ['description', 'role', 'object_id', 'is_active']
    update_fields = {k: v for k, v in data.items() if k in allowed_fields}

    if not update_fields:
        logger.warning(f"Нет допустимых полей для обновления API ключа ID {key_id}.")
        return get_api_key_by_id(cursor, key_id) # Возвращаем текущие данные

    # Валидация значений
    if 'role' in update_fields and update_fields['role'] not in ['agent', 'loader', 'configurator', 'admin']:
        raise ValueError(f"Недопустимая роль: {update_fields['role']}")
    if 'is_active' in update_fields and not isinstance(update_fields['is_active'], bool):
        raise ValueError("Поле 'is_active' должно быть булевым (true/false)")
    if 'object_id' in update_fields and update_fields['object_id'] is not None:
        # Дополнительная проверка существования object_id
        cursor.execute("SELECT EXISTS (SELECT 1 FROM subdivisions WHERE object_id = %s)", (update_fields['object_id'],))
        if not cursor.fetchone()['exists']:
            raise ValueError(f"Подразделение с object_id={update_fields['object_id']} не найдено.")

    set_clause_parts = [f"{field} = %({field})s" for field in update_fields.keys()]
    set_clause = ", ".join(set_clause_parts)
    sql = f"UPDATE api_keys SET {set_clause} WHERE id = %(id)s RETURNING id;" # Только ID, т.к. нам надо перечитать

    params = update_fields
    params['id'] = key_id

    try:
        cursor.execute(sql, params)
        updated_result = cursor.fetchone()
        if updated_result:
            logger.info(f"Обновлен API ключ ID: {key_id}. Поля: {', '.join(update_fields.keys())}")
            # Перечитываем данные, чтобы вернуть актуальные (без хеша)
            return get_api_key_by_id(cursor, key_id)
        else:
            logger.warning(f"API ключ ID {key_id} не найден для обновления.")
            return None # Ключ не найден
    except psycopg2.Error as e:
        logger.error(f"Ошибка БД при обновлении API ключа ID {key_id}: {e}", exc_info=True)
        raise

def delete_api_key(cursor, key_id: int) -> bool:
    """
    Удаляет API ключ по ID.

    :param cursor: Курсор базы данных.
    :param key_id: ID ключа для удаления.
    :return: True если удаление прошло успешно, False если ключ не найден.
    """
    sql = "DELETE FROM api_keys WHERE id = %s RETURNING id;"
    try:
        cursor.execute(sql, (key_id,))
        deleted = cursor.fetchone()
        if deleted:
            logger.info(f"Удален API ключ ID: {key_id}")
            return True
        else:
            logger.warning(f"API ключ ID {key_id} не найден для удаления.")
            return False
    except psycopg2.Error as e:
        logger.error(f"Ошибка БД при удалении API ключа ID {key_id}: {e}", exc_info=True)
        raise

def find_api_key_by_hash(cursor, key_hash: str) -> Optional[Dict[str, Any]]:
    """
    Ищет активный API ключ по его SHA-256 хешу. Используется для аутентификации.

    :param cursor: Курсор базы данных.
    :param key_hash: SHA-256 хеш ключа.
    :return: Словарь с данными ключа (id, role, object_id, is_active) или None.
    """
    sql = """
        SELECT id, role, object_id, is_active
        FROM api_keys
        WHERE key_hash = %s;
    """
    try:
        cursor.execute(sql, (key_hash,))
        return cursor.fetchone() # Возвращает словарь или None
    except psycopg2.Error as e:
        logger.error(f"Ошибка БД при поиске API ключа по хешу: {e}", exc_info=True)
        raise

def update_last_used(cursor, key_id: int) -> None:
    """Обновляет время последнего использования ключа."""
    sql = "UPDATE api_keys SET last_used_at = CURRENT_TIMESTAMP WHERE id = %s;"
    try:
        cursor.execute(sql, (key_id,))
        # Не логируем здесь, чтобы не засорять логи при каждой аутентификации
    except psycopg2.Error as e:
        logger.error(f"Ошибка БД при обновлении last_used_at для ключа ID {key_id}: {e}", exc_info=True)
        # Не пробрасываем ошибку дальше, т.к. это не критично для самой аутентификации