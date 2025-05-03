# status/app/repositories/node_repository.py
import logging
import psycopg2
from psycopg2.extras import RealDictCursor # Хотя пул настроен, импорт может быть полезен для ясности
from typing import List, Dict, Any, Optional, Tuple
from .. import db_helpers # Импорт хелперов из родительского пакета ('app')

logger = logging.getLogger(__name__)
DEFAULT_ICON = "other.svg" # Имя иконки по умолчанию

# --- Функции получения данных (Read) ---

def fetch_node_base_info(cursor, node_id: Optional[int] = None) -> List[Dict[str, Any]]:
    """Получает базовую информацию об узлах из функции БД get_node_base_info()."""
    try:
        # Вызываем функцию БД, передавая ID узла (или NULL)
        sql = "SELECT * FROM get_node_base_info(%(node_id)s)"
        params = {'node_id': node_id}
        cursor.execute(sql, params)
        nodes = cursor.fetchall()
        logger.info(f"Получено базовой информации узлов: {len(nodes)} строк (фильтр node_id: {node_id}).")
        # Дополнительный fallback для иконки
        for node in nodes:
             if not node.get('icon_filename'):
                 node['icon_filename'] = DEFAULT_ICON
                 logger.debug(f"Node ID {node.get('id')} не имеет icon_filename в БД, используется fallback: {DEFAULT_ICON}")
        return nodes
    except psycopg2.Error as e_db:
        logger.error(f"Ошибка БД при вызове get_node_base_info: {e_db}", exc_info=True)
        raise # Пробрасываем исключение psycopg2
    except Exception as e_main:
        logger.error(f"Неожиданная ошибка при получении базовой информации узлов: {e_main}", exc_info=True)
        raise # Пробрасываем другое исключение

def fetch_node_ping_status(cursor, node_id: Optional[int] = None) -> List[Dict[str, Any]]:
    """Получает статус последней PING проверки из функции БД get_node_ping_status()."""
    try:
        sql = "SELECT * FROM get_node_ping_status(%(node_id)s)"
        params = {'node_id': node_id}
        cursor.execute(sql, params)
        statuses = cursor.fetchall()
        logger.info(f"Получено PING статусов: {len(statuses)} строк (фильтр node_id: {node_id}).")
        # Форматирование дат перенесено в сервисный слой или маршруты
        return statuses
    except psycopg2.Warning as w: # Ловим WARNING от функции БД (если метод PING не найден)
         logger.warning(f"Предупреждение от get_node_ping_status: {w}")
         return [] # Возвращаем пустой список при предупреждении
    except psycopg2.Error as e_db:
        logger.error(f"Ошибка БД при вызове get_node_ping_status: {e_db}", exc_info=True)
        raise # Пробрасываем исключение psycopg2
    except Exception as e_main:
        logger.error(f"Неожиданная ошибка при получении PING статусов: {e_main}", exc_info=True)
        raise # Пробрасываем другое исключение

