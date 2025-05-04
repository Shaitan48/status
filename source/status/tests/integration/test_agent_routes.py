# status/tests/integration/test_agent_routes.py
"""
Интеграционные тесты для API эндпоинтов, используемых агентами и конфигуратором
(/api/v1/assignments?object_id=..., /api/v1/objects/<id>/offline_config).
"""
import pytest
import json
import logging
import secrets
import psycopg2

# Используем фикстуры из conftest.py
# logged_in_client - для создания данных
# client - для тестов с API ключом
# db_conn - для прямых проверок/манипуляций с БД
# runner - для создания API ключей
# app - экземпляр приложения

# <<< Импортируем нужные ошибки >>>
from app.errors import ApiNotFound, ApiBadRequest, ApiUnauthorized, ApiForbidden

log = logging.getLogger(__name__)

# --- Фикстура для создания тестовых данных ---
@pytest.fixture(scope='function')
def setup_agent_data(logged_in_client, db_conn):
    """
    Создает данные для тестов агентов:
    - 2 Подразделения (одно с кодом ТС, другое без)
    - 3 Узла (2 в первом подразделении, 1 во втором)
    - 3 Задания (2 PING, 1 SERVICE_STATUS; одно отключено)
    Возвращает словарь с ID и другими полезными данными.
    """
    log.debug("\n[Setup Agent] Создание данных для тестов агентов...")
    created_data = {'nodes': [], 'assignments': []}
    cursor = db_conn.cursor()
    try:
        # Очистка
        cursor.execute("DELETE FROM node_check_assignments WHERE node_id IN (SELECT id FROM nodes WHERE name LIKE %s)", ('AgentTest%',))
        cursor.execute("DELETE FROM nodes WHERE name LIKE %s", ('AgentTest%',))
        cursor.execute("DELETE FROM subdivisions WHERE object_id IN (%s, %s)", (9050, 9051))
        # cursor.execute("DELETE FROM check_methods WHERE method_name IN ('PING', 'SERVICE_STATUS')") # Не удаляем базовые методы

        # Создание Подразделений
        cursor.execute("INSERT INTO subdivisions (object_id, short_name, transport_system_code) VALUES (%s, %s, %s) RETURNING id, object_id", (9050, "Agent Sub Online", "AGTSONL"))
        sub1_res = cursor.fetchone(); created_data['sub1_id'] = sub1_res['id']; created_data['sub1_oid'] = sub1_res['object_id']; created_data['sub1_tc'] = "AGTSONL"
        cursor.execute("INSERT INTO subdivisions (object_id, short_name) VALUES (%s, %s) RETURNING id, object_id", (9051, "Agent Sub Offline"))
        sub2_res = cursor.fetchone(); created_data['sub2_id'] = sub2_res['id']; created_data['sub2_oid'] = sub2_res['object_id']
        log.debug(f"[Setup Agent] Subdivisions created: ID={sub1_res['id']}(OID={sub1_res['object_id']}, TC='AGTSONL'), ID={sub2_res['id']}(OID={sub2_res['object_id']})")

        # Создание Узлов
        node_data = [
            ('AgentTest Node 1', sub1_res['id'], '5.5.5.5'), # В первом подразделении
            ('AgentTest Node 2', sub1_res['id'], '6.6.6.6'), # В первом подразделении
            ('AgentTest Node 3', sub2_res['id'], '7.7.7.7')  # Во втором подразделении
        ]
        for name, sub_id, ip in node_data:
            cursor.execute("INSERT INTO nodes (name, parent_subdivision_id, ip_address) VALUES (%s, %s, %s) RETURNING id", (name, sub_id, ip))
            created_data['nodes'].append(cursor.fetchone()['id'])
        log.debug(f"[Setup Agent] Nodes created: IDs={created_data['nodes']}")

        # Получение ID методов
        cursor.execute("SELECT id FROM check_methods WHERE method_name = 'PING'")
        ping_id = cursor.fetchone()['id']
        cursor.execute("SELECT id FROM check_methods WHERE method_name = 'SERVICE_STATUS'")
        service_id = cursor.fetchone()['id']
        created_data['method_ping_id'] = ping_id
        created_data['method_service_id'] = service_id

        # Создание Заданий
        assignment_data = [
            # Задание 1: PING для Node 1 (включено)
            (created_data['nodes'][0], ping_id, True, None, 60, 'Ping Node 1'),
            # Задание 2: SERVICE_STATUS для Node 1 (включено)
            (created_data['nodes'][0], service_id, True, json.dumps({"service_name": "Spooler"}), None, 'Service Node 1'),
            # Задание 3: PING для Node 2 (ОТКЛЮЧЕНО)
            (created_data['nodes'][1], ping_id, False, None, 120, 'Ping Node 2 (Disabled)'),
            # Задание 4: PING для Node 3 (в другом подразделении)
            (created_data['nodes'][2], ping_id, True, None, 90, 'Ping Node 3')
        ]
        for node_id, meth_id, enabled, params, interval, desc in assignment_data:
            cursor.execute("""
                INSERT INTO node_check_assignments
                (node_id, method_id, is_enabled, parameters, check_interval_seconds, description)
                VALUES (%s, %s, %s, %s::jsonb, %s, %s) RETURNING id
            """, (node_id, meth_id, enabled, params, interval, desc))
            created_data['assignments'].append(cursor.fetchone()['id'])
        log.debug(f"[Setup Agent] Assignments created: IDs={created_data['assignments']}")

        # db_conn.commit() # Не нужно

        yield created_data

    except Exception as e:
        log.error(f"ОШИБКА в фикстуре setup_agent_data: {e}", exc_info=True)
        # db_conn.rollback()
        pytest.fail(f"Не удалось настроить данные для тестов агентов: {e}")

    # Очистка не нужна

