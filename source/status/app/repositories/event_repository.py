# status/app/repositories/event_repository.py
# ... (Полный код из предыдущего ответа для event_repository.py) ...
import logging
import psycopg2
import json
from datetime import datetime
from typing import List, Dict, Any, Optional, Tuple
from .. import db_helpers # Для build_where_clause

logger = logging.getLogger(__name__)

def create_system_event(cursor, data: Dict[str, Any]) -> Optional[int]:
    event_type = data.get('event_type'); message = data.get('message')
    if not event_type or not message: raise ValueError("Отсутствуют обязательные поля: event_type, message")
    severity = data.get('severity', 'INFO').upper();
    if severity not in ('INFO', 'WARN', 'ERROR', 'CRITICAL'): severity = 'INFO'; logger.warning(...)
    details_json = json.dumps(data.get('details'), ensure_ascii=False) if data.get('details') is not None else None
    sql = ''' INSERT INTO system_events( event_type, severity, message, source, object_id, node_id, assignment_id, node_check_id, related_entity, related_entity_id, details ) VALUES ( %(type)s, %(sev)s, %(msg)s, %(src)s, %(obj_id)s, %(node_id)s, %(assign_id)s, %(check_id)s, %(rel_entity)s, %(rel_id)s, %(details)s::jsonb ) RETURNING id; '''
    params = { 'type': event_type, 'sev': severity, 'msg': message, 'src': data.get('source'), 'obj_id': data.get('object_id'), 'node_id': data.get('node_id'), 'assign_id': data.get('assignment_id'), 'check_id': data.get('node_check_id'), 'rel_entity': data.get('related_entity'), 'rel_id': data.get('related_entity_id'), 'details': details_json }
    cursor.execute(sql, params); new_event_id = cursor.fetchone()['id']; logger.info(f"Системное событие записано. ID: {new_event_id}, Тип: {event_type}"); return new_event_id

def fetch_system_events(cursor, limit: int = 100, offset: int = 0, severity: Optional[str] = None, event_type: Optional[str] = None, search_text: Optional[str] = None, object_id: Optional[int] = None, node_id: Optional[int] = None, assignment_id: Optional[int] = None, node_check_id: Optional[int] = None, related_entity: Optional[str] = None, related_entity_id: Optional[str] = None, start_time: Optional[str] = None, end_time: Optional[str] = None) -> Tuple[List[Dict[str, Any]], int]:
    select_clause = """ SELECT se.*, n.name AS node_name, s.short_name AS subdivision_name FROM system_events se LEFT JOIN nodes n ON se.node_id = n.id LEFT JOIN subdivisions s ON se.object_id = s.object_id """
    count_select_clause = "SELECT COUNT(*) FROM system_events se"
    filter_params = {'severity': severity, 'event_type': event_type, 'object_id': object_id, 'node_id': node_id, 'assignment_id': assignment_id, 'node_check_id': node_check_id, 'related_entity': related_entity, 'related_entity_id': related_entity_id, 'search_text': search_text, 'start_time': start_time, 'end_time': end_time}
    allowed_filters = {'severity': 'se.severity', 'event_type': {'col': 'se.event_type', 'op': 'ILIKE', 'fmt': '%{}%'}, 'object_id': 'se.object_id', 'node_id': 'se.node_id', 'assignment_id': 'se.assignment_id', 'node_check_id': 'se.node_check_id', 'related_entity': 'se.related_entity', 'related_entity_id': 'se.related_entity_id', 'search_text': {'col': 'se.message', 'op': 'ILIKE', 'fmt': '%{}%'}, 'start_time': {'col': 'se.event_time', 'op': '>='}, 'end_time': {'col': 'se.event_time', 'op': '<='}}
    if start_time: # Валидация дат
        try: datetime.fromisoformat(start_time.replace('Z', '+00:00'))
        except ValueError: filter_params['start_time'] = None
    if end_time:
         try: datetime.fromisoformat(end_time.replace('Z', '+00:00'))
         except ValueError: filter_params['end_time'] = None
    where_sql, sql_params = db_helpers.build_where_clause(filter_params, allowed_filters)
    total_count = 0; cursor.execute(count_select_clause + where_sql, sql_params); total_count = cursor.fetchone().get('count', 0)
    items = []
    if total_count > 0 and offset < total_count:
        order_by_sql = " ORDER BY se.event_time DESC"; limit_offset_sql = " LIMIT %(limit)s OFFSET %(offset)s"; sql_params['limit'] = limit; sql_params['offset'] = offset
        query = select_clause + where_sql + order_by_sql + limit_offset_sql
        cursor.execute(query, sql_params); items = cursor.fetchall()
    return items, total_count
