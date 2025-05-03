# status/tests/integration/test_api_key_routes.py
import pytest
import json
import secrets
import hashlib
from flask import session
from app.models.user import User

# --- Вспомогательные функции (без изменений) ---
def create_test_user_cli(runner, username='testuser', password='password'):
    print(f"\nВызов CLI: create-user {username} {password}")
    result = runner.invoke(args=['create-user', username, password])
    print(f"Вывод CLI create-user ({username}): {result.output}")
    assert 'Ошибка:' not in result.output or 'уже существует' in result.output, f"Неожиданная ошибка при создании пользователя {username}"
def login_test_user(client, username='testuser', password='password'):
    print(f"\nПопытка логина пользователя: {username}")
    response = client.post('/login', data={'username': username, 'password': password}, follow_redirects=True)
    print(f"Ответ сервера на логин ({username}): {response.status_code}")
    response_text = response.get_data(as_text=True)
    assert 'Неверное имя пользователя или пароль' not in response_text, "Логин не удался (неверные данные)"
    assert 'Учетная запись неактивна' not in response_text, "Логин не удался (учетная запись неактивна)"
    assert response.status_code == 200, "Страница после логина не загрузилась"
    with client.session_transaction() as sess:
        assert '_user_id' in sess, "User ID не найден в сессии после логина"
    print(f"Пользователь '{username}' успешно залогинен.")
    return response
def create_test_subdivision_direct(db_conn, object_id, short_name, transport_code='TEST'):
    print(f"Создание тестового подразделения: object_id={object_id}, short_name='{short_name}', transport_code='{transport_code}'")
    cursor = db_conn.cursor()
    try:
        cursor.execute("DELETE FROM subdivisions WHERE object_id = %s OR transport_system_code = %s", (object_id, transport_code))
        cursor.execute(
            """
            INSERT INTO subdivisions (object_id, short_name, priority, transport_system_code)
            VALUES (%s, %s, 999, %s)
            ON CONFLICT (object_id) DO UPDATE SET
                short_name = EXCLUDED.short_name,
                priority = EXCLUDED.priority,
                transport_system_code = EXCLUDED.transport_system_code
            RETURNING id
            """,
            (object_id, short_name, transport_code)
        )
        result = cursor.fetchone()
        if not result:
            cursor.execute("SELECT id FROM subdivisions WHERE object_id = %s", (object_id,))
            result = cursor.fetchone()
        new_id = result['id']
        print(f"Тестовое подразделение ID {new_id} создано/обновлено.")
        return new_id
    except Exception as e:
        print(f"ОШИБКА создания тестового подразделения {object_id}: {e}")
        raise
