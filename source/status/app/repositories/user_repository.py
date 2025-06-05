# status/app/repositories/user_repository.py
"""
Репозиторий для CRUD-операций и бизнес-логики, связанной с Пользователями UI (таблица users).
Версия 5.0.1: Добавлены CRUD-функции, все функции принимают курсор.
"""
import logging
import psycopg2 # Для типизации курсора и обработки ошибок
from typing import Optional, Dict, Any, List, Tuple # Добавлены List, Tuple

# Импорт для консистентности, хотя функции принимают курсор
from ..db_connection import get_connection
# Утилита для хеширования пароля (если хеширование происходит здесь, а не в auth_utils)
# Но лучше хешировать пароль перед передачей в репозиторий.
# from ..auth_utils import hash_user_password

logger = logging.getLogger(__name__)

# ================================
# ПОЛУЧИТЬ ПОЛЬЗОВАТЕЛЯ ПО ID
# ================================
def get_user_by_id(cursor: psycopg2.extensions.cursor, user_id: int) -> Optional[Dict[str, Any]]:
    """
    Получает данные пользователя из БД по его ID.
    Предназначена для использования в user_loader Flask-Login и других местах.
    Args:
        cursor: Активный курсор базы данных (предполагается RealDictCursor).
        user_id (int): ID пользователя.
    Returns:
        Словарь с данными пользователя (id, username, password_hash, is_active, created_at)
        или None, если пользователь не найден.
    """
    if not cursor:
        logger.error("Репозиторий get_user_by_id: Курсор базы данных не предоставлен.")
        # В реальном приложении это должно вызывать исключение, т.к. это ошибка программирования
        raise ValueError("Курсор базы данных не может быть None.")
    sql = "SELECT id, username, password_hash, is_active, created_at FROM users WHERE id = %s;"
    logger.debug(f"Репозиторий: Запрос пользователя по ID={user_id}")
    try:
        cursor.execute(sql, (user_id,))
        user_data = cursor.fetchone() # Ожидаем словарь от RealDictCursor
        if not user_data:
            logger.warning(f"Репозиторий: Пользователь с ID={user_id} не найден.")
        return user_data
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении пользователя ID {user_id}: {e}", exc_info=True)
        raise # Пробрасываем ошибку psycopg2 для обработки выше

# ================================
# ПОЛУЧИТЬ ПОЛЬЗОВАТЕЛЯ ПО USERNAME
# ================================
def get_user_by_username(cursor: psycopg2.extensions.cursor, username: str) -> Optional[Dict[str, Any]]:
    """
    Получает данные пользователя из БД по его имени пользователя (username).
    Используется, например, при логине для проверки существования пользователя.
    Args:
        cursor: Активный курсор базы данных (RealDictCursor).
        username (str): Имя пользователя.
    Returns:
        Словарь с данными пользователя или None, если не найден.
    """
    if not cursor: raise ValueError("Курсор базы данных не может быть None.")
    sql = "SELECT id, username, password_hash, is_active, created_at FROM users WHERE username = %s;"
    logger.debug(f"Репозиторий: Запрос пользователя по username='{username}'")
    try:
        cursor.execute(sql, (username,))
        user_data = cursor.fetchone()
        if not user_data:
            logger.info(f"Репозиторий: Пользователь с username='{username}' не найден.")
        return user_data
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении пользователя username '{username}': {e}", exc_info=True)
        raise

