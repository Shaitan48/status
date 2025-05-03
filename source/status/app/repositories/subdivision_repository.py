# status/app/repositories/subdivision_repository.py
import logging
import psycopg2
# Убираем импорт RealDictCursor, т.к. пул его предоставляет
from typing import List, Dict, Any, Optional, Tuple

logger = logging.getLogger(__name__)

def create_subdivision(cursor, data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    required_fields = ['object_id', 'short_name']
    if not all(field in data and data[field] is not None for field in required_fields):
        raise ValueError(f"Отсутствуют обязательные поля: {required_fields}")
    parent_id = data.get('parent_id')
    if parent_id is not None:
        cursor.execute("SELECT EXISTS (SELECT 1 FROM subdivisions WHERE id = %(parent_id)s)", {'parent_id': parent_id})
        if not cursor.fetchone()['exists']: raise ValueError(f"Родительское подразделение с id={parent_id} не найдено")
    transport_code = data.get('transport_system_code')
    if transport_code and not (isinstance(transport_code, str) and transport_code.isalnum() and 1 <= len(transport_code) <= 10):
         raise ValueError("Код ТС должен содержать 1-10 латинских букв/цифр.")
    sql = '''INSERT INTO subdivisions (object_id, short_name, full_name, parent_id, domain_name, transport_system_code, priority, comment, icon_filename) VALUES (%(object_id)s, %(short_name)s, %(full_name)s, %(parent_id)s, %(domain_name)s, %(transport_system_code)s, %(priority)s, %(comment)s, %(icon_filename)s) RETURNING *;'''
    params = {'object_id': data['object_id'], 'short_name': data['short_name'], 'full_name': data.get('full_name'), 'parent_id': parent_id, 'domain_name': data.get('domain_name'), 'transport_system_code': transport_code, 'priority': data.get('priority', 10), 'comment': data.get('comment'), 'icon_filename': data.get('icon_filename')}
    cursor.execute(sql, params)
    new_subdivision = cursor.fetchone()
    if new_subdivision: logger.info(f"Создано подразделение ID: {new_subdivision['id']}, ObjectID: {new_subdivision['object_id']}")
    return new_subdivision

def get_subdivision_by_id(cursor, subdivision_id: int) -> Optional[Dict[str, Any]]:
    sql = "SELECT * FROM subdivisions WHERE id = %(id)s;"
    cursor.execute(sql, {'id': subdivision_id})
    subdivision = cursor.fetchone()
    if not subdivision: logger.warning(f"Подразделение с ID {subdivision_id} не найдено.")
    return subdivision

def update_subdivision(cursor, subdivision_id: int, data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    allowed_fields = ['short_name', 'full_name', 'parent_id', 'domain_name', 'transport_system_code', 'priority', 'comment', 'icon_filename']
    update_fields = {k: v for k, v in data.items() if k in allowed_fields}
    if not update_fields: return get_subdivision_by_id(cursor, subdivision_id)
    if 'parent_id' in update_fields and update_fields['parent_id'] is not None:
        if update_fields['parent_id'] == subdivision_id: raise ValueError("Нельзя установить родителя самого на себя")
        cursor.execute("SELECT EXISTS (SELECT 1 FROM subdivisions WHERE id = %(parent_id)s)", {'parent_id': update_fields['parent_id']})
        if not cursor.fetchone()['exists']: raise ValueError(f"Родительское подразделение с id={update_fields['parent_id']} не найдено")
    transport_code = update_fields.get('transport_system_code')
    if transport_code and not (isinstance(transport_code, str) and transport_code.isalnum() and 1 <= len(transport_code) <= 10): raise ValueError("Код ТС должен содержать 1-10 латинских букв/цифр.")
    set_clause = ", ".join([f"{field} = %({field})s" for field in update_fields.keys()])
    sql = f"UPDATE subdivisions SET {set_clause} WHERE id = %(id)s RETURNING *;"
    params = update_fields; params['id'] = subdivision_id
    cursor.execute(sql, params)
    updated_subdivision = cursor.fetchone()
    if updated_subdivision: logger.info(f"Обновлено подразделение ID: {subdivision_id}")
    else:
         exists = get_subdivision_by_id(cursor, subdivision_id)
         if not exists: return None
         else: raise psycopg2.Error(f"Не удалось обновить подразделение ID {subdivision_id}, хотя оно существует.")
    return updated_subdivision

def delete_subdivision(cursor, subdivision_id: int) -> bool:
    sql = "DELETE FROM subdivisions WHERE id = %(id)s RETURNING id;"
    cursor.execute(sql, {'id': subdivision_id})
    deleted = cursor.fetchone()
    if deleted: logger.info(f"Удалено подразделение ID: {subdivision_id}"); return True
    else: logger.warning(f"Подразделение с ID {subdivision_id} не найдено для удаления."); return False

def fetch_subdivisions(cursor, limit: Optional[int] = None, offset: int = 0, parent_id: Optional[int] = None, search_text: Optional[str] = None) -> Tuple[List[Dict[str, Any]], int]:
    select_clause = "SELECT s.*, p.short_name AS parent_name FROM subdivisions s LEFT JOIN subdivisions p ON s.parent_id = p.id"
    count_select_clause = "SELECT COUNT(*) FROM subdivisions s"
    where_clauses = []; sql_params = {}
    if parent_id is not None:
        if parent_id == 0: where_clauses.append("s.parent_id IS NULL")
        else: where_clauses.append("s.parent_id = %(parent_id)s"); sql_params['parent_id'] = parent_id
    if search_text:
        where_clauses.append("(s.short_name ILIKE %(search)s OR s.full_name ILIKE %(search)s)"); sql_params['search'] = f'%{search_text}%'
    where_sql = " WHERE " + " AND ".join(where_clauses) if where_clauses else ""
    total_count = 0
    try:
        cursor.execute(count_select_clause + where_sql, sql_params)
        count_result = cursor.fetchone(); total_count = count_result.get('count', 0) if count_result else 0
    except psycopg2.Error as e: logger.error(...); raise
    items = []
    if total_count > 0 and offset < total_count:
        order_by_sql = " ORDER BY s.priority, s.short_name"; limit_offset_sql = ""
        if limit is not None: limit_offset_sql = " LIMIT %(limit)s OFFSET %(offset)s"; sql_params['limit'] = limit; sql_params['offset'] = offset
        query = select_clause + where_sql + order_by_sql + limit_offset_sql
        try: cursor.execute(query, sql_params); items = cursor.fetchall()
        except psycopg2.Error as e: logger.error(...); raise
    return items, total_count