# --- Фикстура для API ключей (аналогична test_check_routes) ---
@pytest.fixture(scope='function')
def agent_api_keys(runner, setup_agent_data):
    """Создает API ключи ролей agent и configurator."""
    keys = {}
    oid1 = setup_agent_data['sub1_oid']
    oid2 = setup_agent_data['sub2_oid']

    # Ключ agent для первого подразделения
    res1 = runner.invoke(args=['create-api-key', '--description', f'Agent Key {oid1}', '--role', 'agent', '--object-id', str(oid1)])
    assert res1.exit_code == 0 and 'API Ключ успешно создан!' in res1.output
    keys['agent1'] = res1.output.splitlines()[-2].strip()

    # Ключ agent для второго подразделения
    res2 = runner.invoke(args=['create-api-key', '--description', f'Agent Key {oid2}', '--role', 'agent', '--object-id', str(oid2)])
    assert res2.exit_code == 0 and 'API Ключ успешно создан!' in res2.output
    keys['agent2'] = res2.output.splitlines()[-2].strip()

    # Ключ configurator (можно без object_id)
    res3 = runner.invoke(args=['create-api-key', '--description', 'Configurator Key', '--role', 'configurator'])
    assert res3.exit_code == 0 and 'API Ключ успешно создан!' in res3.output
    keys['configurator'] = res3.output.splitlines()[-2].strip()

    log.debug(f"[Fixture Agent Keys] Ключи созданы: Agent1='{keys['agent1'][:5]}...', Agent2='{keys['agent2'][:5]}...', Configurator='{keys['configurator'][:5]}...'")
    return keys

# --- Тесты для GET /assignments?object_id=... ---

