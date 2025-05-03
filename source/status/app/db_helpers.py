# status/app/db_helpers.py
import logging
import psycopg2
from typing import List, Dict, Any, Tuple

logger = logging.getLogger(__name__)

# --- Функции иерархии (перенесены из db.py, принимают курсор) ---
def get_descendant_subdivision_ids(cursor, parent_id: int) -> List[int]:
    """Рекурсивно получает ID всех дочерних подразделений (включая родителя)."""
    if parent_id is None: return []
    ids = [parent_id]
    try:
        sql = """
            WITH RECURSIVE subdivision_tree AS (
                SELECT id FROM subdivisions WHERE id = %(parent_id)s
                UNION ALL
                SELECT s.id FROM subdivisions s JOIN subdivision_tree st ON s.parent_id = st.id
            ) SELECT id FROM subdivision_tree;
        """
        cursor.execute(sql, {'parent_id': parent_id})
        results = cursor.fetchall()
        ids = [row['id'] for row in results]
        logger.debug(f"Найдены дочерние подразделения для {parent_id}: {ids}")
    except psycopg2.Error as e:
        logger.error(f"Ошибка при получении дочерних подразделений для {parent_id}: {e}", exc_info=True)
        return [parent_id] # Возвращаем только исходный ID при ошибке
    except Exception as e:
         logger.error(f"Неожиданная ошибка в get_descendant_subdivision_ids для {parent_id}: {e}", exc_info=True)
         return [parent_id]
    return ids

def get_descendant_node_type_ids(cursor, parent_id: int) -> List[int]:
    """Рекурсивно получает ID всех вложенных типов узлов (включая родителя)."""
    if parent_id is None: return []
    ids = [parent_id]
    try:
        sql = """
            WITH RECURSIVE node_type_tree AS (
                SELECT id FROM node_types WHERE id = %(parent_id)s
                UNION ALL
                SELECT nt.id FROM node_types nt JOIN node_type_tree ntt ON nt.parent_type_id = ntt.id
            ) SELECT id FROM node_type_tree;
        """
        cursor.execute(sql, {'parent_id': parent_id})
        results = cursor.fetchall()
        ids = [row['id'] for row in results]
        logger.debug(f"Найдены вложенные типы узлов для {parent_id}: {ids}")
    except psycopg2.Error as e:
        logger.error(f"Ошибка при получении вложенных типов узлов для {parent_id}: {e}", exc_info=True)
        return [parent_id]
    except Exception as e:
         logger.error(f"Неожиданная ошибка в get_descendant_node_type_ids для {parent_id}: {e}", exc_info=True)
         return [parent_id]
    return ids

# --- Функция построения WHERE (перенесена из db.py) ---
def build_where_clause(params: Dict[str, Any], allowed_filters: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
    """Динамически строит часть WHERE SQL-запроса."""
    where_clauses = []
    sql_params = {}
    for param_key, filter_info in allowed_filters.items():
        if param_key in params and params[param_key] is not None:
            value = params[param_key]
            if isinstance(value, str) and not value.strip(): continue

            if isinstance(filter_info, str): col_name, op, fmt = filter_info, '=', '{}'
            elif isinstance(filter_info, dict): col_name, op, fmt = filter_info['col'], filter_info.get('op', '=').upper(), filter_info.get('fmt', '{}')
            else: logger.warning(f"Некорректный формат фильтра для '{param_key}'"); continue

            param_name = param_key # Имя плейсхолдера

            if op == '= ANY':
                if isinstance(value, list) and len(value) > 0:
                    sql_params[param_name] = tuple(value) # psycopg2 лучше работает с кортежами для ANY
                    where_clauses.append(f"{col_name} = ANY(%({param_name})s)")
                else: logger.warning(f"Ожидался непустой список для ANY для '{param_key}', получен: {value}")
            elif op == 'ILIKE':
                sql_params[param_name] = fmt.format(value)
                where_clauses.append(f"{col_name} ILIKE %({param_name})s")
            else:
                sql_params[param_name] = value
                where_clauses.append(f"{col_name} {op} %({param_name})s")

    where_sql = ""
    if where_clauses: where_sql = " WHERE " + " AND ".join(where_clauses)
    return where_sql, sql_params