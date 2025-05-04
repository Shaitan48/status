# status/tests/integration/test_event_routes.py
"""
Интеграционные тесты для API эндпоинтов управления Системными Событиями
(/api/v1/events).
"""
import pytest
import json
import logging
import secrets
from datetime import datetime, timezone, timedelta

# Используем фикстуры из conftest.py
# logged_in_client - клиент с выполненным входом (нужен для GET /events)
# client - обычный клиент (для тестов POST /events с API ключом)
# db_conn - соединение с БД в транзакции
# runner - для создания API ключа loader'а
# app - экземпляр приложения

# Импортируем нужные ошибки (хотя здесь они не должны явно возникать,
# т.к. обработка ошибок API проверяется в conftest и errors.py)
from app.errors import ApiBadRequest, ApiValidationFailure, ApiUnauthorized, ApiForbidden, ApiInternalError

log = logging.getLogger(__name__)

# --- Фикстура для создания тестовых данных ---
@pytest.fixture(scope='function')
def setup_event_data(logged_in_client, db_conn, runner):
    """
    Создает необходимые данные для тестов событий:
    - Подразделение
    - Тип узла
    - Узел
    - Метод проверки (PING)
    - Задание (PING для созданного узла)
    - API ключ loader'а
    Возвращает словарь с ID и другими полезными данными.
    """
    log.debug("\n[Setup Event] Создание данных для тестов событий...")
    created_ids = {'node_id': None, 'assignment_id': None, 'loader_key': None}
    cursor = db_conn.cursor()
    try:
        # --- Очистка (на всякий случай) ---
        # Удаляем старые данные, если они могли остаться от прерванных тестов
        cursor.execute("DELETE FROM node_check_assignments WHERE node_id IN (SELECT id FROM nodes WHERE name LIKE %s)", ('EventTest Node%',))
        cursor.execute("DELETE FROM nodes WHERE name LIKE %s", ('EventTest Node%',))
        cursor.execute("DELETE FROM subdivisions WHERE object_id = %s", (9060,))
        cursor.execute("DELETE FROM node_types WHERE name = %s", ('EventTest Type',))

        # --- Создание Подразделения ---
        cursor.execute("INSERT INTO subdivisions (object_id, short_name) VALUES (%s, %s) RETURNING id", (9060, "EventTest Sub"))
        sub_id = cursor.fetchone()['id']
        log.debug(f"[Setup Event] Subdivision ID={sub_id} создан.")

        # --- Создание Типа Узла ---
        cursor.execute("INSERT INTO node_types (name) VALUES (%s) RETURNING id", ('EventTest Type',))
        type_id = cursor.fetchone()['id']
        log.debug(f"[Setup Event] Node Type ID={type_id} создан.")

        # --- Создание Узла ---
        node_name = f"EventTest Node {secrets.token_hex(3)}"
        cursor.execute("INSERT INTO nodes (name, parent_subdivision_id, node_type_id, ip_address) VALUES (%s, %s, %s, %s) RETURNING id",
                       (node_name, sub_id, type_id, '8.8.8.8'))
        node_id = cursor.fetchone()['id']; created_ids['node_id'] = node_id
        log.debug(f"[Setup Event] Node ID={node_id} создан.")

        # --- Получение ID метода PING ---
        cursor.execute("SELECT id FROM check_methods WHERE method_name = 'PING'")
        ping_res = cursor.fetchone(); assert ping_res, "Метод PING не найден в БД!"
        method_id = ping_res['id']
        log.debug(f"[Setup Event] Method PING ID={method_id}")

        # --- Создание Задания ---
        cursor.execute("INSERT INTO node_check_assignments (node_id, method_id, description) VALUES (%s, %s, %s) RETURNING id",
                       (node_id, method_id, 'Test PING Assignment for Events'))
        assign_id = cursor.fetchone()['id']; created_ids['assignment_id'] = assign_id
        log.debug(f"[Setup Event] Assignment ID={assign_id} создан.")

        # --- Создание API ключа loader'а ---
        loader_desc = "Test Loader Key For Events"
        # Используем runner для вызова CLI команды
        loader_result = runner.invoke(args=['create-api-key', '--description', loader_desc, '--role', 'loader'])
        log.debug(f"[Setup Event] CLI Loader Key Output: {loader_result.output}")
        # Проверяем успешность команды и наличие ключевой фразы
        assert loader_result.exit_code == 0 and 'API Ключ успешно создан!' in loader_result.output, \
             f"Ошибка создания ключа loader'а: exit={loader_result.exit_code}, out='{loader_result.output}'"
        # Извлекаем сам ключ из предпоследней строки вывода
        created_ids['loader_key'] = loader_result.output.splitlines()[-2].strip()
        log.debug(f"[Setup Event] Ключ loader создан: '{created_ids['loader_key'][:5]}...'")

        yield created_ids # Возвращаем словарь с созданными ID и ключом

    except Exception as e:
        log.error(f"ОШИБКА в фикстуре setup_event_data: {e}", exc_info=True)
        pytest.fail(f"Не удалось настроить данные для тестов событий: {e}")
    # Очистка не нужна, т.к. db_conn откатит транзакцию после теста

