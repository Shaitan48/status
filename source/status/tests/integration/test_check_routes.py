# status/tests/integration/test_check_routes.py
"""
Интеграционные тесты для API эндпоинтов управления Проверками
(/api/v1/checks, /api/v1/node_checks).
"""
import pytest
import json
import logging
import secrets
import psycopg2 # Для ошибок
from datetime import datetime, timezone, timedelta

# Используем фикстуры из conftest.py
# logged_in_client - клиент с выполненным входом (нужен для создания данных)
# client - обычный клиент (для тестов с API ключом)
# db_conn - соединение с БД в транзакции
# app - экземпляр приложения
# runner - для CLI команд (создание API ключа)

# <<< Импортируем нужные ошибки >>>
from app.errors import ApiNotFound, ApiBadRequest, ApiValidationFailure, ApiUnauthorized # Добавили ApiUnauthorized

log = logging.getLogger(__name__)

# --- Фикстура для создания тестовых данных ---
@pytest.fixture(scope='function')
def setup_check_data(logged_in_client, db_conn):
    """
    Создает необходимые данные для тестов проверок:
    - Подразделение
    - Тип узла
    - Узел
    - Метод проверки (PING)
    - Задание (PING для созданного узла)
    Возвращает словарь с ID созданных сущностей.
    """
    log.debug("\n[Setup Check] Создание данных для тестов проверок...")
    created_ids = {}
    cursor = db_conn.cursor()
    try:
        # Очистка
        cursor.execute("DELETE FROM node_checks WHERE assignment_id IN (SELECT id FROM node_check_assignments WHERE node_id IN (SELECT id FROM nodes WHERE name LIKE %s))", ('CheckTest Node%',))
        cursor.execute("DELETE FROM node_check_assignments WHERE node_id IN (SELECT id FROM nodes WHERE name LIKE %s)", ('CheckTest Node%',))
        cursor.execute("DELETE FROM nodes WHERE name LIKE %s", ('CheckTest Node%',))
        cursor.execute("DELETE FROM subdivisions WHERE object_id = %s", (9040,))
        cursor.execute("DELETE FROM node_types WHERE name = %s", ('CheckTest Type',))

        # Создание сущностей
        cursor.execute("INSERT INTO subdivisions (object_id, short_name) VALUES (%s, %s) RETURNING id, object_id", (9040, "CheckTest Sub"))
        sub_res = cursor.fetchone(); sub_id = sub_res['id']; created_ids['subdivision_id'] = sub_id; created_ids['object_id'] = sub_res['object_id']
        log.debug(f"[Setup Check] Subdivision ID={sub_id}, ObjectID={created_ids['object_id']}")

        cursor.execute("INSERT INTO node_types (name) VALUES (%s) RETURNING id", ('CheckTest Type',))
        type_id = cursor.fetchone()['id']; created_ids['node_type_id'] = type_id
        log.debug(f"[Setup Check] Node Type ID={type_id}")

        node_name = f"CheckTest Node {secrets.token_hex(3)}"
        cursor.execute("INSERT INTO nodes (name, parent_subdivision_id, node_type_id, ip_address) VALUES (%s, %s, %s, %s) RETURNING id", (node_name, sub_id, type_id, '4.4.4.4'))
        node_id = cursor.fetchone()['id']; created_ids['node_id'] = node_id
        log.debug(f"[Setup Check] Node ID={node_id}")

        cursor.execute("SELECT id FROM check_methods WHERE method_name = 'PING'")
        ping_res = cursor.fetchone(); assert ping_res, "Метод PING не найден!"
        method_id = ping_res['id']; created_ids['method_ping_id'] = method_id
        log.debug(f"[Setup Check] Method PING ID={method_id}")

        cursor.execute("INSERT INTO node_check_assignments (node_id, method_id, description) VALUES (%s, %s, %s) RETURNING id", (node_id, method_id, 'Test PING Assignment'))
        assign_id = cursor.fetchone()['id']; created_ids['assignment_id'] = assign_id
        log.debug(f"[Setup Check] Assignment ID={assign_id}")

        # db_conn.commit() # Не нужно

        yield created_ids

    except Exception as e:
        log.error(f"ОШИБКА в фикстуре setup_check_data: {e}", exc_info=True)
        # db_conn.rollback() # Откатится само
        pytest.fail(f"Не удалось настроить данные для тестов проверок: {e}")
    # Очистка не нужна, db_conn откатит транзакцию

