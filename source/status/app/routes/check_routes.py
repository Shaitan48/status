# status/app/routes/check_routes.py
import logging
import psycopg2
import json
from datetime import datetime, timezone
from flask import Blueprint, request, jsonify, g
from ..repositories import check_repository, node_repository, assignment_repository
from ..services import node_service
from ..errors import ApiBadRequest, ApiNotFound, ApiInternalError, ApiValidationFailure, ApiException
# from ..app import socketio # <<< Убедитесь, что socketio импортируется ПРАВИЛЬНО (возможно, из app.app)
# Используем current_app вместо прямого импорта socketio, если он инициализируется в create_app
from flask import current_app
from ..db_connection import HAS_DATEUTIL
from ..auth_utils import api_key_required # Для защиты маршрута

if HAS_DATEUTIL:
    from dateutil import parser as dateutil_parser

logger = logging.getLogger(__name__)
bp = Blueprint('checks', __name__) # Префикс /api/v1 в __init__.py

# POST /api/v1/checks
@bp.route('/checks', methods=['POST'])
@api_key_required(required_role=('agent', 'loader')) # Теперь только agent или loader
def add_check_v1():
    # Используем current_app для доступа к socketio
    socketio = current_app.extensions.get('socketio')
    if not socketio:
         logger.error("SocketIO не найден в расширениях приложения!")
         # Можно продолжить без socketio или вернуть ошибку

    logger.info(f"API Check: Запрос POST /checks")
    data = request.get_json();
    if not data: raise ApiBadRequest("Missing JSON body.")
    logger.debug(f"Received check data: {data}")
    node_id_for_socket = None

    try: # Внешний try

        # --- Извлечение и валидация ---
        try: # Внутренний try для валидации входных данных
            assignment_id = data.get('assignment_id')
            is_available = data.get('is_available')
            check_timestamp_str = data.get('check_timestamp')
            executor_object_id = data.get('executor_object_id')
            executor_host = data.get('executor_host')
            resolution_method = data.get('resolution_method')
            nested_details = data.get('details') # Из старого формата online-агента
            detail_type = data.get('detail_type') # Из нового формата API
            detail_data = data.get('detail_data') # Из нового формата API

            # <<< ИЗВЛЕКАЕМ ВЕРСИИ >>>
            assignment_version = data.get('assignment_config_version') # Версия конфига
            agent_version = data.get('agent_script_version') # Версия скрипта

            # --- Валидация обязательных полей ---
            if assignment_id is None: raise ApiValidationFailure("'assignment_id' is required")
            if is_available is None: raise ApiValidationFailure("'is_available' is required")

            # Приведение типов
            assignment_id = int(assignment_id); is_available = bool(is_available)
            if executor_object_id is not None: executor_object_id = int(executor_object_id)

            # Обработка деталей из разных форматов
            if nested_details and isinstance(nested_details, dict) and detail_type is None:
                 # Пытаемся извлечь из старого формата, если новый не предоставлен
                 detail_type = nested_details.get('detail_type') # Может не быть
                 detail_data = nested_details.get('data')      # Может не быть
                 # Если detail_type не извлекся, но есть 'error' или 'info', используем их
                 if not detail_type:
                     if nested_details.get('error'):
                         detail_type = 'ERROR'
                         detail_data = {'message': nested_details['error']}
                     elif nested_details.get('info'):
                         detail_type = 'INFO'
                         detail_data = {'message': nested_details['info']}
                     elif resolution_method: # Используем имя метода как тип, если больше ничего нет
                         detail_type = resolution_method
                         detail_data = nested_details


            # --- Обработка времени --- (логика остается без изменений)
            check_timestamp = None
            if check_timestamp_str:
                 # ... (код парсинга даты с dateutil или стандартный) ...
                 # Код парсинга check_timestamp как в предыдущем ответе
                 if HAS_DATEUTIL:
                     try:
                         check_timestamp = dateutil_parser.isoparse(check_timestamp_str)
                         # Приводим к UTC
                         if check_timestamp.tzinfo: check_timestamp = check_timestamp.astimezone(timezone.utc)
                         else: check_timestamp = check_timestamp.replace(tzinfo=timezone.utc)
                     except ValueError as e_ts:
                         logger.warning(...)
                         check_timestamp = None # Используем время сервера
                 else:
                     logger.warning("dateutil not installed...")
                     try:
                         ts_str_clean = check_timestamp_str.replace('Z', '+00:00')
                         if '.' in ts_str_clean:
                             parts = ts_str_clean.split('.')
                             if len(parts) == 2:
                                 microsecond_part = parts[1].split('+')[0]
                                 if len(microsecond_part) > 6:
                                     ts_str_clean = f"{parts[0]}.{microsecond_part[:6]}{parts[1][len(microsecond_part):]}"
                         check_timestamp = datetime.fromisoformat(ts_str_clean)
                         if check_timestamp.tzinfo is None: check_timestamp = check_timestamp.replace(tzinfo=timezone.utc)
                         elif check_timestamp.tzinfo != timezone.utc: check_timestamp = check_timestamp.astimezone(timezone.utc)
                     except ValueError as e_ts_std:
                         logger.warning(...)
                         check_timestamp = None # Используем время сервера

            # --- Обработка деталей --- (логика остается)
            detail_data_for_db = None # Переименуем, чтобы не конфликтовать
            if detail_type is not None and detail_data is not None:
                 # Преобразуем в JSONB для передачи в БД
                 # Процедура ожидает JSONB, значит передаем словарь/список
                 if isinstance(detail_data, str): # Если вдруг пришел JSON строкой
                     try: detail_data_for_db = json.loads(detail_data)
                     except json.JSONDecodeError:
                          logger.warning("Не удалось распарсить detail_data как JSON строку, сохраняем как текст в объекте.");
                          detail_data_for_db = {"raw_string_data": detail_data}
                 elif isinstance(detail_data, (dict, list)):
                      detail_data_for_db = detail_data
                 else: # Если пришел примитив, оборачиваем в объект
                      logger.warning(f"detail_data имеет неожиданный тип {type(detail_data)}, оборачиваем в объект.")
                      detail_data_for_db = {"value": detail_data}
                 # Проверка на слишком большой размер JSON? (опционально)
            elif detail_type is not None and detail_data is None: detail_type = None # Сбрасываем тип
            elif detail_type is None and detail_data is not None: detail_data_for_db = None # Не сохраняем

        except (ApiValidationFailure, ApiBadRequest) as api_err: raise api_err
        except (ValueError, TypeError) as val_e: raise ApiValidationFailure(f"Data processing error: {val_e}")

        # --- Вызов репозитория ---
        cursor = g.db_conn.cursor()
        check_repository.record_check_result_proc(
            cursor,
            assignment_id=assignment_id,
            is_available=is_available,
            check_timestamp=check_timestamp,
            executor_object_id=executor_object_id,
            executor_host=executor_host,
            resolution_method=resolution_method,
            detail_type=detail_type,
            detail_data=detail_data_for_db, # Передаем подготовленный объект
            # <<< ПЕРЕДАЕМ ВЕРСИИ >>>
            p_assignment_version=assignment_version,
            p_agent_version=agent_version
        )
        # g.db_conn.commit() # Если не autocommit

        # --- Отправка SocketIO --- (логика остается)
        if socketio: # Проверяем, что socketio инициализирован
            try:
                assign_info = assignment_repository.get_assignment_by_id(cursor, assignment_id)
                if assign_info and assign_info.get('node_id'):
                    node_id_for_socket = assign_info['node_id']
                    # Используем сервисный слой для получения актуального статуса узла
                    processed_nodes = node_service.get_processed_node_status(cursor)
                    updated_node_data = next((n for n in processed_nodes if n.get('id') == node_id_for_socket), None)
                    if updated_node_data:
                        socket_data = { 'node_id': node_id_for_socket, **updated_node_data } # Передаем все данные узла
                        socketio.emit('node_status_update', socket_data)
                        logger.debug(f"SocketIO: Отправлено обновление для узла {node_id_for_socket}")
                    else: logger.warning(f"Не найдены обработанные данные для узла {node_id_for_socket} после записи результата.")
                else: logger.warning(f"Не удалось найти узел для задания {assignment_id} для отправки SocketIO.")
            except Exception as socket_err: logger.error(f"Ошибка при отправке SocketIO: {socket_err}", exc_info=True)
        else: logger.warning("SocketIO не настроен, обновление статуса не будет отправлено.")
        # --- Конец SocketIO ---

        return jsonify({"status": "success", "message": f"Result for assignment {assignment_id} accepted."}), 201

    # --- Конец внешнего блока try ---
    except ValueError as repo_val_err: # Ловим ошибку из репозитория
        if "не найдено" in str(repo_val_err): raise ApiNotFound(str(repo_val_err))
        else: raise ApiValidationFailure(str(repo_val_err))
    except psycopg2.Error as db_err: raise ApiInternalError("DB error recording check result")
    except ApiException as api_err: raise api_err
    except Exception as e:
        logger.exception(f"Неожиданная ошибка в add_check_v1") # Логируем полный traceback
        raise ApiInternalError(f"Unexpected server error: {e}")

