# status/app/repositories/assignment_repository.py
# ... (Полный код из предыдущего ответа для assignment_repository.py с исправлением tuple() -> list) ...
import logging
import psycopg2
import json
from typing import List, Dict, Any, Optional, Tuple
from datetime import datetime # Добавлено для аннотаций
from .. import db_helpers # Импортируем хелперы для иерархии/where

logger = logging.getLogger(__name__)

def create_assignments_unified(cursor, assignment_data: Dict[str, Any], criteria: Optional[Dict[str, Any]] = None, node_ids: Optional[List[int]] = None) -> int:
    method_id = assignment_data.get('method_id'); # ... (проверки method_id) ...
    parameters_json = json.dumps(assignment_data['parameters']) if 'parameters' in assignment_data and assignment_data['parameters'] is not None else None
    success_criteria_json = json.dumps(assignment_data['success_criteria']) if 'success_criteria' in assignment_data and assignment_data['success_criteria'] is not None else None
    sql_params = { 'method_id': method_id, 'is_enabled': assignment_data.get('is_enabled', True), 'parameters': parameters_json, 'check_interval_seconds': assignment_data.get('check_interval_seconds'), 'description': assignment_data.get('description'), 'success_criteria': success_criteria_json }
    target_nodes_sql_part = ""; target_where_clauses = []
    if criteria is not None and node_ids is None: # Критерии
        if 'subdivision_ids' in criteria and criteria['subdivision_ids']: target_where_clauses.append("n.parent_subdivision_id = ANY(%(subdivision_ids)s)"); sql_params['subdivision_ids'] = criteria['subdivision_ids'] # LIST
        if 'node_type_ids' in criteria and criteria['node_type_ids']: target_where_clauses.append("n.node_type_id = ANY(%(node_type_ids)s)"); sql_params['node_type_ids'] = criteria['node_type_ids'] # LIST
        if 'node_name_mask' in criteria and criteria['node_name_mask']: target_where_clauses.append("n.name LIKE %(node_name_mask)s"); sql_params['node_name_mask'] = criteria['node_name_mask']
        where_sql = " AND ".join(target_where_clauses) if target_where_clauses else "1=1"; target_nodes_sql_part = f"SELECT n.id as node_id FROM nodes n WHERE {where_sql}"
    elif node_ids is not None and criteria is None: # Список ID
        target_where_clauses.append("n.id = ANY(%(node_ids)s)"); sql_params['node_ids'] = node_ids # LIST
        where_sql = " AND ".join(target_where_clauses); target_nodes_sql_part = f"SELECT n.id as node_id FROM nodes n WHERE {where_sql}"
    else: raise ValueError("Должны быть предоставлены либо 'criteria', либо 'node_ids'")
    sql = f'''WITH target_nodes AS ( {target_nodes_sql_part} ) INSERT INTO node_check_assignments ( node_id, method_id, is_enabled, parameters, check_interval_seconds, description, success_criteria ) SELECT tn.node_id, %(method_id)s, %(is_enabled)s, %(parameters)s::jsonb, %(check_interval_seconds)s, %(description)s, %(success_criteria)s::jsonb FROM target_nodes tn WHERE NOT EXISTS ( SELECT 1 FROM node_check_assignments existing WHERE existing.node_id = tn.node_id AND existing.method_id = %(method_id)s AND COALESCE(existing.parameters::text, 'null') = COALESCE(%(parameters)s, 'null') AND COALESCE(existing.success_criteria::text, 'null') = COALESCE(%(success_criteria)s, 'null') ) RETURNING id;'''
    cursor.execute(sql, sql_params); inserted_count = cursor.rowcount; logger.info(f"Массовое назначение: создано {inserted_count} заданий")
    # ... (логирование если 0) ...
    return inserted_count

def fetch_assignments_paginated(cursor, limit: int = 25, offset: int = 0, node_id: Optional[int] = None, method_id: Optional[int] = None, subdivision_id: Optional[int] = None, node_type_id: Optional[int] = None, search_text: Optional[str] = None, include_child_subdivisions: bool = False, include_nested_types: bool = False) -> Tuple[List[Dict[str, Any]], int]:
    select_clause = """ SELECT a.id, a.node_id, a.method_id, a.is_enabled, a.parameters, a.check_interval_seconds, a.description, a.last_executed_at, a.success_criteria, n.name as node_name, m.method_name FROM node_check_assignments a JOIN nodes n ON a.node_id = n.id JOIN check_methods m ON a.method_id = m.id """
    count_select_clause = "SELECT COUNT(*) FROM node_check_assignments a JOIN nodes n ON a.node_id = n.id JOIN check_methods m ON a.method_id = m.id"; order_by_sql = " ORDER BY n.name, m.method_name, a.id"
    final_sql_params = {}; specific_where_clauses = []
    if subdivision_id is not None:
        target_sub_ids = db_helpers.get_descendant_subdivision_ids(cursor, subdivision_id) if include_child_subdivisions else [subdivision_id]
        if target_sub_ids: specific_where_clauses.append("n.parent_subdivision_id = ANY(%(target_sub_ids)s)"); final_sql_params['target_sub_ids'] = target_sub_ids # LIST
        elif not include_child_subdivisions: return [], 0
    if node_type_id is not None:
        target_type_ids = db_helpers.get_descendant_node_type_ids(cursor, node_type_id) if include_nested_types else [node_type_id]
        if target_type_ids: specific_where_clauses.append("n.node_type_id = ANY(%(target_type_ids)s)"); final_sql_params['target_type_ids'] = target_type_ids # LIST
        elif not include_nested_types: return [], 0
    allowed_filters = {'node_id': 'a.node_id', 'method_id': 'a.method_id', 'search_text': {'col': 'n.name', 'op': 'ILIKE', 'fmt': '%{}%'}}
    filter_params = {'node_id': node_id, 'method_id': method_id, 'search_text': search_text}
    where_sql_part, sql_params_part = db_helpers.build_where_clause(filter_params, allowed_filters); final_sql_params.update(sql_params_part)
    all_where_clauses = specific_where_clauses;
    if where_sql_part: all_where_clauses.append(where_sql_part.replace(" WHERE ", "").strip())
    final_where_sql = " WHERE " + " AND ".join(filter(None, all_where_clauses)) if all_where_clauses else ""
    total_count = 0; cursor.execute(count_select_clause + final_where_sql, final_sql_params); total_count = cursor.fetchone()['count']
    assignments = []
    if total_count > 0 and offset < total_count:
         limit_offset_sql = " LIMIT %(limit)s OFFSET %(offset)s"; final_sql_params['limit'] = limit; final_sql_params['offset'] = offset;
         query = select_clause + final_where_sql + order_by_sql + limit_offset_sql
         cursor.execute(query, final_sql_params); assignments = cursor.fetchall()
    return assignments, total_count

