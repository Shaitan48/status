# status/app/repositories/node_type_repository.py
"""
node_type_repository.py — CRUD-операции и логика для работы с типами узлов (node_types).
Версия 5.0.2: Функции теперь принимают курсор, удалены commit, улучшена обработка ошибок и возвращаемые значения.
"""
import logging
import psycopg2 # Для типизации курсора и обработки ошибок psycopg2.Error
from typing import List, Dict, Any, Optional, Tuple

# Импортируем get_connection для общей консистентности, хотя функции ожидают курсор.
from ..db_connection import get_connection

logger = logging.getLogger(__name__)

# =========================
# Получение типов узлов (Node Types)
# =========================
def fetch_node_types(
    cursor: psycopg2.extensions.cursor,
    limit: Optional[int] = None,
    offset: int = 0,
    parent_id: Optional[int] = None, # 0 для корневых, ID для дочерних, None для всех
    search_text: Optional[str] = None
) -> Tuple[List[Dict[str, Any]], int]:
    """
    Получает страницу типов узлов с фильтрацией и пагинацией.
    Args:
        cursor: Активный курсор базы данных (предполагается RealDictCursor).
        limit: Максимальное количество записей на странице.
        offset: Смещение для пагинации.
        parent_id: Фильтр по ID родительского типа. 0 или None для корневых/всех.
        search_text: Текст для поиска по имени или описанию типа.
    Returns:
        Кортеж (список типов узлов, общее количество типов с учетом фильтров).
    """
    logger.debug(f"Репозиторий: Запрос списка типов узлов. Фильтры: parent_id={parent_id}, search='{search_text}', limit={limit}, offset={offset}")
    
    select_fields = "SELECT id, name, description, parent_type_id, priority, icon_filename FROM node_types"
    count_select = "SELECT COUNT(*) FROM node_types" # Базовый запрос для подсчета
    
    where_clauses: List[str] = []
    query_params: Dict[str, Any] = {}

    if parent_id is not None:
        if parent_id == 0: # 0 или null интерпретируем как корневые типы
            where_clauses.append("parent_type_id IS NULL")
        else: # Фильтр по конкретному ID родителя
            where_clauses.append("parent_type_id = %(p_id_val)s")
            query_params['p_id_val'] = parent_id
    
    if search_text:
        where_clauses.append("(name ILIKE %(search_val)s OR description ILIKE %(search_val)s)")
        query_params['search_val'] = f"%{search_text}%"

    where_sql_clause = (" WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
    
    try:
        # Получаем общее количество с учетом фильтров
        cursor.execute(count_select + where_sql_clause, query_params)
        total_count_result = cursor.fetchone()
        total_types = total_count_result['count'] if total_count_result else 0

        types_list: List[Dict[str, Any]] = []
        if total_types > 0 and (limit is None or offset < total_types): # Запрашиваем страницу, если есть что запрашивать
            order_by_sql = " ORDER BY priority ASC, name ASC" # Сортировка
            limit_offset_sql_part = ""
            if limit is not None:
                limit_offset_sql_part = " LIMIT %(limit_val)s OFFSET %(offset_val)s"
                query_params['limit_val'] = limit
                query_params['offset_val'] = offset
            
            cursor.execute(select_fields + where_sql_clause + order_by_sql + limit_offset_sql_part, query_params)
            types_list = cursor.fetchall() # Ожидаем список словарей от RealDictCursor
            
        logger.info(f"Репозиторий fetch_node_types: Найдено {len(types_list)} типов узлов на странице, всего {total_types}.")
        return types_list, total_types
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при выборке типов узлов: {e}", exc_info=True)
        raise # Пробрасываем ошибку для обработки на более высоком уровне


def get_node_type_by_id(cursor: psycopg2.extensions.cursor, node_type_id: int) -> Optional[Dict[str, Any]]:
    """
    Получить тип узла по его ID.
    Args:
        cursor: Активный курсор базы данных.
        node_type_id (int): ID типа узла.
    Returns:
        Словарь с данными типа узла или None, если не найден.
    """
    sql = "SELECT id, name, description, parent_type_id, priority, icon_filename FROM node_types WHERE id = %s;"
    logger.debug(f"Репозиторий: Запрос типа узла по ID={node_type_id}")
    try:
        cursor.execute(sql, (node_type_id,))
        node_type_data = cursor.fetchone() # Ожидаем словарь от RealDictCursor
        if not node_type_data:
            logger.warning(f"Репозиторий: Тип узла с ID={node_type_id} не найден.")
        return node_type_data
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении типа узла ID {node_type_id}: {e}", exc_info=True)
        raise

# =========================
# CRUD операции для Node Types
# =========================
def create_node_type(
    cursor: psycopg2.extensions.cursor,
    data: Dict[str, Any] # Ожидаем словарь с полями нового типа узла
) -> Optional[Dict[str, Any]]: # Возвращаем созданный объект типа узла
    """
    Создать новый тип узла.
    Ожидает в `data` как минимум 'name'. Остальные поля опциональны.
    Args:
        cursor: Активный курсор базы данных.
        data: Словарь с данными для нового типа узла.
              Пример: {'name': 'Сервер Linux', 'parent_type_id': 1, 'priority': 20}
    Returns:
        Словарь с данными созданного типа узла (включая ID) или None при ошибке.
    """
    if not data.get('name') or not str(data['name']).strip():
        logger.error("Репозиторий create_node_type: Отсутствует обязательное поле 'name'.")
        raise ValueError("Имя типа узла является обязательным полем.")

    sql = """
        INSERT INTO node_types (name, description, parent_type_id, priority, icon_filename)
        VALUES (%(name)s, %(description)s, %(parent_type_id)s, %(priority)s, %(icon_filename)s)
        RETURNING id;
    """
    params = {
        'name': str(data['name']).strip(),
        'description': data.get('description'),
        'parent_type_id': data.get('parent_type_id'), # Может быть None для корневого
        'priority': data.get('priority', 10), # Значение по умолчанию
        'icon_filename': data.get('icon_filename')
    }
    logger.debug(f"Репозиторий: Попытка создания типа узла с данными: {params}")
    try:
        cursor.execute(sql, params)
        result = cursor.fetchone()
        if result and result.get('id') is not None:
            new_type_id = result['id']
            logger.info(f"Репозиторий: Успешно создан тип узла ID={new_type_id}, Имя='{params['name']}'.")
            # Возвращаем полный объект созданного типа
            return get_node_type_by_id(cursor, new_type_id)
        else:
            # Эта ситуация маловероятна с RETURNING id, если вставка прошла без ошибки
            logger.error("Репозиторий create_node_type: Не удалось получить ID после вставки типа узла.")
            return None
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при создании типа узла '{params['name']}': {e}", exc_info=True)
        # Обработка специфичных ошибок PostgreSQL
        if e.pgcode == '23505': # Unique violation (для unique_type_name_parent)
            parent_id_log = params.get('parent_type_id', 'NULL')
            raise ValueError(f"Тип узла с именем '{params['name']}' уже существует для родительского типа ID {parent_id_log}.")
        elif e.pgcode == '23503' and 'node_types_parent_type_id_fkey' in str(e): # Foreign key violation
            raise ValueError(f"Родительский тип узла ID {params.get('parent_type_id')} не найден.")
        raise # Пробрасываем остальные ошибки psycopg2

def update_node_type(
    cursor: psycopg2.extensions.cursor,
    node_type_id: int,
    update_data: Dict[str, Any] # Словарь с полями для обновления
) -> Optional[Dict[str, Any]]: # Возвращаем обновленный объект
    """
    Обновляет параметры существующего типа узла.
    Args:
        cursor: Активный курсор базы данных.
        node_type_id: ID типа узла для обновления.
        update_data: Словарь с полями для обновления.
                     Допустимые ключи: name, description, parent_type_id, priority, icon_filename.
    Returns:
        Словарь с обновленными данными типа узла или None, если тип не найден.
    """
    if not update_data:
        logger.warning(f"Репозиторий update_node_type: Нет данных для обновления типа узла ID={node_type_id}.")
        return get_node_type_by_id(cursor, node_type_id) # Возвращаем текущее состояние

    # Формируем SET clause динамически из допустимых полей
    allowed_fields_for_update = ['name', 'description', 'parent_type_id', 'priority', 'icon_filename']
    set_parts: List[str] = []
    params_for_sql_update: Dict[str, Any] = {}

    for field, value in update_data.items():
        if field in allowed_fields_for_update:
            # Особая обработка для parent_type_id, если он равен ID самого типа (циклическая зависимость)
            if field == 'parent_type_id' and value == node_type_id:
                logger.error(f"Репозиторий update_node_type: Попытка установить тип ID={node_type_id} родителем для самого себя.")
                raise ValueError("Тип узла не может быть родителем для самого себя.")
            
            set_parts.append(f"{field} = %({field}_val)s") # Используем именованные плейсхолдеры
            params_for_sql_update[f"{field}_val"] = value
    
    if not set_parts: # Если не было допустимых полей для обновления
        logger.warning(f"Репозиторий update_node_type: Нет допустимых полей для обновления в типе узла ID={node_type_id}.")
        return get_node_type_by_id(cursor, node_type_id)

    params_for_sql_update['type_id_val'] = node_type_id # Добавляем ID самого типа для WHERE
    sql_update_query = f"UPDATE node_types SET {', '.join(set_parts)} WHERE id = %(type_id_val)s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка обновления типа узла ID={node_type_id} с полями {list(params_for_sql_update.keys())}")
    try:
        cursor.execute(sql_update_query, params_for_sql_update)
        updated_row = cursor.fetchone()
        if updated_row:
            logger.info(f"Репозиторий: Успешно обновлен тип узла ID={node_type_id}. Обновленные поля: {list(update_data.keys())}")
            return get_node_type_by_id(cursor, node_type_id) # Возвращаем полный обновленный объект
        else:
            logger.warning(f"Репозиторий update_node_type: Тип узла ID={node_type_id} не найден для обновления.")
            return None # Тип узла не найден
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при обновлении типа узла ID {node_type_id}: {e}", exc_info=True)
        # Обработка специфичных ошибок
        if e.pgcode == '23505' and 'unique_type_name_parent' in str(e):
            raise ValueError(f"Конфликт имени при обновлении типа узла ID {node_type_id}: имя '{update_data.get('name')}' уже используется для данного родителя.")
        elif e.pgcode == '23503' and 'node_types_parent_type_id_fkey' in str(e):
             raise ValueError(f"Новый родительский тип ID {update_data.get('parent_type_id')} для типа узла ID {node_type_id} не найден.")
        # Здесь можно добавить проверку на циклическую зависимость, если parent_id меняется,
        # хотя базовая (сам на себя) уже проверяется выше. Более сложные циклы лучше ловить в БД триггером.
        raise

