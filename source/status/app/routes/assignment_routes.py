# status/app/routes/assignment_routes.py
"""
Маршруты API для управления Заданиями (Assignments) в pipeline-архитектуре.
Версия 5.0.1: Использует репозиторий, принимающий курсор, управляет транзакциями.
"""
import logging
import psycopg2 # Для обработки psycopg2.Error
import json     # Для работы с JSON
from flask import Blueprint, request, jsonify, g
from typing import Dict, Any, List, Optional

# Импортируем репозитории
from ..repositories import assignment_repository, node_repository, method_repository
# Импортируем кастомные исключения API
from ..errors import (
    ApiBadRequest, ApiNotFound, ApiConflict,
    ApiInternalError, ApiValidationFailure, ApiException
)
# Декоратор для защиты маршрутов, требующих входа пользователя
from flask_login import login_required

logger = logging.getLogger(__name__)
# Создаем Blueprint. Префикс '/api/v1/assignments' будет добавлен при регистрации.
bp = Blueprint('assignments', __name__) # <<< ЭТО ТО, ЧТО ОТСУТСТВОВАЛО

# --- Маршрут для получения списка всех заданий (с пагинацией и фильтрами) ---
@bp.route('/all', methods=['GET'])
@login_required # Защита: только для аутентифицированных пользователей
def api_get_all_assignments_paginated():
    """
    Получает страницу со списком всех заданий с возможностью фильтрации и пагинации.
    Используется в UI для отображения и управления всеми заданиями в системе.

    Query Params:
        limit (int, optional): Количество записей на странице.
        offset (int, optional): Смещение для пагинации.
        node_id (int, optional): Фильтр по ID узла.
        method_id (int, optional): Фильтр по ID основного метода/типа задания.
        subdivision_id (int, optional): Фильтр по ID подразделения (узла).
        node_type_id (int, optional): Фильтр по ID типа узла.
        search_text (str, optional): Поиск по описанию задания или имени узла.
        is_enabled (bool, optional): Фильтр по статусу активности задания.
        include_child_subdivisions (bool, optional): Включить узлы из дочерних подразделений.
        include_nested_types (bool, optional): Включить узлы с дочерними типами.

    Returns:
        JSON: Объект с полями "assignments" (список заданий) и "total_count".
              Каждое задание содержит поле 'pipeline'.
    """
    full_path = request.full_path or "/api/v1/assignments/all (путь не определен)"
    logger.info(f"API Assignment Route: Запрос GET {full_path} (список всех заданий)")
    try:
        # --- Парсинг и валидация параметров запроса ---
        limit_str = request.args.get('limit')
        offset_str = request.args.get('offset', default='0')
        node_id_filter_str = request.args.get('node_id')
        method_id_filter_str = request.args.get('method_id')
        subdivision_id_filter_str = request.args.get('subdivision_id')
        node_type_id_filter_str = request.args.get('node_type_id')
        search_text_filter = request.args.get('search_text')
        is_enabled_filter_str = request.args.get('is_enabled')
        include_child_sub_str = request.args.get('include_child_subdivisions', 'false')
        include_nested_typ_str = request.args.get('include_nested_types', 'false')

        limit: Optional[int] = None
        if limit_str is not None:
            try: limit = int(limit_str); assert limit > 0 and limit <= 500
            except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'limit' должен быть положительным числом (1-500).")
        
        try: offset = int(offset_str); assert offset >= 0
        except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'offset' должен быть неотрицательным целым числом.")

        node_id_filter = int(node_id_filter_str) if node_id_filter_str else None
        method_id_filter = int(method_id_filter_str) if method_id_filter_str else None
        subdivision_id_filter = int(subdivision_id_filter_str) if subdivision_id_filter_str else None
        node_type_id_filter = int(node_type_id_filter_str) if node_type_id_filter_str else None
        is_enabled_filter: Optional[bool] = None
        if is_enabled_filter_str is not None:
            if is_enabled_filter_str.lower() in ['true', '1']: is_enabled_filter = True
            elif is_enabled_filter_str.lower() in ['false', '0']: is_enabled_filter = False
            else: raise ApiBadRequest("Параметр 'is_enabled' должен быть булевым (true/false).")
        
        include_child_subdivisions = include_child_sub_str.lower() == 'true'
        include_nested_types = include_nested_typ_str.lower() == 'true'
        if search_text_filter: search_text_filter = search_text_filter.strip()
        # --- Конец валидации ---

        cursor = g.db_conn.cursor()
        assignments_list, total_assignments = assignment_repository.fetch_assignments_paginated(
            cursor, limit=limit, offset=offset, node_id=node_id_filter,
            method_id=method_id_filter, subdivision_id=subdivision_id_filter,
            node_type_id=node_type_id_filter, search_text=search_text_filter,
            is_enabled=is_enabled_filter,
            include_child_subdivisions=include_child_subdivisions,
            include_nested_types=include_nested_types
        )
        # g.db_conn.commit() # Не нужен для SELECT

        logger.info(f"API Assignment Route: Успешно получен список всех заданий. "
                    f"На странице: {len(assignments_list)}, Всего: {total_assignments}")
        # Имя поля в ответе изменено на "assignments" для консистентности
        return jsonify({"assignments": assignments_list, "total_count": total_assignments, "limit": limit, "offset": offset}), 200

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении списка всех заданий: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении списка заданий.")
    except ApiException: raise # Пробрасываем наши кастомные ошибки (ApiBadRequest)
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при получении списка всех заданий.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


