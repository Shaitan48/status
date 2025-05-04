# status/tests/integration/test_subdivision_routes.py
"""
Интеграционные тесты для API эндпоинтов управления Подразделениями (/api/v1/subdivisions).
"""
import pytest
import json
import logging
import secrets # Для уникальных имен/кодов

# Используем фикстуры из conftest.py
# logged_in_client - клиент с выполненным входом
# db_conn - соединение с БД в транзакции
# app - экземпляр приложения (не используется напрямую в тестах, но нужен для db_conn)

log = logging.getLogger(__name__)

# --- Фикстура для создания базовых данных (опционально, можно и без нее) ---
# Эта фикстура создает только корневой элемент, чтобы было куда добавлять
@pytest.fixture(scope='function') # function scope, т.к. данные меняются в тестах
def setup_subdivision_data(db_conn):
    """Создает базовое корневое подразделение для тестов."""
    log.debug("\n[Setup Subdivision] Настройка базового подразделения...")
    cursor = db_conn.cursor()
    root_oid = 9020
    root_name = "SubTest Root"
    root_id = None
    try:
        # Удаляем, если существует с таким object_id (на случай прерванного теста)
        cursor.execute("DELETE FROM subdivisions WHERE object_id = %s", (root_oid,))
        cursor.execute(
            "INSERT INTO subdivisions (object_id, short_name, priority) VALUES (%s, %s, 1) RETURNING id",
            (root_oid, root_name)
        )
        root_id = cursor.fetchone()['id']
        log.debug(f"[Setup Subdivision] Создано корневое подразделение ID={root_id}, ObjectID={root_oid}")
        yield {'root_id': root_id, 'root_oid': root_oid, 'root_name': root_name}
    except Exception as e:
        log.error(f"ОШИБКА в фикстуре setup_subdivision_data: {e}", exc_info=True)
        pytest.fail(f"Не удалось настроить базовое подразделение: {e}")
    # Очистка не нужна, т.к. db_conn откатит транзакцию

# --- Тесты CRUD для Подразделений ---

