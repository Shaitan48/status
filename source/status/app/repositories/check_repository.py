# status/app/repositories/check_repository.py
"""
Репозиторий для работы с результатами проверок (node_checks) и их деталями (node_check_details).
Версия 5.0.2: Адаптировано для записи 'check_success'.
"""
import json
import logging
import psycopg2 # Для типизации и psycopg2.Error
from typing import List, Dict, Any, Optional, Tuple
from datetime import datetime # Для работы с датами

# from ..db_connection import get_db_connection # Не импортируем, курсор передается

logger = logging.getLogger(__name__)

# ============================================================================
# ЗАПИСЬ РЕЗУЛЬТАТА ПРОВЕРКИ (через хранимую процедуру)
# ============================================================================
def record_check_result_proc(
    cursor: psycopg2.extensions.cursor,
    assignment_id: int,
    is_available: bool,
    check_success: Optional[bool], # <<< НОВЫЙ ПАРАМЕТР
    check_timestamp: Optional[datetime],
    executor_object_id: Optional[int],
    executor_host: Optional[str],
    resolution_method: Optional[str],
    detail_type: Optional[str] = None,
    detail_data: Optional[Any] = None, # Может быть dict, list, str (если JSON-строка)
    p_assignment_version: Optional[str] = None, # Используем префикс p_ для соответствия SQL
    p_agent_version: Optional[str] = None
) -> Optional[int]:
    """
    Вызывает хранимую процедуру record_check_result_proc для атомарной записи
    результата проверки, включая детали, и обновления задания.

    Args:
        cursor: Активный курсор базы данных.
        assignment_id: ID задания.
        is_available: Основной статус доступности.
        check_success: Результат выполнения критериев (True, False, None).
        check_timestamp: Время выполнения проверки на агенте (UTC datetime или None).
        executor_object_id: ID объекта-исполнителя.
        executor_host: Хост исполнителя.
        resolution_method: Метод/тип проверки.
        detail_type: Тип деталей (для node_check_details).
        detail_data: Данные деталей (будут преобразованы в JSONB).
        p_assignment_version: Версия конфигурации заданий.
        p_agent_version: Версия скрипта агента.

    Returns:
        ID созданной записи в node_checks или None при ошибке.
    """
    sql_proc_call = """
        CALL record_check_result_proc(
            p_assignment_id => %(assign_id)s,
            p_is_available => %(is_avail)s,
            p_check_success => %(chk_success)s, -- <<< ПЕРЕДАЕМ НОВЫЙ ПАРАМЕТР
            p_check_timestamp => %(chk_ts)s,
            p_executor_object_id => %(exec_oid)s,
            p_executor_host => %(exec_host)s,
            p_resolution_method => %(res_method)s,
            p_detail_type => %(det_type)s,
            p_detail_data => %(det_data)s,
            p_assignment_version => %(assign_ver)s,
            p_agent_version => %(agent_ver)s
        );
    """
    # Преобразуем detail_data в JSON-строку, если это dict или list,
    # так как psycopg2 лучше работает с JSON-строками для типа JSONB в процедурах,
    # особенно если detail_data может быть None.
    detail_data_json_str: Optional[str] = None
    if detail_data is not None:
        if isinstance(detail_data, (dict, list)):
            try:
                detail_data_json_str = json.dumps(detail_data)
            except TypeError as te:
                logger.error(f"Ошибка сериализации detail_data в JSON для assignment_id {assignment_id}: {te}", exc_info=True)
                # Решаем, что делать: отправить null, пустой объект или вызвать ошибку
                # Пока отправляем null, чтобы не прерывать запись основного результата
                detail_data_json_str = json.dumps({"_serialization_error": str(te)})
        elif isinstance(detail_data, str): # Если это уже строка (например, готовый JSON)
            detail_data_json_str = detail_data
        else: # Преобразуем в строку, если это что-то другое
            detail_data_json_str = json.dumps({"value": str(detail_data)})


    params = {
        'assign_id': assignment_id,
        'is_avail': is_available,
        'chk_success': check_success, # <<< НОВЫЙ ПАРАМЕТР
        'chk_ts': check_timestamp,
        'exec_oid': executor_object_id,
        'exec_host': executor_host,
        'res_method': resolution_method,
        'det_type': detail_type,
        'det_data': detail_data_json_str, # Передаем JSON-строку (или None)
        'assign_ver': p_assignment_version,
        'agent_ver': p_agent_version
    }
    logger.debug(f"Репозиторий: Вызов record_check_result_proc с параметрами (кроме detail_data): "
                 f"assign_id={params['assign_id']}, is_avail={params['is_avail']}, chk_success={params['chk_success']}, "
                 f"chk_ts={params['chk_ts']}, exec_oid={params['exec_oid']}, assign_ver={params['assign_ver']}")
    try:
        cursor.execute(sql_proc_call, params)
        # Процедура CALL не возвращает значения напрямую через RETURNING в Python так же, как SELECT.
        # ID новой записи node_checks теперь будет доступен через обновление last_node_check_id в assignments.
        # Мы можем запросить его, если это критично, или положиться на логику обновления в процедуре.
        # Для простоты, здесь не будем пытаться получить ID напрямую из CALL.
        # Если бы это была функция, можно было бы: new_check_id = cursor.fetchone()['id']
        logger.info(f"Результат для задания ID {assignment_id} успешно передан в процедуру record_check_result_proc.")
        # Так как ID не возвращается, возвращаем None или True/False в зависимости от того,
        # ожидаем ли мы ID от этой функции. Пока вернем 1 как признак вызова (устаревшее поведение)
        # или лучше None, т.к. ID не получен. Давайте изменим на возврат None, т.к. ID не извлекается.
        # Однако, чтобы не ломать существующие вызовы, которые могут ожидать ID,
        # лучше всего, если процедура могла бы вернуть ID через OUT параметр или
        # Flask-эндпоинт получал бы ID из другого источника, если он ему нужен.
        # Пока оставим возвращаемое значение как есть (не None), т.к. Flask-роут его не использует.
        # Изменим на возврат None, так как ID не получаем.
        # Если роуту нужен ID, он должен его получить по-другому (например, через SELECT MAX(id) или SELECT по last_node_check_id задания).
        # В контексте процедуры, которая сама обновляет last_node_check_id, это может быть не нужно.
        # **Уточнение:** Процедура обновляет last_node_check_id. Если ID нужен в Python,
        # можно сделать SELECT currval(pg_get_serial_sequence('node_checks', 'id')) ПОСЛЕ CALL,
        # но это требует осторожности в транзакциях.
        # Для простоты, здесь не будем возвращать ID.
        return None # ID созданной записи теперь не возвращается явно этой функцией
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при вызове record_check_result_proc для задания ID {assignment_id}: {e}", exc_info=True)
        # Пробрасываем ошибку дальше, чтобы ее мог обработать вызывающий код (например, Flask route)
        # и откатить транзакцию, если это необходимо.
        raise
    except Exception as ex_proc: # Другие возможные ошибки
        logger.error(f"Репозиторий: Неожиданная ошибка при вызове record_check_result_proc для задания ID {assignment_id}: {ex_proc}", exc_info=True)
        raise