def get_assignment_by_id(cursor, assignment_id: int) -> Optional[Dict[str, Any]]:
    sql = """ SELECT a.*, n.name as node_name, m.method_name FROM node_check_assignments a JOIN nodes n ON a.node_id = n.id JOIN check_methods m ON a.method_id = m.id WHERE a.id = %(id)s; """
    cursor.execute(sql, {'id': assignment_id}); assignment = cursor.fetchone()
    if not assignment: logger.warning(f"Задание ID {assignment_id} не найдено."); return None
    # Пост-обработка JSON/дат в route
    return assignment

def update_assignment(cursor, assignment_id: int, data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    allowed_fields = ['method_id', 'is_enabled', 'parameters', 'check_interval_seconds', 'description', 'success_criteria']
    update_fields = {k: v for k, v in data.items() if k in allowed_fields}
    if not update_fields: return get_assignment_by_id(cursor, assignment_id)
    if 'method_id' in update_fields and update_fields['method_id'] is not None:
        cursor.execute("SELECT EXISTS (SELECT 1 FROM check_methods WHERE id = %(m_id)s)", {'m_id': update_fields['method_id']})
        if not cursor.fetchone()['exists']: raise ValueError(f"Метод проверки с id={update_fields['method_id']} не найден")
    for json_field in ['parameters', 'success_criteria']:
        if json_field in update_fields:
            if update_fields[json_field] is not None:
                 if not isinstance(update_fields[json_field], dict): raise ValueError(f"'{json_field}' должен быть объектом")
                 update_fields[json_field] = json.dumps(update_fields[json_field])
    set_clause_parts = []
    for field, value in update_fields.items():
        type_cast = "::jsonb" if field in ['parameters', 'success_criteria'] and value is not None else ""
        set_clause_parts.append(f"{field} = %({field})s{type_cast}")
    if not set_clause_parts: return get_assignment_by_id(cursor, assignment_id)
    set_clause = ", ".join(set_clause_parts); sql = f"UPDATE node_check_assignments SET {set_clause} WHERE id = %(id)s RETURNING id;"
    params = update_fields; params['id'] = assignment_id; cursor.execute(sql, params); updated_result = cursor.fetchone()
    if updated_result: return get_assignment_by_id(cursor, assignment_id) # Возвращаем полный объект
    else: # Проверяем, существует ли
         exists = get_assignment_by_id(cursor, assignment_id); return None if not exists else exists # Если существует, но не обновился - ошибка? Возвращаем старый?

def delete_assignment(cursor, assignment_id: int) -> bool:
    sql = "DELETE FROM node_check_assignments WHERE id = %(id)s RETURNING id;"; cursor.execute(sql, {'id': assignment_id}); deleted = cursor.fetchone()
    if deleted: logger.info(f"Удалено задание ID: {assignment_id}"); return True
    else: logger.warning(f"Задание ID {assignment_id} не найдено."); return False

def fetch_assignments_status_for_node(cursor, node_id: int) -> List[Dict[str, Any]]:
    query = ''' SELECT nca.id AS assignment_id, nca.description AS assignment_description, cm.method_name, nca.parameters, nca.is_enabled, nca.check_interval_seconds, nca.last_executed_at, nc.id AS last_check_id, nc.is_available AS last_check_is_available, nc.check_timestamp AS last_check_timestamp, nc.checked_at as last_check_db_timestamp, (SELECT EXISTS (SELECT 1 FROM node_check_details ncd WHERE ncd.node_check_id = nc.id)) AS has_details FROM node_check_assignments nca JOIN check_methods cm ON nca.method_id = cm.id LEFT JOIN node_checks nc ON nca.last_node_check_id = nc.id WHERE nca.node_id = %(node_id)s ORDER BY cm.method_name, nca.id; '''
    params = {'node_id': node_id}; cursor.execute(query, params); assignments = cursor.fetchall()
    # Пост-обработка в route
    return assignments

