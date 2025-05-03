# status/app/routes/node_type_routes.py
import logging
import psycopg2
from flask import Blueprint, request, jsonify, g
from typing import Optional
from ..repositories import node_type_repository
from ..errors import ApiBadRequest, ApiNotFound, ApiConflict, ApiInternalError, ApiValidationFailure
from flask_login import login_required

logger = logging.getLogger(__name__)
bp = Blueprint('node_types', __name__) # Префикс /api/v1/node_types будет в __init__.py

@bp.route('', methods=['GET'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_node_types():
    """Получает список типов узлов с пагинацией и фильтрацией."""
    logger.info(f"API NodeType: Запрос GET {request.full_path}")
    try:
        # ... (Парсинг и валидация параметров limit, offset, parent_type_id, search_text)
        limit = request.args.get('limit', type=int)
        offset = request.args.get('offset', default=0, type=int)
        # ... (остальные параметры)
        cursor = g.db_conn.cursor()
        items, total_count = node_type_repository.fetch_node_types(
            cursor, limit=limit, offset=offset # ... (остальные параметры)
        )
        return jsonify({"items": items, "total_count": total_count, "limit": limit, "offset": offset}), 200
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching node types")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('', methods=['POST'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_create_node_type():
    """Создает новый тип узла."""
    logger.info("API NodeType: Запрос POST /")
    data = request.get_json()
    if not data: raise ApiBadRequest("Missing JSON body")
    if not data.get('name'): raise ApiValidationFailure("Missing required field: name")
    try:
        cursor = g.db_conn.cursor()
        new_type = node_type_repository.create_node_type(cursor, data)
        if not new_type: raise ApiInternalError("Failed to create node type")
        # g.db_conn.commit()
        logger.info(f"API NodeType: Created ID: {new_type['id']}")
        return jsonify(new_type), 201
    except ValueError as val_err: raise ApiValidationFailure(str(val_err))
    except psycopg2.errors.UniqueViolation: raise ApiConflict("Node type with this name and parent already exists")
    except psycopg2.Error as db_err: raise ApiInternalError("DB error creating node type")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/<int:type_id>', methods=['GET'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_node_type(type_id):
    """Получает тип узла по ID."""
    logger.info(f"API NodeType: Запрос GET /{type_id}")
    try:
        cursor = g.db_conn.cursor()
        node_type = node_type_repository.get_node_type_by_id(cursor, type_id)
        if not node_type: raise ApiNotFound(f"Node type id={type_id} not found")
        return jsonify(node_type), 200
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching node type")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/<int:type_id>', methods=['PUT'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_update_node_type(type_id):
    """Обновляет тип узла по ID."""
    logger.info(f"API NodeType: Запрос PUT /{type_id}")
    data = request.get_json()
    if not data: raise ApiBadRequest("Missing JSON body or empty data")
    try:
        cursor = g.db_conn.cursor()
        updated_type = node_type_repository.update_node_type(cursor, type_id, data)
        if updated_type is None: raise ApiNotFound(f"Node type id={type_id} not found for update")
        # g.db_conn.commit()
        logger.info(f"API NodeType: Updated ID: {type_id}")
        return jsonify(updated_type), 200
    except ValueError as val_err: raise ApiValidationFailure(str(val_err))
    except psycopg2.errors.UniqueViolation: raise ApiConflict("Node type update conflict")
    except psycopg2.Error as db_err: raise ApiInternalError("DB error updating node type")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/<int:type_id>', methods=['DELETE'])
@login_required # Защита маршрута, только для авторизованных пользователей
def api_delete_node_type(type_id):
    """Удаляет тип узла по ID."""
    logger.info(f"API NodeType: Запрос DELETE /{type_id}")
    try:
        cursor = g.db_conn.cursor()
        deleted = node_type_repository.delete_node_type(cursor, type_id)
        if not deleted: raise ApiNotFound(f"Node type id={type_id} not found")
        # g.db_conn.commit()
        logger.info(f"API NodeType: Deleted ID: {type_id}")
        return '', 204
    except ValueError as dep_err: raise ApiConflict(str(dep_err)) # Зависимости или базовый тип
    except psycopg2.Error as db_err: raise ApiInternalError("DB error deleting node type")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")

