# status/app/routes/event_routes.py
import logging
import psycopg2
import json
from datetime import datetime
from flask import Blueprint, request, jsonify, g
from ..repositories import event_repository
from ..errors import ApiBadRequest, ApiInternalError, ApiValidationFailure
from ..auth_utils import api_key_required # Защита маршрута (только для авторизованных пользователей)

logger = logging.getLogger(__name__)
bp = Blueprint('events', __name__) # Префикс /api/v1/events в __init__.py

@bp.route('', methods=['GET'])
#@api_key_required(required_role='loader') # <<< Защита (роль 'loader')
def api_get_system_events():
    """Получает список системных событий с фильтрами."""
    logger.info("API Event: Запрос GET /")
    try:
        # --- Парсинг и валидация параметров ---
        limit = request.args.get('limit', default=100, type=int)
        offset = request.args.get('offset', default=0, type=int)
        severity = request.args.get('severity')
        event_type = request.args.get('event_type')
        object_id = request.args.get('object_id', type=int)
        node_id = request.args.get('node_id', type=int)
        assignment_id = request.args.get('assignment_id', type=int)
        node_check_id = request.args.get('node_check_id', type=int)
        related_entity = request.args.get('related_entity')
        related_entity_id = request.args.get('related_entity_id')
        start_time = request.args.get('start_time')
        end_time = request.args.get('end_time')
        search_text = request.args.get('search_text') # Поиск только по message

        if limit <= 0 or limit > 500: limit = 100
        if offset < 0: offset = 0
        if severity and severity.upper() not in ('INFO', 'WARN', 'ERROR', 'CRITICAL'):
             raise ApiValidationFailure("Недопустимое значение 'severity'")
        # ... (доп. валидация дат, если нужно) ...
        # --- Конец парсинга ---

        cursor = g.db_conn.cursor()
        items, total_count = event_repository.fetch_system_events(
            cursor, limit=limit, offset=offset, severity=severity, event_type=event_type,
            search_text=search_text, object_id=object_id, node_id=node_id,
            assignment_id=assignment_id, node_check_id=node_check_id,
            related_entity=related_entity, related_entity_id=related_entity_id,
            start_time=start_time, end_time=end_time
        )
        # --- ПОСТ-ОБРАБОТКА ---
        for item in items:
             if isinstance(item.get('event_time'), datetime): item['event_time'] = item['event_time'].isoformat()
             if isinstance(item.get('details'), str):
                  try: item['details'] = json.loads(item['details'])
                  except json.JSONDecodeError: pass
        # --- КОНЕЦ ПОСТ-ОБРАБОТКИ ---
        return jsonify({"items": items, "total_count": total_count, "limit": limit, "offset": offset}), 200
    except ValueError: raise ApiBadRequest("Invalid parameter type")
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching system events")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")

@bp.route('', methods=['POST'])
@api_key_required(required_role='loader') # <<< POST эндпоинт защищен API ключом
def api_add_system_event():
    """Добавляет новое системное событие."""
    logger.info("API Event: Запрос POST /")
    data = request.get_json()
    if not data: raise ApiBadRequest("Missing JSON body")
    # --- Валидация ---
    if not data.get('event_type') or not data.get('message'):
        raise ApiValidationFailure("Missing required fields: event_type, message")
    severity = data.get('severity', 'INFO').upper()
    if severity not in ('INFO', 'WARN', 'ERROR', 'CRITICAL'):
         raise ApiValidationFailure(f"Invalid severity: {severity}")
    # ... (можно добавить валидацию других полей, если нужно) ...
    # --- Конец валидации ---
    try:
        cursor = g.db_conn.cursor()
        new_event_id = event_repository.create_system_event(cursor, data)
        if new_event_id is None: raise ApiInternalError("Failed to create system event")
        # g.db_conn.commit()
        logger.info(f"API Event: Created event ID: {new_event_id}")
        return jsonify({"status": "success", "event_id": new_event_id}), 201
    except ValueError as val_err: raise ApiValidationFailure(str(val_err)) # Ошибка из репозитория
    except psycopg2.Error as db_err: raise ApiInternalError("DB error creating system event")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")

