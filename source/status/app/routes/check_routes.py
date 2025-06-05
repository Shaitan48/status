# status/app/routes/check_routes.py
"""
Маршруты API для работы с результатами проверок (Checks).
Версия 5.0.2: Адаптировано для обработки поля 'check_success' из запроса
и передачи его в процедуру записи. Включает логику для pipeline-архитектуры.
"""
import logging
import psycopg2 # Для обработки ошибок psycopg2.Error и типизации курсора
import json     # Для работы с JSON
from datetime import datetime, timezone # Для работы с датами и таймзонами
from flask import Blueprint, request, jsonify, g, current_app # g для доступа к db_conn, current_app для SocketIO
from typing import Optional, Any, Dict, List, Union # Для аннотаций типов

# Импортируем зависимости из текущего приложения
from ..repositories import check_repository, node_repository, assignment_repository
from ..services import node_service # Для обновления статуса узла через SocketIO
from ..errors import (
    ApiBadRequest,
    ApiNotFound,
    ApiInternalError,
    ApiValidationFailure,
    ApiException
)
from ..db_connection import HAS_DATEUTIL # Флаг для проверки наличия python-dateutil
from ..auth_utils import api_key_required # Декоратор для защиты API-эндпоинтов

# Условный импорт dateutil для более гибкого парсинга дат
if HAS_DATEUTIL:
    from dateutil import parser as dateutil_parser

# Инициализация логгера для этого модуля
logger = logging.getLogger(__name__)
# Создаем Blueprint. Префикс '/api/v1' будет добавлен при регистрации в app/routes/__init__.py
bp = Blueprint('checks', __name__)

