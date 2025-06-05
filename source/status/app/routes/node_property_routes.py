# status/app/routes/node_property_routes.py
"""
Маршруты API для управления типами свойств узлов (node_property_types)
и значениями этих свойств для конкретных типов узлов (node_properties).
"""
import logging
import psycopg2
# import json # Не используется напрямую в этом файле, если репозиторий возвращает Python dict
from flask import Blueprint, request, jsonify, g
from typing import Dict, Any # Для аннотаций типов
from ..repositories import node_property_repository, node_type_repository # Репозитории
from ..errors import (
    ApiBadRequest,
    ApiNotFound,
    ApiConflict, # На случай попытки создать дубликат типа свойства
    ApiInternalError,
    ApiValidationFailure,
    ApiException
)
from flask_login import login_required # Защита маршрутов

logger = logging.getLogger(__name__)
# Создаем Blueprint. Префикс '/api/v1' будет добавлен при регистрации в app/routes/__init__.py,
# так как этот blueprint обрабатывает пути вида /api/v1/node_property_types и /api/v1/node_types/...
bp = Blueprint('node_properties', __name__)

# --- Маршруты для Типов Свойств (node_property_types) ---

@bp.route('/node_property_types', methods=['GET'])
@login_required # Только авторизованные пользователи могут просматривать типы свойств
def api_get_all_node_property_types():
    """
    Возвращает список всех доступных типов свойств узлов.
    Используется, например, в UI для выбора типа свойства при его назначении типу узла.
    """
    logger.info("API NodeProperty Route: Запрос GET /api/v1/node_property_types (все типы свойств)")
    try:
        cursor = g.db_conn.cursor()
        # Вызываем функцию репозитория для получения всех типов свойств
        property_types_list = node_property_repository.get_all_node_property_types(cursor)
        logger.info(f"Успешно получено {len(property_types_list)} типов свойств узлов.")
        return jsonify(property_types_list), 200
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении списка типов свойств узлов: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении списка типов свойств.")
    except Exception as e:
        logger.exception("Неожиданная ошибка сервера при получении списка типов свойств узлов.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")

# CRUD для node_property_types можно добавить при необходимости (POST, PUT, DELETE для /node_property_types/<id>)
# Обычно это справочник, который редко меняется, поэтому CRUD может быть не нужен в API.

# --- Маршруты для Свойств Конкретного Типа Узла (node_properties) ---