# --- Фикстура для создания API ключей (агента и загрузчика) ---
@pytest.fixture(scope='function')
def api_keys(runner, setup_check_data):
    """Создает API ключи ролей agent и loader."""
    keys = {}
    object_id = setup_check_data['object_id']
    log.debug(f"[Fixture Keys] Создание ключей (Agent для OID {object_id}, Loader)")

    # Создаем ключ агента
    agent_desc = f"Test Agent Key OID {object_id}"
    agent_result = runner.invoke(args=['create-api-key', '--description', agent_desc, '--role', 'agent', '--object-id', str(object_id)])
    log.debug(f"[Fixture Keys] CLI Agent Key Output: {agent_result.output}")
    # <<< ИСПРАВЛЕНИЕ ЗДЕСЬ >>>
    assert agent_result.exit_code == 0 and 'API Ключ успешно создан!' in agent_result.output, \
        f"Ошибка создания ключа агента: exit_code={agent_result.exit_code}, output='{agent_result.output}'"
    keys['agent'] = agent_result.output.splitlines()[-2].strip()

    # Создаем ключ загрузчика
    loader_desc = "Test Loader Key"
    loader_result = runner.invoke(args=['create-api-key', '--description', loader_desc, '--role', 'loader'])
    log.debug(f"[Fixture Keys] CLI Loader Key Output: {loader_result.output}")
    # <<< ИСПРАВЛЕНИЕ ЗДЕСЬ >>>
    assert loader_result.exit_code == 0 and 'API Ключ успешно создан!' in loader_result.output, \
        f"Ошибка создания ключа загрузчика: exit_code={loader_result.exit_code}, output='{loader_result.output}'"
    keys['loader'] = loader_result.output.splitlines()[-2].strip()

    log.debug(f"[Fixture Keys] Ключи созданы: Agent='{keys['agent'][:5]}...', Loader='{keys['loader'][:5]}...'")
    return keys


# --- Тесты для POST /checks ---