# --- Маршрут для приема ОДИНОЧНОГО результата проверки (агрегированного результата pipeline) ---
@bp.route('/checks', methods=['POST'])
@api_key_required(required_role=('agent', 'loader')) # Доступен для ключей с ролью 'agent' (Online) или 'loader' (Offline)
def add_check_v1():
    """
    Принимает и записывает один агрегированный результат выполнения pipeline-задания.
    Этот эндпоинт используется:
    - Гибридным Агентом в Online-режиме после выполнения одного pipeline-задания.
    - Загрузчиком Результатов (result_loader.ps1), если он отправляет результаты по одному
      (хотя предпочтительнее /checks/bulk для Загрузчика).

    Ожидает JSON в теле запроса со следующими основными полями (многие из них приходят от PowerShell агента с PascalCase):
        - assignment_id (int, required): ID задания, к которому относится результат.
        - IsAvailable (bool, required): Общий статус доступности/выполнимости всего pipeline-задания.
        - CheckSuccess (bool, optional, nullable): Общий результат выполнения критериев для всего pipeline.
                                                   Может быть null, если критерии не применялись или произошла ошибка их оценки.
        - Timestamp (str, optional): Время завершения выполнения pipeline на агенте (в формате ISO 8601 UTC).
        - Details (dict, optional): Объект, содержащий детализацию выполнения pipeline.
                                     Ожидаемая структура: { "steps_results": [...], "pipeline_status_message": "..." }
                                     где 'steps_results' - это массив результатов каждого шага.
        - ErrorMessage (str, optional): Общее сообщение об ошибке для всего pipeline, если оно было.
        - executor_object_id (int, optional): ID объекта (подразделения) исполнителя (актуально для Online агента).
        - executor_host (str, optional): Имя хоста исполнителя (актуально для Online агента).
        - resolution_method (str, optional): Имя основного метода/типа задания (для классификации).
        - assignment_config_version (str, optional): Версия конфигурации заданий (актуально для Offline агента через Loader).
        - agent_script_version (str, optional): Версия скрипта агента.

    Действия:
    1. Валидирует входные данные.
    2. Вызывает хранимую процедуру `record_check_result_proc` (через `check_repository`) для записи в БД.
       Эта процедура записывает основной результат в `node_checks` (включая `is_available` и `check_success`)
       и детали в `node_check_details`.
    3. При успешной записи, отправляет обновление статуса затронутого узла через SocketIO (если настроен).

    Returns:
        JSON-ответ со статусом операции (HTTP 201 при успехе).
    """
    # Получаем объект SocketIO из расширений Flask (если он был инициализирован в app.py)
    socketio = current_app.extensions.get('socketio')
    if not socketio:
         logger.error("SocketIO не инициализирован в приложении! Обновления статуса узла через WebSocket не будут отправлены.")

    logger.info("API Check Route (v5.0.2): Запрос POST /api/v1/checks (прием одиночного результата pipeline)")
    data_from_request = request.get_json() # Получаем JSON из тела запроса
    if not data_from_request: # Если тело пустое или не JSON
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")

    logger.debug(f"Получены сырые данные для записи результата pipeline: {data_from_request}")

    try: # Внешний try-блок для перехвата общих ошибок (например, psycopg2.Error или непредвиденных)
        # --- Внутренний try-блок для извлечения и валидации полей из JSON ---
        try:
            # Извлекаем поля, которые приходят от PowerShell агента (обычно PascalCase)
            assignment_id_raw = data_from_request.get('assignment_id')
            is_available_raw = data_from_request.get('IsAvailable') # От PowerShell
            check_success_raw = data_from_request.get('CheckSuccess') # От PowerShell, может быть $null
            check_timestamp_str = data_from_request.get('Timestamp')    # От PowerShell
            nested_details_obj_from_ps = data_from_request.get('Details') # Объект Details от PowerShell
            error_message_from_ps_pipeline = data_from_request.get('ErrorMessage') # Общая ошибка pipeline от PowerShell

            # Поля, которые могут быть добавлены агентом/загрузчиком или установлены по умолчанию
            executor_object_id_raw = data_from_request.get('executor_object_id')
            executor_host = data_from_request.get('executor_host')
            resolution_method_req = data_from_request.get('resolution_method')
            assignment_version_req = data_from_request.get('assignment_config_version')
            agent_version_req = data_from_request.get('agent_script_version')

            # --- Валидация обязательных полей ---
            if assignment_id_raw is None:
                raise ApiValidationFailure("Поле 'assignment_id' является обязательным.")
            if is_available_raw is None: # IsAvailable от агента
                raise ApiValidationFailure("Поле 'IsAvailable' (статус доступности от агента) является обязательным.")

            # --- Приведение типов и дальнейшая валидация ---
            try:
                assignment_id = int(assignment_id_raw)
                if assignment_id <= 0: raise ValueError # ID задания должен быть положительным
            except (ValueError, TypeError):
                raise ValueError("Поле 'assignment_id' должно быть положительным целым числом.")

            is_available: bool # Окончательное значение для записи в БД
            if isinstance(is_available_raw, bool): is_available = is_available_raw
            elif isinstance(is_available_raw, str): is_available = is_available_raw.lower() in ['true', '1', 'yes', 'on']
            elif isinstance(is_available_raw, (int, float)): is_available = bool(is_available_raw) # 0 -> False, остальное -> True
            else: raise ValueError("Поле 'IsAvailable' должно быть булевым значением или приводиться к нему.")

            check_success_final: Optional[bool] = None # Окончательное значение для записи в БД
            if check_success_raw is not None: # Если CheckSuccess вообще передан
                if isinstance(check_success_raw, bool): check_success_final = check_success_raw
                elif isinstance(check_success_raw, str): check_success_final = check_success_raw.lower() in ['true', '1', 'yes', 'on']
                elif isinstance(check_success_raw, (int, float)): check_success_final = bool(check_success_raw)
                else: raise ValueError("Поле 'CheckSuccess' должно быть булевым значением, строкой (true/false) или null.")
            
            executor_object_id: Optional[int] = None
            if executor_object_id_raw is not None:
                try: executor_object_id = int(executor_object_id_raw)
                except (ValueError, TypeError): raise ValueError("Поле 'executor_object_id' должно быть целым числом, если указано.")

            # --- Обработка времени выполнения на агенте (check_timestamp) ---
            check_timestamp_for_db: Optional[datetime] = None # Для передачи в процедуру БД
            if check_timestamp_str: # Если время передано
                try:
                    parsed_dt_obj: datetime
                    if HAS_DATEUTIL: # Используем dateutil для более гибкого парсинга ISO 8601
                        parsed_dt_obj = dateutil_parser.isoparse(check_timestamp_str)
                    else: # Используем стандартный datetime.fromisoformat
                        # Предварительная обработка строки для совместимости с fromisoformat
                        ts_cleaned_for_iso = check_timestamp_str.replace('Z', '+00:00') # Заменяем 'Z'
                        if '.' in ts_cleaned_for_iso: # Обрезаем микросекунды до 6 знаков
                            main_part, micro_tz_part = ts_cleaned_for_iso.split('.', 1)
                            micro_part_actual = micro_tz_part.split('+', 1)[0].split('-', 1)[0] # Извлекаем только микросекунды
                            timezone_suffix_actual = micro_tz_part[len(micro_part_actual):]     # Остаток строки (таймзона)
                            if len(micro_part_actual) > 6: micro_part_actual = micro_part_actual[:6]
                            ts_cleaned_for_iso = f"{main_part}.{micro_part_actual}{timezone_suffix_actual}"
                        parsed_dt_obj = datetime.fromisoformat(ts_cleaned_for_iso)
                    
                    # Приводим время к UTC, если оно с таймзоной, или считаем его UTC, если "наивное"
                    if parsed_dt_obj.tzinfo: # Если таймзона уже есть
                        check_timestamp_for_db = parsed_dt_obj.astimezone(timezone.utc)
                    else: # Если время "наивное" (без таймзоны), считаем, что это UTC
                        check_timestamp_for_db = parsed_dt_obj.replace(tzinfo=timezone.utc)
                    logger.debug(f"Время агента '{check_timestamp_str}' успешно распарсено в UTC: {check_timestamp_for_db.isoformat()}")
                except Exception as e_parse_ts:
                    logger.warning(f"Ошибка парсинга 'Timestamp' ('{check_timestamp_str}'): {e_parse_ts}. "
                                   "Время проверки будет установлено сервером (CURRENT_TIMESTAMP).", exc_info=False)
                    check_timestamp_for_db = None # В случае ошибки, процедура БД использует CURRENT_TIMESTAMP
            else:
                 logger.debug("Поле 'Timestamp' (время на агенте) не предоставлено. Время проверки будет установлено сервером.")

            # --- Формирование detail_type и detail_data для записи в node_check_details ---
            # detail_type теперь будет стандартным для агрегированного результата pipeline.
            final_detail_type_for_db = "PIPELINE_AGGREGATED_RESULT"
            # detail_data будет содержать объект Details от агента, включающий результаты шагов.
            final_detail_data_for_db: Optional[Dict[str, Any]] = None
            if nested_details_obj_from_ps and isinstance(nested_details_obj_from_ps, dict):
                final_detail_data_for_db = nested_details_obj_from_ps # Это уже dict
                # Добавляем общий ErrorMessage для pipeline в детали, если он был
                if error_message_from_ps_pipeline:
                    final_detail_data_for_db['pipeline_overall_error_message'] = error_message_from_ps_pipeline
            elif error_message_from_ps_pipeline: # Если нет Details, но есть ErrorMessage
                final_detail_data_for_db = {'pipeline_overall_error_message': error_message_from_ps_pipeline}
            
            # Определяем resolution_method: либо из запроса, либо из основного метода задания
            final_resolution_method_for_db = resolution_method_req
            if not final_resolution_method_for_db: # Если агент не передал
                cursor_for_method = g.db_conn.cursor() # Используем существующее соединение
                assignment_info = assignment_repository.get_assignment_by_id(cursor_for_method, assignment_id)
                final_resolution_method_for_db = assignment_info.get('method_name', 'UNKNOWN_PIPELINE_TYPE') if assignment_info else 'UNKNOWN_PIPELINE_TYPE'
                # cursor_for_method.close() # Не закрываем, это курсор из g

        except ApiValidationFailure as api_val_err_init: # Пробрасываем наши ошибки валидации
            raise api_val_err_init
        except (ValueError, TypeError) as val_err_init: # Другие ошибки преобразования/типов
            logger.warning(f"Ошибка валидации данных при приеме одиночного результата: {val_err_init}", exc_info=True)
            raise ApiValidationFailure(f"Ошибка обработки предоставленных данных: {val_err_init}")

        # --- Вызов репозитория для записи в БД (через хранимую процедуру) ---
        current_db_cursor = g.db_conn.cursor() # Получаем курсор из контекста запроса
        check_repository.record_check_result_proc(
            cursor=current_db_cursor, # Передаем курсор
            assignment_id=assignment_id,
            is_available=is_available,
            check_success=check_success_final, # <<< ПЕРЕДАЕМ НОВЫЙ ПАРАМЕТР check_success_final
            check_timestamp=check_timestamp_for_db,
            executor_object_id=executor_object_id,
            executor_host=executor_host,
            resolution_method=final_resolution_method_for_db,
            detail_type=final_detail_type_for_db,
            detail_data=final_detail_data_for_db, # Это уже Python dict/list или None
            p_assignment_version=assignment_version_req,
            p_agent_version=agent_version_req
        )
        # g.db_conn.commit() # Коммит не нужен здесь, если autocommit=True для соединения или управляется транзакцией на уровне запроса.
                           # Если autocommit=False, коммит должен быть после всех операций в запросе.

        # --- Отправка обновления статуса узла через SocketIO (если настроен) ---
        if socketio:
            try:
                # Используем тот же курсор, если транзакция еще не завершена
                assignment_details_for_socket = assignment_repository.get_assignment_by_id(current_db_cursor, assignment_id)
                if assignment_details_for_socket and assignment_details_for_socket.get('node_id'):
                    node_id_for_socket_update = assignment_details_for_socket['node_id']
                    # Получаем актуальный ОБРАБОТАННЫЙ статус узла (с учетом check_success)
                    processed_nodes_for_socket = node_service.get_processed_node_status(current_db_cursor)
                    updated_node_data_for_socket = next(
                        (node for node in processed_nodes_for_socket if node.get('id') == node_id_for_socket_update), None
                    )
                    if updated_node_data_for_socket:
                        socket_payload_ui_update = { 'node_id': node_id_for_socket_update, **updated_node_data_for_socket }
                        socketio.emit('node_status_update', socket_payload_ui_update)
                        logger.debug(f"SocketIO: Отправлено событие 'node_status_update' для узла ID {node_id_for_socket_update}.")
                    else:
                        logger.warning(f"SocketIO: Не найдены актуальные данные для узла ID {node_id_for_socket_update} после записи результата. Обновление не отправлено.")
                else:
                    logger.warning(f"SocketIO: Не удалось найти узел для задания ID {assignment_id}. Обновление статуса узла не отправлено.")
            except Exception as socket_err_single_send:
                logger.error(f"Ошибка при отправке обновления статуса узла через SocketIO (одиночный результат): {socket_err_single_send}", exc_info=True)
        else:
            logger.debug("SocketIO не настроен в приложении. Обновление статуса узла через WebSocket пропущено.")
        # --- Конец блока SocketIO ---

        logger.info(f"Результат pipeline-задания ID {assignment_id} успешно принят и записан в БД.")
        return jsonify({"status": "success", "message": f"Результат для задания {assignment_id} успешно принят."}), 201

    # --- Обработка исключений на верхнем уровне функции ---
    except ValueError as repo_validation_error: # Ошибки валидации из репозитория или нашей логики
        error_message_str_val = str(repo_validation_error)
        # Проверяем, не является ли это ошибкой "Задание не найдено" от процедуры
        if "не найдено" in error_message_str_val.lower() and ("задание" in error_message_str_val.lower() or "assignment" in error_message_str_val.lower()):
            logger.warning(f"Попытка записи результата для несуществующего задания: {error_message_str_val}")
            raise ApiNotFound(error_message_str_val) # Преобразуем в 404 Not Found
        else: # Другие ValueError - как ошибки валидации данных запроса
            logger.warning(f"Ошибка ValueError при записи результата проверки: {error_message_str_val}")
            raise ApiValidationFailure(error_message_str_val)
    except psycopg2.Error as db_error_main: # Ошибки базы данных
        logger.error(f"Ошибка БД при записи одиночного результата pipeline: {db_error_main}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при записи результата pipeline.")
    except ApiException as api_custom_error: # Пробрасываем наши кастомные API ошибки (ApiNotFound, ApiValidationFailure)
        raise api_custom_error
    except Exception as generic_error_main: # Ловим все остальные непредвиденные ошибки
        logger.exception("Неожиданная ошибка сервера при записи одиночного результата pipeline.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(generic_error_main).__name__} - {generic_error_main}")


