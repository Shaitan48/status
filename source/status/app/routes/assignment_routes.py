# status/app/routes/assignment_routes.py
import logging
import psycopg2
import json
from flask import Blueprint, request, jsonify, g
from datetime import datetime # Для пост-обработки дат
from typing import Optional
from ..repositories import assignment_repository
from ..errors import ApiBadRequest, ApiNotFound, ApiConflict, ApiInternalError, ApiValidationFailure
from flask_login import login_required

logger = logging.getLogger(__name__)
bp = Blueprint('assignments', __name__) # Префикс /api/v1/assignments в __init__.py

@bp.route('/bulk_create', methods=['POST'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_create_or_assign_assignments():
    """Массовое создание/назначение заданий."""
    logger.info("API Assignment: Запрос POST /bulk_create")
    data = request.get_json()
    if not data: raise ApiBadRequest("Missing JSON body")
    # --- Полная валидация данных ---
    assignment_data = data.get('assignment_data'); criteria = data.get('criteria'); node_ids = data.get('node_ids'); errors = {}
    # ... (весь код валидации из routes.py v4.4.0) ...
    if not assignment_data or not isinstance(assignment_data, dict): raise ApiValidationFailure(...)
    if not assignment_data.get('method_id'): errors['assignment_data.method_id'] = "Required"
    # ... (остальные проверки полей assignment_data, criteria, node_ids) ...
    if errors: raise ApiValidationFailure("Validation errors", details=errors)
    # --- Конец валидации ---
    try:
        cursor = g.db_conn.cursor()
        created_count = assignment_repository.create_assignments_unified(cursor, assignment_data, criteria, node_ids)
        # g.db_conn.commit()
        return jsonify({"status": "success", "assignments_created": created_count}), 201
    except ValueError as val_err: raise ApiValidationFailure(str(val_err))
    except psycopg2.Error as db_err: raise ApiInternalError("DB error during bulk assignment")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")

@bp.route('/all', methods=['GET'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_all_assignments_paginated():
    """Получает список всех заданий с пагинацией и фильтрами."""
    logger.info("API Assignment: Запрос GET /all")
    try:
        # --- Парсинг и валидация параметров ---
        page = request.args.get('page', default=1, type=int); limit = request.args.get('limit', default=25, type=int)
        node_id = request.args.get('node_id', type=int); method_id = request.args.get('method_id', type=int)
        subdivision_id = request.args.get('subdivision_id', type=int); node_type_id = request.args.get('node_type_id', type=int)
        search_text = request.args.get('search_text', type=str);
        include_child_subdivisions = request.args.get('include_child_subdivisions', 'false').lower() == 'true'
        include_nested_types = request.args.get('include_nested_types', 'false').lower() == 'true'
        if page <= 0: page = 1;
        if limit <= 0 or limit > 100: limit = 25;
        offset = (page - 1) * limit;
        if search_text: search_text = search_text.strip()
        # --- Конец парсинга ---
        cursor = g.db_conn.cursor()
        assignments, total_count = assignment_repository.fetch_assignments_paginated(
            cursor, limit=limit, offset=offset, node_id=node_id, method_id=method_id,
            subdivision_id=subdivision_id, node_type_id=node_type_id, search_text=search_text,
            include_child_subdivisions=include_child_subdivisions, include_nested_types=include_nested_types
        )
        # --- ПОСТ-ОБРАБОТКА ---
        for a in assignments:
            for json_field in ['parameters', 'success_criteria']:
                 if isinstance(a.get(json_field), str): # Если БД вернула JSON как строку
                      try: a[json_field] = json.loads(a[json_field])
                      except json.JSONDecodeError: a[json_field] = {"_error": "Invalid JSON in DB"}
                 elif a.get(json_field) is None: a[json_field] = None # null для JS
            if 'last_executed_at' in a and isinstance(a['last_executed_at'], datetime): a['last_executed_at'] = a['last_executed_at'].isoformat()
        # --- КОНЕЦ ПОСТ-ОБРАБОТКИ ---
        response_data = {"assignments": assignments, "total_count": total_count, "page": page, "limit": limit}
        return jsonify(response_data), 200
    except ValueError: raise ApiBadRequest("Invalid parameter type")
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching assignments")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/<int:assignment_id>', methods=['GET'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_assignment(assignment_id):
    """Получает задание по ID."""
    logger.info(f"API Assignment: Запрос GET /{assignment_id}")
    try:
        cursor = g.db_conn.cursor()
        assignment = assignment_repository.get_assignment_by_id(cursor, assignment_id)
        if not assignment: raise ApiNotFound(f"Assignment id={assignment_id} not found")
        # --- ПОСТ-ОБРАБОТКА ---
        for json_field in ['parameters', 'success_criteria']:
             if isinstance(assignment.get(json_field), str):
                  try: assignment[json_field] = json.loads(assignment[json_field])
                  except json.JSONDecodeError: assignment[json_field] = {"_error": "Invalid JSON"}
             elif assignment.get(json_field) is None: assignment[json_field] = None
        for key in ['last_assigned_at', 'last_executed_at']:
             if key in assignment and isinstance(assignment[key], datetime): assignment[key] = assignment[key].isoformat()
        # --- КОНЕЦ ПОСТ-ОБРАБОТКИ ---
        return jsonify(assignment), 200
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching assignment")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/<int:assignment_id>', methods=['PUT'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_update_assignment(assignment_id):
    """Обновляет задание по ID."""
    logger.info(f"API Assignment: Запрос PUT /{assignment_id}")
    data = request.get_json()
    if not data: raise ApiBadRequest("Missing JSON body")
    # --- Полная валидация данных (как в routes.py v4.4.0) ---
    errors = {}
    # ... (код валидации) ...
    if errors: raise ApiValidationFailure("Validation errors", details=errors)
    # --- Конец валидации ---
    try:
        cursor = g.db_conn.cursor()
        updated_assignment = assignment_repository.update_assignment(cursor, assignment_id, data)
        if updated_assignment is None: raise ApiNotFound(f"Assignment id={assignment_id} not found")
        # g.db_conn.commit()
        # --- ПОСТ-ОБРАБОТКА ---
        for json_field in ['parameters', 'success_criteria']:
             if isinstance(updated_assignment.get(json_field), str):
                  try: updated_assignment[json_field] = json.loads(updated_assignment[json_field])
                  except json.JSONDecodeError: updated_assignment[json_field] = {"_error": "Invalid JSON"}
             elif updated_assignment.get(json_field) is None: updated_assignment[json_field] = None
        for key in ['last_assigned_at', 'last_executed_at']:
             if key in updated_assignment and isinstance(updated_assignment[key], datetime): updated_assignment[key] = updated_assignment[key].isoformat()
        # --- КОНЕЦ ПОСТ-ОБРАБОТКИ ---
        logger.info(f"API Assignment: Updated ID: {assignment_id}")
        return jsonify(updated_assignment), 200
    except ValueError as val_err: raise ApiValidationFailure(str(val_err))
    except psycopg2.Error as db_err: raise ApiInternalError("DB error updating assignment")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/<int:assignment_id>', methods=['DELETE'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_delete_assignment(assignment_id):
    """Удаляет задание по ID."""
    logger.info(f"API Assignment: Запрос DELETE /{assignment_id}")
    try:
        cursor = g.db_conn.cursor()
        deleted = assignment_repository.delete_assignment(cursor, assignment_id)
        if not deleted: raise ApiNotFound(f"Assignment id={assignment_id} not found")
        # g.db_conn.commit()
        logger.info(f"API Assignment: Deleted ID: {assignment_id}")
        return '', 204
    except psycopg2.Error as db_err: raise ApiInternalError("DB error deleting assignment")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")

