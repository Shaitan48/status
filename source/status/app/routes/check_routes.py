# status/app/routes/check_routes.py
import logging
import psycopg2
import json
from datetime import datetime, timezone
from flask import Blueprint, request, jsonify, g, current_app
from typing import Optional, Any

# Импортируем зависимости
from ..repositories import check_repository, node_repository, assignment_repository
from ..services import node_service
from ..errors import ApiBadRequest, ApiNotFound, ApiInternalError, ApiValidationFailure, ApiException, ApiUnauthorized
from ..db_connection import HAS_DATEUTIL
from ..auth_utils import api_key_required

# Условный импорт dateutil
if HAS_DATEUTIL:
    from dateutil import parser as dateutil_parser

logger = logging.getLogger(__name__)
# Создаем Blueprint для маршрутов, связанных с проверками
bp = Blueprint('checks', __name__) # Префикс /api/v1 добавится при регистрации

# --- Маршрут для приема ОДИНОЧНОГО результата проверки ---
@bp.route('/checks', methods=['POST'])
@api_key_required(required_role=('agent', 'loader')) # Доступен для агентов и загрузчиков
def add_check_v1():
    """
    Принимает и записывает один результат проверки.
    Ожидает JSON в теле запроса.
    Вызывает хранимую процедуру для записи в БД.
    Отправляет обновление статуса узла через SocketIO при успехе.
    """
    socketio = current_app.extensions.get('socketio') # Получаем экземпляр SocketIO из контекста приложения
    if not socketio:
         logger.error("SocketIO не найден в расширениях приложения!") # Логируем, если SocketIO не инициализирован

    logger.info(f"API Check: Запрос POST /checks")
    data = request.get_json()
    if not data:
        raise ApiBadRequest("Missing JSON body.") # Ошибка, если нет тела или не JSON

    logger.debug(f"Получены данные проверки: {data}")
    node_id_for_socket = None # ID узла для отправки обновления через сокет

    try: # Внешний try для перехвата общих ошибок
        # --- Извлечение и валидация данных из запроса ---
        try: # Внутренний try для ошибок валидации конкретных полей
            assignment_id = data.get('assignment_id')
            is_available_raw = data.get('is_available') # Получаем как есть
            check_timestamp_str = data.get('check_timestamp')
            executor_object_id = data.get('executor_object_id')
            executor_host = data.get('executor_host')
            resolution_method = data.get('resolution_method')
            # Поля для версий
            assignment_version = data.get('assignment_config_version')
            agent_version = data.get('agent_script_version')
            # Поля для деталей (поддержка старого и нового форматов)
            nested_details = data.get('details') # Старый формат { "details": { "detail_type": "...", "data": ... } }
            detail_type = data.get('detail_type') # Новый формат - тип детали верхнего уровня
            detail_data = data.get('detail_data') # Новый формат - данные детали верхнего уровня

            # Валидация обязательных полей
            if assignment_id is None:
                raise ApiValidationFailure("'assignment_id' is required")
            if is_available_raw is None: # Проверяем именно на None, т.к. False - валидное значение
                raise ApiValidationFailure("'is_available' is required")

            # Приведение типов (с проверками)
            try: assignment_id = int(assignment_id)
            except (ValueError, TypeError): raise ValueError("'assignment_id' must be an integer")

            # Преобразование is_available в bool
            if isinstance(is_available_raw, str):
                is_available = is_available_raw.lower() in ['true', '1', 'yes', 'on']
            elif isinstance(is_available_raw, (int, float)):
                 is_available = bool(is_available_raw)
            elif isinstance(is_available_raw, bool):
                 is_available = is_available_raw
            else: raise ValueError("'is_available' must be a boolean (or interpretable as one)")

            if executor_object_id is not None:
                try: executor_object_id = int(executor_object_id)
                except (ValueError, TypeError): raise ValueError("'executor_object_id' must be an integer if provided")

            # Обработка деталей: приоритет у нового формата
            actual_detail_type = detail_type
            actual_detail_data = detail_data
            if actual_detail_type is None and nested_details and isinstance(nested_details, dict):
                 # Пытаемся извлечь из старого формата, если новый не предоставлен
                 actual_detail_type = nested_details.get('detail_type')
                 actual_detail_data = nested_details.get('data')
                 # Если тип не извлекся, но есть сообщение об ошибке/инфо, используем их
                 if not actual_detail_type:
                     if nested_details.get('error'):
                         actual_detail_type = 'ERROR'
                         actual_detail_data = {'message': nested_details['error']}
                     elif nested_details.get('info'):
                         actual_detail_type = 'INFO'
                         actual_detail_data = {'message': nested_details['info']}
                     elif resolution_method: # Последняя попытка - имя метода
                         actual_detail_type = resolution_method.upper() if resolution_method else "GENERIC_DETAIL"
                         actual_detail_data = nested_details # Сохраняем весь объект details

            # Обработка времени агента (timestamp)
             # --- Обработка времени агента (timestamp) ---
            check_timestamp = None # Инициализируем
            if check_timestamp_str:
                try:
                    # Пытаемся использовать dateutil, если он есть
                    if HAS_DATEUTIL:
                        check_timestamp = dateutil_parser.isoparse(check_timestamp_str)
                        logger.debug(f"Parsed timestamp with dateutil: {check_timestamp.isoformat()}")
                    else:
                        # Используем стандартный парсер, если dateutil нет
                        # Убираем 'Z' и обрезаем микросекунды до 6 знаков
                        ts_str_clean = check_timestamp_str.replace('Z', '+00:00')
                        if '.' in ts_str_clean:
                            parts = ts_str_clean.split('.')
                            if len(parts) == 2:
                                microsecond_part = parts[1].split('+')[0].split('-')[0]
                                if len(microsecond_part) > 6:
                                    timezone_part = parts[1][len(microsecond_part):]
                                    ts_str_clean = f"{parts[0]}.{microsecond_part[:6]}{timezone_part}"
                        check_timestamp = datetime.fromisoformat(ts_str_clean)
                        logger.debug(f"Parsed timestamp with standard lib: {check_timestamp.isoformat()}")

                    # Приводим к UTC, если нужно
                    if check_timestamp.tzinfo:
                        check_timestamp = check_timestamp.astimezone(timezone.utc)
                    else: # Если нет информации о зоне, считаем UTC
                        check_timestamp = check_timestamp.replace(tzinfo=timezone.utc)

                except Exception as e_ts: # Ловим ЛЮБУЮ ошибку парсинга
                    # <<< ДОБАВЛЯЕМ ЯВНЫЙ ЛОГ ОШИБКИ ПАРСИНГА >>>
                    logger.error(f"ОШИБКА парсинга check_timestamp '{check_timestamp_str}': {e_ts}. Будет использовано время сервера.", exc_info=False) # Не нужен полный стектрейс здесь
                    check_timestamp = None # Явно ставим None при ошибке
            else:
                 logger.debug("Поле check_timestamp не предоставлено.")

            # Обработка detail_data для передачи в JSONB
            detail_data_for_db = None
            if actual_detail_type is not None and actual_detail_data is not None:
                # psycopg2 умеет сам преобразовывать dict/list в JSONB,
                # но для передачи в процедуру через %s безопаснее передать строку
                # или убедиться, что тип поддерживается адаптером psycopg2.
                # Передаем Python объект, процедура использует `::jsonb`.
                if isinstance(actual_detail_data, str):
                    try: detail_data_for_db = json.loads(actual_detail_data) # Попытка распарсить, если пришла строка JSON
                    except json.JSONDecodeError:
                        logger.warning("Не удалось распарсить detail_data как JSON строку, сохраняем как текст.")
                        detail_data_for_db = {"raw_string_data": actual_detail_data}
                elif isinstance(actual_detail_data, (dict, list)):
                    detail_data_for_db = actual_detail_data # Передаем как есть
                else: # Если пришел примитивный тип, оборачиваем
                    logger.warning(f"detail_data имеет неожиданный тип {type(actual_detail_data)}, оборачиваем.")
                    detail_data_for_db = {"value": actual_detail_data}
                # Проверка размера JSON (опционально)
                # if detail_data_for_db and len(json.dumps(detail_data_for_db)) > MAX_DETAIL_SIZE:
                #    raise ApiValidationFailure("Размер detail_data превышает лимит.")
            elif actual_detail_type is not None and actual_detail_data is None:
                actual_detail_type = None # Если есть тип, но нет данных, тип не сохраняем
            # Если тип null, а данные есть, данные не сохраняем (detail_data_for_db остается None)

        except (ApiValidationFailure, ApiBadRequest) as api_err:
            raise api_err # Пробрасываем ошибки валидации
        except (ValueError, TypeError) as val_e:
            # Преобразуем другие ошибки типов/значений в ошибку валидации
            raise ApiValidationFailure(f"Ошибка обработки данных: {val_e}")

        # --- Вызов репозитория и хранимой процедуры ---
        cursor = g.db_conn.cursor()
        check_repository.record_check_result_proc(
            cursor,
            assignment_id=assignment_id,
            is_available=is_available,
            check_timestamp=check_timestamp,
            executor_object_id=executor_object_id,
            executor_host=executor_host,
            resolution_method=resolution_method,
            detail_type=actual_detail_type,
            detail_data=detail_data_for_db, # Передаем подготовленный объект
            p_assignment_version=assignment_version, # Передаем версии
            p_agent_version=agent_version
        )
        # g.db_conn.commit() # Коммит не нужен при autocommit=True

        # --- Отправка обновления статуса узла через SocketIO ---
        if socketio:
            try:
                # Получаем ID узла, связанного с этим заданием
                assign_info = assignment_repository.get_assignment_by_id(cursor, assignment_id)
                if assign_info and assign_info.get('node_id'):
                    node_id_for_socket = assign_info['node_id']
                    # Получаем актуальный ОБРАБОТАННЫЙ статус узла через сервисный слой
                    # Передаем курсор, чтобы использовать ту же транзакцию (если она есть)
                    processed_nodes = node_service.get_processed_node_status(cursor)
                    updated_node_data = next((n for n in processed_nodes if n.get('id') == node_id_for_socket), None)

                    if updated_node_data:
                        # Формируем данные для отправки по сокету
                        # Включаем ID узла и все поля из get_processed_node_status
                        socket_data = { 'node_id': node_id_for_socket, **updated_node_data }
                        socketio.emit('node_status_update', socket_data)
                        logger.debug(f"SocketIO: Отправлено обновление для узла {node_id_for_socket}")
                    else:
                        logger.warning(f"Не найдены обработанные данные для узла {node_id_for_socket} после записи результата.")
                else:
                    logger.warning(f"Не удалось найти узел для задания {assignment_id} для отправки SocketIO.")
            except Exception as socket_err:
                logger.error(f"Ошибка при отправке SocketIO: {socket_err}", exc_info=True)
        else:
            logger.warning("SocketIO не настроен, обновление статуса не будет отправлено.")
        # --- Конец блока SocketIO ---

        return jsonify({"status": "success", "message": f"Result for assignment {assignment_id} accepted."}), 201

    # --- Конец внешнего блока try ---
    except ValueError as repo_val_err:
        # Перехватываем ValueError, выброшенный из репозитория (например, "Задание не найдено")
        if "не найдено" in str(repo_val_err):
            raise ApiNotFound(str(repo_val_err)) # Преобразуем в 404
        else:
            raise ApiValidationFailure(str(repo_val_err)) # Другие ValueError - как ошибки валидации
    except psycopg2.Error as db_err:
        # Обрабатываем ошибки БД
        raise ApiInternalError("DB error recording check result")
    except ApiException as api_err:
        # Пробрасываем наши кастомные API ошибки дальше
        raise api_err
    except Exception as e:
        # Ловим все остальные непредвиденные ошибки
        logger.exception(f"Неожиданная ошибка в add_check_v1")
        raise ApiInternalError(f"Unexpected server error: {e}")