# --- Маршрут для ПАКЕТНОЙ загрузки результатов (агрегированных результатов pipeline) ---
@bp.route('/checks/bulk', methods=['POST'])
@api_key_required(required_role='loader') # Доступен только для ключей с ролью 'loader'
def add_checks_bulk_v1():
    """
    Принимает массив агрегированных результатов pipeline-заданий для пакетной загрузки.
    Каждый элемент массива 'results' в теле запроса должен соответствовать формату,
    ожидаемому от Гибридного Агента (т.е., содержать 'assignment_id', 'IsAvailable',
    'CheckSuccess', 'Timestamp', и объект 'Details' с 'steps_results').

    JSON Body:
        - results (list, required): Массив объектов агрегированных результатов pipeline.
        - agent_script_version (str, optional): Общая версия скрипта агента для пакета.
        - assignment_config_version (str, optional): Общая версия конфигурации для пакета.
        - object_id (int, optional): Общий ID объекта (подразделения) для пакета.

    Обрабатывает каждую запись индивидуально. При ошибке БД вся транзакция (если не autocommit)
    может быть отменена. Возвращает статус 207 Multi-Status в случае частичных ошибок
    обработки отдельных записей (например, ошибок валидации элемента).
    """
    socketio = current_app.extensions.get('socketio')
    logger.info("API Check Route (v5.0.2): Запрос POST /api/v1/checks/bulk (пакетная загрузка pipeline-результатов)")
    payload_top_level_bulk = request.get_json()
    transaction_had_db_errors_in_bulk = False # Флаг, если ошибка БД затронула всю транзакцию

    # --- Валидация входных данных верхнего уровня ---
    if not payload_top_level_bulk or not isinstance(payload_top_level_bulk, dict):
        raise ApiBadRequest("Тело запроса для пакетной загрузки должно быть JSON-объектом.")
    results_list_from_payload = payload_top_level_bulk.get('results')
    # Получаем общие версии и object_id из верхнеуровневого payload
    agent_version_global_from_payload = payload_top_level_bulk.get('agent_script_version')
    assignment_version_global_from_payload = payload_top_level_bulk.get('assignment_config_version')
    object_id_global_from_payload = payload_top_level_bulk.get('object_id') # Может быть None

    if not isinstance(results_list_from_payload, list):
        raise ApiBadRequest("Поле 'results' в теле запроса должно быть массивом (списком).")
    if not results_list_from_payload: # Если массив пуст
        logger.info("Получен пустой массив 'results' в запросе на пакетную загрузку.")
        return jsonify({"status": "success", "processed": 0, "failed": 0, "message": "Пустой массив результатов был получен и обработан."}), 200

    logger.info(f"Получено {len(results_list_from_payload)} записей для пакетной обработки. "
                f"AgentVer(глоб): {agent_version_global_from_payload}, ConfigVer(глоб): {assignment_version_global_from_payload}, OID(глоб): {object_id_global_from_payload}")

    # --- Инициализация счетчиков и списков для ответа ---
    processed_items_count_bulk = 0
    failed_items_count_bulk = 0
    errors_list_for_response: List[Dict[str, Any]] = []
    successfully_processed_assignment_ids_for_socket: set[int] = set() # Для обновления UI через SocketIO

    # Используем соединение и курсор из контекста запроса Flask (g)
    current_db_connection = g.db_conn
    current_db_cursor = current_db_connection.cursor()

    # if not current_db_connection.autocommit: current_db_connection.begin() # Явно начинаем транзакцию, если autocommit выключен

    # --- Обработка каждого результата в цикле ---
    for item_index_bulk, single_result_item_raw_bulk in enumerate(results_list_from_payload):
        # Если предыдущая ошибка БД привела к сбою транзакции, пропускаем обработку остальных
        if transaction_had_db_errors_in_bulk:
            failed_items_count_bulk += 1
            errors_list_for_response.append({
                "index": item_index_bulk,
                "assignment_id": single_result_item_raw_bulk.get('assignment_id', 'N/A_ID_in_error'),
                "error": "Обработка этого элемента пропущена из-за предыдущей ошибки транзакции базы данных."
            })
            continue # Переходим к следующему элементу

        current_assignment_id_for_log_bulk = single_result_item_raw_bulk.get('assignment_id', '[ID не указан в элементе]')
        try:
            # --- Извлечение и валидация полей для КОНКРЕТНОГО элемента (аналогично add_check_v1) ---
            if not isinstance(single_result_item_raw_bulk, dict):
                raise ValueError("Элемент результата в массиве 'results' не является объектом JSON.")
            
            # Поля из PowerShell объекта (PascalCase)
            assignment_id_item_bulk_raw = single_result_item_raw_bulk.get('assignment_id')
            is_available_item_bulk_raw = single_result_item_raw_bulk.get('IsAvailable')
            check_success_item_bulk_raw = single_result_item_raw_bulk.get('CheckSuccess')
            check_timestamp_item_bulk_str = single_result_item_raw_bulk.get('Timestamp')
            nested_details_item_bulk_obj = single_result_item_raw_bulk.get('Details')
            error_message_from_ps_item_bulk = single_result_item_raw_bulk.get('ErrorMessage')

            # Версии могут быть переопределены на уровне элемента, если есть, иначе используются глобальные
            agent_version_item_for_db = single_result_item_raw_bulk.get('agent_script_version', agent_version_global_from_payload)
            assign_version_item_for_db = single_result_item_raw_bulk.get('assignment_config_version', assignment_version_global_from_payload)
            # executor_object_id и executor_host для bulk обычно берутся из общей части .zrpu или устанавливаются лоадером
            # Здесь мы берем object_id из общей части payload'а, если он есть
            executor_object_id_item_for_db = object_id_global_from_payload # Может быть None

            # Валидация обязательных полей для элемента
            if assignment_id_item_bulk_raw is None: raise ValueError("Поле 'assignment_id' обязательно для каждой записи в пакете.")
            if is_available_item_bulk_raw is None: raise ValueError("Поле 'IsAvailable' обязательно для каждой записи в пакете.")
            
            # Приведение типов для элемента (аналогично add_check_v1)
            assignment_id_item_for_db = int(assignment_id_item_bulk_raw)
            is_available_item_for_db: bool
            if isinstance(is_available_item_bulk_raw, str): is_available_item_for_db = is_available_item_bulk_raw.lower() in ['true','1']
            elif isinstance(is_available_item_bulk_raw, bool): is_available_item_for_db = is_available_item_bulk_raw
            else: raise ValueError("Поле 'IsAvailable' элемента должно быть булевым.")

            check_success_item_for_db: Optional[bool] = None
            if check_success_item_bulk_raw is not None:
                if isinstance(check_success_item_bulk_raw, str): check_success_item_for_db = check_success_item_bulk_raw.lower() in ['true','1']
                elif isinstance(check_success_item_bulk_raw, bool): check_success_item_for_db = check_success_item_bulk_raw
                else: raise ValueError("Поле 'CheckSuccess' элемента должно быть булевым или null.")
            
            check_timestamp_item_for_db: Optional[datetime] = None
            if check_timestamp_item_bulk_str:
                # (Логика парсинга timestamp - без изменений от add_check_v1)
                try:
                    if HAS_DATEUTIL: parsed_dt_bulk_item = dateutil_parser.isoparse(check_timestamp_item_bulk_str)
                    else: # Fallback
                         ts_clean_bulk_item = check_timestamp_item_bulk_str.replace('Z','+00:00');
                         if '.' in ts_clean_bulk_item: parts_bi=ts_clean_bulk_item.split('.',1); micro_bi=parts_bi[1].split('+',1)[0].split('-',1)[0];tz_s_bi=parts_bi[1][len(micro_bi):]; ts_clean_bulk_item=f"{parts_bi[0]}.{micro_bi[:6]}{tz_s_bi}"
                         parsed_dt_bulk_item = datetime.fromisoformat(ts_clean_bulk_item)
                    if parsed_dt_bulk_item.tzinfo: check_timestamp_item_for_db = parsed_dt_bulk_item.astimezone(timezone.utc)
                    else: check_timestamp_item_for_db = parsed_dt_bulk_item.replace(tzinfo=timezone.utc)
                except Exception: check_timestamp_item_for_db = None; logger.warning(f"Ошибка парсинга Timestamp ('{check_timestamp_item_bulk_str}') для элемента {item_index_bulk} в bulk.")

            # Формирование detail_type и detail_data для элемента (аналогично add_check_v1)
            final_detail_type_item_for_db = "PIPELINE_AGGREGATED_RESULT_BULK" # Тип для элемента из bulk
            final_detail_data_item_for_db: Optional[Dict[str, Any]] = None
            if nested_details_item_bulk_obj and isinstance(nested_details_item_bulk_obj, dict):
                final_detail_data_item_for_db = nested_details_item_bulk_obj
                if error_message_from_ps_item_bulk:
                    final_detail_data_item_for_db['pipeline_overall_error_message_bulk'] = error_message_from_ps_item_bulk
                # Добавляем CheckSuccess, если он был, чтобы сохранить в деталях
                if check_success_item_for_db is not None:
                    final_detail_data_item_for_db['pipeline_overall_check_success_bulk'] = check_success_item_for_db
            elif error_message_from_ps_item_bulk:
                final_detail_data_item_for_db = {'pipeline_overall_error_message_bulk': error_message_from_ps_item_bulk}
                if check_success_item_for_db is not None:
                     final_detail_data_item_for_db['pipeline_overall_check_success_bulk'] = check_success_item_for_db
            
            # resolution_method для bulk обычно стандартный
            resolution_method_item_for_db = 'offline_loader_pipeline_bulk'

            # --- Вызов процедуры записи для текущего элемента пакета ---
            check_repository.record_check_result_proc(
                cursor=current_db_cursor,
                assignment_id=assignment_id_item_for_db,
                is_available=is_available_item_for_db,
                check_success=check_success_item_for_db, # <<< ПЕРЕДАЕМ check_success
                check_timestamp=check_timestamp_item_for_db,
                executor_object_id=executor_object_id_item_for_db, # ID объекта из .zrpu
                executor_host=None, # Обычно нет для bulk
                resolution_method=resolution_method_item_for_db,
                detail_type=final_detail_type_item_for_db,
                detail_data=final_detail_data_item_for_db,
                p_assignment_version=assign_version_item_for_db,
                p_agent_version=agent_version_item_for_db
            )
            processed_items_count_bulk += 1
            successfully_processed_assignment_ids_for_socket.add(assignment_id_item_for_db) # Для SocketIO

        except ValueError as val_err_item_processing_bulk: # Ошибки валидации для ЭТОГО элемента
            failed_items_count_bulk += 1
            errors_list_for_response.append({"index": item_index_bulk, "assignment_id": current_assign_id_log_bulk, "error": f"Ошибка валидации данных: {val_err_item_processing_bulk}"})
            logger.warning(f"Ошибка валидации элемента {item_index_bulk} (assign_id: {current_assign_id_log_bulk}) в bulk-запросе: {val_err_item_processing_bulk}")
            # Ошибка валидации НЕ должна прерывать транзакцию для других элементов, если autocommit=False
        except psycopg2.Error as db_err_item_processing_bulk: # Ошибки БД для ЭТОГО элемента
            failed_items_count_bulk += 1
            errors_list_for_response.append({"index": item_index_bulk, "assignment_id": current_assign_id_log_bulk, "error": f"Ошибка базы данных: {db_err_item_processing_bulk.pgcode} - {str(db_err_item_processing_bulk)}"})
            logger.error(f"Ошибка БД при обработке элемента {item_index_bulk} (assign_id: {current_assign_id_log_bulk}) в bulk-запросе: {db_err_item_processing_bulk}", exc_info=False) # exc_info=False, т.к. уже обработали
            transaction_had_db_errors_in_bulk = True # Ставим флаг, что транзакция БД скомпрометирована
            # if not current_db_connection.autocommit: current_db_connection.rollback(); logger.warning("Транзакция для bulk-запроса отменена из-за ошибки БД при обработке элемента. Начата новая."); current_db_connection.begin() # Откат и начало новой (если это нужно)
        except Exception as e_item_processing_bulk: # Другие непредвиденные ошибки для ЭТОГО элемента
            failed_items_count_bulk += 1
            errors_list_for_response.append({"index": item_index_bulk, "assignment_id": current_assign_id_log_bulk, "error": f"Неожиданная ошибка обработки: {type(e_item_processing_bulk).__name__}"})
            logger.exception(f"Неожиданная ошибка при обработке элемента {item_index_bulk} (assign_id: {current_assign_id_log_bulk}) в bulk-запросе.")
            transaction_had_db_errors_in_bulk = True # Непредвиденная ошибка также может повлиять на транзакцию
            # if not current_db_connection.autocommit: current_db_connection.rollback(); logger.warning("Транзакция для bulk-запроса отменена из-за неожиданной ошибки. Начата новая."); current_db_connection.begin()
    # --- Конец цикла по элементам в bulk ---

    # --- Завершение обработки всего пакета ---
    # Коммит/откат транзакции (если autocommit=False)
    # if not current_db_connection.autocommit:
    #     if transaction_had_db_errors_in_bulk:
    #         current_db_connection.rollback()
    #         logger.warning("Итоговая транзакция для bulk-запроса была отменена из-за ошибок БД при обработке некоторых элементов.")
    #         successfully_processed_assignment_ids_for_socket.clear() # Очищаем, т.к. ничего не сохранилось
    #         processed_items_count_bulk = 0 # Реально сохранено 0
    #     else:
    #         current_db_connection.commit()
    #         logger.info(f"Все {processed_items_count_bulk} успешно обработанных записей в bulk-запросе закоммичены.")

    # --- Отправка обновлений через SocketIO для успешно обработанных (если транзакция не была отменена) ---
    if socketio and not transaction_had_db_errors_in_bulk and successfully_processed_assignment_ids_for_socket:
        # (Логика SocketIO для bulk - без изменений от v7.0.5, но использует обновленный node_service)
        # ...
        try:
            node_ids_to_update_socket_bulk: set[int] = set()
            if successfully_processed_assignment_ids_for_socket: # Если есть ID заданий, для которых данные успешно записаны
                placeholders_bulk_socket = ', '.join(['%s'] * len(successfully_processed_assignment_ids_for_socket))
                sql_get_nodes_for_socket = f"SELECT DISTINCT node_id FROM node_check_assignments WHERE id IN ({placeholders_bulk_socket})"
                current_db_cursor.execute(sql_get_nodes_for_socket, tuple(list(successfully_processed_assignment_ids_for_socket)))
                node_ids_to_update_socket_bulk = {row['node_id'] for row in current_db_cursor.fetchall()}

            if node_ids_to_update_socket_bulk:
                processed_nodes_map_for_socket_bulk = {n['id']: n for n in node_service.get_processed_node_status(current_db_cursor)}
                for node_id_to_send_socket_bulk in node_ids_to_update_socket_bulk:
                    if node_id_to_send_socket_bulk in processed_nodes_map_for_socket_bulk:
                        socket_payload_for_ui_bulk = { 'node_id': node_id_to_send_socket_bulk, **processed_nodes_map_for_socket_bulk[node_id_to_send_socket_bulk] }
                        socketio.emit('node_status_update', socket_payload_for_ui_bulk)
                        logger.debug(f"SocketIO (Bulk): Отправлено обновление статуса для узла ID {node_id_to_send_socket_bulk}.")
                    else:
                        logger.warning(f"SocketIO (Bulk): Не найдены актуальные данные для узла ID {node_id_to_send_socket_bulk}. Обновление не отправлено.")
        except Exception as socket_err_bulk_send:
             logger.error(f"Ошибка при отправке обновлений SocketIO после пакетной загрузки: {socket_err_bulk_send}", exc_info=True)
    elif transaction_had_db_errors_in_bulk:
         logger.warning("Обновления UI через SocketIO пропущены из-за общей ошибки транзакции во время пакетной обработки.")

    # --- Формирование HTTP-ответа (логика без изменений от v7.0.5) ---
    # ...
    final_response_status_str_bulk = "success"
    final_http_code_bulk = 200
    if failed_items_count_bulk > 0:
        final_response_status_str_bulk = "partial_error" if processed_items_count_bulk > 0 else "error"
        final_http_code_bulk = 207 # Multi-Status
    if transaction_had_db_errors_in_bulk: # Если была ошибка БД, которая привела к откату
        final_response_status_str_bulk = "error" # Перезаписываем статус
        final_http_code_bulk = 500 if processed_items_count_bulk == 0 and failed_items_count_bulk > 0 else 207
        if not any(e_resp.get("error","").startswith("Ошибка БД") for e_resp in errors_list_for_response):
             errors_list_for_response.append({"index": -1, "error": "Произошла общая ошибка базы данных при обработке пакета. Некоторые или все записи могли не сохраниться."})

    response_payload_for_client = {
        "status": final_response_status_str_bulk,
        "processed": processed_items_count_bulk if not transaction_had_db_errors_in_bulk else 0, # Если транзакция отменена, реально 0
        "failed": failed_items_count_bulk + (len(results_list_from_payload) - processed_items_count_bulk - failed_items_count_bulk if transaction_had_db_errors_in_bulk else 0),
        "total_in_request": len(results_list_from_payload)
    }
    if errors_list_for_response:
        response_payload_for_client["errors"] = errors_list_for_response

    logger.info(f"Пакетная обработка pipeline-результатов завершена. Итоговый статус: {final_response_status_str_bulk}. "
                f"Обработано (до коммита): {processed_items_count_bulk}, Ошибки элементов: {failed_items_count_bulk}, "
                f"Ошибка БД транзакции: {transaction_had_db_errors_in_bulk}")
    return jsonify(response_payload_for_client), final_http_code_bulk