# --- Тесты для POST /events ---

def test_create_event_success(client, db_conn, setup_event_data):
    """Тест: Успешное создание системного события со ссылками на сущности."""
    log.info("\nТест: POST /api/v1/events - Успех")
    loader_key = setup_event_data['loader_key']
    # Используем валидные ID из фикстуры
    node_id_from_fixture = setup_event_data['node_id']
    assign_id_from_fixture = setup_event_data['assignment_id']
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}

    event_data = {
        "event_type": "TEST_SUCCESS_WITH_FK",
        "severity": "WARN",
        "message": "Тестовое событие с реальными ссылками",
        "source": "pytest_event_test_fk",
        "node_id": node_id_from_fixture,          # Валидный ID
        "assignment_id": assign_id_from_fixture,  # Валидный ID
        "related_entity": "FILE",
        "related_entity_id": "test_file.zrpu",
        "details": {"processed": 10, "failed": 0, "duration_ms": 1500}
    }

    # Отправляем запрос на создание
    response = client.post('/api/v1/events', headers=headers, json=event_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    # Проверяем успешный ответ
    assert response.status_code == 201, "Ожидался статус 201 Created"
    data = response.get_json()
    assert data and data['status'] == 'success', "Ожидался статус 'success' в ответе"
    assert 'event_id' in data and isinstance(data['event_id'], int), "Ответ не содержит валидный event_id"
    event_id = data['event_id']

    # Проверяем запись в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT * FROM system_events WHERE id = %s", (event_id,))
    db_event = cursor.fetchone()
    assert db_event is not None, "Событие не найдено в БД после создания"
    # Сравниваем поля
    assert db_event['event_type'] == event_data['event_type']
    assert db_event['severity'] == event_data['severity'] # В БД хранится в uppercase
    assert db_event['message'] == event_data['message']
    assert db_event['source'] == event_data['source']
    assert db_event['node_id'] == node_id_from_fixture # Проверяем сохраненный node_id
    assert db_event['assignment_id'] == assign_id_from_fixture # Проверяем сохраненный assignment_id
    assert db_event['related_entity'] == event_data['related_entity']
    assert db_event['related_entity_id'] == event_data['related_entity_id']
    assert db_event['details'] == event_data['details'], "Поле details не совпадает"
    cursor.close()

def test_create_event_minimal_success(client, db_conn, setup_event_data):
    """Тест: Успешное создание события с минимально необходимыми полями."""
    log.info("\nТест: POST /api/v1/events - Успех (минимальный)")
    loader_key = setup_event_data['loader_key']
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}
    event_data = {
        "event_type": "MINIMAL_TEST",
        "message": "Минимальное тестовое сообщение"
        # severity будет INFO по умолчанию
        # Остальные поля будут NULL
    }
    response = client.post('/api/v1/events', headers=headers, json=event_data)
    assert response.status_code == 201, "Ожидался статус 201 Created"
    event_id = response.get_json()['event_id']

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT event_type, message, severity, node_id FROM system_events WHERE id = %s", (event_id,))
    db_event = cursor.fetchone()
    assert db_event is not None, "Минимальное событие не найдено в БД"
    assert db_event['event_type'] == event_data['event_type']
    assert db_event['message'] == event_data['message']
    assert db_event['severity'] == 'INFO', "Ожидалась severity INFO по умолчанию"
    assert db_event['node_id'] is None, "Ожидался NULL для node_id"
    cursor.close()

