# status/app/repositories/api_key_repository.py
"""
api_key_repository.py — Репозиторий для работы с API-ключами (таблица api_keys).
Версия 5.0.1: Функции теперь принимают курсор, удалены commit, используется get_connection для импорта (хотя не вызывается).
"""
import logging
import psycopg2 # Для типизации курсора и обработки ошибок psycopg2.Error
from typing import List, Dict, Any, Optional, Tuple

# Импортируем get_connection, хотя функции теперь ожидают курсор.
# Это для общей консистентности и если вдруг понадобятся прямые вызовы.
from ..db_connection import get_connection

logger = logging.getLogger(__name__)

# ==============================
# СОЗДАНИЕ API-КЛЮЧА
# ==============================
def create_api_key(
    cursor: psycopg2.extensions.cursor,
    key_hash: str,
    description: str,
    role: str,
    object_id: Optional[int] = None,
    is_active: bool = True # Новые ключи по умолчанию активны
) -> Optional[int]:
    """
    Создать новый API-ключ. Хранится только SHA-256 хеш!
    Args:
        cursor: Активный курсор базы данных.
        key_hash: SHA-256 хеш ключа.
        description: Описание назначения ключа.
        role: Роль ('agent', 'loader', 'configurator', 'admin').
        object_id: Опциональный ID объекта (подразделения).
        is_active: Статус активности ключа.
    Returns:
        ID созданного ключа или None при ошибке.
    """
    allowed_roles = ['agent', 'loader', 'configurator', 'admin']
    if role.lower() not in allowed_roles: # Приводим к нижнему регистру для проверки
        logger.error(f"Попытка создать ключ с недопустимой ролью: {role}")
        raise ValueError(f"Недопустимая роль: {role}. Разрешены: {', '.join(allowed_roles)}")

    sql = """
        INSERT INTO api_keys (key_hash, description, role, object_id, is_active)
        VALUES (%(key_h)s, %(desc)s, %(role_val)s, %(obj_id)s, %(is_act)s)
        RETURNING id;
    """
    params = {
        'key_h': key_hash,
        'desc': description,
        'role_val': role.lower(), # Сохраняем роль в нижнем регистре
        'obj_id': object_id,
        'is_act': is_active
    }
    try:
        cursor.execute(sql, params)
        result = cursor.fetchone()
        new_id = result['id'] if result and 'id' in result else None
        if new_id:
            logger.info(f"Репозиторий: Создан API ключ ID={new_id}, роль={params['role_val']}, описание='{params['desc']}'")
        else:
            # Эта ситуация маловероятна, если RETURNING id отработал без ошибок
            logger.error("Репозиторий create_api_key: Ошибка - не получен ID после вставки API ключа.")
        return new_id # Коммит должен быть выполнен вызывающим кодом
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при создании API ключа: {e}", exc_info=True)
        if e.pgcode == '23505': # UniqueViolation
             raise ValueError(f"API ключ с таким хешем или другими уникальными параметрами уже существует.")
        raise # Пробрасываем ошибку для обработки на верхнем уровне