# GET /api/v1/node_checks/<int:check_id>/details
@bp.route('/node_checks/<int:check_id>/details', methods=['GET'])
def api_get_node_check_details(check_id):
    """Получает детали проверки."""
    logger.info(f"API Check: GET /node_checks/{check_id}/details")
    try:
        cursor = g.db_conn.cursor()
        details = check_repository.fetch_check_details(cursor, check_id)
        # Пост-обработка JSON если data строка
        for item in details:
             if isinstance(item.get('data'), str):
                  try: item['data'] = json.loads(item['data'])
                  except json.JSONDecodeError: item['data'] = {"_error": "Invalid JSON in DB"}
        return jsonify(details), 200
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching check details")
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")

# GET /api/v1/nodes/<int:node_id>/checks_history
@bp.route('/nodes/<int:node_id>/checks_history', methods=['GET'])
def api_get_node_checks_history(node_id):
    """Получает историю проверок узла."""
    logger.info(f"API Check: GET /nodes/{node_id}/checks_history")
    try:
        method_id = request.args.get('method_id', type=int); limit = request.args.get('limit', default=50, type=int)
        if limit <= 0 or limit > 500: limit = 50
        cursor = g.db_conn.cursor()
        if not node_repository.get_node_by_id(cursor, node_id): raise ApiNotFound(...)
        history = check_repository.fetch_node_checks_history(cursor, node_id, method_id, limit)
        # Пост-обработка дат
        for row in history: # ... (isoformat) ...
            pass
        return jsonify(history), 200
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching node history")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")

