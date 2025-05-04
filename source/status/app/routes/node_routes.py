# status/app/routes/node_routes.py
import logging
import psycopg2
from flask import Blueprint, request, jsonify, g
from typing import Optional
from ..repositories import node_repository, assignment_repository # Добавили assignment_repository
import json # Для обработки JSON в assignments_status
from datetime import datetime # Для обработки дат в assignments_status
from ..errors import ApiNotFound, ApiInternalError, ApiException, ApiValidationFailure, ApiConflict # Импортируем нужные исключения
from flask_login import login_required

logger = logging.getLogger(__name__)
bp = Blueprint('nodes', __name__)

@bp.route('', methods=['GET']) # Обрабатывает GET /api/v1/nodes
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_nodes():
    """Получает список узлов с пагинацией и фильтрацией."""
    logger.info(f"API Node: Запрос GET {request.full_path}")
    try:
        # Парсинг параметров запроса
        limit = request.args.get('limit', type=int)
        offset = request.args.get('offset', default=0, type=int)
        subdivision_id = request.args.get('subdivision_id', type=int)
        node_type_id = request.args.get('node_type_id', type=int)
        search_text = request.args.get('search_text')
        include_child_subdivisions = request.args.get('include_child_subdivisions', 'false').lower() == 'true'
        include_nested_types = request.args.get('include_nested_types', 'false').lower() == 'true'

        # Валидация limit/offset
        if limit is not None and limit <= 0: limit = None
        if offset < 0: offset = 0

        cursor = g.db_conn.cursor() # Получаем курсор из контекста g
        items, total_count = node_repository.fetch_nodes(
            cursor, limit=limit, offset=offset, subdivision_id=subdivision_id,
            node_type_id=node_type_id, search_text=search_text,
            include_child_subdivisions=include_child_subdivisions,
            include_nested_types=include_nested_types
        )
        logger.info(f"API Node: Успешно отданы nodes. Найдено: {len(items)}, Всего: {total_count}")
        return jsonify({"items": items, "total_count": total_count, "limit": limit, "offset": offset}), 200

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении списка узлов: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении списка узлов.")
    except ApiException as api_err:
        raise api_err
    except Exception as e:
        logger.exception("Неожиданная ошибка при получении списка узлов")
        raise ApiInternalError("Внутренняя ошибка сервера при получении списка узлов.")


@bp.route('', methods=['POST']) # Обрабатывает POST /api/v1/nodes
@login_required # Защита маршрута, только для авторизованных пользователей
def api_create_node():
    """Создает новый узел."""
    logger.info("API Node: Запрос POST /")
    data = request.get_json()
    if not data:
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")

    required_fields = ['name', 'parent_subdivision_id']
    missing_fields = [field for field in required_fields if field not in data or data[field] is None]
    if missing_fields:
        raise ApiValidationFailure(f"Отсутствуют обязательные поля: {', '.join(missing_fields)}")

    try:
        cursor = g.db_conn.cursor()
        new_node_partial = node_repository.create_node(cursor, data)
        if not new_node_partial or 'id' not in new_node_partial:
            raise ApiInternalError("Не удалось получить ID созданного узла.")
        new_node_id = new_node_partial['id']

        full_new_node = node_repository.get_node_by_id(cursor, new_node_id)
        if not full_new_node:
            logger.error(f"Не удалось получить полную информацию для созданного узла ID: {new_node_id}")
            return jsonify(new_node_partial), 201 # Возвращаем хотя бы частичные данные

        # g.db_conn.commit() # Не нужно при autocommit=True
        logger.info(f"API Node: Успешно создан узел ID: {new_node_id}")
        return jsonify(full_new_node), 201

    except ValueError as val_err: raise ApiValidationFailure(str(val_err))
    except psycopg2.errors.UniqueViolation as unique_err: raise ApiConflict("Узел с таким именем в данном подразделении уже существует.")
    except psycopg2.Error as db_err: raise ApiInternalError("Ошибка базы данных при создании узла.")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Внутренняя ошибка сервера при создании узла: {e}")


@bp.route('/<int:node_id>', methods=['GET']) # Обрабатывает GET /api/v1/nodes/ID
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_node(node_id):
    """Получает узел по ID."""
    logger.info(f"API Node: Запрос GET /{node_id}")
    try:
        cursor = g.db_conn.cursor()
        node = node_repository.get_node_by_id(cursor, node_id)
        if not node: raise ApiNotFound(f"Узел с id={node_id} не найден.")
        logger.info(f"API Node: Успешно получен узел ID: {node_id}")
        return jsonify(node), 200
    except psycopg2.Error as db_err: raise ApiInternalError("Ошибка базы данных при получении узла.")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Внутренняя ошибка сервера при получении узла: {e}")


