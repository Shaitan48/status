# status/app/routes/subdivision_routes.py
"""
Маршруты API для управления Подразделениями (Subdivisions).
Включает CRUD-операции для иерархической структуры подразделений.
"""
import logging
import psycopg2
from flask import Blueprint, request, jsonify, g
from typing import Optional, Dict, Any
from ..repositories import subdivision_repository # Репозиторий для работы с подразделениями
from ..errors import (
    ApiBadRequest,
    ApiNotFound,
    ApiConflict,
    ApiInternalError,
    ApiValidationFailure,
    ApiException
)
from flask_login import login_required # Защита маршрутов

logger = logging.getLogger(__name__)
# Создаем Blueprint. Префикс '/api/v1/subdivisions' будет добавлен при регистрации.
bp = Blueprint('subdivisions', __name__)

@bp.route('', methods=['GET'])
@login_required # Только авторизованные пользователи
def api_get_all_subdivisions():
    """
    Получает список всех подразделений с возможностью фильтрации и пагинации.

    Query Params:
        limit (int, optional): Количество записей.
        offset (int, optional): Смещение.
        parent_id (int/str, optional): Фильтр по ID родительского подразделения.
                                       Значение 'root' или '0' для корневых.
        search_text (str, optional): Поиск по короткому или полному имени.
    Returns:
        JSON: Объект с полями "items" (список подразделений) и "total_count".
    """
    full_path = request.full_path if request else "/api/v1/subdivisions (путь не определен)"
    logger.info(f"API Subdivision Route: Запрос GET {full_path} (список подразделений)")
    try:
        # --- Парсинг и валидация параметров запроса ---
        limit_str = request.args.get('limit')
        offset_str = request.args.get('offset', default='0')
        parent_id_str = request.args.get('parent_id')
        search_text_filter = request.args.get('search_text')

        limit: Optional[int] = None
        if limit_str is not None:
            try: limit = int(limit_str); assert limit > 0
            except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'limit' должен быть положительным целым числом.")
            if limit > 200: limit = 200 # Ограничение максимального размера страницы

        try: offset = int(offset_str); assert offset >= 0
        except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'offset' должен быть неотрицательным целым числом.")

        parent_id_filter: Optional[int] = None # Для передачи в репозиторий (0 или ID)
        if parent_id_str is not None:
            if parent_id_str.lower() == 'root' or parent_id_str == '0':
                parent_id_filter = 0 # Специальное значение для корневых (репозиторий должен обработать как parent_id IS NULL)
            else:
                try:
                    parent_id_filter = int(parent_id_str)
                    if parent_id_filter <= 0: # ID должны быть > 0, 0 - для корневых
                         raise ApiBadRequest("ID родительского подразделения должен быть положительным числом, или 'root'/'0' для корневых.")
                except ValueError:
                    raise ApiBadRequest("Параметр 'parent_id' должен быть целым числом или строкой 'root'/'0'.")
        if search_text_filter: search_text_filter = search_text_filter.strip()
        # --- Конец парсинга и валидации ---

        cursor = g.db_conn.cursor()
        # Вызов функции репозитория для получения списка
        subdivision_items, total_subdivision_count = subdivision_repository.fetch_subdivisions(
            cursor,
            limit=limit, offset=offset,
            parent_id=parent_id_filter, # Передаем 0 для корневых или ID
            search_text=search_text_filter
        )
        logger.info(f"API Subdivision Route: Успешно получен список подразделений. "
                    f"Найдено на странице: {len(subdivision_items)}, Всего (с фильтрами): {total_subdivision_count}")
        return jsonify({"items": subdivision_items, "total_count": total_subdivision_count, "limit": limit, "offset": offset}), 200

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении списка подразделений: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении списка подразделений.")
    except ApiException: # Пробрасываем ApiBadRequest
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при получении списка подразделений.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('', methods=['POST'])
@login_required # Только авторизованные пользователи
def api_create_subdivision():
    """
    Создает новое подразделение.
    Принимает JSON-тело с полями подразделения.
    'object_id' и 'short_name' - обязательные.
    """
    logger.info("API Subdivision Route: Запрос POST /api/v1/subdivisions (создание нового подразделения)")
    data_from_request = request.get_json()
    if not data_from_request:
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")

    # --- Валидация обязательных и опциональных полей ---
    errors: Dict[str, str] = {}
    if data_from_request.get('object_id') is None: # object_id обязателен и может быть 0
        errors['object_id'] = "Поле 'object_id' является обязательным."
    else:
        try:
            obj_id = int(data_from_request['object_id'])
            # if obj_id < 0: errors['object_id'] = "ObjectID не может быть отрицательным." # Может быть 0? Если да, то проверка не нужна.
        except ValueError: errors['object_id'] = "Поле 'object_id' должно быть целым числом."

    if not data_from_request.get('short_name') or not str(data_from_request['short_name']).strip():
        errors['short_name'] = "Поле 'short_name' (короткое имя) является обязательным."
    elif len(str(data_from_request['short_name'])) > 100:
        errors['short_name'] = "Короткое имя не должно превышать 100 символов."

    # Валидация parent_id, если передан
    parent_id_from_req = data_from_request.get('parent_id')
    if parent_id_from_req is not None:
        try:
            parent_id_val = int(parent_id_from_req)
            if parent_id_val < 0: errors['parent_id'] = "ID родительского подразделения не может быть отрицательным."
            # Проверка существования родителя (кроме случая, если parent_id=0, что может быть спец. значением)
            elif parent_id_val > 0:
                 cursor = g.db_conn.cursor()
                 if not subdivision_repository.get_subdivision_by_id(cursor, parent_id_val): # Проверяем по внутреннему ID
                     errors['parent_id'] = f"Родительское подразделение с ID={parent_id_val} не найдено."
        except ValueError: errors['parent_id'] = "ID родительского подразделения должен быть целым числом или null."
        except psycopg2.Error as db_err_val_sub:
            logger.error(f"Ошибка БД при проверке parent_id={parent_id_from_req} для нового подразделения: {db_err_val_sub}")
            raise ApiInternalError("Ошибка БД при проверке родительского подразделения.")

    # Валидация transport_system_code
    transport_code = data_from_request.get('transport_system_code')
    if transport_code is not None and (not isinstance(transport_code, str) or not transport_code.strip() or not transport_code.isalnum() or len(transport_code) > 10):
        errors['transport_system_code'] = "Код транспортной системы должен быть строкой из 1-10 латинских букв/цифр, если указан."
    
    # Валидация priority
    priority_val = data_from_request.get('priority', 10) # Дефолтное значение
    try:
        if int(priority_val) < 0: errors['priority'] = "Приоритет не может быть отрицательным."
    except ValueError: errors['priority'] = "Приоритет должен быть целым числом."
    
    if errors:
        logger.warning(f"Ошибки валидации при создании подразделения: {errors}")
        raise ApiValidationFailure("Обнаружены ошибки валидации входных данных.", details=errors)
    # --- Конец валидации ---

    try:
        cursor = g.db_conn.cursor()
        # Репозиторий должен вернуть полный объект созданного подразделения
        new_subdivision_data = subdivision_repository.create_subdivision(cursor, data_from_request) # Передаем весь dict
        if not new_subdivision_data or 'id' not in new_subdivision_data:
            logger.error("Создание подразделения не удалось: репозиторий не вернул данные с ID.")
            raise ApiInternalError("Не удалось создать подразделение на сервере.")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Subdivision Route: Успешно создано подразделение ID: {new_subdivision_data['id']}, "
                    f"ObjectID: {new_subdivision_data['object_id']}, Имя: '{new_subdivision_data['short_name']}'")
        return jsonify(new_subdivision_data), 201 # HTTP 201 Created

    except ValueError as val_err_repo: # Ошибки бизнес-логики из репозитория
        logger.warning(f"Ошибка ValueError из репозитория при создании подразделения: {val_err_repo}")
        raise ApiValidationFailure(str(val_err_repo))
    except psycopg2.errors.UniqueViolation:
        logger.warning(f"Попытка создания подразделения с дублирующимся ObjectID или кодом ТС. Данные: {data_from_request}")
        raise ApiConflict("Подразделение с таким ObjectID или кодом транспортной системы уже существует.")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при создании подразделения: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при создании подразделения.")
    except ApiException: # Пробрасываем наши кастомные ошибки
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при создании подразделения.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:subdivision_id>', methods=['GET'])
@login_required # Только авторизованные пользователи
def api_get_subdivision_by_id_route(subdivision_id: int): # Добавил type hint
    """Получает детали одного подразделения по его внутреннему ID."""
    logger.info(f"API Subdivision Route: Запрос GET /api/v1/subdivisions/{subdivision_id} (детали подразделения)")
    if subdivision_id <= 0: # Внутренние ID обычно > 0
        raise ApiBadRequest("ID подразделения должен быть положительным целым числом.")
    try:
        cursor = g.db_conn.cursor()
        subdivision_data = subdivision_repository.get_subdivision_by_id(cursor, subdivision_id)
        if not subdivision_data:
            logger.warning(f"Подразделение с ID={subdivision_id} не найдено.")
            raise ApiNotFound(f"Подразделение с ID={subdivision_id} не найдено.")

        logger.info(f"API Subdivision Route: Успешно получены детали для подразделения ID: {subdivision_id}")
        return jsonify(subdivision_data), 200
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении подразделения ID={subdivision_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении информации о подразделении.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при получении подразделения ID={subdivision_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:subdivision_id>', methods=['PUT'])
@login_required # Только авторизованные пользователи
def api_update_subdivision_by_id_route(subdivision_id: int):
    """Обновляет данные существующего подразделения по его внутреннему ID."""
    logger.info(f"API Subdivision Route: Запрос PUT /api/v1/subdivisions/{subdivision_id} (обновление подразделения)")
    if subdivision_id <= 0:
        raise ApiBadRequest("ID подразделения должен быть положительным целым числом.")

    data_to_update = request.get_json()
    if not data_to_update:
        raise ApiBadRequest("Тело запроса отсутствует, не является валидным JSON или не содержит данных для обновления.")

    # Запрещаем изменение object_id через этот эндпоинт, если он уже установлен
    # Это поле обычно является ключевым идентификатором из внешней системы.
    if 'object_id' in data_to_update:
        logger.warning(f"Попытка изменения 'object_id' для подразделения ID={subdivision_id} через PUT. Это поле не изменяется.")
        data_to_update.pop('object_id') # Игнорируем изменение object_id

    if not data_to_update: # Если после удаления object_id ничего не осталось
         raise ApiBadRequest("Отсутствуют допустимые поля для обновления подразделения.")

    # Здесь можно добавить валидацию остальных полей, аналогично create_subdivision
    # Например, проверка parent_id на существование и на циклические зависимости.

    try:
        cursor = g.db_conn.cursor()
        # Репозиторий должен вернуть обновленный объект или None
        updated_subdivision_data = subdivision_repository.update_subdivision(cursor, subdivision_id, data_to_update)

        if updated_subdivision_data is None:
            logger.warning(f"Подразделение с ID={subdivision_id} не найдено при попытке обновления.")
            raise ApiNotFound(f"Подразделение с ID={subdivision_id} не найдено для обновления.")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Subdivision Route: Успешно обновлено подразделение ID: {subdivision_id}. Обновленные поля: {list(data_to_update.keys())}")
        return jsonify(updated_subdivision_data), 200
    except ValueError as val_err_repo: # Ошибки валидации из репозитория (например, цикл. зависимость)
        logger.warning(f"Ошибка ValueError из репозитория при обновлении подразделения ID={subdivision_id}: {val_err_repo}")
        raise ApiValidationFailure(str(val_err_repo))
    except psycopg2.errors.UniqueViolation:
        logger.warning(f"Конфликт уникальности при обновлении подразделения ID={subdivision_id} (например, код ТС).")
        raise ApiConflict("Конфликт данных при обновлении подразделения (возможно, дублирующийся код транспортной системы).")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при обновлении подразделения ID={subdivision_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при обновлении подразделения.")
    except ApiException: # Пробрасываем ApiNotFound или ApiValidationFailure
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при обновлении подразделения ID={subdivision_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:subdivision_id>', methods=['DELETE'])
@login_required # Только авторизованные пользователи
def api_delete_subdivision_by_id_route(subdivision_id: int):
    """Удаляет подразделение по его внутреннему ID."""
    logger.info(f"API Subdivision Route: Запрос DELETE /api/v1/subdivisions/{subdivision_id} (удаление подразделения)")
    if subdivision_id <= 0:
        raise ApiBadRequest("ID подразделения должен быть положительным целым числом.")
    try:
        cursor = g.db_conn.cursor()
        # Репозиторий должен вернуть True, если удаление успешно
        deleted_successfully = subdivision_repository.delete_subdivision(cursor, subdivision_id)

        if not deleted_successfully:
            logger.warning(f"Подразделение с ID={subdivision_id} не найдено при попытке удаления.")
            raise ApiNotFound(f"Подразделение с ID={subdivision_id} не найдено.")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Subdivision Route: Успешно удалено подразделение ID: {subdivision_id}")
        return '', 204 # HTTP 204 No Content

    except psycopg2.errors.ForeignKeyViolation: # Если есть связанные узлы или дочерние подразделения (с ON DELETE RESTRICT)
        logger.warning(f"Попытка удаления подразделения ID={subdivision_id}, на которое есть ссылки (узлы, дочерние подразделения).")
        raise ApiConflict("Невозможно удалить подразделение, так как оно содержит узлы или дочерние подразделения. Сначала удалите или переместите их.")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при удалении подразделения ID={subdivision_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при удалении подразделения.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при удалении подразделения ID={subdivision_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")