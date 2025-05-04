# status/tests/integration/test_data_routes.py
"""
Интеграционные тесты для API эндпоинтов получения агрегированных данных
(/api/v1/dashboard, /api/v1/status_detailed, /api/v1/check_methods).
"""
import pytest
import json
import logging
import secrets
from datetime import datetime, timezone, timedelta

# Используем фикстуры из conftest.py
# logged_in_client - для доступа к этим эндпоинтам (предполагаем, что они защищены)
# client - для отправки результатов проверок через API
# db_conn - для прямых проверок/манипуляций с БД
# runner - для создания API ключа агента
# app - экземпляр приложения

# Импортируем ошибки (хотя здесь ожидаем в основном успешные ответы)
from app.errors import ApiInternalError

log = logging.getLogger(__name__)

# --- Фикстура для создания тестовых данных ---
@pytest.fixture(scope='function')
def setup_data_routes_data(logged_in_client, client, db_conn, runner):
    """
    Создает сложную структуру данных для тестов /dashboard и /status_detailed:
    - 2 Подразделения (одно дочернее).
    - 3 Типа узлов (A, A.1, B).
    - 5 Узлов с разными статусами PING:
        - Node 1 (Sub1, TypeA): Available (недавний PING OK)
        - Node 2 (Sub1, TypeA.1): Unavailable (недавний PING Fail)
        - Node 3 (Sub1.1, TypeA.1): Warning (давний PING OK)
        - Node 4 (Sub1.1, TypeB): Unknown (нет данных PING)
        - Node 5 (Sub1, TypeB): Available (другой)
    - Метод PING.
    - Задания PING для узлов 1, 2, 3, 5.
    - API Ключ агента.
    Возвращает словарь с ID созданных сущностей и ключом агента.
    """
    log.debug("\n[Setup DataRoutes] Создание данных для тестов /dashboard, /status_detailed...")
    created_data = {'nodes': {}, 'subdivisions': {}, 'node_types': {}, 'assignments': {}, 'agent_key': None}
    cursor = db_conn.cursor()
    try:
        # --- Очистка ---
        log.debug("[Setup DataRoutes] Очистка старых данных...")
        cursor.execute("DELETE FROM node_checks WHERE assignment_id IN (SELECT id FROM node_check_assignments WHERE node_id IN (SELECT id FROM nodes WHERE name LIKE %s))", ('DataTest%',))
        cursor.execute("DELETE FROM node_check_assignments WHERE node_id IN (SELECT id FROM nodes WHERE name LIKE %s)", ('DataTest%',))
        cursor.execute("DELETE FROM nodes WHERE name LIKE %s", ('DataTest%',))
        cursor.execute("DELETE FROM subdivisions WHERE object_id >= 9070 AND object_id < 9080")
        cursor.execute("DELETE FROM node_types WHERE name LIKE %s", ('DataTest%',))

        # --- Создание Подразделений ---
        cursor.execute("INSERT INTO subdivisions (object_id, short_name, priority) VALUES (%s, %s, 1) RETURNING id, object_id", (9070, "DataTest Sub 1"))
        sub1_res = cursor.fetchone(); sub1_id = sub1_res['id']; sub1_oid = sub1_res['object_id']
        created_data['subdivisions']['sub1'] = {'id': sub1_id, 'oid': sub1_oid}
        cursor.execute("INSERT INTO subdivisions (object_id, short_name, parent_id, priority) VALUES (%s, %s, %s, 2) RETURNING id, object_id", (9071, "DataTest Sub 1.1", sub1_id))
        sub1_1_res = cursor.fetchone(); sub1_1_id = sub1_1_res['id']; sub1_1_oid = sub1_1_res['object_id']
        created_data['subdivisions']['sub1_1'] = {'id': sub1_1_id, 'oid': sub1_1_oid}
        log.debug(f"[Setup DataRoutes] Subdivisions created: sub1(id={sub1_id}), sub1.1(id={sub1_1_id})")

        # --- Создание Типов Узлов ---
        cursor.execute("INSERT INTO node_types (name, priority) VALUES (%s, 10) RETURNING id", ('DataTest Type A',))
        typeA_id = cursor.fetchone()['id']; created_data['node_types']['typeA'] = typeA_id
        cursor.execute("INSERT INTO node_types (name, parent_type_id, priority) VALUES (%s, %s, 11) RETURNING id", ('DataTest Type A.1', typeA_id))
        typeA1_id = cursor.fetchone()['id']; created_data['node_types']['typeA1'] = typeA1_id
        cursor.execute("INSERT INTO node_types (name, priority) VALUES (%s, 20) RETURNING id", ('DataTest Type B',))
        typeB_id = cursor.fetchone()['id']; created_data['node_types']['typeB'] = typeB_id
        log.debug(f"[Setup DataRoutes] Node Types created: A(id={typeA_id}), A.1(id={typeA1_id}), B(id={typeB_id})")

        # --- Создание Узлов ---
        node_defs = [
            {'name': 'DataTest Node 1 (Avail)', 'sub': sub1_id, 'type': typeA_id, 'ip': '10.1.1.1'},
            {'name': 'DataTest Node 2 (Unavail)', 'sub': sub1_id, 'type': typeA1_id, 'ip': '10.1.1.2'},
            {'name': 'DataTest Node 3 (Warn)', 'sub': sub1_1_id, 'type': typeA1_id, 'ip': '10.1.1.3'},
            {'name': 'DataTest Node 4 (Unk)', 'sub': sub1_1_id, 'type': typeB_id, 'ip': '10.1.1.4'}, # Без задания
            {'name': 'DataTest Node 5 (Avail)', 'sub': sub1_id, 'type': typeB_id, 'ip': '10.1.1.5'},
        ]
        for i, n_def in enumerate(node_defs):
            cursor.execute("INSERT INTO nodes (name, parent_subdivision_id, node_type_id, ip_address) VALUES (%s, %s, %s, %s) RETURNING id",
                           (n_def['name'], n_def['sub'], n_def['type'], n_def['ip']))
            node_id = cursor.fetchone()['id']
            created_data['nodes'][f'node{i+1}'] = node_id
            log.debug(f"[Setup DataRoutes] Node '{n_def['name']}' ID={node_id} created.")

        # --- Получение ID метода PING ---
        cursor.execute("SELECT id FROM check_methods WHERE method_name = 'PING'")
        ping_id = cursor.fetchone()['id']; created_data['method_ping_id'] = ping_id

        # --- Создание Заданий (PING для 1, 2, 3, 5) ---
        assign_defs = [
            {'node_id': created_data['nodes']['node1'], 'desc': 'Ping Node 1'},
            {'node_id': created_data['nodes']['node2'], 'desc': 'Ping Node 2'},
            {'node_id': created_data['nodes']['node3'], 'desc': 'Ping Node 3'},
            {'node_id': created_data['nodes']['node5'], 'desc': 'Ping Node 5'},
        ]
        for i, a_def in enumerate(assign_defs):
            cursor.execute("INSERT INTO node_check_assignments (node_id, method_id, description) VALUES (%s, %s, %s) RETURNING id",
                           (a_def['node_id'], ping_id, a_def['desc']))
            assign_id = cursor.fetchone()['id']
            created_data['assignments'][f'assign{i+1}'] = assign_id # Сохраняем ID задания
        log.debug(f"[Setup DataRoutes] Assignments created: {created_data['assignments']}")

        # --- Создание API ключа агента (для отправки результатов) ---
        agent_desc = f"Agent Key for Data Tests OID {sub1_oid}"
        agent_result = runner.invoke(args=['create-api-key', '--description', agent_desc, '--role', 'agent', '--object-id', str(sub1_oid)])
        assert agent_result.exit_code == 0 and 'API Ключ успешно создан!' in agent_result.output
        created_data['agent_key'] = agent_result.output.splitlines()[-2].strip()
        log.debug(f"[Setup DataRoutes] Agent key created: '{created_data['agent_key'][:5]}...'")

        # --- Отправка результатов PING для имитации статусов ---
        # <<< ИСПРАВЛЕНО: Используем created_data >>>
        agent_headers = {'X-API-Key': created_data['agent_key'], 'Content-Type': 'application/json'}
        now = datetime.now(timezone.utc)
        log.debug(f"[Setup DataRoutes] Current time for check results: {now.isoformat()}")

        # Node 1: Available (недавний OK)
        ts_node1 = (now - timedelta(minutes=1)).isoformat()
        resp_node1 = client.post('/api/v1/checks', headers=agent_headers, json={
            "assignment_id": created_data['assignments']['assign1'], # <<< ИСПРАВЛЕНО
            "is_available": True, "check_timestamp": ts_node1})
        assert resp_node1.status_code == 201, "Failed to post check for Node 1"
        log.debug(f"[Setup DataRoutes] Posted check for Node 1 (Avail): Time={ts_node1}, Status={resp_node1.status_code}")

        # Node 2: Unavailable (недавний Fail)
        ts_node2 = (now - timedelta(minutes=1)).isoformat()
        resp_node2 = client.post('/api/v1/checks', headers=agent_headers, json={
            "assignment_id": created_data['assignments']['assign2'], # <<< ИСПРАВЛЕНО
            "is_available": False, "check_timestamp": ts_node2})
        assert resp_node2.status_code == 201, "Failed to post check for Node 2"
        log.debug(f"[Setup DataRoutes] Posted check for Node 2 (Unavail): Time={ts_node2}, Status={resp_node2.status_code}")

        # Node 3: Warning (давний OK)
        ts_node3 = (now - timedelta(minutes=15)).isoformat()
        resp_node3 = client.post('/api/v1/checks', headers=agent_headers, json={
            "assignment_id": created_data['assignments']['assign3'], # <<< ИСПРАВЛЕНО
            "is_available": True, "check_timestamp": ts_node3})
        assert resp_node3.status_code == 201, "Failed to post check for Node 3"
        log.debug(f"[Setup DataRoutes] Posted check for Node 3 (Warn): Time={ts_node3}, Status={resp_node3.status_code}")

        # Node 5: Available (другой недавний OK)
        ts_node5 = (now - timedelta(seconds=30)).isoformat()
        resp_node5 = client.post('/api/v1/checks', headers=agent_headers, json={
            "assignment_id": created_data['assignments']['assign4'], # <<< ИСПРАВЛЕНО
            "is_available": True, "check_timestamp": ts_node5})
        assert resp_node5.status_code == 201, "Failed to post check for Node 5"
        log.debug(f"[Setup DataRoutes] Posted check for Node 5 (Avail): Time={ts_node5}, Status={resp_node5.status_code}")

        log.debug("[Setup DataRoutes] Результаты PING отправлены.")

        # Проверка времени в БД
        log.debug("[Setup DataRoutes] Проверка времени последней проверки Node 3 в БД...")
        cursor.execute("""
            SELECT check_timestamp
            FROM node_checks
            WHERE assignment_id = %s
            ORDER BY id DESC LIMIT 1
        """, (created_data['assignments']['assign3'],)) # <<< ИСПРАВЛЕНО
        db_ts_node3_row = cursor.fetchone()
        assert db_ts_node3_row, "Запись проверки для Node 3 не найдена в БД!"
        db_ts_node3 = db_ts_node3_row['check_timestamp']
        expected_ts_node3 = datetime.fromisoformat(ts_node3)
        assert abs(db_ts_node3 - expected_ts_node3).total_seconds() < 5, \
            f"Время check_timestamp для Node 3 в БД ({db_ts_node3}) не соответствует отправленному ({expected_ts_node3})!"
        log.debug(f"[Setup DataRoutes] Время Node 3 в БД ({db_ts_node3}) соответствует отправленному ({expected_ts_node3}).")

        yield created_data # <<< ИСПРАВЛЕНО (хотя здесь было правильно)

    except Exception as e:
        log.error(f"ОШИБКА в фикстуре setup_data_routes_data: {e}", exc_info=True)
        pytest.fail(f"Не удалось настроить данные для тестов data_routes: {e}")
        # finally: # Очистка не нужна из-за rollback в db_conn
            # log.info("\n--- Очистка данных после тестов DataRoutes ---")
    # Очистка не нужна