def test_get_assignments_success(client, setup_agent_data, agent_api_keys):
    """Тест: Успешное получение активных заданий для object_id."""
    log.info("\nТест: GET /assignments?object_id=... - Успех")
    object_id = setup_agent_data['sub1_oid']
    node1_id = setup_agent_data['nodes'][0]
    node2_id = setup_agent_data['nodes'][1] # Этот узел тоже в sub1, но его задание PING отключено
    assign1_id = setup_agent_data['assignments'][0] # PING Node 1 (Enabled)
    assign2_id = setup_agent_data['assignments'][1] # SERVICE Node 1 (Enabled)
    # assign3_id = setup_agent_data['assignments'][2] # PING Node 2 (Disabled) - не должно вернуться
    headers = {'X-API-Key': agent_api_keys['agent1']}

    response = client.get(f'/api/v1/assignments?object_id={object_id}', headers=headers)
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200
    data = response.get_json()
    assert isinstance(data, list), "Ответ должен быть списком"
    # Ожидаем 2 активных задания для узла 1
    assert len(data) == 2, f"Ожидалось 2 задания, получено {len(data)}"

    # Проверяем содержимое (ID и метод)
    assign_ids_in_response = {a['assignment_id'] for a in data}
    assert assign_ids_in_response == {assign1_id, assign2_id}, "Вернулись не те ID заданий"

    ping_job = next(a for a in data if a['assignment_id'] == assign1_id)
    service_job = next(a for a in data if a['assignment_id'] == assign2_id)
    assert ping_job['method_name'] == 'PING'
    assert ping_job['node_id'] == node1_id
    assert service_job['method_name'] == 'SERVICE_STATUS'
    assert service_job['node_id'] == node1_id
    assert service_job['parameters'] == {"service_name": "Spooler"}

def test_get_assignments_no_active(client, db_conn, setup_agent_data, agent_api_keys):
    """Тест: Получение пустого списка, если нет активных заданий."""
    log.info("\nТест: GET /assignments?object_id=... - Нет активных")
    object_id = setup_agent_data['sub2_oid'] # Второе подразделение
    node3_id = setup_agent_data['nodes'][2] # Узел 3
    assign4_id = setup_agent_data['assignments'][3] # PING Node 3 (Enabled) - он должен быть там
    headers = {'X-API-Key': agent_api_keys['agent2']} # Ключ для второго подразделения

    # Сначала проверим, что задание для Node 3 возвращается
    response1 = client.get(f'/api/v1/assignments?object_id={object_id}', headers=headers)
    assert response1.status_code == 200
    assert len(response1.get_json()) == 1, "Изначально должно быть одно задание для sub2"

    # Теперь отключаем это задание в БД
    cursor = db_conn.cursor()
    cursor.execute("UPDATE node_check_assignments SET is_enabled = false WHERE id = %s", (assign4_id,))

    # Повторный запрос - должен вернуть пустой список
    response2 = client.get(f'/api/v1/assignments?object_id={object_id}', headers=headers)
    log.info(f"Ответ API (после отключения): {response2.status_code}")
    assert response2.status_code == 200
    data = response2.get_json()
    assert isinstance(data, list) and len(data) == 0, "Ожидался пустой список после отключения задания"
    cursor.close()

def test_get_assignments_no_object_id(client, agent_api_keys):
    """Тест: Ошибка 400, если не передан object_id."""
    log.info("\nТест: GET /assignments - Ошибка (нет object_id)")
    headers = {'X-API-Key': agent_api_keys['agent1']}
    response = client.get('/api/v1/assignments', headers=headers)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 400 # Bad Request
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Отсутствует параметр object_id' in error_data['error']['message']

def test_get_assignments_invalid_role(client, setup_agent_data, agent_api_keys):
    """Тест: Ошибка 403, если используется ключ с неверной ролью."""
    log.info("\nТест: GET /assignments - Ошибка (неверная роль)")
    object_id = setup_agent_data['sub1_oid']
    headers = {'X-API-Key': agent_api_keys['configurator']} # Ключ конфигуратора
    response = client.get(f'/api/v1/assignments?object_id={object_id}', headers=headers)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 403 # Forbidden
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'insufficient permissions' in error_data['error']['message'].lower()

def test_get_assignments_no_auth(client, setup_agent_data):
    """Тест: Ошибка 401, если нет API ключа."""
    log.info("\nТест: GET /assignments - Ошибка (нет ключа)")
    object_id = setup_agent_data['sub1_oid']
    response = client.get(f'/api/v1/assignments?object_id={object_id}') # Без заголовка
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 401 # Unauthorized
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Требуется API ключ' in error_data['error']['message']

