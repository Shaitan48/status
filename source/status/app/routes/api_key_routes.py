# status/app/routes/api_key_routes.py
"""
Маршруты API для управления API-ключами.
Позволяют создавать, получать список, обновлять и удалять API-ключи.
Доступ к этим маршрутам требует аутентификации пользователя (UI).
"""
import logging
import psycopg2
import secrets
import hashlib # Для хеширования ключей
from flask import Blueprint, request, jsonify, g
from flask_login import login_required # Защита маршрутов, требующих входа пользователя
from ..repositories import api_key_repository, subdivision_repository # Репозитории для работы с БД
from ..errors import (
    ApiBadRequest,
    ApiNotFound,
    ApiConflict,
    ApiInternalError,
    ApiValidationFailure,
    ApiException # Базовое исключение API
)
# from ..auth_utils import api_key_required # Этот декоратор здесь не нужен, т.к. маршруты защищены login_required

logger = logging.getLogger(__name__)
# Создаем Blueprint. Префикс '/api/v1/api_keys' будет добавлен при регистрации в app/routes/__init__.py
bp = Blueprint('api_keys', __name__)

@bp.route('', methods=['POST'])
@login_required # Только аутентифицированные пользователи могут создавать ключи
def create_api_key_route():
    """
    Создает новый API-ключ.
    Принимает JSON-тело с полями:
        - "description" (str, required): Описание назначения ключа.
        - "role" (str, required): Роль ключа ('agent', 'loader', 'configurator', 'admin').
        - "object_id" (int, optional): ID объекта (подразделения), к которому привязан ключ (актуально для роли 'agent' или 'configurator').
    Возвращает JSON с метаданными созданного ключа, включая сам сгенерированный API-ключ
    (ключ возвращается **только один раз** при создании).
    """
    logger.info("API Keys Route: Запрос POST /api_keys (Создание нового API-ключа)")
    data = request.get_json()
    if not data:
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")

    description = data.get('description')
    role = data.get('role')
    object_id_str = data.get('object_id') # Получаем как строку, чтобы обработать None и int
    object_id = None

    # --- Валидация входных данных ---
    errors: Dict[str, str] = {} # Словарь для сбора ошибок валидации
    if not description or not description.strip():
        errors['description'] = "Описание API-ключа является обязательным полем."
    if not role:
        errors['role'] = "Роль API-ключа является обязательной."
    elif role.lower() not in ['agent', 'loader', 'configurator', 'admin']:
        errors['role'] = "Указана недопустимая роль. Доступные роли: 'agent', 'loader', 'configurator', 'admin'."

    if object_id_str is not None: # object_id опционален
        try:
            object_id = int(object_id_str)
            if object_id <= 0:
                errors['object_id'] = "Если 'object_id' указан, он должен быть положительным целым числом."
            else:
                # Проверяем, существует ли подразделение с таким object_id
                cursor = g.db_conn.cursor()
                # Используем функцию из subdivision_repository для инкапсуляции логики
                subdivision_exists = subdivision_repository.check_subdivision_exists_by_object_id(cursor, object_id)
                if not subdivision_exists:
                    errors['object_id'] = f"Подразделение с object_id={object_id} не найдено в системе."
        except ValueError:
            errors['object_id'] = "'object_id' должен быть целым числом."
        except psycopg2.Error as db_err:
            logger.error(f"Ошибка БД при проверке object_id={object_id_str} для API-ключа: {db_err}", exc_info=True)
            # Не вываливаем внутреннюю ошибку БД пользователю, но логируем
            raise ApiInternalError("Произошла ошибка при проверке object_id в базе данных.")

    if errors:
        logger.warning(f"Ошибки валидации при создании API-ключа: {errors}")
        raise ApiValidationFailure("Обнаружены ошибки валидации при создании API-ключа.", details=errors)
    # --- Конец валидации ---

    try:
        # Генерируем безопасный API-ключ и его SHA-256 хеш для хранения
        api_key_value = secrets.token_urlsafe(32) # Генерирует достаточно длинный и случайный ключ
        key_hash_to_store = hashlib.sha256(api_key_value.encode('utf-8')).hexdigest()

        cursor = g.db_conn.cursor()
        # Вызываем функцию репозитория для создания ключа в БД
        new_key_id = api_key_repository.create_api_key(
            cursor,
            key_hash=key_hash_to_store,
            description=description.strip(), # Убираем лишние пробелы
            role=role.lower(), # Храним роль в нижнем регистре
            object_id=object_id
        )

        if new_key_id is None: # Если репозиторий вернул None, значит создание не удалось
            logger.error("Создание API-ключа не удалось (репозиторий вернул None).")
            raise ApiInternalError("Не удалось создать API-ключ на сервере.")

        # g.db_conn.commit() # Коммит не нужен, если autocommit=True для соединения

        # Формируем ответ, включая сам сгенерированный ключ (только при создании!)
        response_data = {
            "id": new_key_id,
            "description": description.strip(),
            "role": role.lower(),
            "object_id": object_id,
            "is_active": True, # Новый ключ по умолчанию активен
            "api_key": api_key_value # Возвращаем сам ключ пользователю
        }
        logger.info(f"API Keys Route: Успешно создан API-ключ ID: {new_key_id} для роли '{role.lower()}'.")
        return jsonify(response_data), 201 # HTTP 201 Created

    except (ValueError, ApiValidationFailure) as val_err: # Перехватываем ошибки валидации, если они возникли в репозитории
        logger.warning(f"Ошибка валидации из репозитория при создании API-ключа: {val_err}")
        raise val_err # Пробрасываем их дальше
    except psycopg2.errors.UniqueViolation: # Ошибка уникальности (например, хеш ключа уже существует - крайне маловероятно)
        logger.error("Конфликт при создании API-ключа: попытка создать ключ с уже существующим хешем.", exc_info=True)
        raise ApiConflict("Не удалось создать API-ключ из-за конфликта данных (возможно, такой хеш уже существует).")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при создании API-ключа: {db_err}", exc_info=True)
        raise ApiInternalError("Произошла ошибка базы данных при создании API-ключа.")
    except ApiException: # Пробрасываем другие наши кастомные ошибки
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при создании API-ключа.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('', methods=['GET'])
@login_required # Только аутентифицированные пользователи могут просматривать список ключей
def get_api_keys_route():
    """
    Получает список всех API-ключей с возможностью фильтрации и пагинации.
    Хеши ключей (`key_hash`) не возвращаются в этом списке для безопасности.

    Query Params:
        limit (int, optional): Количество записей на странице.
        offset (int, optional): Смещение для пагинации.
        role (str, optional): Фильтр по роли ключа.
        object_id (int, optional): Фильтр по ID объекта (подразделения).
        is_active (bool, optional): Фильтр по статусу активности.

    Returns:
        JSON: Объект с полями "items" (список ключей) и "total_count".
    """
    logger.info(f"API Keys Route: Запрос GET /api_keys (список ключей), параметры: {request.args}")
    try:
        # --- Парсинг и валидация параметров запроса ---
        limit_str = request.args.get('limit')
        offset_str = request.args.get('offset', default='0')
        role_filter = request.args.get('role')
        object_id_filter_str = request.args.get('object_id')
        is_active_filter_str = request.args.get('is_active')

        limit: Optional[int] = None
        if limit_str is not None:
            try: limit = int(limit_str); assert limit > 0
            except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'limit' должен быть положительным целым числом.")
            if limit > 200: limit = 200 # Ограничение на максимальный размер страницы

        try: offset = int(offset_str); assert offset >= 0
        except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'offset' должен быть неотрицательным целым числом.")

        object_id_filter: Optional[int] = None
        if object_id_filter_str is not None:
            try: object_id_filter = int(object_id_filter_str)
            except ValueError: raise ApiBadRequest("Параметр 'object_id' должен быть целым числом.")

        is_active_filter: Optional[bool] = None
        if is_active_filter_str is not None:
            is_active_filter_str_lower = is_active_filter_str.lower()
            if is_active_filter_str_lower in ['true', '1', 'yes', 'on']: is_active_filter = True
            elif is_active_filter_str_lower in ['false', '0', 'no', 'off']: is_active_filter = False
            else: raise ApiBadRequest("Параметр 'is_active' должен быть булевым значением (true/false).")
        # --- Конец валидации параметров ---

        cursor = g.db_conn.cursor()
        # Вызываем функцию репозитория для получения списка ключей
        items, total_count = api_key_repository.fetch_api_keys(
            cursor,
            limit=limit,
            offset=offset,
            role=role_filter,
            object_id=object_id_filter,
            is_active=is_active_filter
        )

        # Форматируем даты в ISO строку для JSON ответа
        for item in items:
            if item.get('created_at') and isinstance(item['created_at'], datetime):
                item['created_at'] = item['created_at'].isoformat()
            if item.get('last_used_at') and isinstance(item['last_used_at'], datetime):
                item['last_used_at'] = item['last_used_at'].isoformat()

        response_data = {
            "items": items,
            "total_count": total_count,
            "limit": limit,
            "offset": offset
        }
        logger.info(f"API Keys Route: Успешно отдан список API-ключей. Найдено на странице: {len(items)}, Всего (с фильтрами): {total_count}")
        return jsonify(response_data), 200

    except ValueError as val_err: # Ловим ошибки преобразования типов из request.args.get
        logger.warning(f"Неверный тип параметра при запросе списка API-ключей: {val_err}")
        raise ApiBadRequest(f"Неверный тип параметра запроса: {val_err}")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении списка API-ключей: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении списка API-ключей.")
    except ApiException: # Пробрасываем наши кастомные ошибки
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при получении списка API-ключей.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:key_id>', methods=['PUT'])
@login_required # Только аутентифицированные пользователи
def update_api_key_route(key_id: int):
    """
    Обновляет метаданные существующего API-ключа (description, role, object_id, is_active).
    Сам ключ (хеш) не изменяется.

    Path Params:
        key_id (int, required): ID обновляемого API-ключа.
    JSON Body:
        Поля для обновления (все опциональны):
        - "description" (str)
        - "role" (str)
        - "object_id" (int, nullable)
        - "is_active" (bool)
    """
    logger.info(f"API Keys Route: Запрос PUT /api_keys/{key_id} (Обновление API-ключа)")
    data_to_update = request.get_json()
    if not data_to_update: # Пустое тело или не JSON
        raise ApiBadRequest("Тело запроса отсутствует, не является валидным JSON или не содержит данных для обновления.")

    # Удаляем поля, которые не должны изменяться через этот эндпоинт
    data_to_update.pop('id', None)
    data_to_update.pop('key_hash', None)
    data_to_update.pop('created_at', None)
    data_to_update.pop('last_used_at', None)
    data_to_update.pop('api_key', None) # Сам ключ точно нельзя менять

    if not data_to_update: # Если после удаления запрещенных полей ничего не осталось
         raise ApiBadRequest("Отсутствуют допустимые поля для обновления API-ключа.")

    # --- Валидация данных для обновления ---
    # (Аналогична валидации при создании, но поля опциональны)
    errors: Dict[str, str] = {}
    if 'role' in data_to_update and data_to_update['role'] is not None:
        if data_to_update['role'].lower() not in ['agent', 'loader', 'configurator', 'admin']:
            errors['role'] = "Указана недопустимая роль."
    if 'object_id' in data_to_update and data_to_update['object_id'] is not None:
        try:
            obj_id_val = int(data_to_update['object_id'])
            if obj_id_val <= 0: errors['object_id'] = "Если 'object_id' указан, он должен быть положительным целым числом."
            else:
                cursor = g.db_conn.cursor()
                if not subdivision_repository.check_subdivision_exists_by_object_id(cursor, obj_id_val):
                    errors['object_id'] = f"Подразделение с object_id={obj_id_val} не найдено."
        except ValueError: errors['object_id'] = "'object_id' должен быть целым числом."
        except psycopg2.Error as db_err:
            logger.error(f"Ошибка БД при проверке object_id для обновления API-ключа {key_id}: {db_err}")
            raise ApiInternalError("Ошибка БД при проверке object_id.")
    if 'is_active' in data_to_update and not isinstance(data_to_update['is_active'], bool):
        errors['is_active'] = "Поле 'is_active' должно быть булевым (true/false)."
    if 'description' in data_to_update and (data_to_update['description'] is None or not str(data_to_update['description']).strip()):
        errors['description'] = "Описание не может быть пустым, если передано. Для удаления используйте DELETE." # Или разрешить null?

    if errors:
        logger.warning(f"Ошибки валидации при обновлении API-ключа ID={key_id}: {errors}")
        raise ApiValidationFailure("Ошибки валидации при обновлении API-ключа.", details=errors)
    # --- Конец валидации ---

    try:
        cursor = g.db_conn.cursor()
        # Вызываем функцию репозитория для обновления
        # data_to_update уже содержит только разрешенные и провалидированные (частично) поля
        updated_key_data = api_key_repository.update_api_key(cursor, key_id, data_to_update)

        if updated_key_data is None: # Репозиторий возвращает None, если ключ не найден
            raise ApiNotFound(f"API-ключ с ID={key_id} не найден для обновления.")

        # g.db_conn.commit() # Если не autocommit

        # Форматируем даты для ответа
        if updated_key_data.get('created_at') and isinstance(updated_key_data['created_at'], datetime):
            updated_key_data['created_at'] = updated_key_data['created_at'].isoformat()
        if updated_key_data.get('last_used_at') and isinstance(updated_key_data['last_used_at'], datetime):
            updated_key_data['last_used_at'] = updated_key_data['last_used_at'].isoformat()

        logger.info(f"API Keys Route: Успешно обновлен API-ключ ID: {key_id}")
        return jsonify(updated_key_data), 200

    except ValueError as val_err: # Ловим ошибки валидации из репозитория (например, недопустимая роль)
        logger.warning(f"Ошибка ValueError при обновлении API-ключа ID={key_id}: {val_err}")
        raise ApiValidationFailure(str(val_err))
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при обновлении API-ключа ID={key_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при обновлении API-ключа.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при обновлении API-ключа ID={key_id}")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:key_id>', methods=['DELETE'])
@login_required # Только аутентифицированные пользователи
def delete_api_key_route(key_id: int):
    """
    Удаляет API-ключ по его ID.

    Path Params:
        key_id (int, required): ID удаляемого API-ключа.
    """
    logger.info(f"API Keys Route: Запрос DELETE /api_keys/{key_id} (Удаление API-ключа)")
    try:
        cursor = g.db_conn.cursor()
        # Вызываем функцию репозитория для удаления
        deleted_successfully = api_key_repository.delete_api_key(cursor, key_id)

        if not deleted_successfully: # Репозиторий возвращает True/False
            raise ApiNotFound(f"API-ключ с ID={key_id} не найден для удаления.")

        # g.db_conn.commit() # Если не autocommit

        logger.info(f"API Keys Route: Успешно удален API-ключ ID: {key_id}")
        return '', 204 # HTTP 204 No Content, стандартный ответ для успешного DELETE

    except psycopg2.Error as db_err:
        # Обработка специфических ошибок БД, если необходимо (например, ForeignKeyViolation)
        logger.error(f"Ошибка БД при удалении API-ключа ID={key_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при удалении API-ключа.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при удалении API-ключа ID={key_id}")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")