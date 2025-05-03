# status/app/routes/agent_routes.py
import logging
import psycopg2
import json
from flask import Blueprint, request, jsonify, g
from ..repositories import assignment_repository # Используем репозиторий
from ..db_connection import get_connection # Для функций БД
# <<< ДОБАВЛЕН ИМПОРТ ИСКЛЮЧЕНИЙ >>>
from ..errors import ApiBadRequest, ApiNotFound, ApiInternalError, ApiException
from ..auth_utils import api_key_required # Импорт декоратора

logger = logging.getLogger(__name__)
bp = Blueprint('agents', __name__) # Префикс /api/v1 в __init__.py

# GET /api/v1/assignments?object_id=... (для онлайн-агента)
@bp.route('/assignments', methods=['GET'])
@api_key_required(required_role='agent') # Защита (только роль 'agent')
def get_assignments_for_agent():
    object_id_str = request.args.get('object_id')
    logger.info(f"API Agent: Запрос /assignments для object_id={object_id_str}")
    if not object_id_str: raise ApiBadRequest("Отсутствует параметр object_id")
    try: object_id = int(object_id_str); assert object_id > 0
    except (ValueError, AssertionError): raise ApiBadRequest("Неверный формат object_id.")

    conn = None
    try:
        conn = get_connection()
        with conn.cursor() as cursor:
             # Вызываем функцию БД для получения активных заданий
             cursor.execute("SELECT * FROM get_active_assignments_for_object(%(obj_id)s)", {'obj_id': object_id})
             assignments = cursor.fetchall()
             # Можно добавить постобработку JSON полей, если они есть и приходят как строки
             # for assign in assignments:
             #     if isinstance(assign.get('parameters'), str): assign['parameters'] = json.loads(assign['parameters'])
             #     if isinstance(assign.get('success_criteria'), str): assign['success_criteria'] = json.loads(assign['success_criteria'])
        logger.info(f"API Agent: Отдано заданий для object_id={object_id}: {len(assignments)}")
        return jsonify(assignments)
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении заданий для object_id={object_id}: {db_err}", exc_info=True)
        raise ApiInternalError("DB error fetching assignments.") # Перехватится глобальным обработчиком
    except Exception as e:
        logger.exception(f"Неожиданная ошибка при получении заданий для object_id={object_id}")
        raise ApiInternalError(f"Unexpected error: {e}") # Перехватится глобальным обработчиком

# GET /api/v1/objects/<int:object_id>/offline_config (для конфигуратора)
@bp.route('/objects/<int:object_id>/offline_config', methods=['GET'])
@api_key_required(required_role='configurator') # Защита (роль 'configurator')
def get_offline_config(object_id):
    logger.info(f"API Agent: Запрос /objects/{object_id}/offline_config")
    conn = None
    try:
        conn = get_connection()
        with conn.cursor() as cursor:
             # Вызываем функцию БД для генерации конфига
             cursor.execute("SELECT generate_offline_config(%(obj_id)s) as config_json;", {'obj_id': object_id})
             result = cursor.fetchone()

        if not result or result.get('config_json') is None: # Проверяем и config_json на None
            # Это может случиться, если функция БД ничего не вернула
            logger.error(f"Функция generate_offline_config не вернула результат для object_id={object_id}")
            raise ApiInternalError("Failed to generate offline config (DB function returned no result).")

        config_data = result['config_json']

        # Проверяем, вернула ли функция БД ошибку в известном формате
        # (Функция generate_offline_config возвращает {'error': '...', 'object_id': ...} при ошибке)
        if isinstance(config_data, dict) and config_data.get('error'):
            logger.warning(f"Ошибка генерации оффлайн конфига для object_id={object_id}: {config_data.get('message', config_data.get('error'))}")
            # Используем ApiNotFound, т.к. самая частая причина - ненайденное подразделение
            raise ApiNotFound(f"Subdivision object_id={object_id} not found or config generation error: {config_data.get('error')}")

        # Если все хорошо, возвращаем JSON как есть
        logger.info(f"API Agent: Сгенерирован offline_config для object_id={object_id}")
        return jsonify(config_data) # Возвращаем JSON как есть (он уже должен быть словарем/списком)

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при генерации оффлайн конфига для object_id={object_id}: {db_err}", exc_info=True)
        raise ApiInternalError("DB error generating offline config.")
    # <<< ТЕПЕРЬ ЭТОТ БЛОК БУДЕТ РАБОТАТЬ >>>
    except ApiException as api_err: # Ловим ApiNotFound или другие наши кастомные ошибки
        raise api_err # Пробрасываем дальше для стандартной обработки
    except Exception as e:
        logger.exception(f"Неожиданная ошибка при генерации оффлайн конфига для object_id={object_id}")
        raise ApiInternalError(f"Unexpected error: {e}")