# status/app/routes/agent_routes.py
"""
Маршруты API, предназначенные для взаимодействия с Hybrid-Agent и Конфигуратором.
Версия для pipeline-архитектуры (v5.x).
"""
import logging
import psycopg2 # Для обработки ошибок psycopg2.Error
import json     # Для работы с JSON (хотя psycopg2 обычно сам десериализует JSONB)
from flask import Blueprint, request, jsonify, g # g для доступа к db_conn
# from ..repositories import assignment_repository # Не используется напрямую, т.к. вызываются SQL-функции
# from ..db_connection import get_connection       # Соединение через g
from ..errors import ApiBadRequest, ApiNotFound, ApiInternalError, ApiException # Кастомные исключения
from ..auth_utils import api_key_required        # Декоратор для проверки API-ключа

logger = logging.getLogger(__name__)
bp = Blueprint('agents', __name__) # Префикс '/api/v1' будет добавлен при регистрации

@bp.route('/assignments', methods=['GET'])
@api_key_required(required_role='agent') # Защита: только для ключей с ролью 'agent'
def get_assignments_for_agent():
    """
    Возвращает список активных заданий (pipeline) для указанного `object_id`.
    Используется Hybrid-Agent в "онлайн" режиме для получения своих задач.
    Задания извлекаются с помощью SQL-функции get_active_assignments_for_object,
    которая уже фильтрует по is_enabled=TRUE.

    Query Params:
        object_id (int, required): ID объекта (подразделения), для которого запрашиваются задания.

    Returns:
        JSON: Список объектов заданий.
              Каждое задание содержит поле `pipeline` (массив шагов),
              и не содержит устаревшие `parameters` или `success_criteria` на верхнем уровне.
    """
    object_id_str = request.args.get('object_id')
    logger.info(f"API Agent (Pipeline): Запрос /assignments для object_id={object_id_str}")

    if not object_id_str:
        raise ApiBadRequest("Отсутствует обязательный параметр 'object_id'.")
    try:
        object_id = int(object_id_str)
        if object_id <= 0:
            raise ValueError("object_id должен быть положительным.")
    except ValueError:
        raise ApiBadRequest("Параметр 'object_id' должен быть положительным целым числом.")

    try:
        cursor = g.db_conn.cursor() # Используем RealDictCursor из g
        # SQL-функция get_active_assignments_for_object уже фильтрует по is_enabled=TRUE
        # и возвращает поле pipeline (JSONB из БД, psycopg2 должен его десериализовать в dict/list)
        cursor.execute("SELECT * FROM get_active_assignments_for_object(%(obj_id)s);", {'obj_id': object_id})
        assignments_raw = cursor.fetchall() # Список RealDictRow

        assignments_processed = []
        for assign_dict_row in assignments_raw: # assign_dict_row это уже dict благодаря RealDictCursor
            # Поле 'pipeline' из JSONB должно приходить как Python list/dict.
            # Если оно пришло как строка (маловероятно с JSONB и RealDictCursor), то десериализуем.
            # Если pipeline IS NULL в БД, то assign_dict_row.get('pipeline') будет None.
            current_pipeline = assign_dict_row.get('pipeline')
            if isinstance(current_pipeline, str):
                try:
                    current_pipeline = json.loads(current_pipeline)
                except json.JSONDecodeError:
                    logger.error(f"Ошибка декодирования JSON для pipeline в задании ID {assign_dict_row.get('assignment_id')} для object_id {object_id}. Pipeline: {current_pipeline}")
                    current_pipeline = {"_error": "Invalid pipeline JSON format in DB"}
            
            # Убедимся, что pipeline - это список, или null/пустой список, если так пришло
            if current_pipeline is None:
                current_pipeline = [] # Агент может ожидать массив
            
            assign_dict_row['pipeline'] = current_pipeline

            # Удаляем устаревшие поля, если они вдруг есть в результате SQL-функции (хотя не должны)
            assign_dict_row.pop('parameters', None)
            assign_dict_row.pop('success_criteria', None)
            
            assignments_processed.append(assign_dict_row)

        logger.info(f"API Agent (Pipeline): Для object_id={object_id} отдано {len(assignments_processed)} заданий.")
        return jsonify(assignments_processed)

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении заданий для object_id={object_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении заданий.")
    except ApiException:
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка при получении заданий для object_id={object_id}")
        raise ApiInternalError(f"Внутренняя ошибка сервера при получении заданий: {type(e).__name__} - {e}")


@bp.route('/objects/<int:object_id>/offline_config', methods=['GET'])
@api_key_required(required_role='configurator') # Защита: только для ключей с ролью 'configurator'
def get_offline_config(object_id: int):
    """
    Генерирует и возвращает JSON-конфигурацию для оффлайн-режима Hybrid-Agent
    для указанного `object_id`. Конфигурация извлекается SQL-функцией generate_offline_config,
    которая теперь включает pipeline-задания и фильтрует по is_enabled=TRUE.

    Path Params:
        object_id (int, required): ID объекта (подразделения).

    Returns:
        JSON: Объект конфигурации, содержащий метаданные и массив `assignments`,
              где каждое задание имеет поле `pipeline`.
    """
    logger.info(f"API Agent (Pipeline): Запрос /objects/{object_id}/offline_config")

    if object_id <= 0:
        raise ApiBadRequest("Параметр 'object_id' (в пути) должен быть положительным целым числом.")

    try:
        cursor = g.db_conn.cursor()
        # SQL-функция generate_offline_config возвращает JSONB, который psycopg2 преобразует в Python dict/list
        cursor.execute("SELECT generate_offline_config(%(obj_id)s) as config_json;", {'obj_id': object_id})
        result_row = cursor.fetchone()

        if not result_row or result_row.get('config_json') is None:
            logger.error(f"SQL-функция generate_offline_config не вернула результат для object_id={object_id}.")
            raise ApiNotFound(f"Конфигурация для object_id={object_id} не найдена или не может быть сгенерирована (SQL-функция не вернула данные).")

        config_data = result_row['config_json'] # Это уже Python dict/list

        # Проверка на наличие поля 'error' внутри JSON ответа SQL-функции
        if isinstance(config_data, dict) and config_data.get('error'):
            error_message_from_sql = config_data.get('message', config_data.get('error'))
            logger.warning(f"Ошибка от SQL-функции generate_offline_config для object_id={object_id}: {error_message_from_sql}")
            # Чаще всего это будет "Subdivision not found" или "transport_system_code is missing"
            raise ApiNotFound(f"Не удалось сгенерировать конфигурацию для object_id={object_id}: {error_message_from_sql}")

        # Обработка поля 'pipeline' внутри каждого задания в массиве 'assignments'
        # (на случай, если SQL-функция вернула pipeline как JSON-строку внутри своего JSON-ответа)
        if isinstance(config_data, dict) and 'assignments' in config_data and isinstance(config_data['assignments'], list):
            for assignment_item in config_data['assignments']:
                if isinstance(assignment_item, dict) and 'pipeline' in assignment_item:
                    current_item_pipeline = assignment_item['pipeline']
                    if isinstance(current_item_pipeline, str): # Если это строка, пытаемся десериализовать
                        try:
                            assignment_item['pipeline'] = json.loads(current_item_pipeline)
                        except json.JSONDecodeError:
                            assign_id_log = assignment_item.get('assignment_id', 'N/A')
                            logger.error(f"Ошибка декодирования JSON для pipeline в оффлайн-конфиге, задание ID {assign_id_log}, object_id {object_id}. Pipeline: {current_item_pipeline}")
                            assignment_item['pipeline'] = {"_error": "Invalid pipeline JSON in DB for offline config"}
                    
                    # Убедимся, что pipeline - это список, или null/пустой, если так пришло
                    if assignment_item['pipeline'] is None:
                        assignment_item['pipeline'] = []

                    # Удаляем устаревшие поля, если они вдруг есть
                    assignment_item.pop('parameters', None)
                    assignment_item.pop('success_criteria', None)
        else: # Если структура ответа от SQL-функции неожиданная
            logger.error(f"Некорректная структура JSON от generate_offline_config для object_id={object_id}. Ожидался объект с массивом 'assignments'. Получено: {type(config_data)}")
            raise ApiInternalError("Сервер вернул некорректную структуру конфигурации от SQL-функции.")


        logger.info(f"API Agent (Pipeline): Успешно сгенерирован offline_config для object_id={object_id}")
        return jsonify(config_data)

    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при генерации оффлайн конфигурации для object_id={object_id}: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при генерации оффлайн конфигурации.")
    except ApiException:
        raise
    except Exception as e:
        logger.exception(f"Неожиданная ошибка при генерации оффлайн конфигурации для object_id={object_id}")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {type(e).__name__} - {e}")