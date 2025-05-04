# status/app/routes/subdivision_routes.py
import logging
import psycopg2
from flask import Blueprint, request, jsonify, g
from typing import Optional
from ..repositories import subdivision_repository
from ..errors import (
    ApiBadRequest,
    ApiNotFound,
    ApiConflict,
    ApiInternalError,
    ApiValidationFailure,
    ApiException
)
from flask_login import login_required

logger = logging.getLogger(__name__)
# Префикс НЕ указываем здесь
bp = Blueprint('subdivisions', __name__)

@bp.route('', methods=['GET']) # Обрабатывает GET /api/v1/subdivisions
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_subdivisions():
    """Получает список подразделений с пагинацией и фильтрацией."""
    logger.info(f"API Subdivision: Запрос GET {request.full_path}")
    try:
        # Парсинг параметров запроса
        limit = request.args.get('limit', type=int)
        offset = request.args.get('offset', default=0, type=int)
        parent_id_str = request.args.get('parent_id')
        search_text = request.args.get('search_text')
        parent_id: Optional[int] = None

        if parent_id_str is not None:
            if parent_id_str.lower() == 'root' or parent_id_str == '0': parent_id = 0
            else:
                try: parent_id = int(parent_id_str); assert parent_id >= 0
                except (ValueError, AssertionError): raise ApiBadRequest("Неверный параметр 'parent_id'.")

        if limit is not None and limit <= 0: limit = None
        if offset < 0: offset = 0

        cursor = g.db_conn.cursor()
        items, total_count = subdivision_repository.fetch_subdivisions(
            cursor, limit=limit, offset=offset, parent_id=parent_id, search_text=search_text
        )
        logger.info(f"API Subdivision: Успешно отданы subdivisions. Найдено: {len(items)}, Всего: {total_count}")
        return jsonify({"items": items, "total_count": total_count, "limit": limit, "offset": offset}), 200

    except psycopg2.Error as db_err: raise ApiInternalError("Ошибка базы данных при получении списка подразделений.")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Внутренняя ошибка сервера: {e}")


@bp.route('', methods=['POST']) # Обрабатывает POST /api/v1/subdivisions
@login_required # Защита маршрута, только для авторизованных пользователей
def api_create_subdivision():
    """Создает новое подразделение."""
    logger.info("API Subdivision: Запрос POST /")
    data = request.get_json()
    if not data: raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")
    if not data.get('object_id') or not data.get('short_name'): raise ApiValidationFailure("Отсутствуют обязательные поля: object_id, short_name")

    try:
        cursor = g.db_conn.cursor()
        new_subdivision = subdivision_repository.create_subdivision(cursor, data)
        if not new_subdivision: raise ApiInternalError("Не удалось создать подразделение.")
        # g.db_conn.commit()
        logger.info(f"API Subdivision: Создано ID: {new_subdivision['id']}")
        return jsonify(new_subdivision), 201
    except ValueError as val_err: raise ApiValidationFailure(str(val_err))
    except psycopg2.errors.UniqueViolation: raise ApiConflict("Подразделение с таким object_id, кодом ТС или именем+родителем уже существует.")
    except psycopg2.Error as db_err: raise ApiInternalError("Ошибка базы данных при создании подразделения.")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Внутренняя ошибка сервера: {e}")


@bp.route('/<int:subdivision_id>', methods=['GET']) # Обрабатывает GET /api/v1/subdivisions/ID
@login_required # Защита маршрута, только для авторизованных пользователей
def api_get_subdivision(subdivision_id):
    """Получает подразделение по ID."""
    logger.info(f"API Subdivision: Запрос GET /{subdivision_id}")
    try:
        cursor = g.db_conn.cursor()
        subdivision = subdivision_repository.get_subdivision_by_id(cursor, subdivision_id)
        if not subdivision: raise ApiNotFound(f"Подразделение с id={subdivision_id} не найдено.")
        return jsonify(subdivision), 200
    except psycopg2.Error as db_err: raise ApiInternalError("Ошибка базы данных при получении подразделения.")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Внутренняя ошибка сервера: {e}")


@bp.route('/<int:subdivision_id>', methods=['PUT']) # Обрабатывает PUT /api/v1/subdivisions/ID
@login_required # Защита маршрута, только для авторизованных пользователей
def api_update_subdivision(subdivision_id):
    """Обновляет подразделение по ID."""
    logger.info(f"API Subdivision: Запрос PUT /{subdivision_id}")
    data = request.get_json()
    if not data: raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")
    if not data: raise ApiBadRequest("Нет данных для обновления подразделения.")
    if 'object_id' in data: logger.warning(...) # Игнорируем object_id

    try:
        cursor = g.db_conn.cursor()
        updated_subdivision = subdivision_repository.update_subdivision(cursor, subdivision_id, data)
        if updated_subdivision is None: raise ApiNotFound(f"Подразделение с id={subdivision_id} не найдено для обновления.")
        # g.db_conn.commit()
        logger.info(f"API Subdivision: Обновлено ID: {subdivision_id}")
        return jsonify(updated_subdivision), 200
    except ValueError as val_err: raise ApiValidationFailure(str(val_err))
    except psycopg2.errors.UniqueViolation: raise ApiConflict("Конфликт при обновлении подразделения.")
    except psycopg2.Error as db_err: raise ApiInternalError("Ошибка базы данных при обновлении подразделения.")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Внутренняя ошибка сервера: {e}")


@bp.route('/<int:subdivision_id>', methods=['DELETE']) # Обрабатывает DELETE /api/v1/subdivisions/ID
@login_required # Защита маршрута, только для авторизованных пользователей
def api_delete_subdivision(subdivision_id):
    """Удаляет подразделение по ID."""
    logger.info(f"API Subdivision: Запрос DELETE /{subdivision_id}")
    try:
        cursor = g.db_conn.cursor()
        deleted = subdivision_repository.delete_subdivision(cursor, subdivision_id)
        if not deleted: raise ApiNotFound(f"Подразделение с id={subdivision_id} не найдено.")
        # g.db_conn.commit()
        logger.info(f"API Subdivision: Удалено ID: {subdivision_id}")
        return '', 204
    except psycopg2.errors.ForeignKeyViolation: raise ApiConflict("Невозможно удалить подразделение из-за внешних зависимостей.")
    except psycopg2.Error as db_err: raise ApiInternalError("Ошибка базы данных при удалении подразделения.")
    except ApiException as api_err: raise api_err
    except Exception as e: raise ApiInternalError(f"Внутренняя ошибка сервера: {e}")