# ================================
# СОЗДАТЬ НОВОГО ПОЛЬЗОВАТЕЛЯ
# ================================
def create_user(
    cursor: psycopg2.extensions.cursor,
    user_data: Dict[str, Any] # Ожидаем {'username', 'password_hash', 'is_active' (opt)}
) -> Optional[int]:
    """
    Создает нового пользователя в таблице users.
    Пароль должен быть уже хеширован и передан в 'password_hash'.
    Args:
        cursor: Активный курсор базы данных.
        user_data: Словарь с данными пользователя:
                   - 'username' (str, required)
                   - 'password_hash' (str, required) - уже хешированный пароль
                   - 'is_active' (bool, optional, default True)
    Returns:
        ID созданного пользователя или None при ошибке (хотя обычно выбрасывает исключение).
    Raises:
        ValueError: Если обязательные поля отсутствуют.
        psycopg2.Error: При ошибках БД (например, UniqueViolation).
    """
    if not cursor: raise ValueError("Курсор базы данных не может быть None.")
    if not user_data.get('username') or not user_data.get('password_hash'):
        logger.error("Репозиторий create_user: Отсутствуют username или password_hash.")
        raise ValueError("Поля 'username' и 'password_hash' обязательны для создания пользователя.")

    sql = """
        INSERT INTO users (username, password_hash, is_active)
        VALUES (%(uname)s, %(p_hash)s, %(is_act)s)
        RETURNING id;
    """
    params = {
        'uname': user_data['username'],
        'p_hash': user_data['password_hash'],
        'is_act': user_data.get('is_active', True) # По умолчанию активен
    }
    logger.debug(f"Репозиторий: Попытка создания пользователя '{params['uname']}'.")
    try:
        cursor.execute(sql, params)
        result = cursor.fetchone()
        new_user_id = result['id'] if result else None
        if new_user_id:
            logger.info(f"Репозиторий: Успешно создан пользователь ID={new_user_id}, Username='{params['uname']}'.")
        else:
            # Эта ветка маловероятна с RETURNING id, если нет ошибки psycopg2
            logger.error("Репозиторий create_user: Не удалось получить ID после вставки пользователя.")
        return new_user_id # Коммит на вызывающей стороне
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при создании пользователя '{params['uname']}': {e}", exc_info=True)
        if e.pgcode == '23505': # UniqueViolation (users_username_key)
            raise ValueError(f"Пользователь с именем '{params['uname']}' уже существует.")
        raise

# ================================
# ОБНОВИТЬ ДАННЫЕ ПОЛЬЗОВАТЕЛЯ
# ================================
def update_user(
    cursor: psycopg2.extensions.cursor,
    user_id: int,
    update_data: Dict[str, Any] # Поля для обновления: 'username', 'password_hash', 'is_active'
) -> Optional[Dict[str, Any]]:
    """
    Обновляет данные существующего пользователя.
    Args:
        cursor: Активный курсор.
        user_id: ID пользователя для обновления.
        update_data: Словарь с полями для обновления.
    Returns:
        Обновленный объект пользователя или None, если пользователь не найден.
    Raises:
        ValueError: Если данные для обновления некорректны.
        psycopg2.Error: При ошибках БД.
    """
    if not cursor: raise ValueError("Курсор базы данных не может быть None.")
    if not update_data:
        logger.warning(f"Репозиторий update_user: Нет данных для обновления пользователя ID={user_id}.")
        return get_user_by_id(cursor, user_id) # Возвращаем текущее состояние

    allowed_fields = ['username', 'password_hash', 'is_active']
    set_parts: List[str] = []
    params_sql: Dict[str, Any] = {}

    for field, value in update_data.items():
        if field in allowed_fields:
            if field == 'is_active' and value is not None and not isinstance(value, bool):
                raise ValueError("Поле 'is_active' должно быть булевым или null.")
            set_parts.append(f"{field} = %({field}_val)s")
            params_sql[f"{field}_val"] = value
    
    if not set_parts:
        logger.warning(f"Репозиторий update_user: Нет допустимых полей для обновления пользователя ID={user_id}.")
        return get_user_by_id(cursor, user_id)

    params_sql['user_id_val'] = user_id
    sql_query = f"UPDATE users SET {', '.join(set_parts)} WHERE id = %(user_id_val)s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка обновления пользователя ID={user_id} с полями: {list(update_data.keys())}")
    try:
        cursor.execute(sql_query, params_sql)
        updated_row = cursor.fetchone()
        if updated_row:
            logger.info(f"Репозиторий: Успешно обновлен пользователь ID={user_id}.")
            return get_user_by_id(cursor, user_id) # Возвращаем полный обновленный объект
        else:
            logger.warning(f"Репозиторий update_user: Пользователь ID={user_id} не найден для обновления.")
            return None
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при обновлении пользователя ID {user_id}: {e}", exc_info=True)
        if e.pgcode == '23505' and 'users_username_key' in str(e):
            raise ValueError(f"Пользователь с именем '{update_data.get('username')}' уже существует.")
        raise

