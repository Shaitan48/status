# status/app/repositories/event_repository.py
"""
event_repository.py — CRUD-операции и бизнес-логика для системных событий (system_events).
Версия 5.0.1: Функции теперь принимают курсор, удалены commit.
"""
import logging
import json
import psycopg2
from typing import List, Dict, Any, Optional, Tuple

# <<< ИЗМЕНЕНО: Импортируем get_connection >>>
from ..db_connection import get_connection

logger = logging.getLogger(__name__)

# ================================
# Получить список событий
# ================================
def fetch_system_events( # Переименовал для единообразия
    cursor: psycopg2.extensions.cursor, # Ожидаем курсор
    limit: Optional[int] = 200, # Значение по умолчанию для лимита
    offset: int = 0,
    severity: Optional[str] = None,
    event_type: Optional[str] = None,
    search_text: Optional[str] = None,
    object_id: Optional[int] = None,
    node_id: Optional[int] = None,
    assignment_id: Optional[int] = None,
    node_check_id: Optional[int] = None,
    related_entity: Optional[str] = None,
    related_entity_id: Optional[str] = None,
    start_time: Optional[str] = None, # ISO строка даты
    end_time: Optional[str] = None   # ISO строка даты
) -> Tuple[List[Dict[str, Any]], int]:
    """
    Получить страницу системных событий с гибкой фильтрацией и пагинацией.
    """
    logger.debug(f"Репозиторий: Запрос списка системных событий с фильтрами...")
    select_fields = """
        SELECT id, event_time, event_type, severity, message, source,
               object_id, node_id, assignment_id, node_check_id,
               related_entity, related_entity_id, details
        FROM system_events
    """
    count_select = "SELECT COUNT(*) FROM system_events"
    
    where_clauses: List[str] = []
    query_params: Dict[str, Any] = {}

    if severity: where_clauses.append("severity = %(sev)s"); query_params['sev'] = severity.upper()
    if event_type: where_clauses.append("event_type ILIKE %(ev_type)s"); query_params['ev_type'] = f"%{event_type}%" # Частичное совпадение
    if search_text: where_clauses.append("message ILIKE %(s_text)s"); query_params['s_text'] = f"%{search_text}%"
    if object_id is not None: where_clauses.append("object_id = %(o_id)s"); query_params['o_id'] = object_id
    if node_id is not None: where_clauses.append("node_id = %(n_id)s"); query_params['n_id'] = node_id
    if assignment_id is not None: where_clauses.append("assignment_id = %(a_id)s"); query_params['a_id'] = assignment_id
    if node_check_id is not None: where_clauses.append("node_check_id = %(nc_id)s"); query_params['nc_id'] = node_check_id
    if related_entity: where_clauses.append("related_entity = %(rel_ent)s"); query_params['rel_ent'] = related_entity
    if related_entity_id: where_clauses.append("related_entity_id = %(rel_id)s"); query_params['rel_id'] = related_entity_id
    if start_time: where_clauses.append("event_time >= %(start_t)s::timestamptz"); query_params['start_t'] = start_time
    if end_time: where_clauses.append("event_time <= %(end_t)s::timestamptz"); query_params['end_t'] = end_time
    
    where_sql = (" WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
    try:
        cursor.execute(count_select + where_sql, query_params)
        total_count = cursor.fetchone()['count']
        events_list: List[Dict[str, Any]] = []
        if total_count > 0 and (limit is None or offset < total_count):
            order_sql = " ORDER BY event_time DESC, id DESC"
            limit_offset_sql = ""
            if limit is not None: limit_offset_sql = " LIMIT %(lim)s OFFSET %(off)s"; query_params['lim']=limit; query_params['off']=offset
            cursor.execute(select_fields + where_sql + order_sql + limit_offset_sql, query_params)
            events_list = cursor.fetchall()
            # Десериализация details (JSONB -> Python dict) выполняется psycopg2 RealDictCursor
        logger.info(f"Репозиторий fetch_system_events: Найдено {len(events_list)} событий на странице, всего {total_count}.")
        return events_list, total_count
    except psycopg2.Error as e: logger.error(f"Репозиторий: Ошибка БД при выборке событий: {e}", exc_info=True); raise

def get_event_by_id(cursor: psycopg2.extensions.cursor, event_id: int) -> Optional[Dict[str, Any]]:
    # ... (логика такая же, курсор уже передан) ...
    sql = """ SELECT id, event_time, event_type, severity, message, source, object_id, node_id, 
                   assignment_id, node_check_id, related_entity, related_entity_id, details
            FROM system_events WHERE id=%s """
    logger.debug(f"Репозиторий: Запрос события по ID={event_id}")
    try:
        cursor.execute(sql, (event_id,)); event_data = cursor.fetchone()
        if not event_data: logger.warning(f"Событие ID={event_id} не найдено.")
        # Десериализация details здесь, если RealDictCursor не справился (маловероятно для JSONB)
        # if event_data and isinstance(event_data.get('details'), str):
        #     try: event_data['details'] = json.loads(event_data['details'])
        #     except json.JSONDecodeError: event_data['details'] = {"_error_parsing_json_": event_data['details']}
        return event_data
    except psycopg2.Error as e: logger.error(f"Ошибка БД при получении события ID {event_id}: {e}", exc_info=True); raise

def create_system_event( # Переименовал для единообразия
    cursor: psycopg2.extensions.cursor, # Ожидаем курсор
    data: Dict[str, Any]
) -> Optional[int]:
    # ... (логика такая же, курсор уже передан, убираем commit) ...
    # Валидация обязательных полей (event_type, message) лучше на уровне роута/сервиса
    sql = """ INSERT INTO system_events (event_type, severity, message, source, object_id, node_id, 
                                       assignment_id, node_check_id, related_entity, related_entity_id, details)
              VALUES (%(et)s, %(sev)s, %(msg)s, %(src)s, %(oid)s, %(nid)s, %(aid)s, %(ncid)s, %(rent)s, %(reid)s, %(det)s::jsonb)
              RETURNING id; """
    params = {
        'et': data['event_type'], 'sev': data.get('severity', 'INFO').upper(), 'msg': data['message'],
        'src': data.get('source'), 'oid': data.get('object_id'), 'nid': data.get('node_id'),
        'aid': data.get('assignment_id'), 'ncid': data.get('node_check_id'),
        'rent': data.get('related_entity'), 'reid': data.get('related_entity_id'),
        'det': json.dumps(data.get('details')) if data.get('details') is not None else None
    }
    logger.debug(f"Репозиторий: Попытка создания события типа '{params['et']}'.")
    try:
        cursor.execute(sql, params); result = cursor.fetchone()
        new_id = result['id'] if result else None
        if new_id: logger.info(f"Создано событие ID={new_id}, Тип='{params['et']}'.")
        else: logger.error("create_system_event: Не получен ID после вставки.")
        return new_id
    except psycopg2.Error as e: logger.error(f"Ошибка БД при создании события типа '{params['et']}': {e}", exc_info=True); raise

def delete_event(cursor: psycopg2.extensions.cursor, event_id: int) -> bool:
    # ... (логика такая же, курсор уже передан, убираем commit) ...
    sql = "DELETE FROM system_events WHERE id = %s RETURNING id;"
    logger.debug(f"Репозиторий: Попытка удаления события ID={event_id}")
    try:
        cursor.execute(sql, (event_id,)); deleted_row = cursor.fetchone()
        if deleted_row: logger.info(f"Успешно удалено событие ID={event_id}."); return True
        else: logger.warning(f"Событие ID={event_id} не найдено для удаления."); return False
    except psycopg2.Error as e: logger.error(f"Ошибка БД при удалении события ID {event_id}: {e}", exc_info=True); raise

# ================================
# Конец файла
# ================================