# --- Тесты для GET /objects/<id>/offline_config ---

def test_get_offline_config_success(client, setup_agent_data, agent_api_keys):
    """Тест: Успешное получение конфигурации для оффлайн агента."""
    log.info("\nТест: GET /objects/{id}/offline_config - Успех")
    object_id = setup_agent_data['sub1_oid'] # У первого есть код ТС
    transport_code = setup_agent_data['sub1_tc']
    expected_assign_ids = {setup_agent_data['assignments'][0], setup_agent_data['assignments'][1]}
    headers = {'X-API-Key': agent_api_keys['configurator']} # Ключ конфигуратора

    response = client.get(f'/api/v1/objects/{object_id}/offline_config', headers=headers)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:500]}...")
    assert response.status_code == 200
    data = response.get_json()
    assert isinstance(data, dict), "Ответ должен быть объектом"
    # Проверяем основные поля метаданных
    assert data.get('object_id') == object_id
    assert data.get('transport_system_code') == transport_code
    assert 'assignment_config_version' in data and data['assignment_config_version'] is not None
    assert 'generated_at' in data
    assert 'assignments' in data and isinstance(data['assignments'], list)
    # Проверяем количество и состав заданий (только активные для этого object_id)
    assert len(data['assignments']) == 2
    response_assign_ids = {a['assignment_id'] for a in data['assignments']}
    assert response_assign_ids == expected_assign_ids
    # Проверяем структуру одного задания
    first_assignment = data['assignments'][0]
    assert 'assignment_id' in first_assignment
    assert 'node_name' in first_assignment
    assert 'ip_address' in first_assignment
    assert 'method_name' in first_assignment
    assert 'parameters' in first_assignment # Должен быть {}, если не задан
    assert 'interval_seconds' in first_assignment
    assert 'success_criteria' in first_assignment # Должен быть null, если не задан

def test_get_offline_config_no_transport_code(client, setup_agent_data, agent_api_keys):
    """Тест: Ошибка 404, если у подразделения нет transport_system_code."""
    log.info("\nТест: GET /objects/{id}/offline_config - Ошибка (нет кода ТС)")
    object_id = setup_agent_data['sub2_oid'] # У второго нет кода ТС
    headers = {'X-API-Key': agent_api_keys['configurator']}

    response = client.get(f'/api/v1/objects/{object_id}/offline_config', headers=headers)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404, "Ожидался статус 404 Not Found (или 400)" # Зависит от реализации ошибки в функции
    error_data = response.get_json(); assert error_data and 'error' in error_data
    # Функция generate_offline_config возвращает JSON с 'error', который обработчик в route превращает в ApiNotFound
    assert error_data['error']['code'] == 'NOT_FOUND'
    assert 'transport_system_code is missing' in error_data['error']['message']

def test_get_offline_config_subdivision_not_found(client, agent_api_keys):
    """Тест: Ошибка 404, если object_id подразделения не найден."""
    log.info("\nТест: GET /objects/{id}/offline_config - 404 Not Found (подразделение)")
    invalid_object_id = 999990
    headers = {'X-API-Key': agent_api_keys['configurator']}
    response = client.get(f'/api/v1/objects/{invalid_object_id}/offline_config', headers=headers)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Subdivision not found' in error_data['error']['message']

def test_get_offline_config_invalid_role(client, setup_agent_data, agent_api_keys):
    """Тест: Ошибка 403, если используется ключ с неверной ролью."""
    log.info("\nТест: GET /objects/{id}/offline_config - Ошибка (неверная роль)")
    object_id = setup_agent_data['sub1_oid']
    headers = {'X-API-Key': agent_api_keys['agent1']} # Ключ агента
    response = client.get(f'/api/v1/objects/{object_id}/offline_config', headers=headers)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 403
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'insufficient permissions' in error_data['error']['message'].lower()

# ... можно добавить тесты без авторизации ...