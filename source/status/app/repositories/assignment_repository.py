# status/app/repositories/assignment_repository.py
"""
Репозиторий для CRUD-операций и бизнес-логики, связанной с Заданиями (Assignments).
Версия 5.0.1: Исправлен импорт get_connection.
Адаптирован для pipeline-архитектуры (v5.x), где задания определяются полем 'pipeline' (JSONB).
"""
import json
import logging
import psycopg2
from typing import List, Dict, Any, Optional, Tuple

# <<< ИЗМЕНЕНО: Импортируем get_connection >>>
from ..db_connection import get_connection

logger = logging.getLogger(__name__)

# --- Вспомогательная функция для построения WHERE для fetch_assignments_paginated ---
# (Остается без изменений)
def _build_assignments_where_clause(
    filters: Dict[str, Any]
) -> Tuple[str, Dict[str, Any]]:
    # ... (код функции) ...
    where_clauses: List[str] = []
    params: Dict[str, Any] = {}
    if filters.get('node_id') is not None:
        where_clauses.append("a.node_id = %(node_id)s")
        params['node_id'] = filters['node_id']
    if filters.get('method_id') is not None:
        where_clauses.append("a.method_id = %(method_id)s")
        params['method_id'] = filters['method_id']
    if filters.get('is_enabled') is not None:
        where_clauses.append("a.is_enabled = %(is_enabled)s")
        params['is_enabled'] = filters['is_enabled']
    if filters.get('subdivision_id') is not None:
        params['target_subdivision_id'] = filters['subdivision_id']
        params['include_child_subdivisions'] = filters.get('include_child_subdivisions', False)
    if filters.get('node_type_id') is not None:
        params['target_node_type_id'] = filters['node_type_id']
        params['include_nested_types'] = filters.get('include_nested_types', False)
    if filters.get('search_text'):
        where_clauses.append("(a.description ILIKE %(search_text)s OR n.name ILIKE %(search_text)s)")
        params['search_text'] = f"%{filters['search_text']}%"
    where_sql = (" AND " + " AND ".join(where_clauses)) if where_clauses else ""
    return where_sql, params

# --- Основные функции репозитория ---
# (Все вызовы get_db_connection() заменены на get_connection())

