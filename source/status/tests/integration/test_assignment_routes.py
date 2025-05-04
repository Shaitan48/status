# status/tests/integration/test_assignment_routes.py
"""
Интеграционные тесты для API эндпоинтов управления Заданиями
(/api/v1/assignments).
"""
import pytest
import json
import logging
import secrets
import psycopg2 # Для ошибок

# Используем фикстуры из conftest.py
# logged_in_client - клиент с выполненным входом
# db_conn - соединение с БД в транзакции
# app - экземпляр приложения

# <<< Импортируем нужные ошибки >>>
from app.errors import ApiConflict, ApiNotFound, ApiValidationFailure

log = logging.getLogger(__name__)

# --- Фикстура для создания тестовых данных ---
@pytest.fixture(scope='function')
def setup_assignment_data(logged_in_client, db_conn):
    """
    Создает необходимые данные для тестов заданий:
    - 2 Подразделения (одно дочернее)
    - 2 Типа узлов (один дочерний)
    - 3 Узла (в разных подразделениях/с разными типами)
    - 2 Метода проверки (PING и SERVICE_STATUS)
    Возвращает словарь с ID созданных сущностей.
    """
    log.debug("\n[Setup Assignment] Создание данных для тестов заданий...")
    created_ids = {'nodes': [], 'subdivisions': {}, 'node_types': {}}
    cursor = db_conn.cursor()
    try:
        # --- Очистка (на всякий случай) ---
        cursor.execute("DELETE FROM node_check_assignments WHERE node_id IN (SELECT id FROM nodes WHERE name LIKE %s)", ('AssignTest Node%',))
        cursor.execute("DELETE FROM nodes WHERE name LIKE %s", ('AssignTest Node%',))
        cursor.execute("DELETE FROM subdivisions WHERE object_id >= 9030 AND object_id < 9040")
        cursor.execute("DELETE FROM node_types WHERE name LIKE %s", ('AssignTest%',))
        # cursor.execute("DELETE FROM check_methods WHERE method_name IN ('PING_Test', 'SERVICE_Test')")

        # --- Создание Подразделений ---
        cursor.execute("INSERT INTO subdivisions (object_id, short_name, priority) VALUES (%s, %s, 10) RETURNING id", (9030, "AssignTest Sub 1"))
        sub1_id = cursor.fetchone()['id']; created_ids['subdivisions']['sub1'] = sub1_id
        cursor.execute("INSERT INTO subdivisions (object_id, short_name, parent_id, priority) VALUES (%s, %s, %s, 11) RETURNING id", (9031, "AssignTest Sub 1.1", sub1_id))
        sub1_1_id = cursor.fetchone()['id']; created_ids['subdivisions']['sub1_1'] = sub1_1_id

        # --- Создание Типов Узлов ---
        cursor.execute("INSERT INTO node_types (name, priority) VALUES (%s, 50) RETURNING id", ('AssignTest Type A',))
        typeA_id = cursor.fetchone()['id']; created_ids['node_types']['typeA'] = typeA_id
        cursor.execute("INSERT INTO node_types (name, parent_type_id, priority) VALUES (%s, %s, 51) RETURNING id", ('AssignTest Type A.1', typeA_id))
        typeA1_id = cursor.fetchone()['id']; created_ids['node_types']['typeA1'] = typeA1_id

        # --- Создание Узлов ---
        node_names = [f"AssignTest Node {i+1}" for i in range(3)]
        node_data = [
            (node_names[0], sub1_id, typeA_id, '1.1.1.1'),
            (node_names[1], sub1_1_id, typeA1_id, '2.2.2.2'), # В дочернем подразделении и с дочерним типом
            (node_names[2], sub1_id, typeA_id, '3.3.3.3'), # В том же подразделении и с тем же типом, что и первый
        ]
        for name, sub_id, type_id, ip in node_data:
            cursor.execute("INSERT INTO nodes (name, parent_subdivision_id, node_type_id, ip_address) VALUES (%s, %s, %s, %s) RETURNING id", (name, sub_id, type_id, ip))
            created_ids['nodes'].append(cursor.fetchone()['id'])

        # --- Получение ID методов (предполагаем, что они есть из core_data) ---
        cursor.execute("SELECT id FROM check_methods WHERE method_name = 'PING'")
        ping_res = cursor.fetchone(); assert ping_res, "Метод PING не найден в БД!"
        created_ids['method_ping_id'] = ping_res['id']

        cursor.execute("SELECT id FROM check_methods WHERE method_name = 'SERVICE_STATUS'")
        service_res = cursor.fetchone(); assert service_res, "Метод SERVICE_STATUS не найден в БД!"
        created_ids['method_service_id'] = service_res['id']

        log.debug(f"[Setup Assignment] Данные созданы: {created_ids}")
        yield created_ids

    except Exception as e:
        log.error(f"ОШИБКА в фикстуре setup_assignment_data: {e}", exc_info=True)
        pytest.fail(f"Не удалось настроить данные для тестов заданий: {e}")

