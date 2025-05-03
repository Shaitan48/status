# status/app/routes/api_key_routes.py
import logging
import psycopg2
import secrets
import hashlib
from flask import Blueprint, request, jsonify, g
from flask_login import login_required # Защищаем управление ключами
from ..repositories import api_key_repository, subdivision_repository # Импортируем репозитории
from ..errors import ApiBadRequest, ApiNotFound, ApiConflict, ApiInternalError, ApiValidationFailure # Импортируем ошибки
from ..auth_utils import api_key_required # Для возможной защиты самого себя? (Не сейчас)

logger = logging.getLogger(__name__)
bp = Blueprint('api_keys', __name__) # Префикс /api/v1/api_keys будет добавлен при регистрации

@bp.route('', methods=['POST'])
@login_required # Только авторизованные пользователи могут создавать ключи
def create_api_key_route():
    """
    Создает новый API ключ.
    Принимает JSON: {"description": "...", "role": "...", "object_id": N (optional)}
    Возвращает JSON с метаданными И САМИМ КЛЮЧОМ (только один раз!).
    """
    logger.info("API Keys: Запрос POST / (Создание ключа)")
    data = request.get_json()
    if not data:
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")

    description = data.get('description')
    role = data.get('role')
    object_id = data.get('object_id') # Может быть null

    # --- Валидация входных данных ---
    errors = {}
    if not description: errors['description'] = "Описание ключа обязательно."
    if not role: errors['role'] = "Роль ключа обязательна."
    elif role not in ['agent', 'loader', 'configurator', 'admin']: errors['role'] = "Недопустимая роль."
    if object_id is not None:
        try:
            object_id = int(object_id)
            # Проверим, существует ли подразделение с таким object_id
            cursor = g.db_conn.cursor() # Получаем курсор
            cursor.execute("SELECT EXISTS (SELECT 1 FROM subdivisions WHERE object_id = %s)", (object_id,))
            if not cursor.fetchone()['exists']:
                 errors['object_id'] = f"Подразделение с object_id={object_id} не найдено."
        except (ValueError, TypeError):
            errors['object_id'] = "object_id должен быть целым числом."
        except psycopg2.Error as db_err:
            logger.error(f"Ошибка проверки object_id {object_id} при создании API ключа: {db_err}")
            raise ApiInternalError("Ошибка БД при проверке object_id.")

    if errors:
        raise ApiValidationFailure("Ошибки валидации при создании ключа.", details=errors)
    # --- Конец валидации ---

    try:
        # Генерируем ключ и хеш
        api_key = secrets.token_urlsafe(32)
        key_hash = hashlib.sha256(api_key.encode('utf-8')).hexdigest()

        cursor = g.db_conn.cursor()
        new_key_id = api_key_repository.create_api_key(cursor, key_hash, description, role.lower(), object_id)

        if new_key_id is None:
            raise ApiInternalError("Не удалось создать API ключ (репозиторий вернул None).")

        # g.db_conn.commit() # Если не autocommit

        # Формируем ответ, Включая сам ключ!
        response_data = {
            "id": new_key_id,
            "description": description,
            "role": role.lower(),
            "object_id": object_id,
            "is_active": True,
            "api_key": api_key # <<< ВОЗВРАЩАЕМ КЛЮЧ ТОЛЬКО ЗДЕСЬ
        }
        logger.info(f"API Keys: Успешно создан ключ ID: {new_key_id}")
        # Возвращаем 201 Created
        return jsonify(response_data), 201

    except (ValueError, ApiValidationFailure) as val_err:
        raise val_err # Передаем ошибки валидации дальше
    except psycopg2.errors.UniqueViolation:
        raise ApiConflict("API ключ с таким хешем уже существует (очень маловероятно) или другая ошибка уникальности.")
    except psycopg2.Error as db_err:
        raise ApiInternalError("Ошибка БД при создании API ключа.")
    except Exception as e:
        logger.exception("Неожиданная ошибка при создании API ключа")
        raise ApiInternalError("Внутренняя ошибка сервера.")