@bp.route('/node_types/<int:node_type_id>/properties', methods=['GET'])
@login_required # Только авторизованные пользователи
def api_get_properties_for_node_type(node_type_id: int):
    """
    Возвращает все назначенные свойства (и их значения) для указанного типа узла.
    """
    logger.info(f"API NodeProperty Route: Запрос GET /api/v1/node_types/{node_type_id}/properties")
    try:
        cursor = g.db_conn.cursor()
        # Сначала проверяем, существует ли сам тип узла
        if not node_type_repository.get_node_type_by_id(cursor, node_type_id):
            logger.warning(f"Тип узла с ID={node_type_id} не найден при запросе его свойств.")
            raise ApiNotFound(f"Тип узла с ID={node_type_id} не найден.")

        # Получаем свойства для этого типа узла
        properties_list = node_property_repository.get_properties_for_node_type(cursor, node_type_id)
        logger.info(f"Для типа узла ID={node_type_id} найдено {len(properties_list)} свойств.")
        return jsonify(properties_list), 200
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении свойств для типа узла ID={node_type_id}: {db_err}", exc_info=True)
        raise ApiInternalError(f"Ошибка базы данных при получении свойств для типа узла ID={node_type_id}.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при получении свойств для типа узла ID={node_type_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/node_types/<int:node_type_id>/properties', methods=['PUT'])
@login_required # Только авторизованные пользователи
def api_set_or_update_node_type_properties(node_type_id: int):
    """
    Устанавливает или обновляет значения свойств для указанного типа узла.
    Также может удалять свойства, если значение передано как `null`.
    Принимает JSON-объект, где ключи - это ID типов свойств (property_type_id),
    а значения - это новые значения этих свойств.
    Пример тела запроса: {"1": "new_value_for_prop1", "2": null, "3": "another_value"}
    (где 1, 2, 3 - это property_type_id)
    """
    logger.info(f"API NodeProperty Route: Запрос PUT /api/v1/node_types/{node_type_id}/properties (установка/обновление свойств)")
    properties_to_set_or_delete: Optional[Dict[str, Any]] = request.get_json()

    if not properties_to_set_or_delete or not isinstance(properties_to_set_or_delete, dict):
        raise ApiBadRequest("Тело запроса должно быть непустым JSON-объектом (словарем), "
                            "где ключи - ID типов свойств, а значения - их новые значения (или null для удаления).")

    validation_errors: Dict[str, str] = {}
    parsed_properties: Dict[int, Optional[str]] = {}

    # Валидация ключей (должны быть числами - ID типов свойств) и значений
    for prop_type_id_str, value in properties_to_set_or_delete.items():
        try:
            prop_type_id_int = int(prop_type_id_str)
            if prop_type_id_int <= 0:
                validation_errors[prop_type_id_str] = "ID типа свойства должен быть положительным целым числом."
            else:
                # Значение может быть null (для удаления) или строкой
                parsed_properties[prop_type_id_int] = str(value) if value is not None else None
        except ValueError:
            validation_errors[prop_type_id_str] = "Ключ (ID типа свойства) должен быть целым числом."

    if validation_errors:
        logger.warning(f"Ошибки валидации при установке свойств для типа узла ID={node_type_id}: {validation_errors}")
        raise ApiValidationFailure("Обнаружены ошибки валидации в данных свойств.", details=validation_errors)

    try:
        cursor = g.db_conn.cursor()
        # Проверяем существование типа узла
        if not node_type_repository.get_node_type_by_id(cursor, node_type_id):
            logger.warning(f"Тип узла с ID={node_type_id} не найден при попытке обновить его свойства.")
            raise ApiNotFound(f"Тип узла с ID={node_type_id} не найден.")

        # Выполняем операции с каждым свойством
        operation_errors: Dict[str, str] = {}
        for prop_type_id, prop_value in parsed_properties.items():
            try:
                if prop_value is None: # Если значение null, удаляем свойство
                    deleted = node_property_repository.delete_node_property(cursor, node_type_id, prop_type_id)
                    if not deleted: # Если свойство не было найдено для удаления (это не ошибка, просто факт)
                        logger.info(f"Свойство с type_id={prop_type_id} не было назначено типу узла {node_type_id}, удаление не требуется.")
                else: # Иначе устанавливаем/обновляем значение
                    # Репозиторий set_node_property должен обрабатывать UPSERT логику
                    node_property_repository.set_node_property(cursor, node_type_id, prop_type_id, prop_value)
            except ValueError as e_repo_val: # Ошибки валидации из репозитория (например, неверный property_type_id)
                operation_errors[str(prop_type_id)] = str(e_repo_val)
                logger.warning(f"Ошибка валидации от репозитория для prop_type_id={prop_type_id}: {e_repo_val}")
            except psycopg2.Error as e_db_op:
                operation_errors[str(prop_type_id)] = "Ошибка базы данных при обработке свойства."
                logger.error(f"Ошибка БД при обработке свойства prop_type_id={prop_type_id} для типа узла {node_type_id}: {e_db_op}", exc_info=True)

        if operation_errors:
            # Если были ошибки при обработке отдельных свойств, возвращаем их
            raise ApiBadRequest("Произошли ошибки при обновлении некоторых свойств.", details=operation_errors)

        # g.db_conn.commit() # Если не autocommit

        # Возвращаем актуальный список свойств после всех операций
        updated_properties_list = node_property_repository.get_properties_for_node_type(cursor, node_type_id)
        logger.info(f"API NodeProperty Route: Свойства для типа узла ID={node_type_id} успешно обновлены/установлены/удалены.")
        return jsonify(updated_properties_list), 200

    except psycopg2.Error as db_err: # Общая ошибка БД на уровне транзакции
        logger.error(f"Ошибка БД при обработке обновления свойств для типа узла ID={node_type_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при обработке обновления свойств.")
    except ApiException: # Пробрасываем ApiNotFound, ApiBadRequest из блока выше
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при обновлении свойств для типа узла ID={node_type_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")


@bp.route('/node_types/<int:node_type_id>/properties/<int:property_type_id>', methods=['DELETE'])
@login_required # Только авторизованные пользователи
def api_delete_single_node_property(node_type_id: int, property_type_id: int):
    """
    Удаляет одно конкретное свойство (по его property_type_id) у указанного типа узла.
    """
    logger.info(f"API NodeProperty Route: Запрос DELETE /api/v1/node_types/{node_type_id}/properties/{property_type_id}")
    try:
        cursor = g.db_conn.cursor()
        # Проверяем существование типа узла
        if not node_type_repository.get_node_type_by_id(cursor, node_type_id):
            logger.warning(f"Тип узла с ID={node_type_id} не найден при попытке удалить его свойство.")
            raise ApiNotFound(f"Тип узла с ID={node_type_id} не найден.")

        # Вызываем функцию репозитория для удаления конкретного свойства
        deleted_successfully = node_property_repository.delete_node_property(cursor, node_type_id, property_type_id)

        if not deleted_successfully:
            # Это может означать, что такое свойство просто не было назначено этому типу узла
            logger.warning(f"Свойство с type_id={property_type_id} не найдено для типа узла ID={node_type_id} при попытке удаления.")
            raise ApiNotFound(f"Свойство с ID типа={property_type_id} не найдено для типа узла ID={node_type_id}, или не было назначено.")

        # g.db_conn.commit() # Если не autocommit
        logger.info(f"API NodeProperty Route: Успешно удалено свойство с type_id={property_type_id} для типа узла ID={node_type_id}.")
        return '', 204 # HTTP 204 No Content

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при удалении свойства type_id={property_type_id} для типа узла ID={node_type_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при удалении свойства типа узла.")
    except ApiException: # Пробрасываем ApiNotFound
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка сервера при удалении свойства type_id={property_type_id} для типа узла ID={node_type_id}.")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")