def test_create_event_missing_fields(client, setup_event_data):
    """Тест: Ошибка 422 при создании события без обязательных полей."""
    log.info("\nТест: POST /api/v1/events - Ошибка (нет полей)")
    loader_key = setup_event_data['loader_key']
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}

    # Нет event_type
    response1 = client.post('/api/v1/events', headers=headers, json={"message": "No type"})
    assert response1.status_code == 422, "Ожидался 422 при отсутствии event_type"
    assert "Missing required fields: event_type" in response1.get_data(as_text=True)

    # Нет message
    response2 = client.post('/api/v1/events', headers=headers, json={"event_type": "NO_MSG"})
    assert response2.status_code == 422, "Ожидался 422 при отсутствии message"
    # Сообщение об ошибке должно содержать оба поля, т.к. они проверяются вместе
    assert "Missing required fields: event_type, message" in response2.get_data(as_text=True)

def test_create_event_invalid_severity(client, setup_event_data):
    """Тест: Ошибка 422 при создании события с неверным значением severity."""
    log.info("\nТест: POST /api/v1/events - Ошибка (неверный severity)")
    loader_key = setup_event_data['loader_key']
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}
    event_data = {
        "event_type": "INVALID_SEV_TEST",
        "message": "Test with invalid severity",
        "severity": "DEBUG" # Недопустимое значение по DB CHECK
    }
    response = client.post('/api/v1/events', headers=headers, json=event_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 422, "Ожидался статус 422 Validation Failure"
    error_data = response.get_json()
    assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'VALIDATION_FAILURE'
    assert 'Invalid severity' in error_data['error']['message']

def test_create_event_wrong_role(client, runner, setup_event_data):
    """Тест: Ошибка 403 при создании события ключом с ролью 'agent'."""
    log.info("\nТест: POST /api/v1/events - Ошибка (неверная роль)")
    # Нужен ключ agent. Создадим его.
    agent_desc = "Test Agent Key For Events"
    agent_result = runner.invoke(args=['create-api-key', '--description', agent_desc, '--role', 'agent'])
    assert agent_result.exit_code == 0, "Не удалось создать ключ agent для теста"
    agent_key = agent_result.output.splitlines()[-2].strip()

    headers = {'X-API-Key': agent_key, 'Content-Type': 'application/json'}
    event_data = {"event_type": "AGENT_POST_TEST", "message": "This should fail"}
    response = client.post('/api/v1/events', headers=headers, json=event_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 403, "Ожидался статус 403 Forbidden"
    error_data = response.get_json()
    assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'FORBIDDEN'
    assert 'insufficient permissions' in error_data['error']['message'].lower()

# --- Тесты для GET /events ---

def test_get_events_success(logged_in_client, client, db_conn, setup_event_data):
    """Тест: Успешное получение списка событий (без фильтров)."""
    log.info("\nТест: GET /api/v1/events - Успех")
    loader_key = setup_event_data['loader_key']
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}
    node_id = setup_event_data['node_id']

    # Создадим несколько событий для проверки списка
    resp1 = client.post('/api/v1/events', headers=headers, json={"event_type": "EVT_GET_1", "message": "Get Msg1", "severity": "INFO", "node_id": node_id})
    resp2 = client.post('/api/v1/events', headers=headers, json={"event_type": "EVT_GET_2", "message": "Get Msg2", "severity": "WARN"})
    resp3 = client.post('/api/v1/events', headers=headers, json={"event_type": "EVT_GET_3", "message": "Get Msg3", "severity": "ERROR"})
    assert resp1.status_code == 201 and resp2.status_code == 201 and resp3.status_code == 201, "Не удалось создать тестовые события для GET"

    # Запрашиваем список через logged_in_client (предполагаем, что GET доступен авторизованным)
    response = logged_in_client.get('/api/v1/events?limit=10')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200, "Ожидался статус 200 OK"
    data = response.get_json()
    assert data and 'items' in data and isinstance(data['items'], list), "Ответ не содержит массив 'items'"
    assert 'total_count' in data, "Ответ не содержит 'total_count'"
    # Проверяем, что вернулось как минимум 3 + 1 (из DB_INIT) события
    assert data['total_count'] >= 4, f"Ожидалось >= 4 событий, получено {data['total_count']}"
    assert len(data['items']) <= 10, "Limit не сработал"
    # Проверяем наличие наших типов событий в полученном списке
    event_types_in_response = {item['event_type'] for item in data['items']}
    assert "EVT_GET_1" in event_types_in_response
    assert "EVT_GET_2" in event_types_in_response
    assert "EVT_GET_3" in event_types_in_response

def test_get_events_with_filters(logged_in_client, client, db_conn, setup_event_data):
    """Тест: Получение списка событий с различными фильтрами."""
    log.info("\nТест: GET /api/v1/events - Успех с фильтрами")
    loader_key = setup_event_data['loader_key']
    node_id_fixture = setup_event_data['node_id']         # Валидный ID из фикстуры
    assign_id_fixture = setup_event_data['assignment_id'] # Валидный ID из фикстуры
    headers = {'X-API-Key': loader_key, 'Content-Type': 'application/json'}

    # Создаем события с валидными ссылками, используя ID из фикстуры
    resp1 = client.post('/api/v1/events', headers=headers, json={"event_type": "FILTER_NODE_EVT", "message": "Message for node test", "severity": "WARN", "node_id": node_id_fixture})
    resp2 = client.post('/api/v1/events', headers=headers, json={"event_type": "FILTER_ASSIGN_EVT", "message": "Message for assignment test", "severity": "ERROR", "assignment_id": assign_id_fixture})
    resp3 = client.post('/api/v1/events', headers=headers, json={"event_type": "FILTER_NODE_EVT", "message": "Another message for node test", "severity": "INFO", "node_id": node_id_fixture})
    # Проверяем успешность создания
    assert resp1.status_code == 201, "Не удалось создать событие 1 для фильтра"
    assert resp2.status_code == 201, "Не удалось создать событие 2 для фильтра"
    assert resp3.status_code == 201, "Не удалось создать событие 3 для фильтра"

    # Фильтр по severity=WARN
    resp_warn = logged_in_client.get('/api/v1/events?severity=WARN')
    assert resp_warn.status_code == 200; data_warn = resp_warn.get_json()
    assert len(data_warn['items']) >= 1, "Должно быть найдено >=1 события WARN"
    assert all(item['severity'] == 'WARN' for item in data_warn['items']), "Найдены события с неверной severity"
    assert any(item['event_type'] == "FILTER_NODE_EVT" for item in data_warn['items']), "Не найдено ожидаемое событие WARN"

    # Фильтр по event_type=FILTER_NODE_EVT (частичное совпадение)
    resp_type = logged_in_client.get('/api/v1/events?event_type=FILTER_NODE') # Ищем по части имени
    assert resp_type.status_code == 200; data_type = resp_type.get_json()
    assert len(data_type['items']) >= 2, "Ожидалось >=2 события типа FILTER_NODE_EVT"
    assert all('FILTER_NODE_EVT' in item['event_type'] for item in data_type['items']), "Найдены события с неверным типом"

    # Фильтр по node_id (используем валидный ID из фикстуры)
    resp_node = logged_in_client.get(f'/api/v1/events?node_id={node_id_fixture}')
    assert resp_node.status_code == 200; data_node = resp_node.get_json()
    assert len(data_node['items']) >= 2, "Ожидалось >=2 события для этого узла"
    assert all(item['node_id'] == node_id_fixture for item in data_node['items']), "Найдены события с неверным node_id"

    # Фильтр по assignment_id (используем валидный ID из фикстуры)
    resp_assign = logged_in_client.get(f'/api/v1/events?assignment_id={assign_id_fixture}')
    assert resp_assign.status_code == 200; data_assign = resp_assign.get_json()
    assert len(data_assign['items']) >= 1, "Ожидалось >=1 событие для этого задания"
    assert all(item['assignment_id'] == assign_id_fixture for item in data_assign['items']), "Найдены события с неверным assignment_id"

    # Фильтр по search_text в message
    resp_search = logged_in_client.get('/api/v1/events?search_text=assignment test') # Ищем по части сообщения
    assert resp_search.status_code == 200; data_search = resp_search.get_json()
    assert len(data_search['items']) >= 1, "Ожидалось >=1 событие по тексту 'assignment test'"
    assert all('assignment test' in item['message'] for item in data_search['items']), "Найдено событие без нужного текста"

    # Фильтр по времени (просто проверка, что запрос проходит)
    past_time = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
    resp_time = logged_in_client.get(f'/api/v1/events?start_time={past_time}')
    assert resp_time.status_code == 200, "Запрос с фильтром по времени не удался"