def create_api_key_via_api(client, description, role, object_id=None):
    print(f"\nВызов API: POST /api/v1/api_keys (Role: {role}, ObjectID: {object_id})")
    payload = {'description': description, 'role': role}
    if object_id is not None: payload['object_id'] = object_id
    response = client.post('/api/v1/api_keys', json=payload)
    print(f"Ответ API на создание ключа: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    return response

# --- Фикстура для настройки пользователей (без изменений) ---
@pytest.fixture(scope='session')
def setup_session_users(runner):
    print("\n--- Настройка пользователей для сессии тестов api_keys ---")
    create_test_user_cli(runner, username='key_admin', password='password')
    create_test_user_cli(runner, username='key_viewer', password='password')
    print("--- Пользователи для сессии настроены ---")

# --- Тесты ---

def test_api_key_unauthorized_access(client):
    """Тест: Доступ к эндпоинтам ключей без логина."""
    print("\nТест: Доступ без авторизации")
    response_get = client.get('/api/v1/api_keys')
    assert response_get.status_code == 302, f"GET /api_keys без логина должен вернуть 302 (редирект), а не {response_get.status_code}"
    assert '/login' in response_get.location

    response_post = client.post('/api/v1/api_keys', json={'description': 'test', 'role': 'agent'})
    assert response_post.status_code == 302, f"POST /api_keys без логина должен вернуть 302 (редирект), а не {response_post.status_code}"
    assert '/login' in response_post.location

def test_api_key_crud_cycle(client, db_conn, setup_session_users):
    """Тест: Полный CRUD цикл для API ключа."""
    print("\nТест: CRUD цикл API ключа")
    login_test_user(client, username='key_admin')

    test_oid = 9901
    create_test_subdivision_direct(db_conn, test_oid, "CRUD Key Sub", transport_code="CRD")

    desc = "CRUD Test Key"; role = "loader"
    create_response = create_api_key_via_api(client, desc, role, test_oid)
    assert create_response.status_code == 201
    created_data = create_response.get_json(); assert created_data and 'id' in created_data and 'api_key' in created_data
    key_id = created_data['id']; api_key_value = created_data['api_key']
    assert created_data['description'] == desc; assert created_data['role'] == role
    assert created_data['object_id'] == test_oid; assert created_data['is_active'] is True

    print("\nПроверка GET /api/v1/api_keys после создания")
    list_response = client.get(f'/api/v1/api_keys?limit=100'); assert list_response.status_code == 200
    list_data = list_response.get_json(); assert list_data and 'items' in list_data
    found_in_list = next((item for item in list_data['items'] if item['id'] == key_id), None); assert found_in_list is not None
    assert found_in_list['description'] == desc; assert found_in_list['role'] == role
    assert found_in_list['object_id'] == test_oid; assert found_in_list['is_active'] is True

    updated_desc = "CRUD Test Key - Updated"; updated_is_active = False
    print(f"\nВызов API: PUT /api/v1/api_keys/{key_id}")
    update_response = client.put(f'/api/v1/api_keys/{key_id}', json={'description': updated_desc, 'is_active': updated_is_active})
    print(f"Ответ API на обновление ключа: {update_response.status_code}, Тело: {update_response.get_data(as_text=True)[:200]}...")
    assert update_response.status_code == 200; updated_data = update_response.get_json()
    assert updated_data['id'] == key_id; assert updated_data['description'] == updated_desc
    assert updated_data['role'] == role; assert updated_data['object_id'] == test_oid
    assert updated_data['is_active'] is updated_is_active

    print("\nПроверка GET /api/v1/api_keys после обновления (is_active=false)")
    list_response_updated = client.get(f'/api/v1/api_keys?is_active=false&limit=100'); assert list_response_updated.status_code == 200
    list_data_updated = list_response_updated.get_json()
    found_updated = next((item for item in list_data_updated['items'] if item['id'] == key_id), None); assert found_updated is not None
    assert found_updated['description'] == updated_desc; assert found_updated['is_active'] is False

    print("\nПроверка доступа с НЕАКТИВНЫМ ключом")
    headers_inactive = {'X-API-Key': api_key_value}
    health_resp_inactive = client.get('/health', headers=headers_inactive); assert health_resp_inactive.status_code == 200
    assign_resp_inactive = client.get(f'/api/v1/assignments?object_id={test_oid}', headers=headers_inactive)
    assert assign_resp_inactive.status_code == 403
    assign_json_inactive = assign_resp_inactive.get_json()
    assert assign_json_inactive is not None
    assert assign_json_inactive.get('error', {}).get('code') == 'FORBIDDEN'
    assert assign_json_inactive.get('error', {}).get('message') == 'API key is inactive'

    print(f"\nВызов API: DELETE /api/v1/api_keys/{key_id}")
    delete_response = client.delete(f'/api/v1/api_keys/{key_id}'); print(f"Ответ API на удаление ключа: {delete_response.status_code}"); assert delete_response.status_code == 204

    print("\nПроверка GET /api/v1/api_keys после удаления")
    list_response_deleted = client.get(f'/api/v1/api_keys?limit=100'); assert list_response_deleted.status_code == 200
    list_data_deleted = list_response_deleted.get_json()
    found_deleted = next((item for item in list_data_deleted['items'] if item['id'] == key_id), None); assert found_deleted is None

def test_api_key_role_access(client, db_conn, setup_session_users):
    """Тест: Проверка доступа к эндпоинтам с ключами разных ролей."""
    print("\nТест: Проверка ролей API ключей")
    login_test_user(client, username='key_admin')

    test_oid_roles = 9902
    create_test_subdivision_direct(db_conn, test_oid_roles, "Role Test Sub", transport_code="RLS")

    agent_key_resp = create_api_key_via_api(client, "Role Test Agent", "agent", test_oid_roles)
    loader_key_resp = create_api_key_via_api(client, "Role Test Loader", "loader")
    configurator_key_resp = create_api_key_via_api(client, "Role Test Configurator", "configurator", test_oid_roles)
    assert agent_key_resp.status_code == 201 and 'api_key' in agent_key_resp.get_json()
    assert loader_key_resp.status_code == 201 and 'api_key' in loader_key_resp.get_json()
    assert configurator_key_resp.status_code == 201 and 'api_key' in configurator_key_resp.get_json()
    agent_key = agent_key_resp.get_json()['api_key']; loader_key = loader_key_resp.get_json()['api_key']; configurator_key = configurator_key_resp.get_json()['api_key']
    headers_agent = {'X-API-Key': agent_key}; headers_loader = {'X-API-Key': loader_key}; headers_configurator = {'X-API-Key': configurator_key}; headers_invalid = {'X-API-Key': 'invalid-key-string'}

    # 1. /assignments (нужен 'agent')
    print("Проверка /assignments...")
    resp = client.get(f'/api/v1/assignments?object_id={test_oid_roles}', headers=headers_agent); assert resp.status_code == 200
    resp = client.get(f'/api/v1/assignments?object_id={test_oid_roles}', headers=headers_loader); assert resp.status_code == 403
    resp = client.get(f'/api/v1/assignments?object_id={test_oid_roles}', headers=headers_configurator); assert resp.status_code == 403
    resp = client.get(f'/api/v1/assignments?object_id={test_oid_roles}', headers=headers_invalid); assert resp.status_code == 401
    resp = client.get(f'/api/v1/assignments?object_id={test_oid_roles}'); assert resp.status_code == 401

    # 2. /checks (нужен 'agent' или 'loader')
    print("Проверка POST /checks...")
    check_payload = {'assignment_id': 1, 'is_available': True} # Невалидный ID, но роль проверяется раньше
    resp = client.post('/api/v1/checks', json=check_payload, headers=headers_agent)
    assert resp.status_code != 403, "Agent должен иметь доступ к POST /checks"
    resp = client.post('/api/v1/checks', json=check_payload, headers=headers_loader)
    assert resp.status_code != 403, "Loader должен иметь доступ к POST /checks"
    resp = client.post('/api/v1/checks', json=check_payload, headers=headers_configurator)
    assert resp.status_code == 403, "Configurator не должен иметь доступ к POST /checks"
    resp = client.post('/api/v1/checks', json=check_payload, headers=headers_invalid); assert resp.status_code == 401
    resp = client.post('/api/v1/checks', json=check_payload); assert resp.status_code == 401

    # 3. /checks/bulk (нужен 'loader')
    print("Проверка POST /checks/bulk...")
    # Payload теперь должен быть более валидным, чтобы не вызывать ошибку 400 из-за НЕГО
    valid_check_item = {'assignment_id': 1, 'IsAvailable': True, 'Timestamp': '2024-01-01T10:00:00Z'} # PowerShell формат
    bulk_payload_invalid_items = {"results": [check_payload]} # Старый невалидный payload
    bulk_payload_valid_items = {"results": [valid_check_item]} # Более валидный payload (но assignment_id=1 все еще может не существовать)

    resp = client.post('/api/v1/checks/bulk', json=bulk_payload_invalid_items, headers=headers_agent); assert resp.status_code == 403
    # <<< ИЗМЕНЕНО: Ожидаем 207, так как запрос принят, но элемент внутри не прошел валидацию >>>
    resp = client.post('/api/v1/checks/bulk', json=bulk_payload_invalid_items, headers=headers_loader)
    assert resp.status_code == 207, f"Loader с невалидными данными должен получать 207, а не {resp.status_code}"
    # <<< Можно добавить проверку с валидными данными, если создать assignment_id=1 >>>
    # resp_valid = client.post('/api/v1/checks/bulk', json=bulk_payload_valid_items, headers=headers_loader)
    # assert resp_valid.status_code == 207, f"Loader с валидными данными (но не сущ. assignment) должен получать 207, а не {resp_valid.status_code}"

    resp = client.post('/api/v1/checks/bulk', json=bulk_payload_invalid_items, headers=headers_configurator); assert resp.status_code == 403
    resp = client.post('/api/v1/checks/bulk', json=bulk_payload_invalid_items, headers=headers_invalid); assert resp.status_code == 401
    resp = client.post('/api/v1/checks/bulk', json=bulk_payload_invalid_items); assert resp.status_code == 401

    # 4. /events (нужен 'loader')
    print("Проверка POST /events...")
    event_payload = {"event_type": "TEST_EVENT", "message": "Test"}
    resp = client.post('/api/v1/events', json=event_payload, headers=headers_agent); assert resp.status_code == 403
    resp = client.post('/api/v1/events', json=event_payload, headers=headers_loader); assert resp.status_code == 201
    resp = client.post('/api/v1/events', json=event_payload, headers=headers_configurator); assert resp.status_code == 403
    resp = client.post('/api/v1/events', json=event_payload, headers=headers_invalid); assert resp.status_code == 401
    resp = client.post('/api/v1/events', json=event_payload); assert resp.status_code == 401

    # 5. /objects/{id}/offline_config (нужен 'configurator')
    print("Проверка GET /objects/{id}/offline_config...")
    url_offline = f'/api/v1/objects/{test_oid_roles}/offline_config'
    resp = client.get(url_offline, headers=headers_agent); assert resp.status_code == 403
    resp = client.get(url_offline, headers=headers_loader); assert resp.status_code == 403
    resp = client.get(url_offline, headers=headers_configurator); assert resp.status_code == 200
    resp = client.get(url_offline, headers=headers_invalid); assert resp.status_code == 401
    resp = client.get(url_offline); assert resp.status_code == 401