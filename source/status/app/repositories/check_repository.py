# status/app/repositories/check_repository.py
import logging
import psycopg2
import json
from datetime import datetime # Добавлено
from typing import List, Dict, Any, Optional

logger = logging.getLogger(__name__)

# <<< Обновленная сигнатура функции и вызов процедуры >>>
def record_check_result_proc(cursor,
                             assignment_id: int,
                             is_available: bool,
                             check_timestamp: Optional[datetime],
                             executor_object_id: Optional[int],
                             executor_host: Optional[str],
                             resolution_method: Optional[str],
                             detail_type: Optional[str],
                             detail_data: Optional[Any], # Принимаем любой тип данных (dict, list, etc.)
                             # <<< НОВЫЕ ПАРАМЕТРЫ >>>
                             p_assignment_version: Optional[str] = None,
                             p_agent_version: Optional[str] = None):
    """
    Вызывает хранимую процедуру record_check_result для записи результата проверки.

    :param cursor: Курсор базы данных.
    :param assignment_id: ID задания.
    :param is_available: Статус доступности.
    :param check_timestamp: Время проверки на агенте (UTC).
    :param executor_object_id: ID объекта исполнителя.
    :param executor_host: Имя хоста исполнителя.
    :param resolution_method: Метод проверки.
    :param detail_type: Тип деталей (строка).
    :param detail_data: Данные деталей (объект Python, будет преобразован в JSONB процедурой).
    :param p_assignment_version: Версия конфигурации заданий.
    :param p_agent_version: Версия скрипта агента.
    :raises ValueError: Если задание не найдено (ошибка P0002 от процедуры).
    :raises psycopg2.Error: При других ошибках базы данных.
    """
    # Преобразуем detail_data в JSON строку, если это необходимо для передачи в процедуру,
    # которая ожидает JSONB (psycopg2 может сам преобразовывать dict/list в JSONB)
    # Оставляем как есть, процедура сама примет JSONB
    detail_data_for_proc = detail_data # Передаем Python объект

    try:
        # Формируем словарь параметров для вызова процедуры
        sql_params = {
            'p_assignment_id': assignment_id,
            'p_is_available': is_available,
            'p_check_timestamp': check_timestamp,
            'p_executor_object_id': executor_object_id,
            'p_executor_host': executor_host,
            'p_resolution_method': resolution_method,
            'p_detail_type': detail_type,
            'p_detail_data': json.dumps(detail_data_for_proc) if detail_data_for_proc is not None else None, # psycopg2 требует строку для JSONB или использует адаптер
            # <<< ПЕРЕДАЕМ НОВЫЕ ПАРАМЕТРЫ >>>
            'p_assignment_version': p_assignment_version,
            'p_agent_version': p_agent_version
        }
        # Формируем строку вызова процедуры с именованными параметрами
        sql_call = '''
            CALL record_check_result(
                p_assignment_id => %(p_assignment_id)s,
                p_is_available => %(p_is_available)s,
                p_check_timestamp => %(p_check_timestamp)s,
                p_executor_object_id => %(p_executor_object_id)s,
                p_executor_host => %(p_executor_host)s,
                p_resolution_method => %(p_resolution_method)s,
                p_detail_type => %(p_detail_type)s,
                p_detail_data => %(p_detail_data)s::jsonb, -- Явно указываем тип
                p_assignment_version => %(p_assignment_version)s,
                p_agent_version => %(p_agent_version)s
            );
        '''
        cursor.execute(sql_call, sql_params)
        logger.info(f"Вызвана процедура record_check_result для assignment_id={assignment_id}")

    except psycopg2.Error as db_err:
        # Перехватываем ошибку "задание не найдено" и преобразуем в ValueError
        if hasattr(db_err, 'pgcode') and db_err.pgcode == 'P0002':
            logger.warning(f"Задание ID {assignment_id} не найдено при вызове record_check_result.")
            raise ValueError(f"Задание с ID={assignment_id} не найдено.") from db_err
        else:
            # Другие ошибки БД пробрасываем дальше
            logger.error(f"Ошибка БД при вызове record_check_result для assignment_id={assignment_id}: {db_err}", exc_info=True)
            raise

def fetch_check_details(cursor, node_check_id: int) -> List[Dict[str, Any]]:
    query = "SELECT id, detail_type, data FROM node_check_details WHERE node_check_id = %(check_id)s;"
    cursor.execute(query, {'check_id': node_check_id}); details = cursor.fetchall()
    # Пост-обработка JSON в route
    return details

def fetch_node_checks_history(cursor, node_id: int, method_id: Optional[int] = None, limit: int = 50) -> List[Dict[str, Any]]:
    # ... (Можно добавить выборку agent_version, assignment_version)
    query = '''
        SELECT
            nc.id, nc.node_id, nc.assignment_id, nc.method_id, nc.is_available,
            nc.checked_at, nc.check_timestamp, nc.executor_object_id, nc.executor_host,
            nc.resolution_method, cm.method_name,
            nc.agent_script_version, nc.assignment_config_version, -- <<< ДОБАВЛЕНО
            (SELECT EXISTS (SELECT 1 FROM node_check_details ncd WHERE ncd.node_check_id = nc.id)) as has_details
        FROM node_checks nc
        JOIN check_methods cm ON nc.method_id = cm.id
        WHERE nc.node_id = %(node_id)s
    '''
    params = {'node_id': node_id, 'limit': limit};
    if method_id is not None: query += " AND nc.method_id = %(method_id)s"; params['method_id'] = method_id;
    query += " ORDER BY nc.checked_at DESC LIMIT %(limit)s;"
    cursor.execute(query, params); history = cursor.fetchall()
    # Пост-обработка дат в route
    return history

def fetch_assignment_checks_history(cursor, assignment_id: int, limit: int = 50) -> List[Dict[str, Any]]:
    # ... (Можно добавить выборку agent_version, assignment_version)
    query = '''
        SELECT
            nc.id, nc.node_id, nc.assignment_id, nc.method_id, nc.is_available,
            nc.checked_at, nc.check_timestamp, nc.executor_object_id, nc.executor_host,
            nc.resolution_method, cm.method_name,
            nc.agent_script_version, nc.assignment_config_version, -- <<< ДОБАВЛЕНО
            (SELECT EXISTS (SELECT 1 FROM node_check_details ncd WHERE ncd.node_check_id = nc.id)) as has_details
        FROM node_checks nc
        JOIN check_methods cm ON nc.method_id = cm.id
        WHERE nc.assignment_id = %(assignment_id)s ORDER BY nc.checked_at DESC LIMIT %(limit)s;
    '''
    params = {'assignment_id': assignment_id, 'limit': limit}; cursor.execute(query, params); history = cursor.fetchall()
    # Пост-обработка дат в route
    return history
