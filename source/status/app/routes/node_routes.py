# status/app/routes/node_routes.py
"""
Маршруты API для управления Узлами мониторинга (серверы, рабочие станции и т.д.).
Включает CRUD-операции для узлов и получение статуса их заданий.
"""
import logging
import psycopg2
import json # Для обработки JSON в ответе assignments_status
from datetime import datetime # Для форматирования дат
from flask import Blueprint, request, jsonify, g
from typing import Optional, Dict, Any
from ..repositories import node_repository, assignment_repository # Репозитории
from ..errors import (
    ApiNotFound,
    ApiInternalError,
    ApiBadRequest,
    ApiValidationFailure,
    ApiConflict,
    ApiException
)
from flask_login import login_required # Защита маршрутов

logger = logging.getLogger(__name__)
# Создаем Blueprint. Префикс '/api/v1/nodes' будет добавлен при регистрации в app/routes/__init__.py
bp = Blueprint('nodes', __name__)

@bp.route('', methods=['GET'])
@login_required # Только авторизованные пользователи могут просматривать список узлов
def api_get_all_nodes():
    """
    Получает список всех узлов с возможностью фильтрации и пагинации.

    Query Params:
        limit (int, optional): Количество записей на странице.
        offset (int, optional): Смещение для пагинации.
        subdivision_id (int, optional): Фильтр по ID подразделения.
        node_type_id (int, optional): Фильтр по ID типа узла.
        search_text (str, optional): Поиск по имени или IP-адресу узла.
        include_child_subdivisions (bool, optional): Включить узлы из дочерних подразделений.
        include_nested_types (bool, optional): Включить узлы с дочерними типами.

    Returns:
        JSON: Объект с полями "items" (список узлов) и "total_count".
    """
    full_path = request.full_path if request else "/api/v1/nodes (путь не определен)"
    logger.info(f"API Node Route: Запрос GET {full_path} (список узлов)")
    try:
        # --- Парсинг и валидация параметров запроса ---
        limit_str = request.args.get('limit')
        offset_str = request.args.get('offset', default='0')
        subdivision_id_str = request.args.get('subdivision_id')
        node_type_id_str = request.args.get('node_type_id')
        search_text_filter = request.args.get('search_text')
        include_child_subdivisions_filter = request.args.get('include_child_subdivisions', 'false').lower() == 'true'
        include_nested_types_filter = request.args.get('include_nested_types', 'false').lower() == 'true'

        limit: Optional[int] = None
        if limit_str is not None:
            try: limit = int(limit_str); assert limit > 0
            except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'limit' должен быть положительным целым числом.")
            if limit > 200: limit = 200 # Ограничение

        try: offset = int(offset_str); assert offset >= 0
        except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'offset' должен быть неотрицательным целым числом.")

        subdivision_id_filter: Optional[int] = None
        if subdivision_id_str:
            try: subdivision_id_filter = int(subdivision_id_str)
            except ValueError: raise ApiBadRequest("Параметр 'subdivision_id' должен быть целым числом.")
        node_type_id_filter: Optional[int] = None
        if node_type_id_str:
            try: node_type_id_filter = int(node_type_id_str)
            except ValueError: raise ApiBadRequest("Параметр 'node_type_id' должен быть целым числом.")
        if search_text_filter: search_text_filter = search_text_filter.strip()
        # --- Конец парсинга и валидации ---

        cursor = g.db_conn.cursor()
        # Вызов функции репозитория для получения отфильтрованного и пагинированного списка узлов
        node_items, total_node_count = node_repository.fetch_nodes(
            cursor,
            limit=limit, offset=offset, subdivision_id=subdivision_id_filter,
            node_type_id=node_type_id_filter, search_text=search_text_filter,
            include_child_subdivisions=include_child_subdivisions_filter,
            include_nested_types=include_nested_types_filter
        )
        logger.info(f"API Node Route: Успешно получен список узлов. "
                    f"Найдено на странице: {len(node_items)}, Всего (с фильтрами): {total_node_count}")
        return jsonify({"items": node_items, "total_count": total_node_count, "limit": limit, "offset": offset}), 200

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении списка узлов: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении списка узлов.")
    except ApiException: # Пробрасываем ApiBadRequest
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при получении списка узлов.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('', methods=['POST'])
@login_required # Только авторизованные пользователи
def api_create_node():
    """
    Создает новый узел мониторинга.
    Принимает JSON-тело с полями:
        - name (str, required): Имя узла (hostname).
        - parent_subdivision_id (int, required): ID родительского подразделения.
        - ip_address (str, optional): IP-адрес узла.
        - node_type_id (int, optional): ID типа узла.
        - description (str, optional): Описание узла.
    Возвращает JSON с данными созданного узла.
    """
    logger.info("API Node Route: Запрос POST /api/v1/nodes (создание нового узла)")
    data_from_request = request.get_json()
    if not data_from_request:
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")

    # --- Валидация обязательных полей ---
    required_fields_list = ['name', 'parent_subdivision_id']
    missing_fields_list = [field for field in required_fields_list if data_from_request.get(field) is None or str(data_from_request[field]).strip() == ""]
    if missing_fields_list:
        logger.warning(f"Отсутствуют обязательные поля при создании узла: {missing_fields_list}")
        raise ApiValidationFailure(f"Отсутствуют обязательные поля: {', '.join(missing_fields_list)}")

    # Дополнительная валидация типов и значений
    try:
        if not isinstance(data_from_request['name'], str) or len(data_from_request['name']) > 255:
            raise ValueError("Имя узла должно быть строкой до 255 символов.")
        parent_sub_id = int(data_from_request['parent_subdivision_id'])
        if parent_sub_id <= 0: raise ValueError("ID родительского подразделения должен быть положительным.")
        if 'ip_address' in data_from_request and data_from_request['ip_address'] is not None and len(str(data_from_request['ip_address'])) > 45:
            raise ValueError("IP-адрес не должен превышать 45 символов.")
        if 'node_type_id' in data_from_request and data_from_request['node_type_id'] is not None:
            node_type_id_val = int(data_from_request['node_type_id'])
            if node_type_id_val < 0: raise ValueError("ID типа узла не может быть отрицательным (0 - базовый тип).")
    except ValueError as e_val:
        logger.warning(f"Ошибка валидации данных при создании узла: {e_val}")
        raise ApiValidationFailure(str(e_val))
    # --- Конец валидации ---

    try:
        cursor = g.db_conn.cursor()
        # Вызываем функцию репозитория для создания узла
        # Репозиторий должен вернуть частичные данные (например, только ID) или полные, если это удобно
        created_node_info = node_repository.create_node(cursor, data_from_request)

        if not created_node_info or 'id' not in created_node_info:
            logger.error("Создание узла не удалось: репозиторий не вернул ID.")
            raise ApiInternalError("Не удалось получить ID для созданного узла.")
        new_node_id = created_node_info['id']

        # Получаем полную информацию о созданном узле для ответа (включая JOIN'ы)
        full_new_node_data = node_repository.get_node_by_id(cursor, new_node_id)
        if not full_new_node_data:
            logger.error(f"Не удалось получить полную информацию для только что созданного узла ID: {new_node_id}. "
                         "Возвращаем частичные данные.")
            # В крайнем случае, возвращаем то, что вернул create_node, если он возвращает больше чем ID
            return jsonify(created_node_info), 201

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Node Route: Успешно создан узел ID: {new_node_id}, Имя: '{data_from_request['name']}'")
        return jsonify(full_new_node_data), 201 # HTTP 201 Created

    except ValueError as val_err_repo: # Ошибки валидации из репозитория (например, FK constraint)
        logger.warning(f"Ошибка ValueError из репозитория при создании узла: {val_err_repo}")
        raise ApiValidationFailure(str(val_err_repo))
    except psycopg2.errors.UniqueViolation:
        logger.warning(f"Попытка создания узла с дублирующимся именем ('{data_from_request['name']}') "
                       f"в подразделении ID {data_from_request['parent_subdivision_id']}.")
        raise ApiConflict("Узел с таким именем в указанном подразделении уже существует.")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при создании узла: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при создании узла.")
    except ApiException: # Пробрасываем наши кастомные ошибки
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при создании узла.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:node_id>', methods=['GET'])
@login_required # Только авторизованные пользователи
def api_get_node_by_id_route(node_id: int): # Добавил type hint для node_id
    """Получает детали одного узла по его ID."""
    logger.info(f"API Node Route: Запрос GET /api/v1/nodes/{node_id} (детали узла)")
    if node_id <= 0: # Базовая проверка ID
        raise ApiBadRequest("ID узла должен быть положительным целым числом.")
    try:
        cursor = g.db_conn.cursor()
        node_data = node_repository.get_node_by_id(cursor, node_id) # Репозиторий возвращает dict или None
        if not node_data:
            logger.warning(f"Узел с ID={node_id} не найден.")
            raise ApiNotFound(f"Узел с ID={node_id} не найден.")

        logger.info(f"API Node Route: Успешно получены детали для узла ID: {node_id}")
        return jsonify(node_data), 200
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении деталей узла ID={node_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении информации об узле.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при получении деталей узла ID={node_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:node_id>', methods=['PUT'])
@login_required # Только авторизованные пользователи
def api_update_node_by_id_route(node_id: int):
    """Обновляет данные существующего узла по его ID."""
    logger.info(f"API Node Route: Запрос PUT /api/v1/nodes/{node_id} (обновление узла)")
    if node_id <= 0:
        raise ApiBadRequest("ID узла должен быть положительным целым числом.")

    data_to_update = request.get_json()
    if not data_to_update: # Если тело пустое или не JSON
        raise ApiBadRequest("Тело запроса отсутствует, не является валидным JSON или не содержит данных для обновления.")
    if not isinstance(data_to_update, dict) or not data_to_update: # Если JSON не объект или пустой объект
        raise ApiBadRequest("Нет допустимых полей для обновления узла. Требуется JSON-объект с полями.")

    # Удаляем поля, которые не должны изменяться через этот эндпоинт (например, ID)
    data_to_update.pop('id', None)
    if not data_to_update: # Если после удаления запрещенных полей ничего не осталось
         raise ApiBadRequest("Нет допустимых полей для обновления узла.")

    # Здесь можно добавить более строгую валидацию полей в data_to_update, аналогично create_node
    # Например, проверка типов, длин строк, существование FK и т.д.

    try:
        cursor = g.db_conn.cursor()
        # Репозиторий должен вернуть обновленный объект узла или None, если узел не найден
        updated_node_data = node_repository.update_node(cursor, node_id, data_to_update)

        if updated_node_data is None:
            logger.warning(f"Узел с ID={node_id} не найден при попытке обновления.")
            raise ApiNotFound(f"Узел с ID={node_id} не найден для обновления.")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Node Route: Успешно обновлен узел ID: {node_id}. Обновленные поля: {list(data_to_update.keys())}")
        return jsonify(updated_node_data), 200
    except ValueError as val_err_repo: # Ошибки валидации из репозитория
        logger.warning(f"Ошибка ValueError из репозитория при обновлении узла ID={node_id}: {val_err_repo}")
        raise ApiValidationFailure(str(val_err_repo))
    except psycopg2.errors.UniqueViolation:
        logger.warning(f"Конфликт при обновлении узла ID={node_id}: попытка установить дублирующееся имя.")
        raise ApiConflict("Узел с таким именем в указанном подразделении уже существует.")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при обновлении узла ID={node_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при обновлении узла.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при обновлении узла ID={node_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:node_id>', methods=['DELETE'])
@login_required # Только авторизованные пользователи
def api_delete_node_by_id_route(node_id: int):
    """Удаляет узел по его ID."""
    logger.info(f"API Node Route: Запрос DELETE /api/v1/nodes/{node_id} (удаление узла)")
    if node_id <= 0:
        raise ApiBadRequest("ID узла должен быть положительным целым числом.")
    try:
        cursor = g.db_conn.cursor()
        # Репозиторий возвращает True, если удаление успешно, иначе False
        deleted_successfully = node_repository.delete_node(cursor, node_id)

        if not deleted_successfully:
            logger.warning(f"Узел с ID={node_id} не найден при попытке удаления.")
            raise ApiNotFound(f"Узел с ID={node_id} не найден.")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Node Route: Успешно удален узел ID: {node_id}")
        return '', 204 # HTTP 204 No Content (стандарт для успешного DELETE)
    except psycopg2.Error as db_err:
        # Обработка ForeignKeyViolation, если на узел ссылаются задания или проверки
        if db_err.pgcode == '23503': # Код ошибки для foreign_key_violation
            logger.warning(f"Попытка удаления узла ID={node_id}, на который есть ссылки (задания, проверки): {db_err}")
            raise ApiConflict("Невозможно удалить узел, так как на него есть ссылки (например, в заданиях или истории проверок). Сначала удалите связанные записи.")
        logger.error(f"Ошибка БД при удалении узла ID={node_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при удалении узла.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при удалении узла ID={node_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


# --- Маршрут для получения статуса заданий узла ---
# Этот маршрут логично оставить здесь, так как он относится к конкретному узлу.
@bp.route('/<int:node_id>/assignments_status', methods=['GET'])
@login_required # Обычно доступно авторизованным пользователям для просмотра в UI
def api_node_assignments_status_route(node_id: int): # Изменено имя функции для избежания конфликта
    """
    Получает статус всех активных заданий (pipeline) для конкретного узла,
    включая информацию о последней проверке.
    """
    logger.info(f"API Node Route: Запрос GET /api/v1/nodes/{node_id}/assignments_status")
    if node_id <= 0:
        raise ApiBadRequest("ID узла должен быть положительным целым числом.")
    try:
        cursor = g.db_conn.cursor()

        # 1. Проверяем, существует ли узел
        # Используем более легковесный метод, если он есть в репозитории, или get_node_by_id
        node_info = node_repository.get_node_by_id(cursor, node_id)
        if not node_info:
            logger.warning(f"Узел с ID={node_id} не найден при запросе статуса его заданий.")
            raise ApiNotFound(f"Узел с ID={node_id} не найден.")
        logger.debug(f"Узел ID={node_id} найден, запрашиваем статус его заданий.")

        # 2. Получаем статус заданий через репозиторий
        # Эта функция должна вызывать хранимую процедуру/функцию БД get_assignments_status_for_node
        assignments_status_list = assignment_repository.fetch_assignments_status_for_node(cursor, node_id)

        # 3. ПОСТ-ОБРАБОТКА данных для JSON ответа
        for item in assignments_status_list:
            # Десериализуем JSON-поля (pipeline), если они приходят как строки
            # В новой архитектуре 'parameters' и 'success_criteria' должны быть частью 'pipeline'
            # или удалены из выборки/возврата, если они на верхнем уровне задания
            if item.get('pipeline') and isinstance(item['pipeline'], str):
                 try:
                     item['pipeline'] = json.loads(item['pipeline'])
                 except json.JSONDecodeError:
                     logger.warning(f"Ошибка декодирования JSON для 'pipeline' в задании ID {item.get('assignment_id')}")
                     item['pipeline'] = {"_error": "Invalid pipeline JSON in DB"}
            elif item.get('pipeline') is None:
                 item['pipeline'] = [] # null из БД -> пустой массив

            # Удаляем устаревшие поля, если они еще могут быть в результате от БД
            item.pop('parameters', None)
            item.pop('success_criteria', None)

            # Форматируем даты в ISO строки
            for date_key in ['last_executed_at', 'last_check_timestamp', 'last_check_db_timestamp']:
                if item.get(date_key) and isinstance(item[date_key], datetime):
                     item[date_key] = item[date_key].isoformat()
        # --- КОНЕЦ ПОСТ-ОБРАБОТКИ ---

        logger.info(f"API Node Route: Успешно получен статус для {len(assignments_status_list)} заданий узла ID={node_id}.")
        return jsonify(assignments_status_list)

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении статуса заданий для узла ID={node_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении статуса заданий узла.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при получении статуса заданий для узла ID={node_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")