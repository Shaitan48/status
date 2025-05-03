# status/app/repositories/node_property_repository.py
# ... (Полный код из предыдущего ответа для node_property_repository.py) ...
import logging
import psycopg2
from typing import List, Dict, Any, Optional

logger = logging.getLogger(__name__)

def fetch_node_property_types(cursor) -> List[Dict[str, Any]]:
    cursor.execute("SELECT id, name, description FROM node_property_types ORDER BY name")
    types = cursor.fetchall(); logger.info(f"Получено типов свойств узлов: {len(types)} строк."); return types

def get_node_properties_for_type(cursor, type_id: int) -> List[Dict[str, Any]]:
    sql = ''' SELECT pt.id as property_type_id, pt.name as property_name, pt.description, p.property_value FROM node_properties p JOIN node_property_types pt ON p.property_type_id = pt.id WHERE p.node_type_id = %(type_id)s ORDER BY pt.name; '''
    cursor.execute(sql, {'type_id': type_id}); properties = cursor.fetchall()
    logger.debug(f"Получены свойства для типа узла ID {type_id}: {len(properties)} шт."); return properties

def set_node_property(cursor, type_id: int, property_type_id: int, value: str) -> Optional[Dict[str, Any]]:
    cursor.execute("SELECT EXISTS (SELECT 1 FROM node_types WHERE id = %(t_id)s)", {'t_id': type_id})
    if not cursor.fetchone()['exists']: raise ValueError(f"Тип узла с id={type_id} не найден")
    cursor.execute("SELECT EXISTS (SELECT 1 FROM node_property_types WHERE id = %(pt_id)s)", {'pt_id': property_type_id})
    if not cursor.fetchone()['exists']: raise ValueError(f"Тип свойства с id={property_type_id} не найден")
    sql = ''' INSERT INTO node_properties (node_type_id, property_type_id, property_value) VALUES (%(type_id)s, %(prop_type_id)s, %(value)s) ON CONFLICT (node_type_id, property_type_id) DO UPDATE SET property_value = EXCLUDED.property_value RETURNING node_type_id, property_type_id, property_value; '''
    params = {'type_id': type_id, 'prop_type_id': property_type_id, 'value': str(value)}; cursor.execute(sql, params); result = cursor.fetchone()
    logger.info(f"Установлено свойство {property_type_id}='{value}' для типа узла {type_id}"); return result

def delete_node_property(cursor, type_id: int, property_type_id: int) -> bool:
    sql = "DELETE FROM node_properties WHERE node_type_id = %(type_id)s AND property_type_id = %(prop_type_id)s RETURNING id;"
    cursor.execute(sql, {'type_id': type_id, 'prop_type_id': property_type_id}); deleted = cursor.fetchone()
    if deleted: logger.info(f"Удалено свойство {property_type_id} для типа узла {type_id}"); return True
    else: logger.warning(f"Свойство {property_type_id} для типа {type_id} не найдено для удаления."); return False