def delete_node_type(cursor: psycopg2.extensions.cursor, node_type_id: int) -> bool:
    """
    Удаляет тип узла по его ID.
    Перед удалением проверяет, не является ли это базовым типом (ID=0),
    и нет ли у него дочерних типов или назначенных узлов.

    Args:
        cursor: Активный курсор базы данных.
        node_type_id (int): ID удаляемого типа узла.

    Returns:
        True если тип узла удалён, False — если не найден.
    Raises:
        ValueError: Если тип нельзя удалить (базовый, есть дочерние типы, назначен узлам).
        psycopg2.Error: При других ошибках БД.
    """
    if node_type_id == 0: # Базовый тип (ID=0) удалять нельзя
        logger.warning(f"Репозиторий delete_node_type: Попытка удаления базового типа узла ID=0 отклонена.")
        raise ValueError("Базовый тип узла (ID=0) не может быть удален.")

    # 1. Проверка на наличие дочерних типов
    cursor.execute("SELECT EXISTS (SELECT 1 FROM node_types WHERE parent_type_id = %s);", (node_type_id,))
    if cursor.fetchone()['exists']:
        logger.warning(f"Репозиторий delete_node_type: Попытка удаления типа ID={node_type_id}, у которого есть дочерние типы.")
        raise ValueError(f"Невозможно удалить тип узла ID={node_type_id}, так как у него существуют дочерние типы. Сначала удалите или переназначьте их.")

    # 2. Проверка на наличие узлов этого типа
    # (FK в таблице nodes для node_type_id установлен в ON DELETE SET NULL,
    # поэтому узлы не будут препятствовать удалению типа, их тип просто сбросится.
    # Но если мы хотим предотвратить это и требовать сначала переназначения типа у узлов,
    # то эту проверку нужно добавить.)
    # cursor.execute("SELECT EXISTS (SELECT 1 FROM nodes WHERE node_type_id = %s);", (node_type_id,))
    # if cursor.fetchone()['exists']:
    #     logger.warning(f"Репозиторий delete_node_type: Попытка удаления типа ID={node_type_id}, который назначен узлам.")
    #     raise ValueError(f"Невозможно удалить тип узла ID={node_type_id}, так как он назначен одному или нескольким узлам. Сначала измените тип у этих узлов.")

    # 3. Удаление самого типа узла
    sql_delete = "DELETE FROM node_types WHERE id = %s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка удаления типа узла ID={node_type_id}")
    try:
        cursor.execute(sql_delete, (node_type_id,))
        deleted_row = cursor.fetchone()
        if deleted_row:
            logger.info(f"Репозиторий: Успешно удален тип узла ID={node_type_id}.")
            return True
        else:
            logger.warning(f"Репозиторий delete_node_type: Тип узла ID={node_type_id} не найден для удаления.")
            return False # Не найден
    except psycopg2.Error as e: # Другие ошибки БД (например, FK на node_properties, если там RESTRICT)
        logger.error(f"Репозиторий: Ошибка БД при удалении типа узла ID {node_type_id}: {e}", exc_info=True)
        if e.pgcode == '23503': # ForeignKeyViolation
             raise ValueError(f"Невозможно удалить тип узла ID {node_type_id} из-за ссылок в других таблицах (например, свойствах типов). {e.diag.message_detail or str(e)}")
        raise

# =========================
# Конец файла
# =========================