# ==============================
# ПОЛУЧЕНИЕ СПИСКА API-КЛЮЧЕЙ
# ==============================
def fetch_api_keys(
    cursor: psycopg2.extensions.cursor,
    limit: Optional[int] = 25, # Значение по умолчанию для лимита
    offset: int = 0,
    role: Optional[str] = None,
    object_id: Optional[int] = None,
    is_active: Optional[bool] = None
) -> Tuple[List[Dict[str, Any]], int]:
    """
    Получить страницу (список) API-ключей с фильтрацией и пагинацией.
    Args:
        cursor: Активный курсор базы данных.
        limit: Максимальное количество ключей.
        offset: Смещение для пагинации.
        role: Фильтр по роли.
        object_id: Фильтр по ID объекта.
        is_active: Фильтр по статусу активности.
    Returns:
        Кортеж (список ключей, общее количество найденных ключей с учетом фильтров).
    """
    # Не показываем key_hash в общем списке
    select_fields = "SELECT id, description, role, object_id, is_active, created_at, last_used_at FROM api_keys"
    count_select = "SELECT COUNT(*) FROM api_keys"
    
    where_conditions: List[str] = []
    query_params: Dict[str, Any] = {}

    if role:
        where_conditions.append("role = %(role_filter)s")
        query_params['role_filter'] = role.lower()
    if object_id is not None: # object_id может быть 0 или другим числом
        where_conditions.append("object_id = %(obj_id_filter)s")
        query_params['obj_id_filter'] = object_id
    if is_active is not None: # Фильтр по булевому значению
        where_conditions.append("is_active = %(is_active_filter)s")
        query_params['is_active_filter'] = is_active

    where_sql_clause = (" WHERE " + " AND ".join(where_conditions)) if where_conditions else ""
    
    logger.debug(f"Репозиторий fetch_api_keys: Запрос с WHERE='{where_sql_clause}', PARAMS={query_params}")

    try:
        # Сначала получаем общее количество записей с учетом фильтров
        cursor.execute(count_select + where_sql_clause, query_params)
        total_count_result = cursor.fetchone()
        total_keys = total_count_result['count'] if total_count_result else 0

        keys_list: List[Dict[str, Any]] = []
        if total_keys > 0 and (limit is None or offset < total_keys):
            order_by_sql = " ORDER BY created_at DESC, id DESC" # Сортировка
            limit_offset_sql_part = ""
            if limit is not None:
                limit_offset_sql_part = " LIMIT %(limit_val)s OFFSET %(offset_val)s"
                query_params['limit_val'] = limit
                query_params['offset_val'] = offset
            
            cursor.execute(select_fields + where_sql_clause + order_by_sql + limit_offset_sql_part, query_params)
            keys_list = cursor.fetchall() # Ожидаем список словарей от RealDictCursor
            
        logger.info(f"Репозиторий fetch_api_keys: Найдено {len(keys_list)} ключей на странице, всего {total_keys}.")
        return keys_list, total_keys
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении списка API-ключей: {e}", exc_info=True)
        raise

# ==============================
# ПОЛУЧИТЬ API-КЛЮЧ ПО ID
# ==============================
def get_api_key_by_id(cursor: psycopg2.extensions.cursor, key_id: int) -> Optional[Dict[str, Any]]:
    """ Получить данные API-ключа по id (без хеша). """
    sql = "SELECT id, description, role, object_id, is_active, created_at, last_used_at FROM api_keys WHERE id = %s;"
    logger.debug(f"Репозиторий: Запрос API-ключа по ID={key_id}")
    try:
        cursor.execute(sql, (key_id,))
        key_data = cursor.fetchone()
        if not key_data:
            logger.warning(f"Репозиторий: API-ключ с ID={key_id} не найден.")
        return key_data
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении API-ключа ID {key_id}: {e}", exc_info=True)
        raise

# ==============================
# ОБНОВЛЕНИЕ API-КЛЮЧА
# ==============================
def update_api_key(
    cursor: psycopg2.extensions.cursor,
    key_id: int,
    data_to_update: Dict[str, Any]
) -> Optional[Dict[str, Any]]:
    """
    Обновить метаданные API-ключа (description, role, object_id, is_active).
    Возвращает обновленный объект ключа или None, если ключ не найден.
    """
    if not data_to_update:
        logger.warning(f"Репозиторий update_api_key: Нет данных для обновления ключа ID={key_id}.")
        return get_api_key_by_id(cursor, key_id) # Возвращаем текущее состояние

    allowed_fields_to_update = ['description', 'role', 'object_id', 'is_active']
    update_set_parts: List[str] = []
    params_for_sql_update: Dict[str, Any] = {}

    for field, value in data_to_update.items():
        if field in allowed_fields_to_update:
            if field == 'role': # Валидация роли
                if value is not None and value.lower() not in ['agent', 'loader', 'configurator', 'admin']:
                    raise ValueError(f"Недопустимая роль '{value}' для API-ключа.")
                params_for_sql_update[f"{field}_val"] = value.lower() if value is not None else None
            elif field == 'is_active': # Валидация is_active
                if value is not None and not isinstance(value, bool):
                    raise ValueError("Поле 'is_active' должно быть булевым значением (true/false) или null.")
                params_for_sql_update[f"{field}_val"] = value
            elif field == 'object_id': # Валидация object_id (проверка существования в subdivisions)
                if value is not None:
                    # Эта проверка должна быть в роуте или сервисе перед вызовом репозитория,
                    # но для надежности можно добавить и здесь, если курсор передан.
                    # cursor.execute("SELECT EXISTS (SELECT 1 FROM subdivisions WHERE object_id = %s)", (value,))
                    # if not cursor.fetchone()['exists']:
                    #     raise ValueError(f"Подразделение с object_id={value} не найдено.")
                    params_for_sql_update[f"{field}_val"] = int(value) # Убедимся, что это int
                else:
                    params_for_sql_update[f"{field}_val"] = None
            else: # Для description
                params_for_sql_update[f"{field}_val"] = value
            update_set_parts.append(f"{field} = %({field}_val)s")

    if not update_set_parts:
        logger.warning(f"Репозиторий update_api_key: Нет допустимых полей для обновления в ключе ID={key_id}.")
        return get_api_key_by_id(cursor, key_id)

    params_for_sql_update['key_id_val'] = key_id
    sql_update_query = f"UPDATE api_keys SET {', '.join(update_set_parts)} WHERE id = %(key_id_val)s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка обновления API-ключа ID={key_id} с полями: {list(update_data.keys())}")
    try:
        cursor.execute(sql_update_query, params_for_sql_update)
        updated_row = cursor.fetchone()
        if updated_row:
            logger.info(f"Репозиторий: Успешно обновлен API-ключ ID={key_id}.")
            return get_api_key_by_id(cursor, key_id) # Возвращаем полный обновленный объект
        else:
            logger.warning(f"Репозиторий update_api_key: API-ключ ID={key_id} не найден для обновления.")
            return None
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при обновлении API-ключа ID {key_id}: {e}", exc_info=True)
        if e.pgcode == '23503' and 'api_keys_object_id_fkey' in str(e): # Пример для FK на subdivisions.object_id
            raise ValueError(f"Указанный object_id не существует в таблице подразделений.")
        raise