# ============================================================================
# ПОЛУЧЕНИЕ ИСТОРИИ И ДЕТАЛЕЙ ПРОВЕРОК
# ============================================================================

def fetch_check_details(cursor: psycopg2.extensions.cursor, node_check_id: int) -> List[Dict[str, Any]]:
    """
    Получает все детали для указанного результата проверки (node_check_id).
    Поле 'data' (JSONB) десериализуется psycopg2 (если используется RealDictCursor).
    """
    sql = "SELECT id, detail_type, data FROM node_check_details WHERE node_check_id = %s ORDER BY id;"
    logger.debug(f"Репозиторий: Запрос деталей для node_check_id={node_check_id}")
    try:
        cursor.execute(sql, (node_check_id,))
        details_list = cursor.fetchall() # Список словарей
        # Если psycopg2 не десериализовал JSONB 'data' (например, если это строка),
        # можно добавить десериализацию здесь, но обычно RealDictCursor с JSONB это делает.
        # for detail_item in details_list:
        #     if 'data' in detail_item and isinstance(detail_item['data'], str):
        #         try: detail_item['data'] = json.loads(detail_item['data'])
        #         except json.JSONDecodeError: logger.warning(...)
        return details_list
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении деталей для node_check_id {node_check_id}: {e}", exc_info=True)
        raise