def fetch_assignments_paginated(
    cursor: psycopg2.extensions.cursor, # Теперь курсор передается
    limit: Optional[int] = 25,
    offset: int = 0,
    # ... (остальные параметры) ...
    include_nested_types: bool = False
) -> Tuple[List[Dict[str, Any]], int]:
    logger.debug(f"Репозиторий: Запрос списка заданий...") # Упрощенный лог
    # ... (остальная логика функции fetch_assignments_paginated остается,
    #      она уже использует переданный курсор, а не вызывает get_connection() внутри) ...
    # Важно: Эта функция не вызывает get_connection() сама, она ожидает курсор.
    # Если бы она вызывала, нужно было бы заменить.
    # Код для SQL-запросов и обработки такой же, как в твоем файле.
    filters_for_where = { # Собираем фильтры
        'node_id': node_id, 'method_id': method_id, 'search_text': search_text,
        'is_enabled': is_enabled, 'subdivision_id': subdivision_id,
        'include_child_subdivisions': include_child_subdivisions,
        'node_type_id': node_type_id, 'include_nested_types': include_nested_types
    }
    simple_where_clauses: List[str] = []
    params_query: Dict[str, Any] = {}
    if node_id is not None:
        simple_where_clauses.append("a.node_id = %(node_id_filter)s")
        params_query['node_id_filter'] = node_id
    if method_id is not None:
        simple_where_clauses.append("a.method_id = %(method_id_filter)s")
        params_query['method_id_filter'] = method_id
    if is_enabled is not None:
        simple_where_clauses.append("a.is_enabled = %(is_enabled_filter)s")
        params_query['is_enabled_filter'] = is_enabled
    if search_text:
        simple_where_clauses.append("(a.description ILIKE %(search_text_filter)s OR n.name ILIKE %(search_text_filter)s)")
        params_query['search_text_filter'] = f"%{search_text}%"
    if subdivision_id is not None:
        simple_where_clauses.append("n.parent_subdivision_id = %(subdivision_id_filter)s")
        params_query['subdivision_id_filter'] = subdivision_id
    if node_type_id is not None:
         simple_where_clauses.append("n.node_type_id = %(node_type_id_filter)s")
         params_query['node_type_id_filter'] = node_type_id
    where_sql_simple = (" WHERE " + " AND ".join(simple_where_clauses)) if simple_where_clauses else ""
    count_sql = f"""
        SELECT COUNT(DISTINCT a.id) FROM node_check_assignments a
        JOIN nodes n ON a.node_id = n.id JOIN check_methods cm ON a.method_id = cm.id
        LEFT JOIN subdivisions s ON n.parent_subdivision_id = s.id
        LEFT JOIN node_types nt ON n.node_type_id = nt.id {where_sql_simple};
    """
    select_sql_base = """
        SELECT a.id, a.node_id, n.name as node_name, a.method_id, cm.method_name,
            a.pipeline, a.check_interval_seconds, a.is_enabled, a.description,
            a.last_executed_at, a.last_node_check_id, s.short_name as subdivision_name,
            nt.name as node_type_name
        FROM node_check_assignments a JOIN nodes n ON a.node_id = n.id
        JOIN check_methods cm ON a.method_id = cm.id
        LEFT JOIN subdivisions s ON n.parent_subdivision_id = s.id
        LEFT JOIN node_types nt ON n.node_type_id = nt.id
    """
    order_by_sql = " ORDER BY n.name, a.id"; limit_offset_sql = ""
    if limit is not None: limit_offset_sql = " LIMIT %(limit_val)s OFFSET %(offset_val)s"; params_query['limit_val'] = limit; params_query['offset_val'] = offset
    full_select_sql = select_sql_base + where_sql_simple + order_by_sql + limit_offset_sql
    try:
        cursor.execute(count_sql, params_query); total_count = cursor.fetchone()['count']
        assignments = []
        if total_count > 0 and (limit is None or offset < total_count):
            cursor.execute(full_select_sql, params_query); assignments = cursor.fetchall()
    except psycopg2.Error as e: logger.error(f"Ошибка БД при выборке заданий: {e}", exc_info=True); raise
    logger.info(f"Репозиторий: fetch_assignments_paginated вернул {len(assignments)} заданий, всего найдено {total_count}.")
    return assignments, total_count

def get_assignment_by_id(cursor: psycopg2.extensions.cursor, assignment_id: int) -> Optional[Dict[str, Any]]:
    # ... (логика такая же, курсор уже передан) ...
    sql = """ SELECT a.id, a.node_id, n.name as node_name, a.method_id, cm.method_name,
            a.pipeline, a.check_interval_seconds, a.is_enabled, a.description,
            a.last_executed_at, a.last_node_check_id
        FROM node_check_assignments a JOIN nodes n ON a.node_id = n.id
        JOIN check_methods cm ON a.method_id = cm.id WHERE a.id = %s; """
    try:
        cursor.execute(sql, (assignment_id,)); assignment = cursor.fetchone()
        if assignment and 'pipeline' in assignment and isinstance(assignment['pipeline'], str):
            try: assignment['pipeline'] = json.loads(assignment['pipeline'])
            except json.JSONDecodeError: assignment['pipeline'] = {"_error": "Invalid JSON"}
        elif assignment and assignment.get('pipeline') is None: assignment['pipeline'] = []
        return assignment
    except psycopg2.Error as e: logger.error(f"Ошибка БД ID {assignment_id}: {e}", exc_info=True); raise