# --- Маршруты для получения истории и деталей проверок ---
# (Эти маршруты остаются без изменений от версии 7.0.5, так как их SQL-запросы
#  в репозитории уже должны быть адаптированы для выборки нового поля check_success)

@bp.route('/node_checks/<int:check_id>/details', methods=['GET'])
# @login_required # Раскомментировать, если просмотр деталей требует аутентификации UI
def api_get_node_check_details(check_id: int):
    """
    Получает детализированную информацию для конкретного результата проверки (node_check_id).
    Включает десериализацию поля 'data' из JSONB.
    """
    logger.info(f"API Check Route (v5.0.2): Запрос GET /node_checks/{check_id}/details")
    try:
        cursor = g.db_conn.cursor()
        details_list_from_repo = check_repository.fetch_check_details(cursor, check_id)

        # Пост-обработка: десериализация поля 'data', если оно пришло как строка
        # (хотя RealDictCursor с JSONB обычно сам десериализует)
        for item_detail_db in details_list_from_repo:
             if item_detail_db.get('data') and isinstance(item_detail_db['data'], str):
                  try:
                      item_detail_db['data'] = json.loads(item_detail_db['data'])
                  except json.JSONDecodeError:
                      logger.warning(f"Ошибка декодирования JSON для поля 'data' в деталях проверки ID {check_id}, тип детали: {item_detail_db.get('detail_type')}")
                      item_detail_db['data'] = {"_error_parsing_json_in_db_": "Invalid JSON string stored in database."}
        
        logger.debug(f"Для проверки ID {check_id} найдено {len(details_list_from_repo)} записей деталей.")
        return jsonify(details_list_from_repo), 200

    except psycopg2.Error as db_err_details:
        logger.error(f"Ошибка БД при получении деталей для проверки ID={check_id}: {db_err_details}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении деталей проверки.")
    except Exception as e_details:
        logger.exception(f"Неожиданная ошибка сервера при получении деталей для проверки ID={check_id}")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e_details).__name__} - {e_details}")