# --- Маршрут для ПАКЕТНОЙ загрузки результатов ---
@bp.route('/checks/bulk', methods=['POST'])
@api_key_required(required_role='loader') # Доступен только для загрузчиков
def add_checks_bulk_v1():
    """
    Принимает массив результатов проверок для пакетной загрузки.
    Обрабатывает каждую запись индивидуально внутри одной транзакции (если autocommit=False).
    Возвращает статус 207 Multi-Status в случае частичных ошибок.
    """
    socketio = current_app.extensions.get('socketio')
    logger.info("API Check: Запрос POST /checks/bulk")
    payload = request.get_json()
    transaction_failed = False # Флаг, указывающий на сбой транзакции БД

    # --- Валидация входных данных верхнего уровня ---
    if not payload or not isinstance(payload, dict):
        raise ApiBadRequest("Тело запроса должно быть JSON объектом.")

    results_list = payload.get('results')
    agent_version = payload.get('agent_script_version') # Версия из файла
    assignment_version = payload.get('assignment_config_version') # Версия из файла

    if not isinstance(results_list, list):
        raise ApiBadRequest("Поле 'results' должно быть массивом.")
    if not results_list:
        logger.warning("Получен пустой массив 'results' в bulk запросе.")
        return jsonify({"status": "success", "processed": 0, "failed": 0, "message": "Empty results array received."}), 200

    logger.info(f"Получено {len(results_list)} записей для пакетной обработки. AgentVer: {agent_version}, ConfigVer: {assignment_version}")

    # --- Обработка каждого результата в цикле ---
    processed_count = 0
    failed_count = 0
    errors = [] # Список ошибок для ответа 207
    successfully_processed_assignment_ids = set() # Сохраняем ID заданий для SocketIO

    conn = g.db_conn # Используем соединение из контекста запроса
    cursor = conn.cursor()

    # conn.begin() # Начать транзакцию, если autocommit=False

    for index, result_data in enumerate(results_list):
        # Если предыдущая ошибка вызвала сбой транзакции, пропускаем остальные
        if transaction_failed:
            failed_count += 1
            errors.append({"index": index, "assignment_id": result_data.get('assignment_id'), "error": "Skipped due to previous transaction error."})
            continue

        # Валидация формата элемента массива
        if not isinstance(result_data, dict):
            failed_count += 1
            errors.append({"index": index, "error": "Invalid format: result item is not an object."})
            # Ошибка формата не должна ломать транзакцию, но считаем ее как failed
            continue

        try:
            # --- Извлечение и валидация данных КОНКРЕТНОГО элемента ---
            # Поля из PowerShell объекта (PascalCase)
            assignment_id = result_data.get('assignment_id')
            is_available_raw = result_data.get('IsAvailable')
            check_timestamp_str = result_data.get('Timestamp')
            nested_details = result_data.get('Details') # Основной источник деталей от PowerShell
            error_message_from_ps = result_data.get('ErrorMessage') # Ошибка от скрипта PowerShell

            # Проверка обязательных полей
            if assignment_id is None: raise ValueError("'assignment_id' is required.")
            if is_available_raw is None: raise ValueError("'IsAvailable' is required.")

            # Приведение типов
            assignment_id = int(assignment_id)
            # Преобразование is_available в bool
            if isinstance(is_available_raw, str): is_available = is_available_raw.lower() in ['true', '1']
            elif isinstance(is_available_raw, (int, float)): is_available = bool(is_available_raw)
            elif isinstance(is_available_raw, bool): is_available = is_available_raw
            else: raise ValueError("'IsAvailable' must be a boolean")

            # Обработка времени (аналогично одиночному)
            check_timestamp = None
            if check_timestamp_str:
                # ... (скопировать/вынести логику парсинга timestamp из add_check_v1) ...
                if HAS_DATEUTIL:
                     try: check_timestamp = dateutil_parser.isoparse(check_timestamp_str).astimezone(timezone.utc)
                     except: check_timestamp = None
                else:
                     try:
                         ts_str_clean = check_timestamp_str.replace('Z', '+00:00').split('.')[0] # Упрощенный
                         check_timestamp = datetime.fromisoformat(ts_str_clean).replace(tzinfo=timezone.utc)
                     except: check_timestamp = None


            # Обработка деталей (из поля 'Details' PowerShell)
            detail_data_for_db = None
            actual_detail_type = None
            if nested_details and isinstance(nested_details, dict):
                # Пытаемся угадать тип по содержимому, если PowerShell его не передал явно
                # Это хрупкая логика, лучше если PS будет передавать тип!
                if 'response_time_ms' in nested_details: actual_detail_type = 'PING'
                elif 'status' in nested_details and 'display_name' in nested_details: actual_detail_type = 'SERVICE_STATUS'
                elif 'disks' in nested_details and isinstance(nested_details['disks'], list): actual_detail_type = 'DISK_USAGE'
                elif 'processes' in nested_details and isinstance(nested_details['processes'], list): actual_detail_type = 'PROCESS_LIST'
                elif 'certificates' in nested_details and isinstance(nested_details['certificates'], list): actual_detail_type = 'CERT_EXPIRY'
                elif 'extracted_data' in nested_details: actual_detail_type = 'SQL_XML_QUERY'
                elif 'query_result' in nested_details or 'row_count' in nested_details or 'scalar_value' in nested_details: actual_detail_type = 'SQL_QUERY_EXECUTE'
                # Добавляем 'CheckSuccess' и 'ErrorMessage' из PowerShell в детали
                if 'CheckSuccess' in result_data: nested_details['CheckSuccess'] = result_data['CheckSuccess']
                if error_message_from_ps: nested_details['ErrorMessageFromPS'] = error_message_from_ps
                detail_data_for_db = nested_details # Передаем весь объект Details
            elif error_message_from_ps: # Если деталей нет, но есть ошибка от PS
                actual_detail_type = 'ERROR'
                detail_data_for_db = {'message': error_message_from_ps}

            # Если тип так и не определен, ставим заглушку
            if not actual_detail_type: actual_detail_type = 'GENERIC_DETAIL'

            # --- Вызов процедуры записи ---
            # Передаем версии из payload верхнего уровня
            check_repository.record_check_result_proc(
                cursor,
                assignment_id=assignment_id,
                is_available=is_available,
                check_timestamp=check_timestamp,
                executor_object_id=None, # Оффлайн не передает
                executor_host=None,      # Оффлайн не передает
                resolution_method='offline_loader', # Указываем источник
                detail_type=actual_detail_type,
                detail_data=detail_data_for_db,
                p_assignment_version=assignment_version,
                p_agent_version=agent_version
            )
            processed_count += 1
            successfully_processed_assignment_ids.add(assignment_id) # Добавляем ID для SocketIO

        except ValueError as val_err: # Ошибки валидации для ЭТОЙ записи
            failed_count += 1
            errors.append({"index": index, "assignment_id": result_data.get('assignment_id'), "error": f"Validation Error: {val_err}"})
            logger.warning(f"Ошибка валидации элемента {index} в bulk запросе: {val_err}")
            # Ошибка валидации НЕ должна ломать транзакцию БД
        except psycopg2.Error as db_err: # Ошибки БД для ЭТОЙ записи
            failed_count += 1
            errors.append({"index": index, "assignment_id": result_data.get('assignment_id'), "error": f"Database Error: {db_err.pgcode} - {db_err}"})
            logger.error(f"Ошибка БД при обработке элемента {index} (assign_id: {result_data.get('assignment_id')}) в bulk запросе: {db_err}", exc_info=False)
            # Ошибка БД -> транзакция сломана
            transaction_failed = True
            # conn.rollback() # Если autocommit=False, откатываем СРАЗУ
        except Exception as e: # Другие ошибки для ЭТОЙ записи
            failed_count += 1
            errors.append({"index": index, "assignment_id": result_data.get('assignment_id'), "error": f"Unexpected Error: {e}"})
            logger.exception(f"Неожиданная ошибка при обработке элемента {index} (assign_id: {result_data.get('assignment_id')}) в bulk запросе")
            # Неожиданная ошибка -> считаем транзакцию сломанной
            transaction_failed = True
            # conn.rollback() # Если autocommit=False

    # --- Завершение обработки пакета ---
    # if not conn.autocommit and not transaction_failed:
    #    conn.commit() # Коммитим только если НЕ было ошибок БД
    # elif not conn.autocommit and transaction_failed:
    #    # Уже откатили в цикле или откатится в teardown_appcontext
    #    logger.warning("Транзакция bulk-запроса была отменена из-за ошибок БД.")
    #    pass

    # --- Отправка обновлений через SocketIO ---
    if socketio and not transaction_failed and successfully_processed_assignment_ids:
        try:
            # Получаем ID узлов для успешно обработанных заданий
            node_ids_to_update = set()
            if successfully_processed_assignment_ids:
                # Формируем плейсхолдеры %s для каждого ID
                placeholders = ', '.join(['%s'] * len(successfully_processed_assignment_ids))
                sql_nodes = f"SELECT DISTINCT node_id FROM node_check_assignments WHERE id IN ({placeholders})"
                # Передаем ID как кортеж
                cursor.execute(sql_nodes, tuple(successfully_processed_assignment_ids))
                node_ids_to_update = {row['node_id'] for row in cursor.fetchall()}

            # Получаем актуальные статусы этих узлов
            if node_ids_to_update:
                processed_nodes_map = {n['id']: n for n in node_service.get_processed_node_status(cursor)}
                for node_id in node_ids_to_update:
                    if node_id in processed_nodes_map:
                        socket_data = { 'node_id': node_id, **processed_nodes_map[node_id] }
                        socketio.emit('node_status_update', socket_data)
                        logger.debug(f"SocketIO (Bulk): Отправлено обновление для узла {node_id}")
                    else:
                        logger.warning(f"SocketIO (Bulk): Не найдены обработанные данные для узла {node_id}")
        except Exception as socket_err:
             logger.error(f"Ошибка при отправке SocketIO после bulk: {socket_err}", exc_info=True)
    elif transaction_failed:
         logger.warning("SocketIO update skipped due to transaction error during bulk processing.")

    # --- Формирование HTTP ответа ---
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