def create_assignment(
    cursor: psycopg2.extensions.cursor, # Ожидаем курсор
    node_id: int,
    method_id: int,
    pipeline: List[Dict[str, Any]],
    check_interval_seconds: int,
    is_enabled: bool = True,
    description: Optional[str] = None
) -> Optional[int]:
    # ... (логика такая же, курсор уже передан) ...
    sql = """ INSERT INTO node_check_assignments (node_id, method_id, pipeline, check_interval_seconds, is_enabled, description)
        VALUES (%s, %s, %s::jsonb, %s, %s, %s) RETURNING id; """
    try:
        pipeline_json_str = json.dumps(pipeline)
        cursor.execute(sql, (node_id, method_id, pipeline_json_str, check_interval_seconds, is_enabled, description))
        result = cursor.fetchone(); new_id = result['id'] if result else None
        if new_id: logger.info(f"Создано задание ID={new_id} для узла ID={node_id}.")
        return new_id # Важно: не коммитим здесь, пусть коммитит вызывающий код (например, роут)
    except psycopg2.Error as e: logger.error(f"Ошибка БД при создании задания: {e}", exc_info=True); raise
    except json.JSONDecodeError as je: logger.error(f"Ошибка JSON pipeline: {je}", exc_info=True); raise ValueError(f"Некорректный pipeline: {je}")

def update_assignment(
    cursor: psycopg2.extensions.cursor, # Ожидаем курсор
    assignment_id: int,
    update_data: Dict[str, Any]
) -> Optional[Dict[str, Any]]:
    # ... (логика такая же, курсор уже передан) ...
    if not update_data: return get_assignment_by_id(cursor, assignment_id)
    set_parts: List[str] = []; params_update: Dict[str, Any] = {}
    for field, value in update_data.items():
        if field == 'pipeline': set_parts.append("pipeline = %(pipeline_val)s::jsonb"); params_update['pipeline_val'] = json.dumps(value)
        elif field in ['method_id', 'check_interval_seconds', 'is_enabled', 'description']: set_parts.append(f"{field} = %({field}_val)s"); params_update[f"{field}_val"] = value
    if not set_parts: return get_assignment_by_id(cursor, assignment_id)
    params_update['assignment_id_val'] = assignment_id
    sql = f"UPDATE node_check_assignments SET {', '.join(set_parts)} WHERE id = %(assignment_id_val)s RETURNING id;"
    try:
        cursor.execute(sql, params_update); updated_row = cursor.fetchone()
        if updated_row: logger.info(f"Обновлено задание ID={assignment_id}."); return get_assignment_by_id(cursor, assignment_id)
        else: logger.warning(f"Задание ID={assignment_id} не найдено для обновления."); return None
    except psycopg2.Error as e: logger.error(f"Ошибка БД при обновлении ID {assignment_id}: {e}", exc_info=True); raise
    except json.JSONDecodeError as je_upd: logger.error(f"Ошибка JSON pipeline ID {assignment_id}: {je_upd}", exc_info=True); raise ValueError(f"Некорректный pipeline: {je_upd}")


def delete_assignment(cursor: psycopg2.extensions.cursor, assignment_id: int) -> bool:
    # ... (логика такая же, курсор уже передан) ...
    sql = "DELETE FROM node_check_assignments WHERE id = %s RETURNING id;"
    try:
        cursor.execute(sql, (assignment_id,)); deleted_row = cursor.fetchone()
        if deleted_row: logger.info(f"Удалено задание ID={assignment_id}."); return True
        else: logger.warning(f"Задание ID={assignment_id} не найдено для удаления."); return False
    except psycopg2.Error as e: logger.error(f"Ошибка БД при удалении ID {assignment_id}: {e}", exc_info=True); raise

