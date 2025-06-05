# status/app/routes/event_routes.py
"""
Маршруты API для работы с системными событиями (журнал).
Позволяет получать список событий с фильтрацией и добавлять новые события.
"""
import logging
import psycopg2
import json
from datetime import datetime # Для проверки типа datetime при пост-обработке
from flask import Blueprint, request, jsonify, g
from ..repositories import event_repository # Репозиторий для работы с событиями
from ..errors import ApiBadRequest, ApiInternalError, ApiValidationFailure, ApiException # Кастомные исключения
from ..auth_utils import api_key_required # Декоратор для защиты эндпоинта создания события

logger = logging.getLogger(__name__)
# Создаем Blueprint. Префикс '/api/v1/events' будет добавлен при регистрации.
bp = Blueprint('events', __name__)

@bp.route('', methods=['GET'])
# @login_required # Раскомментировать, если просмотр событий требует аутентификации пользователя UI
# @api_key_required(required_role=['admin', 'loader']) # Или защитить API-ключом, если нужно
def api_get_system_events():
    """
    Получает список системных событий с возможностью фильтрации и пагинации.

    Query Params:
        limit (int, optional): Количество записей на странице (default 100, max 500).
        offset (int, optional): Смещение для пагинации (default 0).
        severity (str, optional): Фильтр по уровню важности ('INFO', 'WARN', 'ERROR', 'CRITICAL').
        event_type (str, optional): Фильтр по точному типу события.
        object_id (int, optional): Фильтр по ID объекта (подразделения).
        node_id (int, optional): Фильтр по ID узла.
        assignment_id (int, optional): Фильтр по ID задания.
        node_check_id (int, optional): Фильтр по ID результата проверки.
        related_entity (str, optional): Фильтр по типу связанной сущности (например, 'FILE').
        related_entity_id (str, optional): Фильтр по ID связанной сущности (например, имя файла).
        start_time (str, optional): Фильтр по времени начала периода (ISO 8601).
        end_time (str, optional): Фильтр по времени конца периода (ISO 8601).
        search_text (str, optional): Поиск по текстовому полю 'message'.

    Returns:
        JSON: Объект с полями "items" (список событий) и "total_count".
    """
    logger.info(f"API Event Route: Запрос GET /api/v1/events, параметры: {request.args}")
    try:
        # --- Парсинг и валидация параметров запроса ---
        limit_str = request.args.get('limit', default='100')
        offset_str = request.args.get('offset', default='0')
        severity_filter = request.args.get('severity')
        event_type_filter = request.args.get('event_type')
        object_id_filter_str = request.args.get('object_id')
        node_id_filter_str = request.args.get('node_id')
        assignment_id_filter_str = request.args.get('assignment_id')
        node_check_id_filter_str = request.args.get('node_check_id')
        related_entity_filter = request.args.get('related_entity')
        related_entity_id_filter = request.args.get('related_entity_id')
        start_time_filter = request.args.get('start_time') # Валидация формата даты - на стороне репозитория/БД
        end_time_filter = request.args.get('end_time')
        search_text_filter = request.args.get('search_text')

        try:
            limit = int(limit_str); assert limit > 0 and limit <= 500
        except (ValueError, AssertionError): limit = 100 # Значение по умолчанию при ошибке
        try:
            offset = int(offset_str); assert offset >= 0
        except (ValueError, AssertionError): offset = 0

        object_id_filter: Optional[int] = None
        if object_id_filter_str:
            try: object_id_filter = int(object_id_filter_str)
            except ValueError: raise ApiBadRequest("Параметр 'object_id' должен быть целым числом.")
        # Аналогично для node_id, assignment_id, node_check_id
        node_id_filter: Optional[int] = None
        if node_id_filter_str:
            try: node_id_filter = int(node_id_filter_str)
            except ValueError: raise ApiBadRequest("Параметр 'node_id' должен быть целым числом.")
        assignment_id_filter: Optional[int] = None
        if assignment_id_filter_str:
            try: assignment_id_filter = int(assignment_id_filter_str)
            except ValueError: raise ApiBadRequest("Параметр 'assignment_id' должен быть целым числом.")
        node_check_id_filter: Optional[int] = None
        if node_check_id_filter_str:
            try: node_check_id_filter = int(node_check_id_filter_str)
            except ValueError: raise ApiBadRequest("Параметр 'node_check_id' должен быть целым числом.")

        if severity_filter and severity_filter.upper() not in ('INFO', 'WARN', 'ERROR', 'CRITICAL'):
             raise ApiValidationFailure("Недопустимое значение для параметра 'severity'. Допустимы: INFO, WARN, ERROR, CRITICAL.")
        if search_text_filter: search_text_filter = search_text_filter.strip()
        # --- Конец парсинга и валидации ---

        cursor = g.db_conn.cursor()
        # Вызов функции репозитория для получения событий
        event_items, total_event_count = event_repository.fetch_system_events(
            cursor,
            limit=limit, offset=offset, severity=severity_filter.upper() if severity_filter else None,
            event_type=event_type_filter, search_text=search_text_filter,
            object_id=object_id_filter, node_id=node_id_filter,
            assignment_id=assignment_id_filter, node_check_id=node_check_id_filter,
            related_entity=related_entity_filter, related_entity_id=related_entity_id_filter,
            start_time=start_time_filter, end_time=end_time_filter
        )

        # --- ПОСТ-ОБРАБОТКА для JSON ответа ---
        for item in event_items:
            # Преобразуем datetime в ISO строку
            if item.get('event_time') and isinstance(item['event_time'], datetime):
                item['event_time'] = item['event_time'].isoformat()
            # Десериализуем поле 'details', если оно является строкой JSON
            if item.get('details') and isinstance(item['details'], str):
                try:
                    item['details'] = json.loads(item['details'])
                except json.JSONDecodeError:
                    logger.warning(f"Ошибка декодирования JSON для поля 'details' в событии ID {item.get('id')}")
                    item['details'] = {"_error": "Invalid JSON in DB"}
            elif item.get('details') is None:
                 item['details'] = {} # Для консистентности, если в JS ожидается объект
        # --- КОНЕЦ ПОСТ-ОБРАБОТКИ ---

        response_data = {
            "items": event_items,
            "total_count": total_event_count,
            "limit": limit,
            "offset": offset
        }
        logger.info(f"API Event Route: Успешно отдан список системных событий. Найдено на странице: {len(event_items)}, Всего: {total_event_count}")
        return jsonify(response_data), 200

    except ValueError as val_err: # Ошибки типа параметров
        logger.warning(f"Неверный тип параметра при запросе списка событий: {val_err}")
        raise ApiBadRequest(f"Неверный тип параметра запроса: {val_err}")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении списка системных событий: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении списка системных событий.")
    except ApiException: # Пробрасываем наши кастомные ошибки
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при получении списка системных событий.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('', methods=['POST'])
@api_key_required(required_role='loader') # Только ключи с ролью 'loader' могут создавать события
def api_add_system_event():
    """
    Добавляет новое системное событие в журнал.
    Используется, например, Загрузчиком Результатов (`result_loader.ps1`) для
    логирования обработки файлов.

    JSON Body:
        - event_type (str, required): Тип события (например, 'FILE_PROCESSED').
        - message (str, required): Основное сообщение события.
        - severity (str, optional, default 'INFO'): Уровень важности ('INFO', 'WARN', 'ERROR', 'CRITICAL').
        - source (str, optional): Источник события (например, 'result_loader.ps1').
        - object_id (int, optional): ID связанного объекта (подразделения).
        - node_id (int, optional): ID связанного узла.
        - assignment_id (int, optional): ID связанного задания.
        - node_check_id (int, optional): ID связанного результата проверки.
        - related_entity (str, optional): Тип связанной сущности (например, 'ZRPU_FILE').
        - related_entity_id (str, optional): ID/имя связанной сущности (например, имя файла).
        - details (dict, optional): Дополнительные детали события в формате JSON.
    """
    logger.info("API Event Route: Запрос POST /api/v1/events (создание нового события)")
    data = request.get_json()
    if not data:
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")

    # --- Валидация входных данных ---
    errors: Dict[str, str] = {}
    event_type = data.get('event_type')
    message = data.get('message')
    severity = data.get('severity', 'INFO').upper() # По умолчанию 'INFO', приводим к верхнему регистру

    if not event_type or not str(event_type).strip():
        errors['event_type'] = "Поле 'event_type' обязательно и не может быть пустым."
    if not message or not str(message).strip():
        errors['message'] = "Поле 'message' обязательно и не может быть пустым."
    if severity not in ('INFO', 'WARN', 'ERROR', 'CRITICAL'):
         errors['severity'] = f"Недопустимое значение для 'severity': '{data.get('severity')}'. Допустимы: INFO, WARN, ERROR, CRITICAL."

    # Проверка опциональных числовых ID, если они переданы
    for id_field in ['object_id', 'node_id', 'assignment_id', 'node_check_id']:
        if id_field in data and data[id_field] is not None:
            try:
                val = int(data[id_field])
                if val < 0: errors[id_field] = f"Поле '{id_field}' не может быть отрицательным."
            except ValueError: errors[id_field] = f"Поле '{id_field}' должно быть целым числом."

    if errors:
        logger.warning(f"Ошибки валидации при создании системного события: {errors}")
        raise ApiValidationFailure("Обнаружены ошибки валидации входных данных.", details=errors)
    # --- Конец валидации ---

    try:
        cursor = g.db_conn.cursor()
        # Вызываем функцию репозитория для создания события
        # Репозиторий сам обработает `data.get('details')` для JSONB
        new_event_id = event_repository.create_system_event(cursor, data)
        if new_event_id is None: # Если репозиторий вернул None
            logger.error("Создание системного события не удалось (репозиторий вернул None). Данные: %s", data)
            raise ApiInternalError("Не удалось создать системное событие на сервере.")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Event Route: Успешно создано системное событие ID: {new_event_id}, Тип: '{event_type}', Сообщение: '{message[:50]}...'")
        return jsonify({"status": "success", "event_id": new_event_id}), 201 # HTTP 201 Created

    except ValueError as val_err: # Ошибки валидации из репозитория (если есть)
        logger.warning(f"Ошибка ValueError при создании системного события: {val_err}")
        raise ApiValidationFailure(str(val_err))
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при создании системного события: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при создании системного события.")
    except ApiException: # Пробрасываем наши кастомные ошибки
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при создании системного события.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")