# --- Маршруты для получения деталей и истории (уже существуют, можно оставить здесь или вынести) ---

@bp.route('/node_checks/<int:check_id>/details', methods=['GET'])
def api_get_node_check_details(check_id):
    """Получает детали конкретной проверки по её ID."""
    logger.info(f"API Check: GET /node_checks/{check_id}/details")
    try:
        cursor = g.db_conn.cursor()
        details = check_repository.fetch_check_details(cursor, check_id)
        # Пост-обработка JSON, если data приходит строкой
        for item in details:
             if isinstance(item.get('data'), str):
                  try: item['data'] = json.loads(item['data'])
                  except json.JSONDecodeError: item['data'] = {"_error": "Invalid JSON in DB"}
        return jsonify(details), 200
    except psycopg2.Error as db_err:
        raise ApiInternalError("DB error fetching check details")
    except Exception as e:
        raise ApiInternalError(f"Unexpected error fetching check details: {e}")

@bp.route('/nodes/<int:node_id>/checks_history', methods=['GET'])
def api_get_node_checks_history(node_id):
    """Получает историю последних N проверок для указанного узла."""
    logger.info(f"API Check: GET /nodes/{node_id}/checks_history")
    try:
        # Получение параметров запроса
        method_id = request.args.get('method_id', type=int)
        limit = request.args.get('limit', default=50, type=int)
        if limit <= 0 or limit > 500: limit = 50 # Ограничение лимита

        cursor = g.db_conn.cursor()
        # Проверка существования узла (опционально, но желательно)
        node_exists = node_repository.get_node_by_id(cursor, node_id)
        if not node_exists: raise ApiNotFound(f"Node with id={node_id} not found")

        history = check_repository.fetch_node_checks_history(cursor, node_id, method_id, limit)
        # Пост-обработка дат в ISO формат
        for row in history:
            for key in ['checked_at', 'check_timestamp']:
                 if key in row and isinstance(row[key], datetime):
                     row[key] = row[key].isoformat()
        return jsonify(history), 200
    except psycopg2.Error as db_err:
        raise ApiInternalError("DB error fetching node history")
    except ApiException as api_err: # Ловим ApiNotFound
        raise api_err
    except Exception as e:
        raise ApiInternalError(f"Unexpected error fetching node history: {e}")

@bp.route('/assignments/<int:assignment_id>/checks_history', methods=['GET'])
def api_get_assignment_checks_history(assignment_id):
    """Получает историю последних N проверок для указанного задания."""
    logger.info(f"API Check: GET /assignments/{assignment_id}/checks_history")
    try:
        limit = request.args.get('limit', default=50, type=int)
        if limit <= 0 or limit > 500: limit = 50

        cursor = g.db_conn.cursor()
        # Проверка существования задания (опционально)
        assign_exists = assignment_repository.get_assignment_by_id(cursor, assignment_id)
        if not assign_exists: raise ApiNotFound(f"Assignment with id={assignment_id} not found")

        history = check_repository.fetch_assignment_checks_history(cursor, assignment_id, limit)
        # Пост-обработка дат
        for row in history:
            for key in ['checked_at', 'check_timestamp']:
                 if key in row and isinstance(row[key], datetime):
                     row[key] = row[key].isoformat()
        return jsonify(history), 200
    except psycopg2.Error as db_err:
        raise ApiInternalError("DB error fetching assignment history")
    except ApiException as api_err: # Ловим ApiNotFound
        raise api_err
    except Exception as e:
        raise ApiInternalError(f"Unexpected error fetching assignment history: {e}")