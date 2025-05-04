# status/app/routes/node_property_routes.py
import logging
import psycopg2
import json
from flask import Blueprint, request, jsonify, g
from ..repositories import node_property_repository, node_type_repository
from ..errors import (
    ApiBadRequest,
    ApiNotFound, 
    ApiConflict,#(на всякий случай)
    ApiInternalError,
    ApiValidationFailure,
    ApiException 
)
from flask_login import login_required

logger = logging.getLogger(__name__)
bp = Blueprint('node_properties', __name__) # Префикс /api/v1 будет в __init__.py

@bp.route('/node_property_types', methods=['GET']) # Путь /api/v1/node_property_types
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_node_property_types():
    """Получает список всех типов свойств."""
    logger.info("API NodeProperty: Запрос GET /node_property_types")
    try:
        cursor = g.db_conn.cursor()
        types = node_property_repository.fetch_node_property_types(cursor)
        return jsonify(types), 200
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching property types")
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/node_types/<int:type_id>/properties', methods=['GET']) # /api/v1/node_types/ID/properties
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_node_properties(type_id):
    """Получает свойства для типа узла."""
    logger.info(f"API NodeProperty: GET /node_types/{type_id}/properties")
    try:
        cursor = g.db_conn.cursor()
        if not node_type_repository.get_node_type_by_id(cursor, type_id): raise ApiNotFound(f"Node type id={type_id} not found")
        properties = node_property_repository.get_node_properties_for_type(cursor, type_id)
        return jsonify(properties), 200
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching node properties")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/node_types/<int:type_id>/properties', methods=['PUT']) # /api/v1/node_types/ID/properties
@login_required # Защита маршрута, только для авторизованных пользователей
def api_set_node_properties(type_id):
    """Устанавливает/обновляет/удаляет свойства для типа узла."""
    logger.info(f"API NodeProperty: PUT /node_types/{type_id}/properties")
    data = request.get_json()
    if not data or not isinstance(data, dict): raise ApiBadRequest("Request body must be a JSON object { prop_type_id: value }")
    errors = {}
    try:
        cursor = g.db_conn.cursor()
        if not node_type_repository.get_node_type_by_id(cursor, type_id): raise ApiNotFound(f"Node type id={type_id} not found")

        for prop_type_id_str, value in data.items():
            try:
                prop_type_id = int(prop_type_id_str)
                if value is None: # Удаление
                    node_property_repository.delete_node_property(cursor, type_id, prop_type_id)
                else: # Установка/Обновление
                    node_property_repository.set_node_property(cursor, type_id, prop_type_id, str(value))
            except ValueError as val_err: errors[prop_type_id_str] = str(val_err)
            except psycopg2.Error as db_err: errors[prop_type_id_str] = "DB Error"; logger.error(...)
            except Exception as e: errors[prop_type_id_str] = "Server Error"; logger.error(...)

        # g.db_conn.commit()
        if errors: raise ApiBadRequest("Errors occurred while updating properties.", details=errors)
        updated_properties = node_property_repository.get_node_properties_for_type(cursor, type_id)
        logger.info(f"API NodeProperty: Properties updated for type {type_id}")
        return jsonify(updated_properties), 200
    except psycopg2.Error as db_err: raise ApiInternalError("DB error processing properties update")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/node_types/<int:type_id>/properties/<int:property_type_id>', methods=['DELETE']) # /api/v1/node_types/ID/properties/PROP_ID
@login_required # Защита маршрута, только для авторизованных пользователей
def api_delete_node_property(type_id, property_type_id):
    """Удаляет конкретное свойство у типа узла."""
    logger.info(f"API NodeProperty: DELETE /node_types/{type_id}/properties/{property_type_id}")
    try:
        cursor = g.db_conn.cursor()
        if not node_type_repository.get_node_type_by_id(cursor, type_id): raise ApiNotFound(f"Node type id={type_id} not found")
        deleted = node_property_repository.delete_node_property(cursor, type_id, property_type_id)
        if not deleted: raise ApiNotFound(f"Property type id={property_type_id} not found for node type id={type_id}")
        # g.db_conn.commit()
        logger.info(f"API NodeProperty: Deleted property {property_type_id} for type {type_id}")
        return '', 204
    except psycopg2.Error as db_err: raise ApiInternalError("DB error deleting node property")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")