def fetch_nodes(cursor, limit: Optional[int] = None, offset: int = 0,
                 subdivision_id: Optional[int] = None, node_type_id: Optional[int] = None,
                 search_text: Optional[str] = None,
                 include_child_subdivisions: bool = False, include_nested_types: bool = False
                 ) -> Tuple[List[Dict[str, Any]], int]:
    """Получает список узлов с пагинацией и фильтрацией."""
    logger.debug(f"fetch_nodes: limit={limit}, offset={offset}, sub_id={subdivision_id}({include_child_subdivisions}), type_id={node_type_id}({include_nested_types}), search={search_text}")

    select_clause = """
        SELECT n.id, n.name, n.ip_address, n.description,
               n.parent_subdivision_id as subdivision_id,
               s.short_name as subdivision_short_name,
               n.node_type_id,
               nt.name as node_type_name
        FROM nodes n
        LEFT JOIN subdivisions s ON n.parent_subdivision_id = s.id
        LEFT JOIN node_types nt ON n.node_type_id = nt.id
    """
    count_select_clause = "SELECT COUNT(*) FROM nodes n" # Базовый подсчет

    where_clauses = []
    sql_params = {}

    # --- Фильтрация ---
    if subdivision_id is not None:
        target_sub_ids = db_helpers.get_descendant_subdivision_ids(cursor, subdivision_id) if include_child_subdivisions else [subdivision_id]
        if target_sub_ids:
            where_clauses.append("n.parent_subdivision_id = ANY(%(target_sub_ids)s)")
            sql_params['target_sub_ids'] = target_sub_ids # Передаем LIST
        elif not include_child_subdivisions: return [], 0 # Если искали конкретный ID и не нашли

    if node_type_id is not None:
         target_type_ids = db_helpers.get_descendant_node_type_ids(cursor, node_type_id) if include_nested_types else [node_type_id]
         if target_type_ids:
             where_clauses.append("n.node_type_id = ANY(%(target_type_ids)s)")
             sql_params['target_type_ids'] = target_type_ids # Передаем LIST
         elif not include_nested_types: return [], 0

    if search_text:
        search_pattern = f'%{search_text}%'
        # Поиск по имени узла, IP или описанию
        where_clauses.append("(n.name ILIKE %(search_text)s OR n.ip_address ILIKE %(search_text)s OR n.description ILIKE %(search_text)s)")
        sql_params['search_text'] = search_pattern

    # --- Сборка запросов ---
    where_sql = ""
    if where_clauses:
        where_sql = " WHERE " + " AND ".join(where_clauses)
        # Добавляем JOIN'ы в COUNT, если фильтровали по связанным таблицам
        if subdivision_id is not None: count_select_clause += " LEFT JOIN subdivisions s ON n.parent_subdivision_id = s.id"
        if node_type_id is not None: count_select_clause += " LEFT JOIN node_types nt ON n.node_type_id = nt.id"

    # --- Выполнение ---
    total_count = 0
    try:
        cursor.execute(count_select_clause + where_sql, sql_params)
        count_result = cursor.fetchone()
        total_count = count_result.get('count', 0) if count_result else 0
        logger.debug(f"Подсчет узлов: {total_count} найдено по фильтрам.")
    except psycopg2.Error as e_count:
        logger.error(f"Ошибка БД при подсчете узлов: {e_count}", exc_info=True)
        raise

    items = []
    if total_count > 0 and offset < total_count:
        order_by_sql = " ORDER BY s.short_name NULLS LAST, n.name" # NULLS LAST для s.short_name
        limit_offset_sql = ""
        if limit is not None:
            limit_offset_sql = " LIMIT %(limit)s OFFSET %(offset)s"
            sql_params['limit'] = limit
            sql_params['offset'] = offset

        query = select_clause + where_sql + order_by_sql + limit_offset_sql
        logger.debug(f"Выполнение запроса узлов: {query} с параметрами: {sql_params}")
        try:
            cursor.execute(query, sql_params)
            items = cursor.fetchall()
            logger.info(f"Получено узлов: {len(items)} (Страница, offset={offset}, limit={limit})")
        except psycopg2.Error as e_fetch:
            logger.error(f"Ошибка БД при получении страницы узлов: {e_fetch}", exc_info=True)
            raise
    else:
         logger.info(f"Нет узлов для отображения (Total: {total_count}, Offset: {offset})")

    return items, total_count

# --- CRUD Функции ---