# GET /api/v1/assignments/<int:assignment_id>/checks_history
@bp.route('/assignments/<int:assignment_id>/checks_history', methods=['GET'])
def api_get_assignment_checks_history(assignment_id):
    """Получает историю проверок задания."""
    logger.info(f"API Check: GET /assignments/{assignment_id}/checks_history")
    try:
        limit = request.args.get('limit', default=50, type=int)
        if limit <= 0 or limit > 500: limit = 50
        cursor = g.db_conn.cursor()
        if not assignment_repository.get_assignment_by_id(cursor, assignment_id): raise ApiNotFound(...)
        history = check_repository.fetch_assignment_checks_history(cursor, assignment_id, limit)
        # Пост-обработка дат
        for row in history: # ... (isoformat) ...
            pass
        return jsonify(history), 200
    except psycopg2.Error as db_err: raise ApiInternalError("DB error fetching assignment history")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Unexpected error: {e}")


@bp.route('/checks/bulk', methods=['POST']) # Новый маршрут
@api_key_required(required_role='loader') # Защищаем ключом (роль 'loader')
def add_checks_bulk_v1():
    """Принимает массив результатов проверок для пакетной загрузки."""
    socketio = current_app.extensions.get('socketio') # Доступ к socketio
    logger.info("API Check: Запрос POST /checks/bulk")
    payload = request.get_json()

    # --- Валидация входных данных ---
    if not payload or not isinstance(payload, dict):
        raise ApiBadRequest("Тело запроса должно быть JSON объектом.")

    results_list = payload.get('results')
    agent_version = payload.get('agent_script_version') # Версия из метаданных файла
    assignment_version = payload.get('assignment_config_version') # Версия из метаданных файла

    if not isinstance(results_list, list):
        raise ApiBadRequest("Поле 'results' должно быть массивом.")
    if not results_list:
        logger.warning("Получен пустой массив 'results' в bulk запросе.")
        return jsonify({"status": "success", "processed": 0, "failed": 0, "message": "Empty results array received."}), 200

    logger.info(f"Получено {len(results_list)} записей для пакетной обработки. AgentVer: {agent_version}, ConfigVer: {assignment_version}")

    # --- Обработка результатов ---
    processed_count = 0
    failed_count = 0
    errors = []
    affected_node_ids = set() # Сохраняем ID узлов для обновления по SocketIO

    conn = g.db_conn # Получаем соединение один раз
    cursor = conn.cursor()

    # Если autocommit=False, начинаем транзакцию
    # conn.begin() # Раскомментировать при autocommit=False

    for index, result_data in enumerate(results_list):
        if not isinstance(result_data, dict):
            failed_count += 1
            errors.append({"index": index, "error": "Invalid format: result item is not an object."})
            continue

        try:
            # --- Извлечение и валидация КАЖДОГО элемента ---
            assignment_id = result_data.get('assignment_id')
            is_available = result_data.get('IsAvailable') # PowerShell использует PascalCase
            check_timestamp_str = result_data.get('Timestamp') # PowerShell использует PascalCase
            detail_type = result_data.get('detail_type') # Ожидаем snake_case из нового формата
            detail_data = result_data.get('Details') # PowerShell -> Details

            # Проверяем обязательные поля ИМЕННО из PowerShell объекта
            if assignment_id is None: raise ValueError("'assignment_id' is required.")
            if is_available is None: raise ValueError("'IsAvailable' is required.")
            # Остальные поля опциональны, будут обработаны в репозитории/процедуре

            # Приведение типов
            assignment_id = int(assignment_id)
            is_available = bool(is_available)

            # Обработка времени (та же логика, что и в одиночном эндпоинте)
            check_timestamp = None
            if check_timestamp_str:
                # ... (логика парсинга даты с dateutil или стандартная) ...
                 if HAS_DATEUTIL:
                     try: check_timestamp = dateutil_parser.isoparse(check_timestamp_str).astimezone(timezone.utc)
                     except: check_timestamp = None
                 else:
                     try:
                         ts_str_clean = check_timestamp_str.replace('Z', '+00:00').split('.')[0] # Упрощенный парсинг
                         check_timestamp = datetime.fromisoformat(ts_str_clean).replace(tzinfo=timezone.utc)
                     except: check_timestamp = None

            # Обработка деталей (из поля 'Details' от PowerShell)
            detail_data_for_db = None
            # Попытка использовать 'detail_type' если оно вдруг пришло от агента
            actual_detail_type = detail_type
            if not actual_detail_type and isinstance(detail_data, dict):
                # Пытаемся угадать тип из содержимого Details
                if 'disk_letter' in detail_data: actual_detail_type = 'DISK_USAGE'
                elif 'response_time_ms' in detail_data: actual_detail_type = 'PING'
                elif 'service_name' in detail_data: actual_detail_type = 'SERVICE_STATUS'
                # ... другие угадывания ...
                elif 'certificates' in detail_data: actual_detail_type = 'CERT_EXPIRY'
                elif 'processes' in detail_data: actual_detail_type = 'PROCESS_LIST'
                elif 'extracted_data' in detail_data: actual_detail_type = 'SQL_XML_QUERY'
                elif 'query_result' in detail_data or 'row_count' in detail_data or 'scalar_value' in detail_data: actual_detail_type = 'SQL_QUERY_EXECUTE'
                elif result_data.get('ErrorMessage'): actual_detail_type = 'ERROR' # Если есть ошибка, но нет деталей
                else: actual_detail_type = result_data.get('resolution_method') or 'GENERIC_DETAIL' # Последняя попытка

            if actual_detail_type and detail_data is not None:
                 detail_data_for_db = detail_data # Передаем как есть, процедура разберется
                 if isinstance(detail_data, str): # Если это строка JSON
                      try: detail_data_for_db = json.loads(detail_data)
                      except: detail_data_for_db = {"raw_string_data": detail_data}
                 elif not isinstance(detail_data, (dict, list)):
                      detail_data_for_db = {"value": detail_data}

            # --- Вызов процедуры записи ---
            # Передаем версии из payload верхнего уровня!
            check_repository.record_check_result_proc(
                cursor,
                assignment_id=assignment_id,
                is_available=is_available,
                check_timestamp=check_timestamp,
                executor_object_id=None, # Оффлайн не знает этого
                executor_host=None,      # Оффлайн не знает этого
                resolution_method='offline_loader', # Указываем источник
                detail_type=actual_detail_type,
                detail_data=detail_data_for_db,
                p_assignment_version=assignment_version,
                p_agent_version=agent_version
            )
            processed_count += 1

            # Запоминаем ID узла, если запись прошла успешно
            # Нужно получить node_id из assignment_id
            try:
                assign_info = assignment_repository.get_assignment_by_id(cursor, assignment_id)
                if assign_info and assign_info.get('node_id'):
                    affected_node_ids.add(assign_info['node_id'])
            except Exception as e_node_fetch:
                logger.warning(f"Не удалось получить node_id для assignment {assignment_id}: {e_node_fetch}")


        except (ValueError, TypeError) as val_err:
            failed_count += 1
            errors.append({"index": index, "assignment_id": result_data.get('assignment_id'), "error": f"Validation Error: {val_err}"})
            logger.warning(f"Ошибка валидации элемента {index} в bulk запросе: {val_err}")
            # conn.rollback() # Откатываем, если autocommit=False И мы хотим строгую транзакционность
        except psycopg2.Error as db_err:
            failed_count += 1
            errors.append({"index": index, "assignment_id": result_data.get('assignment_id'), "error": f"Database Error: {db_err.pgcode} - {db_err}"})
            logger.error(f"Ошибка БД при обработке элемента {index} (assign_id: {result_data.get('assignment_id')}) в bulk запросе: {db_err}", exc_info=True)
            # conn.rollback() # Откатываем, если autocommit=False
        except Exception as e:
            failed_count += 1
            errors.append({"index": index, "assignment_id": result_data.get('assignment_id'), "error": f"Unexpected Error: {e}"})
            logger.exception(f"Неожиданная ошибка при обработке элемента {index} (assign_id: {result_data.get('assignment_id')}) в bulk запросе")
            # conn.rollback() # Откатываем, если autocommit=False

    # --- Завершение обработки ---
    # if not conn.autocommit:
    #    conn.commit() # Коммитим всю пачку, если не было отката

    # --- Отправка обновлений через SocketIO ---
    if socketio and affected_node_ids:
        try:
            processed_nodes_map = {n['id']: n for n in node_service.get_processed_node_status(cursor)}
            for node_id in affected_node_ids:
                if node_id in processed_nodes_map:
                    socket_data = { 'node_id': node_id, **processed_nodes_map[node_id] }
                    socketio.emit('node_status_update', socket_data)
                    logger.debug(f"SocketIO (Bulk): Отправлено обновление для узла {node_id}")
                else:
                    logger.warning(f"SocketIO (Bulk): Не найдены обработанные данные для узла {node_id}")
        except Exception as socket_err:
             logger.error(f"Ошибка при отправке SocketIO после bulk: {socket_err}", exc_info=True)

    # --- Формирование ответа ---
    response_status = "success"
    response_code = 200
    if failed_count > 0:
        response_status = "partial_error" if processed_count > 0 else "error"
        response_code = 207 # Multi-Status
        logger.warning(f"Пакетная обработка завершена с {failed_count} ошибками.")

    response_data = {
        "status": response_status,
        "processed": processed_count,
        "failed": failed_count,
        "total_in_request": len(results_list)
    }
    if errors:
        response_data["errors"] = errors

    logger.info(f"Пакетная обработка завершена. Успешно: {processed_count}, Ошибки: {failed_count}")
    return jsonify(response_data), response_code