# status/app/repositories/subdivision_repository.py
"""
subdivision_repository.py — CRUD и бизнес-логика для работы с подразделениями (subdivisions).
Версия 5.0.1: Исправлен импорт get_connection.
"""
import logging
import psycopg2 # Для psycopg2.extras, если потребуется RealDictCursor здесь
from typing import List, Dict, Any, Optional, Tuple # Для аннотаций типов

# <<< ИЗМЕНЕНО: Импортируем get_connection >>>
from ..db_connection import get_connection

logger = logging.getLogger(__name__)

# =========================
# Получение подразделений (Subdivisions)
# =========================

def fetch_subdivisions(
    cursor: psycopg2.extensions.cursor,
    limit: Optional[int] = None,
    offset: int = 0,
    parent_id: Optional[int] = None, # 0 для корневых, ID для дочерних, None для всех
    search_text: Optional[str] = None
) -> Tuple[List[Dict[str, Any]], int]:
    """
    Получает страницу подразделений с фильтрацией и пагинацией.
    Возвращает (список подразделений, общее количество с учетом фильтров).
    """
    logger.debug(f"Репозиторий: Запрос списка подразделений. Фильтры: parent_id={parent_id}, search='{search_text}', limit={limit}, offset={offset}")
    
    select_fields = """
        SELECT id, object_id, short_name, full_name, parent_id, domain_name, 
               transport_system_code, priority, comment, icon_filename
        FROM subdivisions
    """
    count_select = "SELECT COUNT(*) FROM subdivisions"
    
    where_clauses: List[str] = []
    query_params: Dict[str, Any] = {}

    if parent_id is not None:
        if parent_id == 0: # Специальное значение для корневых
            where_clauses.append("parent_id IS NULL")
        else:
            where_clauses.append("parent_id = %(p_id)s")
            query_params['p_id'] = parent_id
    
    if search_text:
        where_clauses.append("(short_name ILIKE %(search)s OR full_name ILIKE %(search)s)")
        query_params['search'] = f"%{search_text}%"

    where_sql = (" WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
    
    try:
        cursor.execute(count_select + where_sql, query_params)
        total_count_result = cursor.fetchone()
        total_subdivisions = total_count_result['count'] if total_count_result else 0

        subdivisions_list: List[Dict[str, Any]] = []
        if total_subdivisions > 0 and (limit is None or offset < total_subdivisions):
            order_sql = " ORDER BY priority, short_name"
            limit_offset_sql = ""
            if limit is not None:
                limit_offset_sql = " LIMIT %(lim)s OFFSET %(off)s"
                query_params['lim'] = limit
                query_params['off'] = offset
            
            cursor.execute(select_fields + where_sql + order_sql + limit_offset_sql, query_params)
            subdivisions_list = cursor.fetchall() # Ожидаем список словарей от RealDictCursor
            
        logger.info(f"Репозиторий fetch_subdivisions: Найдено {len(subdivisions_list)} подразд. на странице, всего {total_subdivisions}.")
        return subdivisions_list, total_subdivisions
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при выборке подразделений: {e}", exc_info=True)
        raise


def get_subdivision_by_id(cursor: psycopg2.extensions.cursor, subdivision_id: int) -> Optional[Dict[str, Any]]:
    """
    Получить подразделение по его внутреннему ID.
    """
    sql = """
        SELECT id, object_id, short_name, full_name, parent_id, domain_name, 
               transport_system_code, priority, comment, icon_filename
        FROM subdivisions
        WHERE id = %s;
    """
    logger.debug(f"Репозиторий: Запрос подразделения по ID={subdivision_id}")
    try:
        cursor.execute(sql, (subdivision_id,))
        subdivision_data = cursor.fetchone()
        if not subdivision_data:
            logger.warning(f"Репозиторий: Подразделение с ID={subdivision_id} не найдено.")
        return subdivision_data
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении подразделения ID {subdivision_id}: {e}", exc_info=True)
        raise

def check_subdivision_exists_by_object_id(cursor: psycopg2.extensions.cursor, object_id: int) -> bool:
    """
    Проверяет существование подразделения по его внешнему object_id.
    Используется, например, при создании API-ключа для валидации.
    """
    logger.debug(f"Репозиторий: Проверка существования подразделения по ObjectID={object_id}")
    try:
        cursor.execute("SELECT EXISTS (SELECT 1 FROM subdivisions WHERE object_id = %s);", (object_id,))
        exists_result = cursor.fetchone()
        return exists_result['exists'] if exists_result else False
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при проверке существования подразделения ObjectID {object_id}: {e}", exc_info=True)
        raise # Пробрасываем ошибку, т.к. это может быть важно для вызывающего кода


def create_subdivision(
    cursor: psycopg2.extensions.cursor,
    data: Dict[str, Any] # Ожидаем словарь с полями
) -> Optional[Dict[str, Any]]: # Возвращаем созданный объект
    """
    Создает новое подразделение.
    Ожидает в `data` как минимум 'object_id' и 'short_name'.
    """
    # Валидация может быть на уровне роута/сервиса, здесь предполагаем, что данные корректны
    # или обрабатываем psycopg2.Error (например, UniqueViolation)
    sql = """
        INSERT INTO subdivisions (
            object_id, short_name, full_name, parent_id, domain_name,
            transport_system_code, priority, comment, icon_filename
        ) VALUES (
            %(object_id)s, %(short_name)s, %(full_name)s, %(parent_id)s, %(domain_name)s,
            %(transport_system_code)s, %(priority)s, %(comment)s, %(icon_filename)s
        ) RETURNING id;
    """
    params = {
        'object_id': data['object_id'],
        'short_name': data['short_name'],
        'full_name': data.get('full_name'),
        'parent_id': data.get('parent_id'),
        'domain_name': data.get('domain_name'),
        'transport_system_code': data.get('transport_system_code'),
        'priority': data.get('priority', 10), # Значение по умолчанию
        'comment': data.get('comment'),
        'icon_filename': data.get('icon_filename')
    }
    logger.debug(f"Репозиторий: Попытка создания подразделения с данными: {params}")
    try:
        cursor.execute(sql, params)
        result = cursor.fetchone()
        if result and result.get('id') is not None:
            new_sub_id = result['id']
            logger.info(f"Репозиторий: Успешно создано подразделение ID={new_sub_id}, ObjectID='{params['object_id']}'.")
            # Возвращаем полный объект созданного подразделения
            return get_subdivision_by_id(cursor, new_sub_id)
        else:
            logger.error("Репозиторий create_subdivision: Не удалось получить ID после вставки.")
            return None # Или выбросить исключение
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при создании подразделения ObjectID '{params['object_id']}': {e}", exc_info=True)
        # Обработка специфичных ошибок (UniqueViolation, ForeignKeyViolation)
        if e.pgcode == '23505': # Unique violation
            if 'subdivisions_object_id_key' in str(e) or 'unique_subdivision_object_id' in str(e): # Проверяем имя ограничения
                raise ValueError(f"Подразделение с ObjectID {params['object_id']} уже существует.")
            elif 'unique_subdivision_transport_code' in str(e):
                 raise ValueError(f"Подразделение с кодом ТС '{params['transport_system_code']}' уже существует.")
            else:
                 raise ValueError(f"Конфликт уникальности при создании подразделения: {e.diag.message_detail or str(e)}")
        elif e.pgcode == '23503' and 'subdivisions_parent_id_fkey' in str(e): # Foreign key violation
            raise ValueError(f"Родительское подразделение ID {params['parent_id']} не найдено.")
        raise # Пробрасываем остальные ошибки psycopg2

def update_subdivision(
    cursor: psycopg2.extensions.cursor,
    subdivision_id: int,
    update_data: Dict[str, Any]
) -> Optional[Dict[str, Any]]: # Возвращаем обновленный объект
    """
    Обновляет данные существующего подразделения.
    Запрещает изменение object_id.
    """
    if not update_data:
        logger.warning(f"Репозиторий update_subdivision: Нет данных для обновления подразделения ID={subdivision_id}.")
        return get_subdivision_by_id(cursor, subdivision_id)

    if 'object_id' in update_data:
        logger.warning(f"Репозиторий update_subdivision: Попытка изменить object_id для ID={subdivision_id} игнорируется.")
        update_data.pop('object_id')
        if not update_data: return get_subdivision_by_id(cursor, subdivision_id) # Если больше нечего обновлять

    allowed_fields = ['short_name', 'full_name', 'parent_id', 'domain_name',
                      'transport_system_code', 'priority', 'comment', 'icon_filename']
    set_parts: List[str] = []
    params_for_update: Dict[str, Any] = {}

    for field, value in update_data.items():
        if field in allowed_fields:
            set_parts.append(f"{field} = %({field}_val)s")
            params_for_update[f"{field}_val"] = value
    
    if not set_parts:
        logger.warning(f"Репозиторий update_subdivision: Нет допустимых полей для обновления ID={subdivision_id}.")
        return get_subdivision_by_id(cursor, subdivision_id)

    params_for_update['sub_id_val'] = subdivision_id
    sql_update = f"UPDATE subdivisions SET {', '.join(set_parts)} WHERE id = %(sub_id_val)s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка обновления подразделения ID={subdivision_id} с полями {list(params_for_update.keys())}")
    try:
        cursor.execute(sql_update, params_for_update)
        updated_row = cursor.fetchone()
        if updated_row:
            logger.info(f"Репозиторий: Успешно обновлено подразделение ID={subdivision_id}. Поля: {list(update_data.keys())}")
            return get_subdivision_by_id(cursor, subdivision_id) # Возвращаем полный обновленный объект
        else:
            logger.warning(f"Репозиторий update_subdivision: Подразделение ID={subdivision_id} не найдено для обновления.")
            return None
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при обновлении подразделения ID {subdivision_id}: {e}", exc_info=True)
        # Обработка специфичных ошибок (например, попытка установить parent_id самого на себя или на несуществующего)
        if e.pgcode == '23505' and 'unique_subdivision_transport_code' in str(e):
            raise ValueError(f"Код ТС '{update_data.get('transport_system_code')}' уже используется другим подразделением.")
        elif e.pgcode == '23503' and 'subdivisions_parent_id_fkey' in str(e):
            raise ValueError(f"Новый родитель ID {update_data.get('parent_id')} для подразделения ID {subdivision_id} не найден.")
        # Можно добавить проверку на циклическую зависимость (parent_id = id) на уровне SQL триггера или здесь, если нужно
        raise


def delete_subdivision(cursor: psycopg2.extensions.cursor, subdivision_id: int) -> bool:
    """
    Удаляет подразделение по его внутреннему ID.
    """
    sql_delete = "DELETE FROM subdivisions WHERE id = %s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка удаления подразделения ID={subdivision_id}")
    try:
        cursor.execute(sql_delete, (subdivision_id,))
        deleted_row = cursor.fetchone()
        if deleted_row:
            logger.info(f"Репозиторий: Успешно удалено подразделение ID={subdivision_id}.")
            return True
        else:
            logger.warning(f"Репозиторий delete_subdivision: Подразделение ID={subdivision_id} не найдено для удаления.")
            return False
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при удалении подразделения ID {subdivision_id}: {e}", exc_info=True)
        # Если есть FK на это подразделение (например, из nodes или дочерних subdivisions с ON DELETE RESTRICT),
        # будет psycopg2.errors.ForeignKeyViolation (pgcode '23503').
        # Ее лучше обработать в роуте, вернув 409 Conflict.
        raise

# =========================
# Конец файла
# =========================