def test_add_check_success_agent(client, db_conn, setup_check_data, api_keys):
    """Тест: Успешная отправка результата проверки ключом агента."""
    log.info("\nТест: POST /api/v1/checks - Успех (Agent)")
    assignment_id = setup_check_data['assignment_id']
    node_id = setup_check_data['node_id']
    object_id = setup_check_data['object_id']
    agent_key = api_keys['agent']
    headers = {'X-API-Key': agent_key, 'Content-Type': 'application/json'}

    timestamp = datetime.now(timezone.utc) - timedelta(seconds=5)
    payload = {
        "assignment_id": assignment_id,
        "is_available": True,
        "check_timestamp": timestamp.isoformat(), # Отправляем ISO строку
        "executor_object_id": object_id,
        "executor_host": "agent-host-01",
        "resolution_method": "PING",
        "detail_type": "PING", # Добавляем детали
        "detail_data": {
            "response_time_ms": 25,
            "ip_address": "4.4.4.4",
            "target_ip": "host.name",
            "ping_count": 1
        },
        "agent_script_version": "agent_v1.0" # Добавляем версии
        # assignment_config_version опускаем для агента
    }

    response = client.post('/api/v1/checks', headers=headers, json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 201, "Ожидался статус 201 Created"
    data = response.get_json()
    assert data and data['status'] == 'success'

    # Проверка в БД
    cursor = db_conn.cursor()
    # Проверка записи в node_checks
    cursor.execute("SELECT * FROM node_checks WHERE assignment_id = %s ORDER BY checked_at DESC LIMIT 1", (assignment_id,))
    check_row = cursor.fetchone()
    assert check_row is not None, "Запись проверки не найдена в node_checks"
    assert check_row['is_available'] is True
    assert check_row['node_id'] == node_id
    assert check_row['executor_object_id'] == object_id
    assert check_row['executor_host'] == "agent-host-01"
    assert check_row['resolution_method'] == "PING"
    assert check_row['agent_script_version'] == "agent_v1.0"
    assert check_row['assignment_config_version'] is None # Не передавали
    # Сравнение времени (учитываем возможную погрешность парсинга/хранения)
    # assert abs(check_row['check_timestamp'] - timestamp).total_seconds() < 1

    # Проверка записи в node_check_details
    check_id = check_row['id']
    cursor.execute("SELECT detail_type, data FROM node_check_details WHERE node_check_id = %s", (check_id,))
    details_row = cursor.fetchone()
    assert details_row is not None, "Запись деталей не найдена в node_check_details"
    assert details_row['detail_type'] == "PING"
    assert details_row['data']['response_time_ms'] == 25
    assert details_row['data']['target_ip'] == "host.name"

    # Проверка обновления last_node_check_id в задании
    cursor.execute("SELECT last_node_check_id, last_executed_at FROM node_check_assignments WHERE id = %s", (assignment_id,))
    assign_row = cursor.fetchone()
    assert assign_row['last_node_check_id'] == check_id
    assert assign_row['last_executed_at'] is not None
    cursor.close()


def test_add_check_success_loader(client, db_conn, setup_check_data, api_keys):
    """Тест: Успешная отправка результата проверки ключом загрузчика."""
    log.info("\nТест: POST /api/v1/checks - Успех (Loader)")
    assignment_id = setup_check_data['assignment_id']
    loader_key = api_keys['loader']
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}

    timestamp = datetime.now(timezone.utc) - timedelta(seconds=10)
    payload = {
        "assignment_id": assignment_id,
        "is_available": False,
        "check_timestamp": timestamp.isoformat(),
        "resolution_method": "offline_loader", # Указываем другой метод
        "detail_type": "ERROR",
        "detail_data": {"message": "Timeout during offline check"},
        # <<< Передаем версии от загрузчика >>>
        "assignment_config_version": "conf_v2.1_abc",
        "agent_script_version": "offline_agent_v3.0"
    }
    # executor_object_id и executor_host не передаем

    response = client.post('/api/v1/checks', headers=headers, json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 201
    data = response.get_json()
    assert data and data['status'] == 'success'

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT is_available, resolution_method, assignment_config_version, agent_script_version FROM node_checks WHERE assignment_id = %s ORDER BY checked_at DESC LIMIT 1", (assignment_id,))
    check_row = cursor.fetchone()
    assert check_row is not None
    assert check_row['is_available'] is False
    assert check_row['resolution_method'] == "offline_loader"
    assert check_row['assignment_config_version'] == "conf_v2.1_abc"
    assert check_row['agent_script_version'] == "offline_agent_v3.0"
    cursor.close()

def test_add_check_invalid_assignment_id(client, api_keys):
    """Тест: Ошибка при отправке результата для несуществующего задания."""
    log.info("\nТест: POST /api/v1/checks - Ошибка (неверный assignment_id)")
    invalid_assignment_id = 99999
    agent_key = api_keys['agent'] # Используем любой валидный ключ
    headers = {'X-API-Key': agent_key, 'Content-Type': 'application/json'}
    payload = {"assignment_id": invalid_assignment_id, "is_available": True}

    response = client.post('/api/v1/checks', headers=headers, json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 404, "Ожидался статус 404 Not Found"
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'NOT_FOUND' # Ошибка из процедуры транслируется в ApiNotFound
    assert 'Задание с ID' in error_data['error']['message']
    assert str(invalid_assignment_id) in error_data['error']['message']

def test_add_check_missing_fields(client, api_keys):
    """Тест: Ошибка при отправке результата с отсутствующими полями."""
    log.info("\nТест: POST /api/v1/checks - Ошибка (нет полей)")
    agent_key = api_keys['agent']
    headers = {'X-API-Key': agent_key, 'Content-Type': 'application/json'}

    # Нет assignment_id
    payload1 = {"is_available": True}
    response1 = client.post('/api/v1/checks', headers=headers, json=payload1)
    assert response1.status_code == 422, "Ожидался 422 при отсутствии assignment_id"
    assert "'assignment_id' is required" in response1.get_data(as_text=True)

    # Нет is_available
    payload2 = {"assignment_id": 1}
    response2 = client.post('/api/v1/checks', headers=headers, json=payload2)
    assert response2.status_code == 422, "Ожидался 422 при отсутствии is_available"
    assert "'is_available' is required" in response2.get_data(as_text=True)

def test_add_check_no_auth(client):
    """Тест: Ошибка при отправке результата без API ключа."""
    log.info("\nТест: POST /api/v1/checks - Ошибка (нет авторизации)")
    payload = {"assignment_id": 1, "is_available": True}
    response = client.post('/api/v1/checks', json=payload) # Без заголовка X-API-Key
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 401, "Ожидался статус 401 Unauthorized"
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'UNAUTHORIZED'
    assert 'Требуется API ключ' in error_data['error']['message']

def test_add_check_invalid_key(client):
    """Тест: Ошибка при отправке результата с неверным API ключом."""
    log.info("\nТест: POST /api/v1/checks - Ошибка (неверный ключ)")
    headers = {'X-API-Key': 'this-is-a-wrong-key', 'Content-Type': 'application/json'}
    payload = {"assignment_id": 1, "is_available": True}
    response = client.post('/api/v1/checks', headers=headers, json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 401, "Ожидался статус 401 Unauthorized"
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'UNAUTHORIZED'
    assert 'Invalid API key' in error_data['error']['message']

def test_add_check_wrong_role(client, runner, api_keys, setup_check_data):
    """Тест: Ошибка при отправке результата с ключом неверной роли (configurator)."""
    log.info("\nТест: POST /api/v1/checks - Ошибка (неверная роль ключа)")
    assignment_id = setup_check_data['assignment_id']
    # Создаем ключ configurator
    config_desc = "Test Configurator Key For Check"
    config_result = runner.invoke(args=['create-api-key', '--description', config_desc, '--role', 'configurator'])
    assert config_result.exit_code == 0
    configurator_key = config_result.output.splitlines()[-2].strip()

    headers = {'X-API-Key': configurator_key, 'Content-Type': 'application/json'}
    payload = {"assignment_id": assignment_id, "is_available": True}
    response = client.post('/api/v1/checks', headers=headers, json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 403, "Ожидался статус 403 Forbidden"
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'FORBIDDEN'
    assert 'insufficient permissions' in error_data['error']['message'].lower()


# --- Тесты для GET /node_checks/<id>/details ---

def test_get_check_details_success(client, db_conn, setup_check_data, api_keys):
    """Тест: Успешное получение деталей проверки."""
    log.info("\nТест: GET /node_checks/{id}/details - Успех")
    assignment_id = setup_check_data['assignment_id']
    agent_key = api_keys['agent']
    headers = {'X-API-Key': agent_key, 'Content-Type': 'application/json'}

    # Сначала отправляем проверку с деталями
    detail_payload = {"response_time_ms": 55}
    payload = {
        "assignment_id": assignment_id, "is_available": True,
        "detail_type": "PING", "detail_data": detail_payload
    }
    post_response = client.post('/api/v1/checks', headers=headers, json=payload)
    assert post_response.status_code == 201

    # Получаем ID созданной проверки из БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT last_node_check_id FROM node_check_assignments WHERE id = %s", (assignment_id,))
    check_id = cursor.fetchone()['last_node_check_id']
    assert check_id is not None

    # Запрашиваем детали этой проверки (используем logged_in_client для удобства, т.к. GET не требует API ключа)
    response = client.get(f'/api/v1/node_checks/{check_id}/details')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 200
    data = response.get_json()
    assert isinstance(data, list)
    assert len(data) == 1
    assert data[0]['detail_type'] == 'PING'
    assert data[0]['data'] == detail_payload # Проверяем содержимое деталей
    cursor.close()

def test_get_check_details_no_details(client, db_conn, setup_check_data, api_keys):
    """Тест: Получение пустого списка деталей, если их не было."""
    log.info("\nТест: GET /node_checks/{id}/details - Успех (нет деталей)")
    assignment_id = setup_check_data['assignment_id']
    agent_key = api_keys['agent']
    headers = {'X-API-Key': agent_key, 'Content-Type': 'application/json'}

    # Отправляем проверку БЕЗ деталей
    payload = {"assignment_id": assignment_id, "is_available": False}
    post_response = client.post('/api/v1/checks', headers=headers, json=payload)
    assert post_response.status_code == 201

    # Получаем ID созданной проверки
    cursor = db_conn.cursor()
    cursor.execute("SELECT last_node_check_id FROM node_check_assignments WHERE id = %s", (assignment_id,))
    check_id = cursor.fetchone()['last_node_check_id']
    assert check_id is not None

    # Запрашиваем детали
    response = client.get(f'/api/v1/node_checks/{check_id}/details')
    assert response.status_code == 200
    data = response.get_json()
    assert isinstance(data, list)
    assert len(data) == 0 # Ожидаем пустой список
    cursor.close()

def test_get_check_details_invalid_id(client):
    """Тест: Получение деталей для несуществующего check_id."""
    log.info("\nТест: GET /node_checks/{id}/details - Not Found (ожидаем пустой список)")
    invalid_check_id = 999990
    response = client.get(f'/api/v1/node_checks/{invalid_check_id}/details')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 200 # API не возвращает 404, а просто пустой список
    data = response.get_json()
    assert isinstance(data, list)
    assert len(data) == 0

# --- Тесты для POST /checks/bulk ---

def test_add_checks_bulk_success(client, db_conn, setup_check_data, api_keys):
    """Тест: Успешная пакетная загрузка валидных результатов."""
    log.info("\nТест: POST /api/v1/checks/bulk - Успех")
    loader_key = api_keys['loader'] # Используем ключ загрузчика
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}

    assign_id = setup_check_data['assignment_id']
    node_id = setup_check_data['node_id']
    # Создадим еще одно задание для разнообразия
    cursor = db_conn.cursor()
    cursor.execute("SELECT id FROM check_methods WHERE method_name = 'SERVICE_STATUS'")
    service_method_id = cursor.fetchone()['id']
    cursor.execute("INSERT INTO node_check_assignments (node_id, method_id, description) VALUES (%s, %s, %s) RETURNING id",
                   (node_id, service_method_id, 'Test Service Assignment Bulk'))
    assign_id_service = cursor.fetchone()['id']

    # Подготавливаем payload как от offline-agent
    ts1 = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
    ts2 = (datetime.now(timezone.utc) - timedelta(seconds=30)).isoformat()
    results_list = [
        { # Результат PING (OK)
            "assignment_id": assign_id,
            "IsAvailable": True,
            "Timestamp": ts1,
            "Details": {"response_time_ms": 10},
            "CheckSuccess": True # Предполагаем, что PowerShell агент это поле добавляет
        },
        { # Результат Service (Stopped, но проверка успешна)
            "assignment_id": assign_id_service,
            "IsAvailable": True, # Проверка выполнилась
            "Timestamp": ts2,
            "Details": {"status": "Stopped", "display_name": "Fake Service"},
            "CheckSuccess": False, # Не соответствует критерию по умолчанию "Running"
            "ErrorMessage": "Status is Stopped"
        }
    ]
    payload = {
        "agent_script_version": "offline_v3.1",
        "assignment_config_version": "conf_abc_123",
        "results": results_list
    }

    response = client.post('/api/v1/checks/bulk', headers=headers, json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 200, "Ожидался статус 200 OK для полностью успешной загрузки"
    data = response.get_json()
    assert data is not None, "Ответ не содержит JSON"
    assert data.get('status') == 'success'
    assert data.get('processed') == 2
    assert data.get('failed') == 0
    assert data.get('total_in_request') == 2

    # Проверка в БД (проверяем последние записи для каждого задания)
    cursor.execute("SELECT is_available, agent_script_version, assignment_config_version FROM node_checks WHERE assignment_id = %s ORDER BY id DESC LIMIT 1", (assign_id,))
    check1 = cursor.fetchone()
    assert check1 and check1['is_available'] is True
    assert check1['agent_script_version'] == 'offline_v3.1'
    assert check1['assignment_config_version'] == 'conf_abc_123'

    # <<< ИЗМЕНЕНИЕ ЗАПРОСА И ПРОВЕРКИ ДЛЯ check2 >>>
    cursor.execute("""
        SELECT
            nc.is_available, nc.agent_script_version, nc.assignment_config_version,
            ncd.data -- Получаем весь JSONB
        FROM node_checks nc
        LEFT JOIN node_check_details ncd ON nc.id = ncd.node_check_id
        WHERE nc.assignment_id = %s ORDER BY nc.id DESC LIMIT 1
        """, (assign_id_service,))
    check2 = cursor.fetchone()
    assert check2 is not None, "Вторая запись проверки не найдена"
    assert check2['is_available'] is True # Проверяем, что IsAvailable сохранился как True
    assert check2['agent_script_version'] == 'offline_v3.1'
    assert check2['assignment_config_version'] == 'conf_abc_123'
    # Проверяем наличие и значение CheckSuccess внутри JSONB поля 'data'
    assert 'data' in check2 and isinstance(check2['data'], dict), "Детали не найдены или не являются словарем"
    assert 'CheckSuccess' in check2['data'], "Ключ 'CheckSuccess' отсутствует в деталях"
    assert check2['data']['CheckSuccess'] is False, "Ожидалось CheckSuccess=False в деталях"
    # Также можно проверить ErrorMessage, если он сохраняется в деталях
    assert 'ErrorMessageFromPS' in check2['data'], "Ключ 'ErrorMessageFromPS' отсутствует в деталях"
    assert check2['data']['ErrorMessageFromPS'] == "Status is Stopped"
    # <<< КОНЕЦ ИЗМЕНЕНИЙ >>>

    # Проверка обновления last_node_check_id
    cursor.execute("SELECT last_node_check_id FROM node_check_assignments WHERE id = %s", (assign_id,))
    assert cursor.fetchone()['last_node_check_id'] is not None
    cursor.execute("SELECT last_node_check_id FROM node_check_assignments WHERE id = %s", (assign_id_service,))
    assert cursor.fetchone()['last_node_check_id'] is not None

    cursor.close()


def test_add_checks_bulk_partial_error(client, db_conn, setup_check_data, api_keys):
    """Тест: Пакетная загрузка с частичными ошибками (невалидный assignment_id)."""
    log.info("\nТест: POST /api/v1/checks/bulk - Частичная ошибка")
    loader_key = api_keys['loader']
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}

    assign_id_valid = setup_check_data['assignment_id']
    assign_id_invalid = 999999

    ts1 = (datetime.now(timezone.utc) - timedelta(minutes=2)).isoformat()
    ts2 = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
    results_list = [
        { # Валидный результат
            "assignment_id": assign_id_valid,
            "IsAvailable": True,
            "Timestamp": ts1
        },
        { # Невалидный assignment_id
            "assignment_id": assign_id_invalid,
            "IsAvailable": False,
            "Timestamp": ts2
        },
         { # Отсутствует IsAvailable
            "assignment_id": assign_id_valid,
            "Timestamp": ts2
        }
    ]
    payload = {
        "agent_script_version": "offline_v3.2",
        "assignment_config_version": "conf_xyz_456",
        "results": results_list
    }

    response = client.post('/api/v1/checks/bulk', headers=headers, json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 207, "Ожидался статус 207 Multi-Status"
    data = response.get_json()
    assert data is not None
    assert data.get('status') == 'partial_error'
    assert data.get('processed') == 1 # Только первая запись должна обработаться
    assert data.get('failed') == 2 # Вторая и третья должны упасть
    assert data.get('total_in_request') == 3
    assert 'errors' in data and isinstance(data['errors'], list) and len(data['errors']) == 2

   # Проверка ошибки для невалидного ID
    error1 = next((e for e in data['errors'] if e.get('index') == 1), None)
    assert error1 is not None
    assert error1.get('assignment_id') == assign_id_invalid
    # <<< ИСПРАВЛЕНО: Проверяем конкретное сообщение об ошибке валидации >>>
    assert 'Validation Error: Задание с ID=' in error1.get('error')
    assert 'не найдено' in error1.get('error')

    # Проверка ошибки для отсутствующего поля
    error2 = next((e for e in data['errors'] if e.get('index') == 2), None)
    assert error2 is not None
    assert error2.get('assignment_id') == assign_id_valid
    assert 'Validation Error' in error2.get('error') and "'IsAvailable' is required" in error2.get('error')

def test_add_checks_bulk_empty_list(client, api_keys):
    """Тест: Отправка пустого массива results."""
    log.info("\nТест: POST /api/v1/checks/bulk - Пустой список")
    loader_key = api_keys['loader']
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}
    payload = {
        "agent_script_version": "offline_v3.3",
        "assignment_config_version": "conf_empty_789",
        "results": [] # Пустой массив
    }
    response = client.post('/api/v1/checks/bulk', headers=headers, json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 200, "Ожидался статус 200 OK"
    data = response.get_json()
    assert data and data.get('status') == 'success'
    assert data.get('processed') == 0
    assert data.get('failed') == 0
    assert 'Empty results array received' in data.get('message', '')

def test_add_checks_bulk_bad_payload(client, api_keys):
    """Тест: Отправка некорректного payload (не объект, нет results)."""
    log.info("\nТест: POST /api/v1/checks/bulk - Некорректный payload")
    loader_key = api_keys['loader']
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}

    # Payload не объект
    response1 = client.post('/api/v1/checks/bulk', headers=headers, json=[1, 2, 3])
    assert response1.status_code == 400, "Ожидался 400 Bad Request для не-объекта"
    assert 'Тело запроса должно быть JSON объектом' in response1.get_json()['error']['message']

    # Нет поля results
    response2 = client.post('/api/v1/checks/bulk', headers=headers, json={"agent_script_version": "v1"})
    assert response2.status_code == 400, "Ожидался 400 Bad Request при отсутствии 'results'"
    assert "'results' должно быть массивом" in response2.get_json()['error']['message']

    # results не массив
    response3 = client.post('/api/v1/checks/bulk', headers=headers, json={"results": "not an array"})
    assert response3.status_code == 400, "Ожидался 400 Bad Request, если 'results' не массив"
    assert "'results' должно быть массивом" in response3.get_json()['error']['message']

def test_add_checks_bulk_wrong_role(client, api_keys):
    """Тест: Ошибка при отправке bulk ключом с ролью 'agent'."""
    log.info("\nТест: POST /api/v1/checks/bulk - Ошибка (неверная роль)")
    agent_key = api_keys['agent'] # Ключ АГЕНТА
    headers = {'X-API-Key': agent_key, 'Content-Type': 'application/json'}
    payload = {"results": []} # Не важно, что внутри
    response = client.post('/api/v1/checks/bulk', headers=headers, json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 403, "Ожидался статус 403 Forbidden"
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'insufficient permissions' in error_data['error']['message'].lower()


# --- Тесты для GET .../checks_history ---

def test_get_node_checks_history_success(client, db_conn, setup_check_data, api_keys):
    """Тест: Успешное получение истории проверок для узла."""
    log.info("\nТест: GET /nodes/{id}/checks_history - Успех")
    node_id = setup_check_data['node_id']
    assign_id1 = setup_check_data['assignment_id'] # PING
    agent_key = api_keys['agent']
    headers = {'X-API-Key': agent_key, 'Content-Type': 'application/json'}

    # Создаем еще одно задание (SERVICE_STATUS) для этого же узла
    cursor = db_conn.cursor()
    cursor.execute("SELECT id FROM check_methods WHERE method_name = 'SERVICE_STATUS'")
    service_method_id = cursor.fetchone()['id']
    cursor.execute("INSERT INTO node_check_assignments (node_id, method_id, description) VALUES (%s, %s, %s) RETURNING id",
                   (node_id, service_method_id, 'History Test Service'))
    assign_id2 = cursor.fetchone()['id']

    # Отправляем несколько результатов для этого узла (разные задания)
    results_to_send = [
        {"assignment_id": assign_id1, "is_available": True, "check_timestamp": (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()},
        {"assignment_id": assign_id2, "is_available": False, "check_timestamp": (datetime.now(timezone.utc) - timedelta(minutes=3)).isoformat()},
        {"assignment_id": assign_id1, "is_available": False, "check_timestamp": (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()}
    ]
    for payload in results_to_send:
        post_resp = client.post('/api/v1/checks', headers=headers, json=payload)
        assert post_resp.status_code == 201, f"Не удалось отправить результат для {payload['assignment_id']}"

    # 1. Запрос истории БЕЗ фильтра по методу
    response_all = client.get(f'/api/v1/nodes/{node_id}/checks_history?limit=10')
    log.info(f"Ответ API (all history): {response_all.status_code}")
    assert response_all.status_code == 200
    history_all = response_all.get_json()
    assert isinstance(history_all, list)
    assert len(history_all) == 3, f"Ожидалось 3 записи в истории, получено {len(history_all)}"

    # <<< НАЧАЛО ИЗМЕНЕНИЙ В ПРОВЕРКЕ >>>
    # Проверяем, что в истории есть правильные записи, не полагаясь на строгий порядок
    # Создаем множества ожидаемых кортежей (assignment_id, is_available)
    expected_results = {
        (assign_id1, True),
        (assign_id2, False),
        (assign_id1, False)
    }
    # Создаем множество реальных кортежей из ответа
    actual_results = {(item['assignment_id'], item['is_available']) for item in history_all}

    # Сравниваем множества
    assert actual_results == expected_results, \
        f"Содержимое истории не совпадает. Ожидалось: {expected_results}, Получено: {actual_results}"

    # Дополнительно проверим сортировку по времени (checked_at):
    # Убедимся, что даты убывают (или равны, если вставки были очень быстрыми)
    timestamps = [datetime.fromisoformat(item['checked_at'].replace('Z', '+00:00')) for item in history_all]
    assert timestamps == sorted(timestamps, reverse=True), "История отсортирована неправильно по checked_at"
    # <<< КОНЕЦ ИЗМЕНЕНИЙ В ПРОВЕРКЕ >>>

    # 2. Запрос истории С ФИЛЬТРОМ по методу PING
    ping_method_id = setup_check_data['method_ping_id']
    response_ping = client.get(f'/api/v1/nodes/{node_id}/checks_history?method_id={ping_method_id}&limit=10')
    log.info(f"Ответ API (ping history): {response_ping.status_code}")
    assert response_ping.status_code == 200
    history_ping = response_ping.get_json()
    assert isinstance(history_ping, list)
    assert len(history_ping) == 2, f"Ожидалось 2 записи PING, получено {len(history_ping)}"
    assert all(h['method_id'] == ping_method_id for h in history_ping)
    # <<< НАЧАЛО ИЗМЕНЕНИЙ В ПРОВЕРКЕ ФИЛЬТРА PING >>>
    # Проверяем значения is_available без строгого порядка, т.к. обе записи от PING
    ping_results_available = {item['is_available'] for item in history_ping}
    assert ping_results_available == {True, False}, "Ожидались записи PING со статусами True и False"
    # Проверяем сортировку по времени
    ping_timestamps = [datetime.fromisoformat(item['checked_at'].replace('Z', '+00:00')) for item in history_ping]
    assert ping_timestamps == sorted(ping_timestamps, reverse=True), "История PING отсортирована неправильно"
    # <<< КОНЕЦ ИЗМЕНЕНИЙ В ПРОВЕРКЕ ФИЛЬТРА PING >>>

    # 3. Запрос истории С ФИЛЬТРОМ по методу SERVICE_STATUS (проверка остается прежней, т.к. одна запись)
    response_service = client.get(f'/api/v1/nodes/{node_id}/checks_history?method_id={service_method_id}&limit=10')
    log.info(f"Ответ API (service history): {response_service.status_code}")
    assert response_service.status_code == 200
    history_service = response_service.get_json()
    assert isinstance(history_service, list)
    assert len(history_service) == 1, f"Ожидалась 1 запись SERVICE_STATUS, получено {len(history_service)}"
    assert history_service[0]['method_id'] == service_method_id
    assert history_service[0]['is_available'] is False

    cursor.close()


def test_get_node_checks_history_not_found(logged_in_client):
    """Тест: Ошибка 404 при запросе истории для несуществующего узла."""
    log.info("\nТест: GET /nodes/{id}/checks_history - 404 Not Found")
    invalid_node_id = 999980
    response = logged_in_client.get(f'/api/v1/nodes/{invalid_node_id}/checks_history')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404, "Ожидался статус 404 Not Found"
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Node with id=' in error_data['error']['message']
    assert 'not found' in error_data['error']['message']


def test_get_assignment_checks_history_success(client, db_conn, setup_check_data, api_keys):
    """Тест: Успешное получение истории проверок для задания."""
    log.info("\nТест: GET /assignments/{id}/checks_history - Успех")
    assignment_id = setup_check_data['assignment_id']
    agent_key = api_keys['agent']
    headers = {'X-API-Key': agent_key, 'Content-Type': 'application/json'}

    # Отправляем несколько результатов для ЭТОГО задания
    client.post('/api/v1/checks', headers=headers, json={"assignment_id": assignment_id, "is_available": True})
    client.post('/api/v1/checks', headers=headers, json={"assignment_id": assignment_id, "is_available": False})
    client.post('/api/v1/checks', headers=headers, json={"assignment_id": assignment_id, "is_available": True})

    # Запрос истории для этого задания
    response = client.get(f'/api/v1/assignments/{assignment_id}/checks_history?limit=10')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200
    history = response.get_json()
    assert isinstance(history, list)
    assert len(history) == 3, f"Ожидалось 3 записи в истории, получено {len(history)}"
    # Проверяем сортировку (последняя запись - первая в списке)
    assert history[0]['is_available'] is True
    assert history[1]['is_available'] is False
    assert history[2]['is_available'] is True


def test_get_assignment_checks_history_not_found(logged_in_client):
    """Тест: Ошибка 404 при запросе истории для несуществующего задания."""
    log.info("\nТест: GET /assignments/{id}/checks_history - 404 Not Found")
    invalid_assignment_id = 999979
    response = logged_in_client.get(f'/api/v1/assignments/{invalid_assignment_id}/checks_history')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404, "Ожидался статус 404 Not Found"
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Assignment with id=' in error_data['error']['message']
    assert 'not found' in error_data['error']['message']

# --- Конец файла ---