@bp.route('/nodes/<int:node_id>/checks_history', methods=['GET'])
# @login_required
def api_get_node_checks_history(node_id: int):
    """
    Получает историю последних N результатов проверок для указанного узла.
    Может фильтроваться по ID метода проверки. Возвращает `check_success`.
    """
    logger.info(f"API Check Route (v5.0.2): Запрос GET /nodes/{node_id}/checks_history, параметры: {request.args}")
    try:
        limit_str = request.args.get('limit', default='50'); limit = int(limit_str)
        method_id_str = request.args.get('method_id'); method_id_filter = int(method_id_str) if method_id_str else None
        
        cursor = g.db_conn.cursor()
        # Проверка существования узла
        if not node_repository.get_node_by_id(cursor, node_id): # Используем репозиторий для проверки
            raise ApiNotFound(f"Узел с ID={node_id} не найден.")
        
        history_items_from_repo = check_repository.fetch_node_checks_history(cursor, node_id, method_id_filter, limit)
        # Форматирование дат
        for item_hist_node in history_items_from_repo:
            for date_key_node in ['checked_at', 'check_timestamp']:
                 if item_hist_node.get(date_key_node) and isinstance(item_hist_node[date_key_node], datetime):
                     item_hist_node[date_key_node] = item_hist_node[date_key_node].isoformat()
        
        logger.info(f"Для узла ID={node_id} (метод: {method_id_filter or 'все'}) найдено {len(history_items_from_repo)} записей истории (лимит: {limit}).")
        return jsonify(history_items_from_repo), 200

    except ValueError: raise ApiBadRequest("Неверный формат параметра limit или method_id.") # От int()
    except psycopg2.Error as db_err_hist_node:
        logger.error(f"Ошибка БД при получении истории проверок для узла ID={node_id}: {db_err_hist_node}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении истории проверок узла.")
    except ApiException: raise # Пробрасываем ApiNotFound
    except Exception as e_hist_node:
        logger.exception(f"Неожиданная ошибка сервера при получении истории проверок для узла ID={node_id}")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e_hist_node).__name__} - {e_hist_node}")