# --- Тесты для GET /check_methods ---

def test_get_check_methods(logged_in_client):
    """Тест: Успешное получение списка методов проверки."""
    log.info("\nТест: GET /api/v1/check_methods - Успех")
    response = logged_in_client.get('/api/v1/check_methods')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200
    data = response.get_json()
    assert isinstance(data, list)
    assert len(data) > 0, "Список методов не должен быть пустым"
    # Проверяем наличие известных методов
    method_names = {m['method_name'] for m in data}
    assert 'PING' in method_names
    assert 'SERVICE_STATUS' in method_names
    # Проверяем структуру одного элемента
    first_method = data[0]
    assert 'id' in first_method and isinstance(first_method['id'], int)
    assert 'method_name' in first_method and isinstance(first_method['method_name'], str)
    assert 'description' in first_method # Может быть null

# --- Тесты для GET /dashboard ---

def test_get_dashboard_data_success(logged_in_client, setup_data_routes_data):
    """Тест: Успешное получение данных для дашборда."""
    log.info("\nТест: GET /api/v1/dashboard - Успех")
    response = logged_in_client.get('/api/v1/dashboard')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200
    data = response.get_json() # Ожидаем список подразделений
    assert isinstance(data, list), "Ответ /dashboard должен быть списком"
    assert len(data) >= 2, "Должно быть как минимум 2 тестовых подразделения"

    # Находим наши тестовые подразделения
    sub1 = next((s for s in data if s['id'] == setup_data_routes_data['subdivisions']['sub1']['id']), None)
    sub1_1 = next((s for s in data if s['id'] == setup_data_routes_data['subdivisions']['sub1_1']['id']), None)

    assert sub1 is not None, "Не найдено подразделение Sub1 в ответе /dashboard"
    assert sub1_1 is not None, "Не найдено подразделение Sub1.1 в ответе /dashboard"

    # Проверяем структуру и узлы в Sub1
    assert 'id' in sub1 and 'short_name' in sub1 and 'nodes' in sub1
    assert isinstance(sub1['nodes'], list)
    sub1_node_map = {n['id']: n for n in sub1['nodes']}
    node1_id = setup_data_routes_data['nodes']['node1']
    node2_id = setup_data_routes_data['nodes']['node2']
    node5_id = setup_data_routes_data['nodes']['node5']
    assert node1_id in sub1_node_map, "Node 1 не найден в Sub1"
    assert node2_id in sub1_node_map, "Node 2 не найден в Sub1"
    assert node5_id in sub1_node_map, "Node 5 не найден в Sub1"

    # Проверяем статусы узлов в Sub1
    assert sub1_node_map[node1_id]['status_class'] == 'available'
    assert sub1_node_map[node2_id]['status_class'] == 'unavailable'
    assert sub1_node_map[node5_id]['status_class'] == 'available'

    # Проверяем структуру и узлы в Sub1.1
    assert 'id' in sub1_1 and 'short_name' in sub1_1 and 'nodes' in sub1_1
    assert isinstance(sub1_1['nodes'], list)
    sub1_1_node_map = {n['id']: n for n in sub1_1['nodes']}
    node3_id = setup_data_routes_data['nodes']['node3']
    node4_id = setup_data_routes_data['nodes']['node4']
    assert node3_id in sub1_1_node_map, "Node 3 не найден в Sub1.1"
    assert node4_id in sub1_1_node_map, "Node 4 не найден в Sub1.1"

    # Проверяем статусы узлов в Sub1.1
    assert sub1_1_node_map[node3_id]['status_class'] == 'warning'
    assert sub1_1_node_map[node4_id]['status_class'] == 'unknown'