# --- Тесты для POST /bulk_create ---

def test_bulk_create_by_node_ids_success(logged_in_client, db_conn, setup_assignment_data):
    """Тест: Успешное массовое создание заданий по списку ID узлов."""
    log.info("\nТест: POST /bulk_create - Успех (по node_ids)")
    node_ids_to_assign = setup_assignment_data['nodes'][:2] # Берем первые два узла
    method_id = setup_assignment_data['method_ping_id']
    assignment_data = {
        "method_id": method_id,
        "check_interval_seconds": 180,
        "description": "Bulk PING by Node IDs"
    }
    payload = {"node_ids": node_ids_to_assign, "assignment_data": assignment_data}

    response = logged_in_client.post('/api/v1/assignments/bulk_create', json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 201
    data = response.get_json()
    assert data and data['status'] == 'success'
    assert data['assignments_created'] == 2 # Должно создаться 2 задания

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT node_id FROM node_check_assignments WHERE method_id = %s AND description = %s", (method_id, assignment_data['description']))
    created_nodes = {row['node_id'] for row in cursor.fetchall()}
    assert set(node_ids_to_assign) == created_nodes
    cursor.close()

def test_bulk_create_by_criteria_subdivision_success(logged_in_client, db_conn, setup_assignment_data):
    """Тест: Успешное массовое создание по критерию подразделения."""
    log.info("\nТест: POST /bulk_create - Успех (по subdivision_id)")
    sub_id_to_assign = setup_assignment_data['subdivisions']['sub1'] # Берем родительское
    node_ids_in_sub1 = [setup_assignment_data['nodes'][0], setup_assignment_data['nodes'][2]] # Узлы 1 и 3
    method_id = setup_assignment_data['method_service_id']
    assignment_data = {
        "method_id": method_id,
        "parameters": {"service_name": "Spooler"},
        "description": "Bulk Service by Sub ID"
    }
    criteria = {"subdivision_ids": [sub_id_to_assign]} # Критерий по ID подразделения
    payload = {"criteria": criteria, "assignment_data": assignment_data}

    response = logged_in_client.post('/api/v1/assignments/bulk_create', json=payload)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 201
    data = response.get_json()
    assert data and data['status'] == 'success'
    # В subdivision=sub1 находятся узлы 1 и 3
    assert data['assignments_created'] == 2, "Должно создаться 2 задания для подразделения"

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT node_id FROM node_check_assignments WHERE method_id = %s AND description = %s", (method_id, assignment_data['description']))
    created_nodes = {row['node_id'] for row in cursor.fetchall()}
    assert set(node_ids_in_sub1) == created_nodes
    cursor.close()

# TODO: Добавить тесты для bulk_create по другим критериям (type_id, name_mask) и их комбинациям.
# TODO: Добавить тесты для bulk_create, когда некоторые задания уже существуют (проверить assignments_created).
# TODO: Добавить тесты для bulk_create с ошибками валидации (неверный method_id, нет criteria и node_ids).

# --- Тесты для GET /all ---

def test_get_assignments_all_success(logged_in_client, db_conn, setup_assignment_data):
    """Тест: Успешное получение списка всех заданий (базовый)."""
    log.info("\nТест: GET /all - Успех")
    # Создадим пару заданий
    nodes = setup_assignment_data['nodes']
    ping_id = setup_assignment_data['method_ping_id']
    service_id = setup_assignment_data['method_service_id']
    logged_in_client.post('/api/v1/assignments/bulk_create', json={"node_ids": [nodes[0]], "assignment_data": {"method_id": ping_id}})
    logged_in_client.post('/api/v1/assignments/bulk_create', json={"node_ids": [nodes[1]], "assignment_data": {"method_id": service_id, "parameters": {"s":"s1"}}})

    response = logged_in_client.get('/api/v1/assignments/all?limit=10')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 200
    data = response.get_json()
    assert data and 'assignments' in data and isinstance(data['assignments'], list)
    assert 'total_count' in data and data['total_count'] >= 2
    assert len(data['assignments']) <= 10 # Проверка limit
    # Проверка наличия созданных заданий
    assert any(a['node_id'] == nodes[0] and a['method_id'] == ping_id for a in data['assignments'])
    assert any(a['node_id'] == nodes[1] and a['method_id'] == service_id for a in data['assignments'])

# TODO: Добавить тесты для GET /all с пагинацией (offset) и всеми фильтрами.

# --- Тесты для GET /<id>, PUT /<id>, DELETE /<id> ---

@pytest.fixture(scope='function')
def create_single_assignment(logged_in_client, setup_assignment_data):
    """Фикстура для создания одного задания для тестов GET/PUT/DELETE."""
    node_id = setup_assignment_data['nodes'][0]
    method_id = setup_assignment_data['method_ping_id']
    assignment_data = {"method_id": method_id, "description": "Single Assignment Test"}
    payload = {"node_ids": [node_id], "assignment_data": assignment_data}
    response = logged_in_client.post('/api/v1/assignments/bulk_create', json=payload)
    assert response.status_code == 201
    # Нужно получить ID созданного задания
    list_resp = logged_in_client.get(f'/api/v1/assignments/all?node_id={node_id}&method_id={method_id}')
    assert list_resp.status_code == 200
    assignment_id = list_resp.get_json()['assignments'][0]['id']
    log.debug(f"[Fixture create_single] Создано задание ID={assignment_id}")
    return {'assignment_id': assignment_id, 'node_id': node_id, 'method_id': method_id}

def test_get_assignment_detail_success(logged_in_client, create_single_assignment):
    """Тест: Успешное получение деталей одного задания."""
    log.info("\nТест: GET /assignments/{id} - Успех")
    assignment_id = create_single_assignment['assignment_id']
    response = logged_in_client.get(f'/api/v1/assignments/{assignment_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 200
    data = response.get_json()
    assert data and data['id'] == assignment_id
    assert data['node_id'] == create_single_assignment['node_id']
    assert data['method_id'] == create_single_assignment['method_id']
    assert data['description'] == "Single Assignment Test"

def test_get_assignment_detail_not_found(logged_in_client):
    """Тест: Ошибка 404 при запросе несуществующего задания."""
    log.info("\nТест: GET /assignments/{id} - 404 Not Found")
    assignment_id = 99999
    response = logged_in_client.get(f'/api/v1/assignments/{assignment_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'not found' in error_data['error']['message']

def test_update_assignment_success(logged_in_client, db_conn, create_single_assignment):
    """Тест: Успешное обновление задания."""
    log.info("\nТест: PUT /assignments/{id} - Успех")
    assignment_id = create_single_assignment['assignment_id']
    new_desc = "Updated Single Desc"
    new_interval = 300
    new_enabled = False
    new_params = {"timeout_ms": 2000}
    new_criteria = {"max_rtt_ms": 150}
    update_data = {
        "description": new_desc,
        "check_interval_seconds": new_interval,
        "is_enabled": new_enabled,
        "parameters": new_params,
        "success_criteria": new_criteria
    }
    response = logged_in_client.put(f'/api/v1/assignments/{assignment_id}', json=update_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:300]}...")
    assert response.status_code == 200
    updated_assign = response.get_json()
    assert updated_assign and updated_assign['id'] == assignment_id
    assert updated_assign['description'] == new_desc
    assert updated_assign['check_interval_seconds'] == new_interval
    assert updated_assign['is_enabled'] is new_enabled
    # Сравниваем параметры и критерии как объекты Python
    assert updated_assign['parameters'] == new_params
    assert updated_assign['success_criteria'] == new_criteria

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT description, check_interval_seconds, is_enabled, parameters, success_criteria FROM node_check_assignments WHERE id = %s", (assignment_id,))
    db_assign = cursor.fetchone()
    assert db_assign['description'] == new_desc
    assert db_assign['check_interval_seconds'] == new_interval
    assert db_assign['is_enabled'] is new_enabled
    assert db_assign['parameters'] == new_params # psycopg2 вернет dict
    assert db_assign['success_criteria'] == new_criteria # psycopg2 вернет dict
    cursor.close()

def test_update_assignment_not_found(logged_in_client):
    """Тест: Ошибка 404 при обновлении несуществующего задания."""
    log.info("\nТест: PUT /assignments/{id} - 404 Not Found")
    assignment_id = 99998
    response = logged_in_client.put(f'/api/v1/assignments/{assignment_id}', json={"description": "Update non-existent"})
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'not found' in error_data['error']['message']

def test_delete_assignment_success(logged_in_client, db_conn, create_single_assignment):
    """Тест: Успешное удаление задания."""
    log.info("\nТест: DELETE /assignments/{id} - Успех")
    assignment_id = create_single_assignment['assignment_id']
    response = logged_in_client.delete(f'/api/v1/assignments/{assignment_id}')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 204, "Ожидался статус 204 No Content"

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT 1 FROM node_check_assignments WHERE id = %s", (assignment_id,))
    assert cursor.fetchone() is None, "Задание все еще в БД после DELETE"
    cursor.close()

def test_delete_assignment_not_found(logged_in_client):
    """Тест: Ошибка 404 при удалении несуществующего задания."""
    log.info("\nТест: DELETE /assignments/{id} - 404 Not Found")
    assignment_id = 99997
    response = logged_in_client.delete(f'/api/v1/assignments/{assignment_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'not found' in error_data['error']['message']