def fetch_node_checks_history(
    cursor: psycopg2.extensions.cursor,
    node_id: int,
    method_id_filter: Optional[int] = None,
    limit: int = 50
) -> List[Dict[str, Any]]:
    """
    Получает историю последних N результатов проверок для узла.
    Может фильтроваться по ID метода проверки.
    Включает поле check_success.
    """
    sql_base = """
        SELECT
            nc.id, nc.assignment_id, nc.method_id, cm.method_name,
            nc.is_available, nc.check_success, -- <<< ВКЛЮЧАЕМ check_success
            nc.checked_at, nc.check_timestamp,
            nc.executor_object_id, nc.executor_host, nc.resolution_method,
            nc.assignment_config_version, nc.agent_script_version,
            EXISTS (SELECT 1 FROM node_check_details ncd WHERE ncd.node_check_id = nc.id) AS has_details
        FROM node_checks nc
        JOIN check_methods cm ON nc.method_id = cm.id
        WHERE nc.node_id = %(node_id_param)s
    """
    params: Dict[str, Any] = {'node_id_param': node_id, 'limit_param': limit}
    if method_id_filter is not None:
        sql_base += " AND nc.method_id = %(method_id_param)s"
        params['method_id_param'] = method_id_filter
    
    sql_final = sql_base + " ORDER BY nc.checked_at DESC, nc.id DESC LIMIT %(limit_param)s;"
    logger.debug(f"Репозиторий: Запрос истории проверок для node_id={node_id}, method_id={method_id_filter}, limit={limit}")
    try:
        cursor.execute(sql_final, params)
        history_list = cursor.fetchall()
        return history_list
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении истории проверок для узла {node_id}: {e}", exc_info=True)
        raise

def fetch_assignment_checks_history(
    cursor: psycopg2.extensions.cursor,
    assignment_id: int,
    limit: int = 50
) -> List[Dict[str, Any]]:
    """
    Получает историю последних N результатов проверок для задания.
    Включает поле check_success.
    """
    # SQL-запрос очень похож на fetch_node_checks_history, только фильтр по assignment_id
    sql = """
        SELECT
            nc.id, nc.node_id, n.name as node_name, nc.method_id, cm.method_name,
            nc.is_available, nc.check_success, -- <<< ВКЛЮЧАЕМ check_success
            nc.checked_at, nc.check_timestamp,
            nc.executor_object_id, nc.executor_host, nc.resolution_method,
            nc.assignment_config_version, nc.agent_script_version,
            EXISTS (SELECT 1 FROM node_check_details ncd WHERE ncd.node_check_id = nc.id) AS has_details
        FROM node_checks nc
        JOIN nodes n ON nc.node_id = n.id
        JOIN check_methods cm ON nc.method_id = cm.id
        WHERE nc.assignment_id = %(assign_id_param)s
        ORDER BY nc.checked_at DESC, nc.id DESC
        LIMIT %(limit_param)s;
    """
    params: Dict[str, Any] = {'assign_id_param': assignment_id, 'limit_param': limit}
    logger.debug(f"Репозиторий: Запрос истории проверок для assignment_id={assignment_id}, limit={limit}")
    try:
        cursor.execute(sql, params)
        history_list = cursor.fetchall()
        return history_list
    except psycopg2.Error as e:
        logger.error(f"Репозиторий: Ошибка БД при получении истории проверок для задания {assignment_id}: {e}", exc_info=True)
        raise

# ============================================================================
# Конец файла
# ============================================================================