# ==============================
# УДАЛЕНИЕ API-КЛЮЧА
# ==============================
def delete_api_key(cursor: psycopg2.extensions.cursor, key_id: int) -> bool:
    """ Удалить API-ключ по id. Возвращает True если удален, False если не найден. """
    sql = "DELETE FROM api_keys WHERE id = %s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка удаления API-ключа ID={key_id}")
    try:
        cursor.execute(sql, (key_id,))
        deleted_row = cursor.fetchone()
        if deleted_row:
            logger.info(f"Репозиторий: Успешно удален API-ключ ID={key_id}.")
            return True
        else:
            logger.warning(f"Репозиторий delete_api_key: API-ключ ID={key_id} не найден для удаления.")
            return False
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при удалении API-ключа ID {key_id}: {e}", exc_info=True)
        raise

# ==============================
# АУТЕНТИФИКАЦИЯ ПО ХЕШУ
# ==============================
def find_api_key_by_hash(cursor: psycopg2.extensions.cursor, key_hash: str) -> Optional[Dict[str, Any]]:
    """
    Найти активный API-ключ по SHA-256 хешу (для аутентификации).
    Возвращает словарь {id, role, object_id, is_active} или None.
    """
    sql = "SELECT id, role, object_id, is_active FROM api_keys WHERE key_hash = %s;"
    # Не проверяем is_active здесь, это делает вызывающий auth_utils.verify_api_key
    logger.debug(f"Репозиторий: Поиск API-ключа по хешу (начало): {key_hash[:10]}...")
    try:
        cursor.execute(sql, (key_hash,))
        key_info = cursor.fetchone()
        if key_info: logger.debug(f"Репозиторий: Найден API-ключ по хешу. ID={key_info.get('id')}, Role={key_info.get('role')}")
        else: logger.debug(f"Репозиторий: API-ключ по хешу {key_hash[:10]}... не найден.")
        return key_info
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при поиске API-ключа по хешу: {e}", exc_info=True)
        raise

# ==============================
# ОБНОВИТЬ last_used_at
# ==============================
def update_last_used(cursor: psycopg2.extensions.cursor, key_id: int) -> None:
    """ Обновить поле last_used_at. Вызывается при успешной аутентификации ключа. """
    sql = "UPDATE api_keys SET last_used_at = CURRENT_TIMESTAMP WHERE id = %s;"
    logger.debug(f"Репозиторий: Обновление last_used_at для API-ключа ID={key_id}")
    try:
        cursor.execute(sql, (key_id,))
        # Не логируем успех выполнения, чтобы не засорять логи. Ошибку логируем.
    except psycopg2.Error as e: # Ошибку не пробрасываем, чтобы не ломать основной процесс аутентификации
        logger.error(f"Репозиторий: Ошибка БД при обновлении last_used_at для ключа ID {key_id}: {e}", exc_info=True)

# ==============================
# Конец файла
# ==============================