# --- Маршрут для массового создания/назначения заданий ---
@bp.route('/bulk_create', methods=['POST'])
@login_required
def api_create_or_assign_assignments():
    """
    Массово создает или назначает задания узлам.
    Принимает JSON-тело:
    {
        "assignment_data": { // Шаблон задания
            "method_id": int,
            "pipeline": list_of_steps,
            "check_interval_seconds": int,
            "is_enabled": bool (optional, default true),
            "description": str (optional)
        },
        "criteria": { // Критерии для выбора узлов (опционально)
            "subdivision_ids": [int],
            "node_type_ids": [int],
            "node_name_mask": str (SQL LIKE)
            // include_child_subdivisions и include_nested_types пока не поддерживаются здесь
        },
        "node_ids": [int] // Список ID узлов (опционально, приоритетнее criteria)
    }
    Если указаны и `criteria`, и `node_ids`, используются `node_ids`.
    Если не указаны ни `criteria`, ни `node_ids`, вернет ошибку.
    """
    logger.info("API Assignment Route: Запрос POST /api/v1/assignments/bulk_create (массовое создание)")
    payload = request.get_json()
    if not payload:
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")

    assignment_template_data = payload.get('assignment_data')
    criteria_for_nodes = payload.get('criteria')
    target_node_ids_list = payload.get('node_ids')

    # --- Валидация входных данных ---
    if not assignment_template_data or not isinstance(assignment_template_data, dict):
        raise ApiValidationFailure("Поле 'assignment_data' (шаблон задания) обязательно и должно быть объектом.")
    if not target_node_ids_list and not criteria_for_nodes:
        raise ApiValidationFailure("Необходимо указать либо 'node_ids' (список ID узлов), либо 'criteria' (критерии выбора узлов).")
    if target_node_ids_list and not (isinstance(target_node_ids_list, list) and all(isinstance(nid, int) for nid in target_node_ids_list)):
        raise ApiValidationFailure("Поле 'node_ids' должно быть массивом целых чисел.")
    if criteria_for_nodes and not isinstance(criteria_for_nodes, dict):
        raise ApiValidationFailure("Поле 'criteria' должно быть объектом.")

    # Валидация полей в assignment_template_data
    if not assignment_template_data.get('method_id') or not isinstance(assignment_template_data['method_id'], int):
        raise ApiValidationFailure("В 'assignment_data' обязательно поле 'method_id' (целое число).")
    if not assignment_template_data.get('pipeline') or not isinstance(assignment_template_data['pipeline'], list):
        raise ApiValidationFailure("В 'assignment_data' обязательно поле 'pipeline' (массив шагов).")
    if not assignment_template_data.get('check_interval_seconds') or not isinstance(assignment_template_data['check_interval_seconds'], int):
        raise ApiValidationFailure("В 'assignment_data' обязательно поле 'check_interval_seconds' (целое число).")
    # --- Конец валидации ---

    try:
        cursor = g.db_conn.cursor()
        # Используем репозиторий для массового создания
        # Репозиторий должен сам обработать выборку узлов по criteria или использовать node_ids
        num_created, list_of_created_ids = assignment_repository.create_assignments_unified(
            cursor,
            assignment_template=assignment_template_data,
            criteria_target=criteria_for_nodes if not target_node_ids_list else None, # criteria, если нет node_ids
            node_ids_target=target_node_ids_list
        )
        g.db_conn.commit() # Коммитим транзакцию после всех операций

        logger.info(f"API Assignment Route: Массовое создание завершено. Создано новых заданий: {num_created}.")
        return jsonify({
            "status": "success",
            "assignments_created": num_created,
            "created_ids": list_of_created_ids, # Список ID созданных для информации
            "message": f"Успешно создано/назначено {num_created} заданий."
        }), 201

    except ValueError as val_err_repo: # Ошибки валидации из репозитория
        g.db_conn.rollback()
        logger.warning(f"Ошибка ValueError из репозитория при массовом создании заданий: {val_err_repo}")
        raise ApiValidationFailure(str(val_err_repo))
    except psycopg2.Error as db_err:
        g.db_conn.rollback()
        logger.error(f"Ошибка БД при массовом создании заданий: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при массовом создании заданий.")
    except ApiException: raise
    except Exception as e:
        g.db_conn.rollback()
        logger.exception("Неожиданная ошибка сервера при массовом создании заданий.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


# --- Маршруты для управления конкретным заданием (GET, PUT, DELETE по ID) ---
@bp.route('/<int:assignment_id>', methods=['GET'])
@login_required
def api_get_assignment(assignment_id: int):
    """ Получает детали одного задания по его ID. """
    logger.info(f"API Assignment Route: Запрос GET /api/v1/assignments/{assignment_id}")
    if assignment_id <= 0: raise ApiBadRequest("ID задания должен быть положительным.")
    try:
        cursor = g.db_conn.cursor()
        assignment_data = assignment_repository.get_assignment_by_id(cursor, assignment_id)
        if not assignment_data:
            raise ApiNotFound(f"Задание с ID={assignment_id} не найдено.")
        # g.db_conn.commit() # Не нужен для SELECT
        return jsonify(assignment_data), 200
    except psycopg2.Error as db_err: logger.error(f"Ошибка БД (GET assign_id={assignment_id}): {db_err}", exc_info=True); raise ApiInternalError("Ошибка БД.")
    except ApiException: raise
    except Exception as e: logger.exception(f"Ошибка (GET assign_id={assignment_id})"); raise ApiInternalError(f"{type(e).__name__}")


@bp.route('/<int:assignment_id>', methods=['PUT'])
@login_required
def api_update_assignment(assignment_id: int):
    """ Обновляет существующее задание по ID. """
    logger.info(f"API Assignment Route: Запрос PUT /api/v1/assignments/{assignment_id}")
    if assignment_id <= 0: raise ApiBadRequest("ID задания должен быть положительным.")
    update_payload = request.get_json()
    if not update_payload or not isinstance(update_payload, dict):
        raise ApiBadRequest("Тело запроса для обновления отсутствует или не JSON-объект.")
    
    # Валидация данных для обновления (можно вынести в отдельную функцию)
    # ... (пример: проверить типы, наличие pipeline, если он обновляется) ...
    if 'pipeline' in update_payload and not isinstance(update_payload['pipeline'], list):
        raise ApiValidationFailure("Поле 'pipeline' должно быть массивом, если передано для обновления.")

    try:
        cursor = g.db_conn.cursor()
        updated_assignment = assignment_repository.update_assignment(cursor, assignment_id, update_payload)
        if not updated_assignment:
            raise ApiNotFound(f"Задание с ID={assignment_id} не найдено для обновления.")
        g.db_conn.commit()
        return jsonify(updated_assignment), 200
    except ValueError as val_err_repo_upd: g.db_conn.rollback(); raise ApiValidationFailure(str(val_err_repo_upd))
    except psycopg2.Error as db_err_upd: g.db_conn.rollback(); logger.error(f"Ошибка БД (PUT assign_id={assignment_id}): {db_err_upd}", exc_info=True); raise ApiInternalError("Ошибка БД.")
    except ApiException: g.db_conn.rollback(); raise
    except Exception as e_upd: g.db_conn.rollback(); logger.exception(f"Ошибка (PUT assign_id={assignment_id})"); raise ApiInternalError(f"{type(e_upd).__name__}")


@bp.route('/<int:assignment_id>', methods=['DELETE'])
@login_required
def api_delete_assignment(assignment_id: int):
    """ Удаляет задание по ID. """
    logger.info(f"API Assignment Route: Запрос DELETE /api/v1/assignments/{assignment_id}")
    if assignment_id <= 0: raise ApiBadRequest("ID задания должен быть положительным.")
    try:
        cursor = g.db_conn.cursor()
        deleted_successfully = assignment_repository.delete_assignment(cursor, assignment_id)
        if not deleted_successfully:
            raise ApiNotFound(f"Задание с ID={assignment_id} не найдено для удаления.")
        g.db_conn.commit()
        return '', 204 # No Content
    except psycopg2.Error as db_err_del:
        g.db_conn.rollback()
        # Обработка ForeignKeyViolation (если на задание ссылаются node_checks и ON DELETE RESTRICT)
        if db_err_del.pgcode == '23503':
            raise ApiConflict(f"Невозможно удалить задание ID={assignment_id}, так как на него есть ссылки в истории проверок.")
        logger.error(f"Ошибка БД (DELETE assign_id={assignment_id}): {db_err_del}", exc_info=True)
        raise ApiInternalError("Ошибка БД при удалении задания.")
    except ApiException: g.db_conn.rollback(); raise
    except Exception as e_del: g.db_conn.rollback(); logger.exception(f"Ошибка (DELETE assign_id={assignment_id})"); raise ApiInternalError(f"{type(e_del).__name__}")

# --- Конец файла ---