def create_assignments_unified(
    cursor: psycopg2.extensions.cursor, # Ожидаем курсор
    assignment_template: Dict[str, Any],
    criteria_target: Optional[Dict[str, Any]],
    node_ids_target: Optional[List[int]]
) -> Tuple[int, List[int]]:
    # ... (логика такая же, курсор уже передан) ...
    # Важно: эта функция выполняет множественные INSERT, она должна быть обернута в транзакцию
    # на уровне вызывающего кода, если это необходимо.
    logger.info(f"Репозиторий: Массовое создание заданий...")
    target_node_ids: List[int] = []
    if node_ids_target: target_node_ids = node_ids_target
    elif criteria_target:
        sql_select_nodes = "SELECT DISTINCT n.id FROM nodes n "; joins: List[str] = []; where_criteria: List[str] = []; params_criteria: Dict[str, Any] = {}
        if criteria_target.get('subdivision_ids'): joins.append("JOIN subdivisions s ON n.parent_subdivision_id = s.id"); where_criteria.append("s.id = ANY(%(tsid)s)"); params_criteria['tsid'] = criteria_target['subdivision_ids']
        if criteria_target.get('node_type_ids'): where_criteria.append("n.node_type_id = ANY(%(ttid)s)"); params_criteria['ttid'] = criteria_target['node_type_ids']
        if criteria_target.get('node_name_mask'): where_criteria.append("n.name ILIKE %(nnm)s"); params_criteria['nnm'] = criteria_target['node_name_mask']
        if where_criteria: sql_select_nodes += " ".join(joins) + " WHERE " + " AND ".join(where_criteria)
        try: cursor.execute(sql_select_nodes, params_criteria); target_node_ids = [row['id'] for row in cursor.fetchall()]
        except psycopg2.Error as e: logger.error(f"Ошибка БД при выборке узлов: {e}", exc_info=True); raise ValueError(f"Ошибка выборки узлов: {e}")
    if not target_node_ids: logger.info("Нет узлов для массового назначения."); return 0, []
    method_id=assignment_template['method_id']; pipeline_obj=assignment_template['pipeline']
    check_interval=assignment_template.get('check_interval_seconds',300); is_enabled_val=assignment_template.get('is_enabled',True)
    description_val=assignment_template.get('description'); pipeline_json_str_bulk = json.dumps(pipeline_obj)
    created_count_bulk=0; created_assignment_ids: List[int] = []
    insert_sql_bulk = """ INSERT INTO node_check_assignments (node_id, method_id, pipeline, check_interval_seconds, is_enabled, description)
        VALUES (%(node_id)s, %(method_id)s, %(pipeline_json)s::jsonb, %(interval)s, %(enabled)s, %(desc)s)
        ON CONFLICT (node_id, method_id, pipeline) DO NOTHING RETURNING id; """
    for node_id_item in target_node_ids:
        try:
            params_item = {'node_id':node_id_item,'method_id':method_id,'pipeline_json':pipeline_json_str_bulk,'interval':check_interval,'enabled':is_enabled_val,'desc':description_val}
            cursor.execute(insert_sql_bulk, params_item); result_insert_item = cursor.fetchone()
            if result_insert_item: created_count_bulk+=1; created_assignment_ids.append(result_insert_item['id'])
            else: logger.debug(f"Задание для узла ID {node_id_item} уже существует, пропущено.")
        except psycopg2.Error as e: logger.error(f"Ошибка БД при создании задания для узла ID {node_id_item} в bulk: {e}", exc_info=False)
    logger.info(f"Массовое назначение: создано {created_count_bulk} заданий."); return created_count_bulk, created_assignment_ids

def fetch_assignments_status_for_node(cursor: psycopg2.extensions.cursor, node_id: int) -> List[Dict[str, Any]]:
    # ... (логика такая же, курсор уже передан) ...
    logger.debug(f"Репозиторий: Запрос статуса заданий для узла ID={node_id}.")
    sql = "SELECT * FROM get_assignments_status_for_node(%(node_id_param)s);" # SQL-функция должна быть адаптирована
    try:
        cursor.execute(sql, {'node_id_param': node_id}); assignments_status = cursor.fetchall()
        for item in assignments_status: # Десериализация pipeline
            if 'pipeline' in item and isinstance(item['pipeline'], str):
                try: item['pipeline'] = json.loads(item['pipeline'])
                except json.JSONDecodeError: item['pipeline'] = {"_error": "Invalid JSON"}
            elif item.get('pipeline') is None: item['pipeline'] = []
        return assignments_status
    except psycopg2.Error as e: logger.error(f"Ошибка БД при получении статуса заданий для узла ID {node_id}: {e}", exc_info=True); raise

# ================================
# Конец файла
# ================================