# --- Тесты для GET /status_detailed ---

def test_get_status_detailed_success(logged_in_client, setup_data_routes_data):
    """Тест: Успешное получение данных для детального статуса."""
    log.info("\nТест: GET /api/v1/status_detailed - Успех")
    response = logged_in_client.get('/api/v1/status_detailed')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200
    data = response.get_json()
    assert isinstance(data, dict), "Ответ /status_detailed должен быть объектом"
    assert 'nodes' in data and isinstance(data['nodes'], list), "Ответ не содержит список 'nodes'"
    assert 'subdivisions' in data and isinstance(data['subdivisions'], list), "Ответ не содержит список 'subdivisions'"

    # Проверяем наличие наших тестовых узлов и их статусы
    node_map = {n['id']: n for n in data['nodes']}
    node1_id = setup_data_routes_data['nodes']['node1']
    node2_id = setup_data_routes_data['nodes']['node2']
    node3_id = setup_data_routes_data['nodes']['node3']
    node4_id = setup_data_routes_data['nodes']['node4']
    node5_id = setup_data_routes_data['nodes']['node5']

    assert node1_id in node_map and node_map[node1_id]['status_class'] == 'available'
    assert node2_id in node_map and node_map[node2_id]['status_class'] == 'unavailable'
    assert node3_id in node_map and node_map[node3_id]['status_class'] == 'warning'
    assert node4_id in node_map and node_map[node4_id]['status_class'] == 'unknown'
    assert node5_id in node_map and node_map[node5_id]['status_class'] == 'available'

    # Проверяем наличие подразделений
    sub_ids = {s['id'] for s in data['subdivisions']}
    assert setup_data_routes_data['subdivisions']['sub1']['id'] in sub_ids
    assert setup_data_routes_data['subdivisions']['sub1_1']['id'] in sub_ids