@bp.route('/<int:node_id>', methods=['PUT']) # Обрабатывает PUT /api/v1/nodes/ID
@login_required # Защита маршрута, только для авторизованных пользователей
def api_update_node(node_id):
    """Обновляет узел по ID."""
    logger.info(f"API Node: Запрос PUT /{node_id}")
    data = request.get_json()
    if not data: raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")
    if not data: raise ApiBadRequest("Нет данных для обновления узла.") # Проверка на пустой объект

    try:
        cursor = g.db_conn.cursor()
        updated_node = node_repository.update_node(cursor, node_id, data)
        if updated_node is None: raise ApiNotFound(f"Узел с id={node_id} не найден для обновления.")
        # g.db_conn.commit() # Не нужно при autocommit=True
        logger.info(f"API Node: Успешно обновлен узел ID: {node_id}")
        return jsonify(updated_node), 200
    except ValueError as val_err: raise ApiValidationFailure(str(val_err))
    except psycopg2.errors.UniqueViolation as unique_err: raise ApiConflict("Узел с таким именем в данном подразделении уже существует.")
    except psycopg2.Error as db_err: raise ApiInternalError("Ошибка базы данных при обновлении узла.")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Внутренняя ошибка сервера при обновлении узла: {e}")


@bp.route('/<int:node_id>', methods=['DELETE']) # Обрабатывает DELETE /api/v1/nodes/ID
@login_required # Защита маршрута, только для авторизованных пользователей
def api_delete_node(node_id):
    """Удаляет узел по ID."""
    logger.info(f"API Node: Запрос DELETE /{node_id}")
    try:
        cursor = g.db_conn.cursor()
        deleted = node_repository.delete_node(cursor, node_id)
        if not deleted: raise ApiNotFound(f"Узел с id={node_id} не найден.")
        # g.db_conn.commit() # Не нужно при autocommit=True
        logger.info(f"API Node: Успешно удален узел ID: {node_id}")
        return '', 204
    except psycopg2.Error as db_err: raise ApiInternalError("Ошибка базы данных при удалении узла.")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Внутренняя ошибка сервера при удалении узла: {e}")

# --- Маршруты, специфичные для узлов (история, статус заданий) ---
# Перенесены в check_routes.py и assignment_routes.py (или data_routes.py)
# Например, /nodes/<id>/checks_history -> /checks/history/node/<id> (для примера)
# Или оставить здесь, если логично:

@bp.route('/<int:node_id>/assignments_status', methods=['GET'])
def api_node_assignments_status(node_id):
    """Получает статус всех заданий для конкретного узла."""
    logger.info(f"API Node: Запрос GET /{node_id}/assignments_status")
    try:
        cursor = g.db_conn.cursor() # Получаем курсор из контекста

        # --- >>> ДОБАВЛЕНЫ ЛОГИ ДЛЯ ОТЛАДКИ <<< ---
        logger.debug(f"Проверка существования узла ID={node_id}...")
        # Вызов функции репозитория для проверки существования узла
        node_exists_check_result = node_repository.get_node_by_id(cursor, node_id)
        # Логируем результат вызова
        logger.debug(f"Результат node_repository.get_node_by_id для ID={node_id}: {node_exists_check_result}")
        # --- >>> КОНЕЦ ДОБАВЛЕННЫХ ЛОГОВ <<< ---

        # Проверка существования узла
        if not node_exists_check_result:
            # --- >>> ДОБАВЛЕН ЛОГ ПЕРЕД ОШИБКОЙ <<< ---
            logger.warning(f"Проверка существования узла ID={node_id} вернула Falsy ({type(node_exists_check_result)}), хотя узел должен существовать! Выбрасываем ApiNotFound.")
            # --- >>> КОНЕЦ ДОБАВЛЕННОГО ЛОГА <<< ---
            raise ApiNotFound(f"Узел с id={node_id} не найден.")

        # Если узел существует, получаем статус его заданий
        assignments = assignment_repository.fetch_assignments_status_for_node(cursor, node_id)

        # --- ПОСТ-ОБРАБОТКА ДАТ И JSON ---
        for row in assignments:
            # Обработка JSON поля 'parameters'
            if isinstance(row.get('parameters'), str):
                 try:
                     row['parameters'] = json.loads(row['parameters'])
                 except json.JSONDecodeError:
                     logger.warning(f"Не удалось распарсить JSON параметров для assignment_id={row.get('assignment_id')}")
                     row['parameters'] = {"_error": "Invalid JSON in DB"}
            elif row.get('parameters') is None:
                 row['parameters'] = {} # null -> {} для единообразия

            # Обработка полей с датами/временем
            for key in ['last_executed_at', 'last_check_timestamp', 'last_check_db_timestamp']:
                if key in row and isinstance(row[key], datetime):
                     row[key] = row[key].isoformat() # Преобразуем в ISO строку

        # --- КОНЕЦ ПОСТ-ОБРАБОТКИ ---
        logger.info(f"API Node: Успешно отданы assignments_status для узла {node_id}, заданий: {len(assignments)}")
        return jsonify(assignments)

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении статуса заданий для узла {node_id}: {db_err}", exc_info=True)
        raise ApiInternalError("DB error fetching assignment status.")
    except ApiException as api_err:
        # Перехватываем и пробрасываем дальше, чтобы сработал глобальный обработчик
        # Логирование уже произошло в глобальном обработчике или при вызове raise
        raise api_err
    except Exception as e:
        logger.exception(f"Неожиданная ошибка при получении статуса заданий для узла {node_id}")
        raise ApiInternalError(f"Unexpected error: {e}")

