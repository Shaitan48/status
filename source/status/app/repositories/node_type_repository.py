# status/app/repositories/node_type_repository.py
# ... (Полный код из предыдущего ответа для node_type_repository.py) ...
import logging
import psycopg2
from typing import List, Dict, Any, Optional, Tuple

logger = logging.getLogger(__name__)

# --- CRUD Функции для Node Types ---

def create_node_type(cursor, data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    if not data.get('name'): raise ValueError("Отсутствует обязательное поле: name")
    parent_type_id = data.get('parent_type_id')
    if parent_type_id is not None:
        cursor.execute("SELECT EXISTS (SELECT 1 FROM node_types WHERE id = %(p_id)s)", {'p_id': parent_type_id})
        if not cursor.fetchone()['exists']: raise ValueError(f"Родительский тип узла с id={parent_type_id} не найден")
    icon_filename = data.get('icon_filename')
    if icon_filename and len(icon_filename) > 100: raise ValueError("Имя файла иконки не может быть длиннее 100 символов.")
    sql = '''INSERT INTO node_types (name, description, parent_type_id, priority, icon_filename) VALUES (%(name)s, %(description)s, %(parent_type_id)s, %(priority)s, %(icon_filename)s) RETURNING *;'''
    params = {'name': data['name'], 'description': data.get('description'), 'parent_type_id': parent_type_id, 'priority': data.get('priority', 10), 'icon_filename': icon_filename}
    cursor.execute(sql, params); new_type = cursor.fetchone()
    if new_type: logger.info(f"Создан тип узла ID: {new_type['id']}, Имя: {new_type['name']}")
    return new_type

def get_node_type_by_id(cursor, type_id: int) -> Optional[Dict[str, Any]]:
    sql = "SELECT * FROM node_types WHERE id = %(id)s;"; cursor.execute(sql, {'id': type_id}); node_type = cursor.fetchone()
    if not node_type: logger.warning(f"Тип узла с ID {type_id} НЕ НАЙДЕН.")
    return node_type

def update_node_type(cursor, type_id: int, data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    allowed_fields = ['name', 'description', 'parent_type_id', 'priority', 'icon_filename']
    update_fields = {k: v for k, v in data.items() if k in allowed_fields}
    if not update_fields: return get_node_type_by_id(cursor, type_id)
    parent_type_id = update_fields.get('parent_type_id')
    if parent_type_id is not None:
        if parent_type_id == type_id: raise ValueError("Нельзя установить родителя самого на себя")
        cursor.execute("SELECT EXISTS (SELECT 1 FROM node_types WHERE id = %(p_id)s)", {'p_id': parent_type_id})
        if not cursor.fetchone()['exists']: raise ValueError(f"Родительский тип узла с id={parent_type_id} не найден")
    icon_filename = update_fields.get('icon_filename')
    if icon_filename and len(icon_filename) > 100: raise ValueError("Имя файла иконки не может быть длиннее 100 символов.")
    set_clause = ", ".join([f"{field} = %({field})s" for field in update_fields.keys()])
    sql = f"UPDATE node_types SET {set_clause} WHERE id = %(id)s RETURNING *;"
    params = update_fields; params['id'] = type_id; cursor.execute(sql, params); updated_type = cursor.fetchone()
    if updated_type: logger.info(f"Обновлен тип узла ID: {type_id}")
    else:
         exists = get_node_type_by_id(cursor, type_id)
         if not exists: return None
         else: raise psycopg2.Error(f"Не удалось обновить тип узла ID {type_id}, хотя он существует.")
    return updated_type

def delete_node_type(cursor, type_id: int) -> bool:
    if type_id == 0: raise ValueError("Нельзя удалить базовый тип узла (ID=0).")
    cursor.execute("SELECT COUNT(*) FROM node_types WHERE parent_type_id = %(id)s", {'id': type_id})
    if cursor.fetchone()['count'] > 0: raise ValueError("Невозможно удалить тип узла: существуют дочерние типы.")
    cursor.execute("SELECT COUNT(*) FROM nodes WHERE node_type_id = %(id)s", {'id': type_id})
    if cursor.fetchone()['count'] > 0: raise ValueError("Невозможно удалить тип узла: он назначен узлам.")
    sql = "DELETE FROM node_types WHERE id = %(id)s RETURNING id;"; cursor.execute(sql, {'id': type_id}); deleted = cursor.fetchone()
    if deleted: logger.info(f"Удален тип узла ID: {type_id}"); return True
    else: logger.warning(f"Тип узла с ID {type_id} не найден для удаления."); return False

def fetch_node_types(cursor, limit: Optional[int] = None, offset: int = 0, parent_type_id: Optional[int] = None, search_text: Optional[str] = None) -> Tuple[List[Dict[str, Any]], int]:
    select_clause = "SELECT nt.*, p.name AS parent_name FROM node_types nt LEFT JOIN node_types p ON nt.parent_type_id = p.id"
    count_select_clause = "SELECT COUNT(*) FROM node_types nt"
    where_clauses = []; sql_params = {}
    if parent_type_id is not None:
        if parent_type_id == 0: where_clauses.append("nt.parent_type_id IS NULL")
        else: where_clauses.append("nt.parent_type_id = %(parent_id)s"); sql_params['parent_id'] = parent_type_id
    if search_text: where_clauses.append("(nt.name ILIKE %(search)s OR nt.description ILIKE %(search)s)"); sql_params['search'] = f'%{search_text}%'
    where_sql = " WHERE " + " AND ".join(where_clauses) if where_clauses else ""
    total_count = 0
    try: cursor.execute(count_select_clause + where_sql, sql_params); total_count = cursor.fetchone().get('count', 0)
    except psycopg2.Error as e: logger.error(...); raise
    items = []
    if total_count > 0 and offset < total_count:
        order_by_sql = " ORDER BY nt.priority, nt.name"; limit_offset_sql = ""
        if limit is not None: limit_offset_sql = " LIMIT %(limit)s OFFSET %(offset)s"; sql_params['limit'] = limit; sql_params['offset'] = offset
        query = select_clause + where_sql + order_by_sql + limit_offset_sql
        try: cursor.execute(query, sql_params); items = cursor.fetchall()
        except psycopg2.Error as e: logger.error(...); raise
    return items, total_count