def test_create_subdivision_success(logged_in_client, db_conn, setup_subdivision_data):
    """Тест: Успешное создание дочернего подразделения."""
    log.info("\nТест: POST /api/v1/subdivisions - Успех")
    parent_id = setup_subdivision_data['root_id']
    new_oid = 9021
    new_name = f"Sub Child {secrets.token_hex(3)}"
    new_transport = f"TC{secrets.token_hex(3).upper()}"
    sub_data = {
        "object_id": new_oid,
        "short_name": new_name,
        "parent_id": parent_id,
        "full_name": "Полное имя дочернего",
        "domain_name": "child.test",
        "transport_system_code": new_transport,
        "priority": 5,
        "comment": "Тестовый дочерний",
        "icon_filename": "folder.svg"
    }

    response = logged_in_client.post('/api/v1/subdivisions', json=sub_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")

    assert response.status_code == 201, "Ожидался статус 201 Created"
    created_sub = response.get_json()
    assert created_sub and 'id' in created_sub, "Ответ не содержит JSON с ID созданного подразделения"
    # Проверяем все поля
    assert created_sub['object_id'] == new_oid
    assert created_sub['short_name'] == new_name
    assert created_sub['parent_id'] == parent_id
    assert created_sub['full_name'] == sub_data['full_name']
    assert created_sub['domain_name'] == sub_data['domain_name']
    assert created_sub['transport_system_code'] == new_transport
    assert created_sub['priority'] == sub_data['priority']
    assert created_sub['comment'] == sub_data['comment']
    assert created_sub['icon_filename'] == sub_data['icon_filename']

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT * FROM subdivisions WHERE id = %s", (created_sub['id'],))
    db_sub = cursor.fetchone()
    assert db_sub is not None, "Подразделение не найдено в БД"
    assert db_sub['object_id'] == new_oid
    assert db_sub['short_name'] == new_name
    assert db_sub['parent_id'] == parent_id
    assert db_sub['transport_system_code'] == new_transport
    cursor.close()

def test_create_subdivision_root_success(logged_in_client, db_conn):
    """Тест: Успешное создание корневого подразделения (parent_id = null)."""
    log.info("\nТест: POST /api/v1/subdivisions - Успех (корневой)")
    new_oid = 9022
    new_name = f"Sub Root {secrets.token_hex(3)}"
    sub_data = {
        "object_id": new_oid,
        "short_name": new_name,
        "parent_id": None # Явно указываем null
    }
    response = logged_in_client.post('/api/v1/subdivisions', json=sub_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 201
    created_sub = response.get_json()
    assert created_sub and 'id' in created_sub
    assert created_sub['parent_id'] is None # Проверяем, что родитель null

def test_create_subdivision_missing_fields(logged_in_client):
    """Тест: Ошибка создания (нет object_id или short_name)."""
    log.info("\nТест: POST /api/v1/subdivisions - Ошибка (нет полей)")
    response1 = logged_in_client.post('/api/v1/subdivisions', json={"short_name": "No ObjectID"})
    assert response1.status_code == 422
    assert 'object_id' in response1.get_json()['error']['message']
    response2 = logged_in_client.post('/api/v1/subdivisions', json={"object_id": 9023})
    assert response2.status_code == 422
    assert 'short_name' in response2.get_json()['error']['message']

def test_create_subdivision_duplicate_object_id(logged_in_client, setup_subdivision_data):
    """Тест: Ошибка создания (дубликат object_id)."""
    log.info("\nТест: POST /api/v1/subdivisions - Ошибка (дубль ObjectID)")
    duplicate_oid = setup_subdivision_data['root_oid']
    sub_data = {"object_id": duplicate_oid, "short_name": "Duplicate OID Test"}
    response = logged_in_client.post('/api/v1/subdivisions', json=sub_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 409, "Ожидался статус 409 Conflict"
    error_data = response.get_json()
    assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'CONFLICT'
    # Проверяем, что сообщение содержит object_id (или информацию об уникальности)
    assert 'object_id' in error_data['error']['message'] or 'уже существует' in error_data['error']['message']


def test_create_subdivision_invalid_parent(logged_in_client):
    """Тест: Ошибка создания (неверный parent_id)."""
    log.info("\nТест: POST /api/v1/subdivisions - Ошибка (неверный parent_id)")
    invalid_parent_id = 999999
    sub_data = {"object_id": 9024, "short_name": "Invalid Parent Test", "parent_id": invalid_parent_id}
    response = logged_in_client.post('/api/v1/subdivisions', json=sub_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 422 # Validation Failure (т.к. проверка в коде)
    error_data = response.get_json()
    assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'VALIDATION_FAILURE'
    assert 'Родительское подразделение' in error_data['error']['message']
    assert str(invalid_parent_id) in error_data['error']['message']

def test_create_subdivision_invalid_transport_code(logged_in_client):
    """Тест: Ошибка создания (неверный формат transport_system_code)."""
    log.info("\nТест: POST /api/v1/subdivisions - Ошибка (неверный Код ТС)")
    sub_data = {"object_id": 9025, "short_name": "Invalid TC", "transport_system_code": "INVALID TC!"}
    response = logged_in_client.post('/api/v1/subdivisions', json=sub_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 422
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Код ТС' in error_data['error']['message']

# --- Тесты для GET ---

def test_get_subdivision_list_success(logged_in_client, setup_subdivision_data):
    """Тест: Успешное получение списка подразделений."""
    log.info("\nТест: GET /api/v1/subdivisions - Успех")
    # Создадим дочернее, чтобы в списке было > 1
    parent_id = setup_subdivision_data['root_id']
    child_oid = 9026; child_name = f"Sub List Child {secrets.token_hex(3)}"
    create_resp = logged_in_client.post('/api/v1/subdivisions', json={"object_id": child_oid, "short_name": child_name, "parent_id": parent_id})
    assert create_resp.status_code == 201

    response = logged_in_client.get('/api/v1/subdivisions')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200
    data = response.get_json()
    assert data and 'items' in data and isinstance(data['items'], list)
    assert 'total_count' in data and data['total_count'] >= 2 # Должно быть как минимум 2
    # Проверяем наличие созданных
    root_found = any(item['id'] == parent_id for item in data['items'])
    child_found = any(item['object_id'] == child_oid for item in data['items'])
    assert root_found, "Корневое тестовое подразделение не найдено в списке"
    assert child_found, "Дочернее тестовое подразделение не найдено в списке"

# Добавить тесты для фильтрации GET /subdivisions (по parent_id, search_text)

def test_get_subdivision_detail_success(logged_in_client, setup_subdivision_data):
    """Тест: Успешное получение деталей подразделения."""
    log.info("\nТест: GET /api/v1/subdivisions/{id} - Успех")
    sub_id = setup_subdivision_data['root_id']
    response = logged_in_client.get(f'/api/v1/subdivisions/{sub_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 200
    data = response.get_json()
    assert data and data['id'] == sub_id
    assert data['short_name'] == setup_subdivision_data['root_name']
    assert data['object_id'] == setup_subdivision_data['root_oid']

def test_get_subdivision_detail_not_found(logged_in_client):
    """Тест: Ошибка 404 при запросе несуществующего подразделения."""
    log.info("\nТест: GET /api/v1/subdivisions/{id} - 404 Not Found")
    sub_id = 999996
    response = logged_in_client.get(f'/api/v1/subdivisions/{sub_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'не найдено' in error_data['error']['message']

# --- Тесты для PUT ---

def test_update_subdivision_success(logged_in_client, db_conn, setup_subdivision_data):
    """Тест: Успешное обновление подразделения."""
    log.info("\nТест: PUT /api/v1/subdivisions/{id} - Успех")
    sub_id = setup_subdivision_data['root_id']
    updated_name = f"Updated Sub Name {secrets.token_hex(3)}"
    updated_prio = 20
    updated_tc = "UTEST"
    update_data = {
        "short_name": updated_name,
        "priority": updated_prio,
        "transport_system_code": updated_tc,
        "comment": "Updated comment"
        # parent_id и object_id не меняем
    }
    response = logged_in_client.put(f'/api/v1/subdivisions/{sub_id}', json=update_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 200
    updated_sub = response.get_json()
    assert updated_sub and updated_sub['id'] == sub_id
    assert updated_sub['short_name'] == updated_name
    assert updated_sub['priority'] == updated_prio
    assert updated_sub['transport_system_code'] == updated_tc
    assert updated_sub['comment'] == update_data['comment']

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT short_name, priority, transport_system_code, comment FROM subdivisions WHERE id = %s", (sub_id,))
    db_sub = cursor.fetchone()
    assert db_sub['short_name'] == updated_name
    assert db_sub['priority'] == updated_prio
    assert db_sub['transport_system_code'] == updated_tc
    assert db_sub['comment'] == update_data['comment']
    cursor.close()

def test_update_subdivision_set_parent(logged_in_client, db_conn, setup_subdivision_data):
    """Тест: Успешное изменение родителя подразделения."""
    log.info("\nТест: PUT /api/v1/subdivisions/{id} - Смена родителя")
    parent_id = setup_subdivision_data['root_id']
    # Создаем еще одно подразделение, которое станет дочерним
    child_oid = 9027; child_name = f"Sub To Move {secrets.token_hex(3)}"
    create_resp = logged_in_client.post('/api/v1/subdivisions', json={"object_id": child_oid, "short_name": child_name, "parent_id": None}) # Сначала корневое
    assert create_resp.status_code == 201
    child_id = create_resp.get_json()['id']

    # Обновляем его, устанавливая родителя
    update_data = {"parent_id": parent_id}
    response = logged_in_client.put(f'/api/v1/subdivisions/{child_id}', json=update_data)
    assert response.status_code == 200
    updated_sub = response.get_json()
    assert updated_sub['id'] == child_id
    assert updated_sub['parent_id'] == parent_id

def test_update_subdivision_circular_parent(logged_in_client, setup_subdivision_data):
    """Тест: Ошибка обновления (попытка установить родителя самого на себя)."""
    log.info("\nТест: PUT /api/v1/subdivisions/{id} - Ошибка (цикл. родитель)")
    sub_id = setup_subdivision_data['root_id']
    update_data = {"parent_id": sub_id} # Пытаемся установить себя родителем
    response = logged_in_client.put(f'/api/v1/subdivisions/{sub_id}', json=update_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 422 # Validation Failure
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Нельзя установить родителя самого на себя' in error_data['error']['message']

def test_update_subdivision_not_found(logged_in_client):
    """Тест: Ошибка 404 при обновлении несуществующего подразделения."""
    log.info("\nТест: PUT /api/v1/subdivisions/{id} - 404 Not Found")
    sub_id = 999995
    response = logged_in_client.put(f'/api/v1/subdivisions/{sub_id}', json={"short_name": "Update non-existent"})
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'не найдено для обновления' in error_data['error']['message']

# --- Тесты для DELETE ---

def test_delete_subdivision_success(logged_in_client, db_conn, setup_subdivision_data):
    """Тест: Успешное удаление подразделения (без узлов и детей)."""
    log.info("\nТест: DELETE /api/v1/subdivisions/{id} - Успех")
    # Создаем подразделение специально для удаления
    del_oid = 9028; del_name = f"Sub To Delete {secrets.token_hex(3)}"
    create_resp = logged_in_client.post('/api/v1/subdivisions', json={"object_id": del_oid, "short_name": del_name})
    assert create_resp.status_code == 201
    sub_id = create_resp.get_json()['id']

    # Удаляем
    response = logged_in_client.delete(f'/api/v1/subdivisions/{sub_id}')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 204

    # Проверяем в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT 1 FROM subdivisions WHERE id = %s", (sub_id,))
    assert cursor.fetchone() is None, "Подразделение все еще в БД после DELETE"
    cursor.close()

def test_delete_subdivision_not_found(logged_in_client):
    """Тест: Ошибка 404 при удалении несуществующего подразделения."""
    log.info("\nТест: DELETE /api/v1/subdivisions/{id} - 404 Not Found")
    sub_id = 999994
    response = logged_in_client.delete(f'/api/v1/subdivisions/{sub_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    # <<< ИЗМЕНЕНА ПРОВЕРКА СООБЩЕНИЯ >>>
    assert 'не найдено' in error_data['error']['message'] # Достаточно проверить "не найдено"
    assert str(sub_id) in error_data['error']['message'] # Убедимся, что ID есть в сообщении

# TODO: Добавить тесты на удаление подразделения с узлами (ожидать 500 или 409, в зависимости от ON DELETE)
# TODO: Добавить тесты на удаление подразделения с дочерними (ожидать 500 или 409, если ON DELETE RESTRICT, или проверять, что у детей parent_id стал NULL, если ON DELETE SET NULL)