@bp.route('', methods=['GET'])
@login_required # Просмотр ключей только для авторизованных
def get_api_keys_route():
    """
    Получает список API ключей с пагинацией и фильтрацией.
    НЕ возвращает хеши ключей.
    """
    logger.info(f"API Keys: Запрос GET / (Список ключей), args: {request.args}")
    try:
        # Парсинг параметров запроса
        limit = request.args.get('limit', type=int)
        offset = request.args.get('offset', default=0, type=int)
        role = request.args.get('role')
        object_id = request.args.get('object_id', type=int)
        is_active_str = request.args.get('is_active')

        is_active = None
        if is_active_str is not None:
            is_active = is_active_str.lower() in ['true', '1', 'yes', 'on']

        # Валидация limit/offset
        if limit is not None and limit <= 0: limit = None # Если limit не указан, репозиторий вернет все
        if offset < 0: offset = 0

        cursor = g.db_conn.cursor()
        items, total_count = api_key_repository.fetch_api_keys(
            cursor, limit=limit, offset=offset, role=role, object_id=object_id, is_active=is_active
        )

        # Форматируем даты перед отправкой
        for item in items:
            if item.get('created_at'): item['created_at'] = item['created_at'].isoformat()
            if item.get('last_used_at'): item['last_used_at'] = item['last_used_at'].isoformat()

        response_data = {
            "items": items,
            "total_count": total_count,
            "limit": limit,
            "offset": offset
        }
        logger.info(f"API Keys: Успешно отдан список ключей. Найдено: {len(items)}, Всего: {total_count}")
        return jsonify(response_data), 200

    except ValueError:
        raise ApiBadRequest("Неверный тип параметра запроса.")
    except psycopg2.Error as db_err:
        raise ApiInternalError("Ошибка БД при получении списка API ключей.")
    except Exception as e:
        logger.exception("Неожиданная ошибка при получении списка API ключей")
        raise ApiInternalError("Внутренняя ошибка сервера.")


@bp.route('/<int:key_id>', methods=['PUT'])
@login_required # Обновление ключей только для авторизованных
def update_api_key_route(key_id):
    """
    Обновляет метаданные API ключа (description, role, object_id, is_active).
    """
    logger.info(f"API Keys: Запрос PUT /{key_id}")
    data = request.get_json()
    if not data:
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON, или пусто.")

    # Удаляем поля, которые нельзя изменять напрямую (id, key_hash, created_at, last_used_at)
    data.pop('id', None)
    data.pop('key_hash', None)
    data.pop('created_at', None)
    data.pop('last_used_at', None)

    if not data: # Если после удаления ничего не осталось
         raise ApiBadRequest("Нет допустимых полей для обновления.")

    try:
        cursor = g.db_conn.cursor()
        updated_key = api_key_repository.update_api_key(cursor, key_id, data)

        if updated_key is None:
            raise ApiNotFound(f"API ключ с ID={key_id} не найден для обновления.")

        # g.db_conn.commit() # Если не autocommit

        # Форматируем даты для ответа
        if updated_key.get('created_at'): updated_key['created_at'] = updated_key['created_at'].isoformat()
        if updated_key.get('last_used_at'): updated_key['last_used_at'] = updated_key['last_used_at'].isoformat()

        logger.info(f"API Keys: Успешно обновлен ключ ID: {key_id}")
        return jsonify(updated_key), 200

    except ValueError as val_err:
        raise ApiValidationFailure(str(val_err)) # Ошибки валидации из репозитория
    except psycopg2.Error as db_err:
        raise ApiInternalError("Ошибка БД при обновлении API ключа.")
    except ApiException as api_err: # Ловим ApiNotFound
        raise api_err
    except Exception as e:
        logger.exception(f"Неожиданная ошибка при обновлении API ключа ID={key_id}")
        raise ApiInternalError("Внутренняя ошибка сервера.")


@bp.route('/<int:key_id>', methods=['DELETE'])
@login_required # Удаление ключей только для авторизованных
def delete_api_key_route(key_id):
    """
    Удаляет API ключ.
    """
    logger.info(f"API Keys: Запрос DELETE /{key_id}")
    try:
        cursor = g.db_conn.cursor()
        deleted = api_key_repository.delete_api_key(cursor, key_id)

        if not deleted:
            raise ApiNotFound(f"API ключ с ID={key_id} не найден.")

        # g.db_conn.commit() # Если не autocommit

        logger.info(f"API Keys: Успешно удален ключ ID: {key_id}")
        return '', 204 # No Content

    except psycopg2.Error as db_err:
        # Здесь могут быть ошибки внешних ключей, если они есть
        logger.error(f"Ошибка БД при удалении API ключа ID={key_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка БД при удалении API ключа.")
    except ApiException as api_err: # Ловим ApiNotFound
        raise api_err
    except Exception as e:
        logger.exception(f"Неожиданная ошибка при удалении API ключа ID={key_id}")
        raise ApiInternalError("Внутренняя ошибка сервера.")