@bp.route('/assignments/<int:assignment_id>/checks_history', methods=['GET'])
# @login_required
def api_get_assignment_checks_history(assignment_id: int):
    """
    Получает историю последних N результатов проверок для указанного задания.
    Возвращает `check_success`.
    """
    logger.info(f"API Check Route (v5.0.2): Запрос GET /assignments/{assignment_id}/checks_history, параметры: {request.args}")
    try:
        limit_str = request.args.get('limit', default='50'); limit = int(limit_str)
        
        cursor = g.db_conn.cursor()
        # Проверка существования задания
        if not assignment_repository.get_assignment_by_id(cursor, assignment_id): # Используем репозиторий
            raise ApiNotFound(f"Задание с ID={assignment_id} не найдено.")
        
        history_items_from_repo_assign = check_repository.fetch_assignment_checks_history(cursor, assignment_id, limit)
        # Форматирование дат
        for item_hist_assign in history_items_from_repo_assign:
            for date_key_assign in ['checked_at', 'check_timestamp']:
                 if item_hist_assign.get(date_key_assign) and isinstance(item_hist_assign[date_key_assign], datetime):
                     item_hist_assign[date_key_assign] = item_hist_assign[date_key_assign].isoformat()

        logger.info(f"Для задания ID={assignment_id} найдено {len(history_items_from_repo_assign)} записей истории (лимит: {limit}).")
        return jsonify(history_items_from_repo_assign), 200

    except ValueError: raise ApiBadRequest("Неверный формат параметра limit.") # От int()
    except psycopg2.Error as db_err_hist_assign:
        logger.error(f"Ошибка БД при получении истории проверок для задания ID={assignment_id}: {db_err_hist_assign}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении истории проверок задания.")
    except ApiException: raise # Пробрасываем ApiNotFound
    except Exception as e_hist_assign:
        logger.exception(f"Неожиданная ошибка сервера при получении истории проверок для задания ID={assignment_id}")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e_hist_assign).__name__} - {e_hist_assign}")