def create_node(cursor, data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Создает новый узел мониторинга. Выполняет валидацию. Возвращает частичные данные."""
    required_fields = ['name', 'parent_subdivision_id']
    if not all(field in data and data[field] is not None for field in required_fields):
        raise ValueError(f"Отсутствуют обязательные поля: {required_fields}")

    # Проверка родителя
    cursor.execute("SELECT EXISTS (SELECT 1 FROM subdivisions WHERE id = %(sub_id)s)", {'sub_id': data['parent_subdivision_id']})
    if not cursor.fetchone()['exists']:
        raise ValueError(f"Родительское подразделение с id={data['parent_subdivision_id']} не найдено")

    # Проверка типа узла
    node_type_id = data.get('node_type_id')
    if node_type_id is not None:
         cursor.execute("SELECT EXISTS (SELECT 1 FROM node_types WHERE id = %(type_id)s)", {'type_id': node_type_id})
         if not cursor.fetchone()['exists']:
             raise ValueError(f"Тип узла с id={node_type_id} не найден")

    # Валидация IP (простая)
    ip_address = data.get('ip_address')
    if ip_address and not isinstance(ip_address, str):
        raise ValueError("IP-адрес должен быть строкой")
    # TODO: Добавить более строгую валидацию IP, если нужно

    sql = """
        INSERT INTO nodes (name, parent_subdivision_id, ip_address, node_type_id, description)
        VALUES (%(name)s, %(parent_subdivision_id)s, %(ip_address)s, %(node_type_id)s, %(description)s)
        RETURNING id;
    """
    try:
        params = {
            'name': data['name'],
            'parent_subdivision_id': data['parent_subdivision_id'],
            'ip_address': ip_address,
            'node_type_id': node_type_id,
            'description': data.get('description')
        }
        cursor.execute(sql, params)
        result = cursor.fetchone()
        if not result or 'id' not in result:
             logger.error("RETURNING id не вернул ID при создании узла.")
             return None # Или пробросить исключение

        new_node_id = result['id']
        logger.info(f"Создан узел ID: {new_node_id}, Имя: {data['name']}")
        # Возвращаем ID и исходные параметры, чтобы route мог получить полные данные
        return {'id': new_node_id, **params}
    except psycopg2.Error as e: # Ловим UniqueViolation и другие ошибки БД
        logger.error(f"Ошибка БД при создании узла: {e}", exc_info=True)
        raise # Передаем ошибку наверх для обработки в route

def get_node_by_id(cursor, node_id: int) -> Optional[Dict[str, Any]]:
    """Получает ПОЛНУЮ информацию об одном узле по ID, используя get_node_base_info."""
    # Используем уже существующую функцию fetch_node_base_info
    node_info_list = fetch_node_base_info(cursor, node_id=node_id)
    if node_info_list:
        logger.debug(f"Получена базовая информация для узла ID: {node_id}")
        return node_info_list[0]
    else:
        logger.warning(f"Узел с ID {node_id} не найден (через get_node_base_info).")
        return None # Возвращаем None, если не найден

def update_node(cursor, node_id: int, data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Обновляет существующий узел. Возвращает ПОЛНЫЕ обновленные данные узла."""
    allowed_fields = ['name', 'parent_subdivision_id', 'ip_address', 'node_type_id', 'description']
    update_fields = {k: v for k, v in data.items() if k in allowed_fields} # Обновляем и None значения тоже, если переданы

    if not update_fields:
        logger.warning(f"Нет данных для обновления узла ID: {node_id}. Возвращаем текущие данные.")
        return get_node_by_id(cursor, node_id) # Возвращаем текущие данные, если нечего обновлять

    # Валидация родителя и типа (только если они переданы для обновления)
    if 'parent_subdivision_id' in update_fields and update_fields['parent_subdivision_id'] is not None:
        cursor.execute("SELECT EXISTS (SELECT 1 FROM subdivisions WHERE id = %(sub_id)s)", {'sub_id': update_fields['parent_subdivision_id']})
        if not cursor.fetchone()['exists']:
            raise ValueError(f"Родительское подразделение с id={update_fields['parent_subdivision_id']} не найдено")
    if 'node_type_id' in update_fields and update_fields['node_type_id'] is not None:
         cursor.execute("SELECT EXISTS (SELECT 1 FROM node_types WHERE id = %(type_id)s)", {'type_id': update_fields['node_type_id']})
         if not cursor.fetchone()['exists']:
             raise ValueError(f"Тип узла с id={update_fields['node_type_id']} не найден")
    if 'ip_address' in update_fields and update_fields['ip_address'] is not None and not isinstance(update_fields['ip_address'], str):
         raise ValueError("IP-адрес должен быть строкой или null")

    set_clause = ", ".join([f"{field} = %({field})s" for field in update_fields.keys()])
    sql = f"UPDATE nodes SET {set_clause} WHERE id = %(id)s RETURNING id;"

    try:
        params = update_fields
        params['id'] = node_id
        cursor.execute(sql, params)
        updated_result = cursor.fetchone()

        if updated_result:
            logger.info(f"Обновлен узел ID: {node_id}")
            # Получаем и возвращаем ПОЛНУЮ обновленную информацию
            return get_node_by_id(cursor, node_id)
        else:
            # Если RETURNING ничего не вернул, значит запись с таким ID не найдена
            # Проверяем явно, прежде чем вернуть None
            exists = get_node_by_id(cursor, node_id)
            if not exists:
                 logger.warning(f"Узел с ID {node_id} не найден для обновления.")
                 return None
            else:
                 # Ситуация, когда запись есть, но UPDATE ее не затронул (маловероятно)
                 logger.error(f"Запись Node ID {node_id} существует, но UPDATE не вернул данных.")
                 raise psycopg2.Error(f"Не удалось обновить узел ID {node_id}, хотя он существует.")

    except psycopg2.Error as e: # Ловим UniqueViolation и другие ошибки БД
        logger.error(f"Ошибка БД при обновлении узла ID {node_id}: {e}", exc_info=True)
        raise # Передаем ошибку наверх

def delete_node(cursor, node_id: int) -> bool:
    """Удаляет узел. ВНИМАНИЕ: CASCADE удалит связанные записи! Возвращает True/False."""
    try:
        sql = "DELETE FROM nodes WHERE id = %(id)s RETURNING id;"
        cursor.execute(sql, {'id': node_id})
        deleted = cursor.fetchone()
        if deleted:
            logger.info(f"Удален узел ID: {node_id} (и связанные записи)")
            return True
        else:
            logger.warning(f"Узел с ID {node_id} не найден для удаления.")
            return False
    except psycopg2.Error as e:
        logger.error(f"Ошибка БД при удалении узла ID {node_id}: {e}", exc_info=True)
        raise # Передаем ошибку наверх