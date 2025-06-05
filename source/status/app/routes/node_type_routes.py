# status/app/routes/node_type_routes.py
"""
Маршруты API для управления Типами Узлов (Node Types).
Включает CRUD-операции для типов узлов.
"""
import logging
import psycopg2
from flask import Blueprint, request, jsonify, g
from typing import Optional, Dict, Any
from ..repositories import node_type_repository # Репозиторий для типов узлов
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
# Создаем Blueprint. Префикс '/api/v1/node_types' будет добавлен при регистрации.
bp = Blueprint('node_types', __name__)

@bp.route('', methods=['GET'])
@login_required # Только авторизованные пользователи
def api_get_all_node_types():
    """
    Получает список всех типов узлов с возможностью фильтрации и пагинации.

    Query Params:
        limit (int, optional): Количество записей.
        offset (int, optional): Смещение.
        parent_type_id (int, optional): Фильтр по ID родительского типа (0 или null для корневых).
        search_text (str, optional): Поиск по имени или описанию типа.
    Returns:
        JSON: Объект с полями "items" (список типов) и "total_count".
    """
    full_path = request.full_path if request else "/api/v1/node_types (путь не определен)"
    logger.info(f"API Node Type Route: Запрос GET {full_path} (список типов узлов)")
    try:
        # --- Парсинг и валидация параметров запроса ---
        limit_str = request.args.get('limit')
        offset_str = request.args.get('offset', default='0')
        parent_id_str = request.args.get('parent_type_id') # Имя параметра для фильтра
        search_text_filter = request.args.get('search_text')

        limit: Optional[int] = None
        if limit_str is not None:
            try: limit = int(limit_str); assert limit > 0
            except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'limit' должен быть положительным целым числом.")
            if limit > 200: limit = 200

        try: offset = int(offset_str); assert offset >= 0
        except (ValueError, AssertionError): raise ApiBadRequest("Параметр 'offset' должен быть неотрицательным целым числом.")

        parent_type_id_filter: Optional[int] = None
        if parent_id_str is not None:
            if parent_id_str.lower() == 'root' or parent_id_str == '0': # '0' или 'root' для корневых
                parent_type_id_filter = 0 # Репозиторий должен обработать 0 как parent_id IS NULL
            else:
                try: parent_type_id_filter = int(parent_id_str)
                except ValueError: raise ApiBadRequest("Параметр 'parent_type_id' должен быть целым числом или 'root'.")
        if search_text_filter: search_text_filter = search_text_filter.strip()
        # --- Конец парсинга и валидации ---

        cursor = g.db_conn.cursor()
        # Вызов функции репозитория
        type_items, total_type_count = node_type_repository.fetch_node_types(
            cursor,
            limit=limit, offset=offset,
            parent_id=parent_type_id_filter, # Передаем ID родителя
            search_text=search_text_filter
        )
        logger.info(f"API Node Type Route: Успешно получен список типов узлов. "
                    f"Найдено на странице: {len(type_items)}, Всего (с фильтрами): {total_type_count}")
        return jsonify({"items": type_items, "total_count": total_type_count, "limit": limit, "offset": offset}), 200

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении списка типов узлов: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении списка типов узлов.")
    except ApiException: # Пробрасываем ApiBadRequest
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при получении списка типов узлов.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('', methods=['POST'])
@login_required # Только авторизованные пользователи
def api_create_node_type():
    """
    Создает новый тип узла.
    Принимает JSON-тело с полями:
        - name (str, required): Уникальное имя типа узла (в пределах одного родителя).
        - description (str, optional): Описание типа.
        - parent_type_id (int, optional, nullable): ID родительского типа (null для корневого).
        - priority (int, optional, default 10): Приоритет для сортировки.
        - icon_filename (str, optional, nullable): Имя файла иконки.
    Возвращает JSON с данными созданного типа.
    """
    logger.info("API Node Type Route: Запрос POST /api/v1/node_types (создание нового типа узла)")
    data_from_request = request.get_json()
    if not data_from_request:
        raise ApiBadRequest("Тело запроса отсутствует или не является валидным JSON.")

    # --- Валидация входных данных ---
    errors: Dict[str, str] = {}
    name = data_from_request.get('name')
    if not name or not str(name).strip():
        errors['name'] = "Имя типа узла является обязательным полем."
    elif len(str(name)) > 255: # Пример ограничения длины
         errors['name'] = "Имя типа узла не должно превышать 255 символов."

    parent_type_id_from_req = data_from_request.get('parent_type_id')
    parent_type_id_validated: Optional[int] = None
    if parent_type_id_from_req is not None: # Если parent_type_id передан
        try:
            parent_type_id_validated = int(parent_type_id_from_req)
            if parent_type_id_validated < 0: # ID 0 - специальный базовый тип, не может быть родителем в обычном смысле
                 errors['parent_type_id'] = "ID родительского типа не может быть отрицательным. Используйте null для корневого типа."
            # Проверка существования родительского типа (если он не 0)
            elif parent_type_id_validated > 0:
                 cursor = g.db_conn.cursor()
                 if not node_type_repository.get_node_type_by_id(cursor, parent_type_id_validated):
                     errors['parent_type_id'] = f"Родительский тип узла с ID={parent_type_id_validated} не найден."
        except ValueError:
            errors['parent_type_id'] = "ID родительского типа должен быть целым числом или null."
        except psycopg2.Error as db_err_val: # Ошибка при проверке родителя
            logger.error(f"Ошибка БД при проверке parent_type_id={parent_type_id_from_req} для нового типа узла: {db_err_val}")
            raise ApiInternalError("Ошибка БД при проверке родительского типа узла.")

    priority_from_req = data_from_request.get('priority', 10) # Значение по умолчанию
    try:
        priority_validated = int(priority_from_req)
        if priority_validated < 0: errors['priority'] = "Приоритет не может быть отрицательным."
    except ValueError: errors['priority'] = "Приоритет должен быть целым числом."

    icon_filename_from_req = data_from_request.get('icon_filename')
    if icon_filename_from_req is not None and len(str(icon_filename_from_req)) > 100:
        errors['icon_filename'] = "Имя файла иконки не должно превышать 100 символов."

    if errors:
        logger.warning(f"Ошибки валидации при создании типа узла: {errors}")
        raise ApiValidationFailure("Обнаружены ошибки валидации входных данных.", details=errors)
    # --- Конец валидации ---

    try:
        cursor = g.db_conn.cursor()
        # Передаем провалидированные данные в репозиторий
        # Репозиторий должен вернуть полный объект созданного типа
        new_type_data = node_type_repository.create_node_type(cursor, data_from_request) # data_from_request т.к. он содержит все поля
        if not new_type_data or 'id' not in new_type_data:
            logger.error("Создание типа узла не удалось: репозиторий не вернул данные с ID.")
            raise ApiInternalError("Не удалось создать тип узла на сервере.")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Node Type Route: Успешно создан тип узла ID: {new_type_data['id']}, Имя: '{new_type_data['name']}'")
        return jsonify(new_type_data), 201 # HTTP 201 Created

    except ValueError as val_err_repo: # Ошибки валидации из репозитория (например, бизнес-логика)
        logger.warning(f"Ошибка ValueError из репозитория при создании типа узла: {val_err_repo}")
        raise ApiValidationFailure(str(val_err_repo))
    except psycopg2.errors.UniqueViolation: # Конфликт уникальности (имя + родитель)
        logger.warning(f"Попытка создания типа узла с дублирующимся именем ('{name}') "
                       f"и родителем ID {parent_type_id_validated if parent_type_id_validated is not None else 'NULL'}.")
        raise ApiConflict(f"Тип узла с именем '{name}' уже существует для данного родителя (или как корневой).")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при создании типа узла: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при создании типа узла.")
    except ApiException: # Пробрасываем наши кастомные ошибки
        raise
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при создании типа узла.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:type_id>', methods=['GET'])
@login_required # Только авторизованные пользователи
def api_get_node_type_by_id_route(type_id: int): # Добавил type hint
    """Получает детали одного типа узла по его ID."""
    logger.info(f"API Node Type Route: Запрос GET /api/v1/node_types/{type_id} (детали типа узла)")
    if type_id < 0: # ID 0 - специальный базовый тип, он валиден
        raise ApiBadRequest("ID типа узла должен быть неотрицательным целым числом.")
    try:
        cursor = g.db_conn.cursor()
        node_type_data = node_type_repository.get_node_type_by_id(cursor, type_id)
        if not node_type_data:
            logger.warning(f"Тип узла с ID={type_id} не найден.")
            raise ApiNotFound(f"Тип узла с ID={type_id} не найден.")

        logger.info(f"API Node Type Route: Успешно получены детали для типа узла ID: {type_id}")
        return jsonify(node_type_data), 200
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении типа узла ID={type_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении информации о типе узла.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при получении типа узла ID={type_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:type_id>', methods=['PUT'])
@login_required # Только авторизованные пользователи
def api_update_node_type_by_id_route(type_id: int):
    """Обновляет данные существующего типа узла по его ID."""
    logger.info(f"API Node Type Route: Запрос PUT /api/v1/node_types/{type_id} (обновление типа узла)")
    if type_id < 0: # ID 0 - базовый тип, его можно обновлять (но не parent_id)
        raise ApiBadRequest("ID типа узла должен быть неотрицательным целым числом.")

    data_to_update = request.get_json()
    if not data_to_update:
        raise ApiBadRequest("Тело запроса отсутствует, не является валидным JSON или не содержит данных для обновления.")

    # Удаляем поля, которые не должны изменяться через этот эндпоинт (например, ID)
    data_to_update.pop('id', None)
    if not data_to_update: # Если после удаления запрещенных полей ничего не осталось
         raise ApiBadRequest("Отсутствуют допустимые поля для обновления типа узла.")

    # --- Валидация данных для обновления (аналогично create, но поля опциональны) ---
    errors: Dict[str, str] = {}
    if 'name' in data_to_update and (data_to_update['name'] is None or not str(data_to_update['name']).strip()):
        errors['name'] = "Имя типа узла не может быть пустым, если передано для обновления."
    # ... (добавить другие валидации для полей name, parent_type_id, priority, icon_filename, description, как в create) ...
    # Особое внимание на parent_type_id: нельзя установить самого себя или создать цикл.
    if 'parent_type_id' in data_to_update:
        if data_to_update['parent_type_id'] == type_id: # Попытка установить себя родителем
            errors['parent_type_id'] = "Нельзя установить тип узла родителем для самого себя."
        elif data_to_update['parent_type_id'] is not None: # Если родитель не null, проверяем его существование
            try:
                parent_id_val = int(data_to_update['parent_type_id'])
                if parent_id_val < 0: errors['parent_type_id'] = "ID родительского типа не может быть отрицательным."
                # Здесь также нужна проверка на циклические зависимости, если parent_id меняется.
                # Это сложнее и может потребовать отдельной логики в репозитории или сервисе.
                # Пока что ограничимся проверкой существования.
                elif parent_id_val > 0 : # ID 0 не проверяем как родителя, он особенный
                    cursor = g.db_conn.cursor()
                    if not node_type_repository.get_node_type_by_id(cursor, parent_id_val):
                        errors['parent_type_id'] = f"Родительский тип узла с ID={parent_id_val} не найден."
            except ValueError: errors['parent_type_id'] = "ID родительского типа должен быть целым числом или null."
            except psycopg2.Error as db_err_val_upd:
                 logger.error(f"Ошибка БД при проверке parent_type_id для обновления типа узла {type_id}: {db_err_val_upd}")
                 raise ApiInternalError("Ошибка БД при проверке родительского типа узла.")

    if errors:
        logger.warning(f"Ошибки валидации при обновлении типа узла ID={type_id}: {errors}")
        raise ApiValidationFailure("Ошибки валидации при обновлении типа узла.", details=errors)
    # --- Конец валидации ---

    try:
        cursor = g.db_conn.cursor()
        # Репозиторий должен вернуть обновленный объект или None
        updated_type_data = node_type_repository.update_node_type(cursor, type_id, data_to_update)

        if updated_type_data is None:
            logger.warning(f"Тип узла с ID={type_id} не найден при попытке обновления.")
            raise ApiNotFound(f"Тип узла с ID={type_id} не найден для обновления.")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Node Type Route: Успешно обновлен тип узла ID: {type_id}. Обновленные поля: {list(data_to_update.keys())}")
        return jsonify(updated_type_data), 200
    except ValueError as val_err_repo: # Ошибки бизнес-логики из репозитория
        logger.warning(f"Ошибка ValueError из репозитория при обновлении типа узла ID={type_id}: {val_err_repo}")
        raise ApiValidationFailure(str(val_err_repo)) # Например, "Нельзя удалить базовый тип" или "Циклическая зависимость"
    except psycopg2.errors.UniqueViolation:
        logger.warning(f"Конфликт уникальности при обновлении типа узла ID={type_id} (имя + родитель).")
        raise ApiConflict("Тип узла с таким именем и родителем уже существует.")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при обновлении типа узла ID={type_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при обновлении типа узла.")
    except ApiException: # Пробрасываем ApiNotFound или ApiValidationFailure
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при обновлении типа узла ID={type_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/<int:type_id>', methods=['DELETE'])
@login_required # Только авторизованные пользователи
def api_delete_node_type_by_id_route(type_id: int):
    """Удаляет тип узла по его ID."""
    logger.info(f"API Node Type Route: Запрос DELETE /api/v1/node_types/{type_id} (удаление типа узла)")
    if type_id < 0: # ID 0 - базовый тип, его нельзя удалять через API этим путем (репозиторий должен это проверить)
        raise ApiBadRequest("ID типа узла должен быть неотрицательным целым числом.")
    try:
        cursor = g.db_conn.cursor()
        # Репозиторий должен вернуть True/False и обработать логику невозможности удаления (например, базовый тип или есть зависимости)
        deleted_successfully = node_type_repository.delete_node_type(cursor, type_id)

        if not deleted_successfully:
            # Если репозиторий вернул False, значит, тип не найден ИЛИ его нельзя удалить (детали должны быть в ValueError из репозитория)
            # Этот блок может не понадобиться, если репозиторий выбрасывает ValueError
            logger.warning(f"Тип узла с ID={type_id} не найден или не может быть удален (проверьте зависимости).")
            raise ApiNotFound(f"Тип узла с ID={type_id} не найден или не может быть удален (возможно, есть связанные узлы или дочерние типы).")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API Node Type Route: Успешно удален тип узла ID: {type_id}")
        return '', 204 # HTTP 204 No Content
    except ValueError as dep_err: # Ошибки бизнес-логики из репозитория (нельзя удалить базовый, есть дети/узлы)
        logger.warning(f"Конфликт при удалении типа узла ID={type_id}: {dep_err}")
        raise ApiConflict(str(dep_err)) # Используем 409 Conflict для таких случаев
    except psycopg2.errors.ForeignKeyViolation: # На случай, если в БД FK не настроены на SET NULL/CASCADE, а RESTRICT
        logger.warning(f"Невозможно удалить тип узла ID={type_id} из-за ограничений внешнего ключа.")
        raise ApiConflict("Невозможно удалить тип узла, так как на него есть ссылки в других таблицах (например, узлы или дочерние типы).")
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при удалении типа узла ID={type_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при удалении типа узла.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при удалении типа узла ID={type_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")