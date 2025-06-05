# status/app/repositories/node_repository.py
"""
node_repository.py — CRUD-операции и логика для управления узлами мониторинга (nodes).
Версия 5.0.1: Добавлены функции fetch_node_base_info и fetch_node_ping_status,
             вызывающие соответствующие SQL-функции для node_service.
Везде добавлено логгирование, подробные комментарии и docstring.
"""

import logging
import psycopg2 # Для типизации курсора и обработки psycopg2.Error
from typing import List, Dict, Any, Optional

# Используем относительный импорт для db_connection, если он в том же пакете
from ..db_connection import get_connection # get_connection теперь возвращает контекстный менеджер

logger = logging.getLogger(__name__)

# =========================
# Получение узлов (Nodes) - Базовые CRUD и выборки
# =========================

def fetch_nodes(
    cursor: psycopg2.extensions.cursor, # Ожидаем курсор как аргумент
    limit: Optional[int] = None,
    offset: int = 0,
    subdivision_id: Optional[int] = None,
    node_type_id: Optional[int] = None,
    search_text: Optional[str] = None,
    include_child_subdivisions: bool = False, # Флаги для иерархической фильтрации
    include_nested_types: bool = False
) -> tuple[List[Dict[str, Any]], int]:
    """
    Получает страницу узлов с фильтрацией и пагинацией.
    Эта функция должна вызывать более сложный SQL-запрос или хранимую процедуру,
    которая умеет обрабатывать иерархическую фильтрацию по подразделениям и типам.

    Args:
        cursor: Активный курсор базы данных.
        limit: Максимальное количество узлов на странице.
        offset: Смещение для пагинации.
        subdivision_id: Фильтр по ID родительского подразделения.
        node_type_id: Фильтр по ID типа узла.
        search_text: Текст для поиска по имени или IP-адресу узла.
        include_child_subdivisions: Включать ли узлы из дочерних подразделений.
        include_nested_types: Включать ли узлы с дочерними типами.

    Returns:
        Кортеж (список узлов, общее количество узлов с учетом фильтров).
    """
    logger.debug(f"Репозиторий: Запрос списка узлов с фильтрами: sub_id={subdivision_id}(children:{include_child_subdivisions}), "
                 f"type_id={node_type_id}(nested:{include_nested_types}), search='{search_text}', limit={limit}, offset={offset}")

    # --- Формирование SQL-запроса с учетом фильтров ---
    # Это сложный запрос, который лучше реализовать как хранимую функцию в PostgreSQL
    # для обработки иерархии подразделений и типов.
    # Здесь будет упрощенный пример, который не полностью реализует иерархию,
    # но показывает принцип. Для полной реализации см. SQL-функции.

    # Базовые части запроса
    select_fields = """
        SELECT n.id, n.name, n.parent_subdivision_id, n.ip_address, n.node_type_id, n.description,
               s.short_name as subdivision_short_name, s.object_id as subdivision_object_id,
               nt.name as node_type_name, nt.icon_filename as node_type_icon
    """
    count_select = "SELECT COUNT(DISTINCT n.id)" # DISTINCT n.id на случай сложных JOIN
    from_clause = """
        FROM nodes n
        LEFT JOIN subdivisions s ON n.parent_subdivision_id = s.id
        LEFT JOIN node_types nt ON n.node_type_id = nt.id
    """
    where_clauses: List[str] = []
    query_params: Dict[str, Any] = {}

    # Фильтр по подразделению (упрощенный, без рекурсии здесь)
    if subdivision_id is not None:
        if include_child_subdivisions:
            # Для иерархии нужна рекурсивная CTE в SQL, здесь не реализуем полностью
            logger.warning("Фильтрация по дочерним подразделениям в Python-репозитории упрощена (только прямой родитель). "
                           "Для полной иерархии используйте SQL-функцию.")
            # Примерно: WHERE n.parent_subdivision_id IN (SELECT id FROM get_subdivision_descendants_and_self(%(sid)s))
            where_clauses.append("n.parent_subdivision_id = %(sub_id)s") # Упрощенный вариант
            query_params['sub_id'] = subdivision_id
        else:
            where_clauses.append("n.parent_subdivision_id = %(sub_id)s")
            query_params['sub_id'] = subdivision_id

    # Фильтр по типу узла (упрощенный)
    if node_type_id is not None:
        if include_nested_types:
            logger.warning("Фильтрация по вложенным типам узлов в Python-репозитории упрощена.")
            where_clauses.append("n.node_type_id = %(type_id)s") # Упрощенный вариант
            query_params['type_id'] = node_type_id
        else:
            where_clauses.append("n.node_type_id = %(type_id)s")
            query_params['type_id'] = node_type_id
    
    # Фильтр по тексту
    if search_text:
        where_clauses.append("(n.name ILIKE %(search)s OR n.ip_address ILIKE %(search)s OR n.description ILIKE %(search)s)")
        query_params['search'] = f"%{search_text}%"

    where_sql = (" WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
    
    # Запрос на общее количество
    sql_count = count_select + from_clause + where_sql
    try:
        cursor.execute(sql_count, query_params)
        total_count_result = cursor.fetchone()
        total_nodes = total_count_result['count'] if total_count_result else 0
    except psycopg2.Error as e_count:
        logger.error(f"Репозиторий: Ошибка БД при подсчете узлов: {e_count}", exc_info=True)
        raise # Пробрасываем ошибку

    nodes_list: List[Dict[str, Any]] = []
    if total_nodes > 0 and (limit is None or offset < total_nodes):
        order_by_sql = " ORDER BY s.priority, nt.priority, n.name" # Пример сортировки
        limit_offset_sql = ""
        if limit is not None:
            limit_offset_sql = " LIMIT %(lim)s OFFSET %(off)s"
            query_params['lim'] = limit
            query_params['off'] = offset
        
        sql_select_page = select_fields + from_clause + where_sql + order_by_sql + limit_offset_sql
        try:
            cursor.execute(sql_select_page, query_params)
            nodes_list = cursor.fetchall() # Ожидаем список словарей от RealDictCursor
        except psycopg2.Error as e_select:
            logger.error(f"Репозиторий: Ошибка БД при выборке страницы узлов: {e_select}", exc_info=True)
            raise
            
    logger.info(f"Репозиторий fetch_nodes: Найдено {len(nodes_list)} узлов на странице, всего {total_nodes}.")
    return nodes_list, total_nodes


def get_node_by_id(cursor: psycopg2.extensions.cursor, node_id: int) -> Optional[Dict[str, Any]]:
    """
    Получить данные по конкретному узлу по его ID.
    Включает информацию о подразделении и типе узла.

    Args:
        cursor: Активный курсор базы данных.
        node_id (int): ID узла.

    Returns:
        Словарь с данными узла или None, если узел не найден.
    """
    sql = """
        SELECT
            n.id, n.name, n.parent_subdivision_id, n.ip_address, n.node_type_id, n.description,
            s.short_name as subdivision_short_name, s.object_id as subdivision_object_id,
            nt.name as node_type_name, nt.icon_filename as node_type_icon
        FROM nodes n
        LEFT JOIN subdivisions s ON n.parent_subdivision_id = s.id
        LEFT JOIN node_types nt ON n.node_type_id = nt.id
        WHERE n.id = %s;
    """
    logger.debug(f"Репозиторий: Запрос узла по ID={node_id}")
    try:
        cursor.execute(sql, (node_id,))
        node_data = cursor.fetchone() # Словарь, если RealDictCursor
        if not node_data:
            logger.warning(f"Репозиторий: Узел с ID={node_id} не найден.")
        return node_data
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении узла ID {node_id}: {e}", exc_info=True)
        raise


# =================================================================================
# НОВЫЕ ФУНКЦИИ для вызова SQL-функций, используемых в node_service.py
# =================================================================================

def fetch_node_base_info(cursor: psycopg2.extensions.cursor, node_id: Optional[int] = None) -> List[Dict[str, Any]]:
    """
    Вызывает SQL-функцию get_node_base_info для получения базовой информации об узлах,
    включая вычисленные свойства типа узла.

    Args:
        cursor: Активный курсор базы данных.
        node_id (int, optional): ID конкретного узла для фильтрации. Если None, для всех узлов.

    Returns:
        Список словарей с базовой информацией об узлах.
    """
    sql_function_call = "SELECT * FROM get_node_base_info(%(node_id_param)s);"
    params = {'node_id_param': node_id} # SQL-функция ожидает NULL, если все узлы
    logger.debug(f"Репозиторий: Вызов SQL-функции get_node_base_info с node_id={node_id}")
    try:
        cursor.execute(sql_function_call, params)
        base_info_list = cursor.fetchall()
        logger.info(f"Репозиторий: fetch_node_base_info вернула {len(base_info_list)} записей.")
        return base_info_list
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при вызове get_node_base_info: {e}", exc_info=True)
        raise

def fetch_node_ping_status(cursor: psycopg2.extensions.cursor, node_id_filter: Optional[int] = None) -> List[Dict[str, Any]]:
    """
    Вызывает SQL-функцию get_node_ping_status для получения статуса последней PING-проверки,
    включая is_available и check_success.

    Args:
        cursor: Активный курсор базы данных.
        node_id_filter (int, optional): ID конкретного узла для фильтрации. Если None, для всех узлов.

    Returns:
        Список словарей со статусами PING-проверок для узлов.
    """
    # SQL-функция get_node_ping_status была обновлена и теперь возвращает check_success
    sql_function_call = "SELECT * FROM get_node_ping_status(%(node_id_param)s);"
    params = {'node_id_param': node_id_filter}
    logger.debug(f"Репозиторий: Вызов SQL-функции get_node_ping_status с node_id_filter={node_id_filter}")
    try:
        cursor.execute(sql_function_call, params)
        ping_status_list = cursor.fetchall()

        # --- ОТЛАДОЧНОЕ ЛОГИРОВАНИЕ ---
        if ping_status_list:
            logger.debug(f"Репозиторий fetch_node_ping_status: Тип первого элемента в ping_status_list: {type(ping_status_list[0])}")
            if isinstance(ping_status_list[0], dict):
                logger.debug(f"Репозиторий fetch_node_ping_status: Ключи первого элемента: {list(ping_status_list[0].keys())}")
                if 'check_success' not in ping_status_list[0]:
                    logger.warning("Репозиторий fetch_node_ping_status: Поле 'check_success' ОТСУТСТВУЕТ в словаре первого элемента!")
                else:
                    logger.debug(f"Репозиторий fetch_node_ping_status: Значение 'check_success' в первом элементе: {ping_status_list[0]['check_success']}")
            elif isinstance(ping_status_list[0], tuple):
                 logger.warning("Репозиторий fetch_node_ping_status: Первый элемент является КОРТЕЖЕМ, а не словарем! Проблема с RealDictCursor.")
                 logger.debug(f"Репозиторий fetch_node_ping_status: Содержимое первого кортежа: {ping_status_list[0]}")
        else:
            logger.debug("Репозиторий fetch_node_ping_status: SQL-функция вернула пустой список.")
        # --- КОНЕЦ ОТЛАДОЧНОГО ЛОГИРОВАНИЯ ---
        
        logger.info(f"Репозиторий: fetch_node_ping_status вернула {len(ping_status_list)} записей.")
        # Проверяем, что поле check_success присутствует (для отладки)
        if ping_status_list and 'check_success' not in ping_status_list[0]:
            logger.warning("Репозиторий: В результате fetch_node_ping_status отсутствует поле 'check_success'! "
                           "Убедитесь, что SQL-функция get_node_ping_status обновлена.")
        return ping_status_list
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при вызове get_node_ping_status: {e}", exc_info=True)
        raise

# =================================================================================
# CRUD операции для Узлов (Nodes) - остаются в основном без изменений
# =================================================================================

def create_node(
    cursor: psycopg2.extensions.cursor,
    data: Dict[str, Any] # Ожидаем словарь с полями узла
) -> Optional[Dict[str, Any]]: # Возвращаем созданный объект или None
    """
    Создает новый узел мониторинга.
    Ожидает в `data` ключи: name, parent_subdivision_id, и опционально
    ip_address, node_type_id, description.

    Args:
        cursor: Активный курсор базы данных.
        data: Словарь с данными нового узла.

    Returns:
        Словарь с данными созданного узла (включая ID) или None при ошибке.
    """
    # Валидация обязательных полей может быть здесь или на уровне роута/сервиса
    if not data.get('name') or not data.get('parent_subdivision_id'):
        logger.error("Репозиторий create_node: Отсутствуют обязательные поля 'name' или 'parent_subdivision_id'.")
        raise ValueError("Имя узла и ID родительского подразделения обязательны.")

    sql = """
        INSERT INTO nodes (name, parent_subdivision_id, ip_address, node_type_id, description)
        VALUES (%(name)s, %(parent_subdivision_id)s, %(ip_address)s, %(node_type_id)s, %(description)s)
        RETURNING id;
    """
    params = {
        'name': data['name'],
        'parent_subdivision_id': data['parent_subdivision_id'],
        'ip_address': data.get('ip_address'), # Может быть None
        'node_type_id': data.get('node_type_id'), # Может быть None
        'description': data.get('description')  # Может быть None
    }
    logger.debug(f"Репозиторий: Попытка создания узла с данными: {params}")
    try:
        cursor.execute(sql, params)
        result = cursor.fetchone()
        if result and result.get('id') is not None:
            new_node_id = result['id']
            logger.info(f"Репозиторий: Успешно создан узел ID={new_node_id}, Имя='{params['name']}'.")
            # Возвращаем словарь с ID для консистентности (или можно запросить полный объект get_node_by_id)
            return {'id': new_node_id, **data} # Возвращаем ID и исходные данные
        else:
            logger.error("Репозиторий create_node: Не удалось получить ID после вставки узла.")
            return None
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при создании узла '{params['name']}': {e}", exc_info=True)
        # Проверяем специфичные ошибки, если нужно (например, UniqueViolation, ForeignKeyViolation)
        if e.pgcode == '23505': # Unique violation
            raise ValueError(f"Узел с именем '{params['name']}' уже существует в данном подразделении.")
        elif e.pgcode == '23503': # Foreign key violation
            # Проверяем, какой FK нарушен (parent_subdivision_id или node_type_id)
            if 'nodes_parent_subdivision_id_fkey' in str(e):
                raise ValueError(f"Родительское подразделение ID {params['parent_subdivision_id']} не найдено.")
            elif 'nodes_node_type_id_fkey' in str(e):
                 raise ValueError(f"Тип узла ID {params['node_type_id']} не найден.")
            else:
                 raise ValueError(f"Ошибка связи с другой таблицей при создании узла: {e.diag.message_detail or str(e)}")
        raise # Пробрасываем остальные ошибки psycopg2


def update_node(
    cursor: psycopg2.extensions.cursor,
    node_id: int,
    update_data: Dict[str, Any] # Словарь с полями для обновления
) -> Optional[Dict[str, Any]]: # Возвращаем обновленный объект или None
    """
    Обновляет параметры существующего узла.

    Args:
        cursor: Активный курсор базы данных.
        node_id: ID узла для обновления.
        update_data: Словарь с полями для обновления.
                     Допустимые ключи: name, parent_subdivision_id, ip_address, node_type_id, description.

    Returns:
        Словарь с обновленными данными узла (после SELECT) или None, если узел не найден.
    """
    if not update_data:
        logger.warning(f"Репозиторий update_node: Нет данных для обновления узла ID={node_id}.")
        return get_node_by_id(cursor, node_id) # Возвращаем текущее состояние, если нет изменений

    # Формируем SET clause динамически
    allowed_fields_for_update = ['name', 'parent_subdivision_id', 'ip_address', 'node_type_id', 'description']
    set_parts: List[str] = []
    params_for_update: Dict[str, Any] = {}

    for field, value in update_data.items():
        if field in allowed_fields_for_update:
            set_parts.append(f"{field} = %({field}_val)s") # Используем именованные плейсхолдеры
            params_for_update[f"{field}_val"] = value
    
    if not set_parts:
        logger.warning(f"Репозиторий update_node: Нет допустимых полей для обновления в узле ID={node_id}.")
        return get_node_by_id(cursor, node_id)

    params_for_update['node_id_val'] = node_id
    sql_update = f"UPDATE nodes SET {', '.join(set_parts)} WHERE id = %(node_id_val)s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка обновления узла ID={node_id} с полями {list(params_for_update.keys())}")

    try:
        cursor.execute(sql_update, params_for_update)
        updated_row = cursor.fetchone()
        if updated_row:
            logger.info(f"Репозиторий: Успешно обновлен узел ID={node_id}. Поля: {list(update_data.keys())}")
            return get_node_by_id(cursor, node_id) # Возвращаем полный обновленный объект
        else:
            logger.warning(f"Репозиторий update_node: Узел ID={node_id} не найден для обновления (RETURNING не вернул ID).")
            return None # Узел не найден
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при обновлении узла ID {node_id}: {e}", exc_info=True)
        # Обработка специфичных ошибок, как в create_node
        if e.pgcode == '23505': raise ValueError(f"Конфликт имени при обновлении узла ID {node_id}.")
        elif e.pgcode == '23503':
             if 'nodes_parent_subdivision_id_fkey' in str(e): raise ValueError(f"Новое родительское подразделение для узла ID {node_id} не найдено.")
             elif 'nodes_node_type_id_fkey' in str(e): raise ValueError(f"Новый тип узла для узла ID {node_id} не найден.")
             else: raise ValueError(f"Ошибка связи при обновлении узла ID {node_id}: {e.diag.message_detail or str(e)}")
        raise


def delete_node(cursor: psycopg2.extensions.cursor, node_id: int) -> bool:
    """
    Удаляет узел по его ID.

    Args:
        cursor: Активный курсор базы данных.
        node_id (int): ID удаляемого узла.

    Returns:
        True если узел удалён, False — иначе.
    """
    sql_delete = "DELETE FROM nodes WHERE id = %s RETURNING id;" # RETURNING для проверки факта удаления
    logger.debug(f"Репозиторий: Попытка удаления узла ID={node_id}")
    try:
        cursor.execute(sql_delete, (node_id,))
        deleted_row = cursor.fetchone()
        if deleted_row:
            logger.info(f"Репозиторий: Успешно удален узел ID={node_id}.")
            return True
        else:
            logger.warning(f"Репозиторий delete_node: Узел ID={node_id} не найден для удаления.")
            return False
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при удалении узла ID {node_id}: {e}", exc_info=True)
        # Если есть FK на этот узел (например, из node_check_assignments),
        # и ON DELETE не CASCADE/SET NULL, то будет ошибка.
        # Ее лучше обработать на уровне роута (вернуть 409 Conflict).
        raise # Пробрасываем ошибку для обработки выше

# =========================
# Конец файла
# =========================