# ================================
# УДАЛИТЬ ПОЛЬЗОВАТЕЛЯ
# ================================
def delete_user(cursor: psycopg2.extensions.cursor, user_id: int) -> bool:
    """
    Удаляет пользователя по ID.
    Args:
        cursor: Активный курсор.
        user_id: ID пользователя для удаления.
    Returns:
        True если удален, False если не найден.
    """
    if not cursor: raise ValueError("Курсор базы данных не может быть None.")
    sql = "DELETE FROM users WHERE id = %s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка удаления пользователя ID={user_id}")
    try:
        cursor.execute(sql, (user_id,))
        deleted_row = cursor.fetchone()
        if deleted_row:
            logger.info(f"Репозиторий: Успешно удален пользователь ID={user_id}.")
            return True
        else:
            logger.warning(f"Репозиторий delete_user: Пользователь ID={user_id} не найден для удаления.")
            return False
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при удалении пользователя ID {user_id}: {e}", exc_info=True)
        # В таблице users обычно нет внешних ключей, указывающих на нее,
        # поэтому ForeignKeyViolation здесь маловероятен при удалении.
        raise

# ================================
# ПОЛУЧИТЬ ВСЕХ ПОЛЬЗОВАТЕЛЕЙ (для UI админки)
# ================================
def fetch_users(
    cursor: psycopg2.extensions.cursor,
    limit: Optional[int] = 25,
    offset: int = 0,
    search_username: Optional[str] = None,
    is_active_filter: Optional[bool] = None
) -> Tuple[List[Dict[str, Any]], int]:
    """
    Получает страницу со списком пользователей с фильтрацией и пагинацией.
    Не возвращает password_hash.
    """
    if not cursor: raise ValueError("Курсор базы данных не может быть None.")
    logger.debug(f"Репозиторий: Запрос списка пользователей. Фильтры: search='{search_username}', active={is_active_filter}, limit={limit}, offset={offset}")
    
    select_fields = "SELECT id, username, is_active, created_at FROM users"
    count_select = "SELECT COUNT(*) FROM users"
    
    where_conditions_user: List[str] = []
    query_params_user: Dict[str, Any] = {}

    if search_username:
        where_conditions_user.append("username ILIKE %(uname_search)s")
        query_params_user['uname_search'] = f"%{search_username}%"
    if is_active_filter is not None:
        where_conditions_user.append("is_active = %(is_act_filter)s")
        query_params_user['is_act_filter'] = is_active_filter
    
    where_sql_user = (" WHERE " + " AND ".join(where_conditions_user)) if where_conditions_user else ""
    
    try:
        cursor.execute(count_select + where_sql_user, query_params_user)
        total_count_res_user = cursor.fetchone()
        total_users = total_count_res_user['count'] if total_count_res_user else 0

        users_list: List[Dict[str, Any]] = []
        if total_users > 0 and (limit is None or offset < total_users):
            order_sql_user = " ORDER BY username ASC, id ASC"
            limit_offset_sql_user = ""
            if limit is not None:
                limit_offset_sql_user = " LIMIT %(lim_user)s OFFSET %(off_user)s"
                query_params_user['lim_user'] = limit
                query_params_user['off_user'] = offset
            
            cursor.execute(select_fields + where_sql_user + order_sql_user + limit_offset_sql_user, query_params_user)
            users_list = cursor.fetchall()
            
        logger.info(f"Репозиторий fetch_users: Найдено {len(users_list)} пользователей на странице, всего {total_users}.")
        return users_list, total_users
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при выборке пользователей: {e}", exc_info=True)
        raise

# ================================
# Конец файла
# ================================