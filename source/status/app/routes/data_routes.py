# status/app/routes/data_routes.py
"""
Маршруты API для получения агрегированных данных.
Версия 5.0.1: Используется g.db_cursor (RealDictCursor) вместо создания нового.
"""
import logging
import psycopg2
from flask import Blueprint, jsonify, g # g используется для доступа к db_cursor
from psycopg2.extras import RealDictCursor # Импортируем на случай, если нужно создать
from ..services import node_service
from ..repositories import subdivision_repository, method_repository # Убрал node_type_repository, т.к. не используется напрямую
from ..errors import ApiInternalError, ApiException

logger = logging.getLogger(__name__)
bp = Blueprint('data', __name__)

@bp.route('/dashboard', methods=['GET'])
def api_dashboard_data():
    logger.info("API Data Route: Запрос GET /api/v1/dashboard (данные для сводки)")
    try:
        # <<< ИЗМЕНЕНО: Используем g.db_cursor >>>
        if not hasattr(g, 'db_cursor') or g.db_cursor is None or g.db_cursor.closed:
            logger.error("api_dashboard_data: g.db_cursor отсутствует или закрыт! Невозможно выполнить запрос.")
            raise ApiInternalError("Ошибка соединения с базой данных (нет курсора).")
        cursor = g.db_cursor # Используем курсор из глобального контекста запроса

        nodes_with_status = node_service.get_processed_node_status(cursor)
        logger.debug(f"Данные узлов со статусами получены, количество: {len(nodes_with_status)}")

        # Получаем все подразделения (fetch_subdivisions ожидает курсор)
        all_subdivisions_flat, _ = subdivision_repository.fetch_subdivisions(cursor, limit=None)
        logger.debug(f"Данные подразделений получены, количество: {len(all_subdivisions_flat)}")

        if not all_subdivisions_flat:
            logger.warning("API Data Route: В системе нет подразделений. Дашборд будет пустым.")
            return jsonify([])

        subdivision_map = {
            sub['id']: {**sub, 'nodes': []} for sub in all_subdivisions_flat
        }
        nodes_without_valid_subdivision_count = 0
        for node_data in nodes_with_status:
            subdivision_id = node_data.get('subdivision_id')
            node_id = node_data.get('id')
            if subdivision_id is not None and subdivision_id in subdivision_map:
                node_display_data = {
                    'id': node_id, 'name': node_data.get('name'),
                    'ip_address': node_data.get('ip_address'),
                    'status_class': node_data.get('status_class', 'unknown'),
                    'status_text': node_data.get('status_text', 'Нет данных'),
                    'node_type_path': node_data.get('node_type_path'),
                    'icon_filename': node_data.get('icon_filename', 'other.svg'),
                    'check_timestamp': node_data.get('check_timestamp'),
                    'last_checked': node_data.get('last_checked'),
                    'last_available': node_data.get('last_available'),
                    'display_order': node_data.get('display_order')
                }
                subdivision_map[subdivision_id]['nodes'].append(node_display_data)
            else:
                nodes_without_valid_subdivision_count += 1
                logger.warning(f"Узел '{node_data.get('name')}' (ID: {node_id}) имеет некорректный subdivision_id ({subdivision_id}).")
        if nodes_without_valid_subdivision_count > 0:
            logger.warning(f"Обнаружено {nodes_without_valid_subdivision_count} узлов с некорректным/отсутствующим subdivision_id.")

        for sub_id_key in subdivision_map:
            subdivision_map[sub_id_key]['nodes'].sort(
                key=lambda n: (n.get('display_order', float('inf')), (n.get('name') or '').lower())
            )
        result_list = sorted(
            list(subdivision_map.values()),
            key=lambda s: (s.get('priority', float('inf')), (s.get('short_name') or '').lower())
        )
        # cursor.close() # Не закрываем g.db_cursor здесь, это делает teardown_appcontext
        logger.info(f"API Data Route: Данные для дашборда успешно сформированы. Подразделений: {len(result_list)}.")
        return jsonify(result_list), 200
    # ... (обработка ошибок без изменений) ...
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при формировании данных для дашборда: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при подготовке данных для сводки.")
    except ApiException: raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при формировании данных для дашборда.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/status_detailed', methods=['GET'])
def api_detailed_status():
    logger.info("API Data Route: Запрос GET /api/v1/status_detailed (детальный статус)")
    try:
        # <<< ИЗМЕНЕНО: Используем g.db_cursor >>>
        if not hasattr(g, 'db_cursor') or g.db_cursor is None or g.db_cursor.closed:
            logger.error("api_detailed_status: g.db_cursor отсутствует или закрыт!")
            raise ApiInternalError("Ошибка соединения с БД (нет курсора).")
        cursor = g.db_cursor

        nodes_with_status = node_service.get_processed_node_status(cursor)
        subdivisions_flat, _ = subdivision_repository.fetch_subdivisions(cursor, limit=None)
        # cursor.close() # Не закрываем g.db_cursor

        response_data = {"nodes": nodes_with_status, "subdivisions": subdivisions_flat}
        logger.info("API Data Route: Данные для детального статуса успешно сформированы.")
        return jsonify(response_data), 200
    # ... (обработка ошибок без изменений) ...
    except psycopg2.Error as db_err_det:
        logger.error(f"Ошибка БД (детальный статус): {db_err_det}", exc_info=True)
        raise ApiInternalError("Ошибка БД при подготовке детального статуса.")
    except ApiException: raise
    except Exception as e_det:
        logger.exception("Неожиданная ошибка (детальный статус).")
        raise ApiInternalError(f"Внутренняя ошибка: {type(e_det).__name__}")


@bp.route('/check_methods', methods=['GET'])
def api_get_check_methods():
    logger.info("API Data Route: Запрос GET /api/v1/check_methods (справочник методов проверки)")
    try:
        # <<< ИЗМЕНЕНО: Используем g.db_cursor >>>
        if not hasattr(g, 'db_cursor') or g.db_cursor is None or g.db_cursor.closed:
            logger.error("api_get_check_methods: g.db_cursor отсутствует или закрыт!")
            raise ApiInternalError("Ошибка соединения с БД (нет курсора).")
        cursor = g.db_cursor

        check_methods_list = method_repository.fetch_check_methods(cursor) # Репозиторий ожидает курсор
        # cursor.close() # Не закрываем g.db_cursor
        logger.info(f"API Data Route: Успешно получено {len(check_methods_list)} методов проверки.")
        return jsonify(check_methods_list)
    # ... (обработка ошибок без изменений) ...
    except psycopg2.Error as db_err_meth:
        logger.error(f"Ошибка БД (методы проверки): {db_err_meth}", exc_info=True)
        raise ApiInternalError("Ошибка БД при получении методов проверки.")
    except Exception as e_meth:
        logger.exception("Неожиданная ошибка (методы проверки).")
        raise ApiInternalError(f"Внутренняя ошибка: {type(e_meth).__name__}")