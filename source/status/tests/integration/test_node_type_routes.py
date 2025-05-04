# status/tests/integration/test_node_type_routes.py
"""
Интеграционные тесты для API эндпоинтов управления Типами Узлов (/api/v1/node_types).
"""
import pytest
import json
import logging
import secrets

# Используем фикстуры из conftest.py
# logged_in_client - клиент с выполненным входом
# db_conn - соединение с БД в транзакции
# app - экземпляр приложения

log = logging.getLogger(__name__)

# --- Фикстура для создания базового типа (для тестов создания дочерних) ---
@pytest.fixture(scope='function')
def setup_node_type_data(logged_in_client, db_conn):
    """Создает базовый тип узла для использования в качестве родителя."""
    log.debug("\n[Setup Node Type] Создание базового типа для тестов...")
    type_name = f"APITest BaseType {secrets.token_hex(3)}"
    create_data = {"name": type_name, "priority": 1}
    response = logged_in_client.post('/api/v1/node_types', json=create_data)
    assert response.status_code == 201, "Не удалось создать базовый тип узла в фикстуре"
    created_type = response.get_json()
    type_id = created_type['id']
    log.debug(f"[Setup Node Type] Базовый тип ID={type_id} создан.")
    yield {'base_type_id': type_id, 'base_type_name': type_name}
    # Очистка не нужна, db_conn откатит транзакцию

# --- Тесты CRUD для Типов Узлов ---

def test_create_node_type_root_success(logged_in_client, db_conn):
    """Тест: Успешное создание корневого типа узла."""
    log.info("\nТест: POST /api/v1/node_types - Успех (корневой)")
    type_name = f"API Root Type {secrets.token_hex(4)}"
    type_data = {
        "name": type_name,
        "description": "Тестовый корневой тип",
        "parent_type_id": None, # Явно указываем null
        "priority": 5,
        "icon_filename": "server.svg"
    }
    response = logged_in_client.post('/api/v1/node_types', json=type_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")

    assert response.status_code == 201, "Ожидался статус 201 Created"
    created_type = response.get_json()
    assert created_type and 'id' in created_type, "Ответ не содержит JSON с ID"
    assert created_type['name'] == type_name
    assert created_type['parent_type_id'] is None
    assert created_type['priority'] == 5
    assert created_type['icon_filename'] == "server.svg"
    assert created_type['description'] == type_data['description']

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT name, parent_type_id, priority, icon_filename FROM node_types WHERE id = %s", (created_type['id'],))
    db_type = cursor.fetchone()
    assert db_type is not None
    assert db_type['name'] == type_name
    assert db_type['parent_type_id'] is None
    assert db_type['priority'] == 5
    assert db_type['icon_filename'] == "server.svg"
    cursor.close()

def test_create_node_type_child_success(logged_in_client, db_conn, setup_node_type_data):
    """Тест: Успешное создание дочернего типа узла."""
    log.info("\nТест: POST /api/v1/node_types - Успех (дочерний)")
    parent_type_id = setup_node_type_data['base_type_id']
    type_name = f"API Child Type {secrets.token_hex(4)}"
    type_data = {"name": type_name, "parent_type_id": parent_type_id}

    response = logged_in_client.post('/api/v1/node_types', json=type_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")

    assert response.status_code == 201
    created_type = response.get_json()
    assert created_type and 'id' in created_type
    assert created_type['name'] == type_name
    assert created_type['parent_type_id'] == parent_type_id

def test_create_node_type_missing_name(logged_in_client):
    """Тест: Ошибка создания типа (нет обязательного поля 'name')."""
    log.info("\nТест: POST /api/v1/node_types - Ошибка (нет имени)")
    response = logged_in_client.post('/api/v1/node_types', json={"description": "Нет имени"})
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 422 # Validation Failure
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Missing required field: name' in error_data['error']['message']

def test_create_node_type_invalid_parent(logged_in_client):
    """Тест: Ошибка создания типа (несуществующий parent_type_id)."""
    log.info("\nТест: POST /api/v1/node_types - Ошибка (неверный родитель)")
    invalid_parent_id = 999999
    type_data = {"name": "Invalid Parent Type", "parent_type_id": invalid_parent_id}
    response = logged_in_client.post('/api/v1/node_types', json=type_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 422 # Validation Failure
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Родительский тип узла' in error_data['error']['message']
    assert str(invalid_parent_id) in error_data['error']['message']

def test_create_node_type_duplicate_name_root(logged_in_client):
    """Тест: Ошибка создания типа (дубликат имени для корневого)."""
    log.info("\nТест: POST /api/v1/node_types - Ошибка (дубль имени, корень)")
    type_name = f"API Dup Root Type {secrets.token_hex(3)}"
    resp1 = logged_in_client.post('/api/v1/node_types', json={"name": type_name})
    assert resp1.status_code == 201, "Не удалось создать первый тип для теста дубликата"
    # Повторный запрос с тем же именем
    resp2 = logged_in_client.post('/api/v1/node_types', json={"name": type_name})
    log.info(f"Ответ API (дубликат): {resp2.status_code}, Тело: {resp2.get_data(as_text=True)}")
    assert resp2.status_code == 409, "Ожидался статус 409 Conflict"
    error_data = resp2.get_json(); assert error_data and 'error' in error_data
    assert 'already exists' in error_data['error']['message']

def test_create_node_type_duplicate_name_child(logged_in_client, setup_node_type_data):
    """Тест: Ошибка создания типа (дубликат имени у одного родителя)."""
    log.info("\nТест: POST /api/v1/node_types - Ошибка (дубль имени, дочерний)")
    parent_id = setup_node_type_data['base_type_id']
    child_name = f"API Dup Child Type {secrets.token_hex(3)}"
    resp1 = logged_in_client.post('/api/v1/node_types', json={"name": child_name, "parent_type_id": parent_id})
    assert resp1.status_code == 201, "Не удалось создать первый дочерний тип"
    # Повторный запрос с тем же именем и родителем
    resp2 = logged_in_client.post('/api/v1/node_types', json={"name": child_name, "parent_type_id": parent_id})
    log.info(f"Ответ API (дубликат): {resp2.status_code}, Тело: {resp2.get_data(as_text=True)}")
    assert resp2.status_code == 409, "Ожидался статус 409 Conflict"
    error_data = resp2.get_json(); assert error_data and 'error' in error_data
    assert 'already exists' in error_data['error']['message']

# --- Тесты для GET ---

def test_get_node_type_list_success(logged_in_client, setup_node_type_data):
    """Тест: Успешное получение списка типов узлов."""
    log.info("\nТест: GET /api/v1/node_types - Успех")
    base_type_id = setup_node_type_data['base_type_id'] # ID типа, созданного в фикстуре
    response = logged_in_client.get('/api/v1/node_types')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200
    data = response.get_json()
    assert data and 'items' in data and isinstance(data['items'], list)
    assert 'total_count' in data and data['total_count'] > 0 # Должен быть хотя бы базовый тип 0 и наш
    # Проверяем наличие типа из фикстуры
    assert any(item['id'] == base_type_id for item in data['items']), "Тестовый тип не найден в списке"

def test_get_node_type_detail_success(logged_in_client, setup_node_type_data):
    """Тест: Успешное получение деталей типа по ID."""
    log.info("\nТест: GET /api/v1/node_types/{id} - Успех")
    type_id = setup_node_type_data['base_type_id']
    type_name = setup_node_type_data['base_type_name']
    response = logged_in_client.get(f'/api/v1/node_types/{type_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 200
    data = response.get_json()
    assert data and data['id'] == type_id
    assert data['name'] == type_name

def test_get_node_type_detail_not_found(logged_in_client):
    """Тест: Ошибка 404 при запросе несуществующего типа."""
    log.info("\nТест: GET /api/v1/node_types/{id} - 404 Not Found")
    type_id = 999995
    response = logged_in_client.get(f'/api/v1/node_types/{type_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'not found' in error_data['error']['message']

# --- Тесты для PUT ---

def test_update_node_type_success(logged_in_client, db_conn, setup_node_type_data):
    """Тест: Успешное обновление типа узла."""
    log.info("\nТест: PUT /api/v1/node_types/{id} - Успех")
    type_id = setup_node_type_data['base_type_id']
    updated_name = f"Updated Type Name {secrets.token_hex(3)}"
    updated_desc = "Новое описание"
    updated_prio = 50
    updated_icon = "cpu.svg"
    update_data = {
        "name": updated_name,
        "description": updated_desc,
        "priority": updated_prio,
        "icon_filename": updated_icon
        # parent_type_id не меняем
    }
    response = logged_in_client.put(f'/api/v1/node_types/{type_id}', json=update_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 200
    updated_type = response.get_json()
    assert updated_type and updated_type['id'] == type_id
    assert updated_type['name'] == updated_name
    assert updated_type['description'] == updated_desc
    assert updated_type['priority'] == updated_prio
    assert updated_type['icon_filename'] == updated_icon

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT name, description, priority, icon_filename FROM node_types WHERE id = %s", (type_id,))
    db_type = cursor.fetchone()
    assert db_type['name'] == updated_name
    assert db_type['description'] == updated_desc
    assert db_type['priority'] == updated_prio
    assert db_type['icon_filename'] == updated_icon
    cursor.close()

def test_update_node_type_not_found(logged_in_client):
    """Тест: Ошибка 404 при обновлении несуществующего типа."""
    log.info("\nТест: PUT /api/v1/node_types/{id} - 404 Not Found")
    type_id = 999994
    response = logged_in_client.put(f'/api/v1/node_types/{type_id}', json={"name": "Update non-existent"})
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'not found for update' in error_data['error']['message']

def test_update_node_type_circular_parent(logged_in_client, setup_node_type_data):
    """Тест: Ошибка обновления (попытка установить родителя самого на себя)."""
    log.info("\nТест: PUT /api/v1/node_types/{id} - Ошибка (цикл. родитель)")
    type_id = setup_node_type_data['base_type_id']
    update_data = {"parent_type_id": type_id} # Себя в родители
    response = logged_in_client.put(f'/api/v1/node_types/{type_id}', json=update_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 422 # Validation Failure
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Нельзя установить родителя самого на себя' in error_data['error']['message']

# --- Тесты для DELETE ---

def test_delete_node_type_success(logged_in_client, db_conn, setup_node_type_data):
    """Тест: Успешное удаление типа узла (без зависимостей)."""
    log.info("\nТест: DELETE /api/v1/node_types/{id} - Успех")
    # Используем тип, созданный в фикстуре
    type_id = setup_node_type_data['base_type_id']
    response = logged_in_client.delete(f'/api/v1/node_types/{type_id}')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 204, "Ожидался статус 204 No Content"

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT 1 FROM node_types WHERE id = %s", (type_id,))
    assert cursor.fetchone() is None, "Тип узла все еще в БД после DELETE"
    cursor.close()

def test_delete_node_type_not_found(logged_in_client):
    """Тест: Ошибка 404 при удалении несуществующего типа."""
    log.info("\nТест: DELETE /api/v1/node_types/{id} - 404 Not Found")
    type_id = 999993
    response = logged_in_client.delete(f'/api/v1/node_types/{type_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'not found' in error_data['error']['message']

def test_delete_node_type_base_type_zero(logged_in_client):
    """Тест: Ошибка при попытке удаления базового типа ID=0."""
    log.info("\nТест: DELETE /api/v1/node_types/0 - Ошибка (нельзя удалить ID=0)")
    response = logged_in_client.delete('/api/v1/node_types/0')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 409, "Ожидался статус 409 Conflict (или 422)"
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Нельзя удалить базовый тип' in error_data['error']['message']

def test_delete_node_type_has_children(logged_in_client, setup_node_type_data):
    """Тест: Ошибка при попытке удаления типа с дочерними типами."""
    log.info("\nТест: DELETE /api/v1/node_types/{id} - Ошибка (есть дочерние)")
    parent_id = setup_node_type_data['base_type_id']
    # Создаем дочерний тип
    child_name = f"Child Type For Delete Test {secrets.token_hex(3)}"
    create_resp = logged_in_client.post('/api/v1/node_types', json={"name": child_name, "parent_type_id": parent_id})
    assert create_resp.status_code == 201, "Не удалось создать дочерний тип"

    # Пытаемся удалить родителя
    response = logged_in_client.delete(f'/api/v1/node_types/{parent_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 409, "Ожидался статус 409 Conflict (или 422)"
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'существуют дочерние типы' in error_data['error']['message']

# TODO: Добавить тест test_delete_node_type_has_nodes (требует создания узла и подразделения)
# def test_delete_node_type_has_nodes(logged_in_client, db_conn, setup_nodes_data):
#     log.info("\nТест: DELETE /api/v1/node_types/{id} - Ошибка (назначен узлам)")
#     type_id_to_use = setup_nodes_data['base_type_id']
#     # 1. Нужна фикстура, создающая subdivision и node, использующий type_id_to_use
#     # ... (код создания узла) ...
#     # node_id = ...
#
#     # 2. Пытаемся удалить тип
#     response = logged_in_client.delete(f'/api/v1/node_types/{type_id_to_use}')
#     log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
#     assert response.status_code == 409 # Или 422
#     error_data = response.get_json(); assert error_data and 'error' in error_data
#     assert 'назначен узлам' in error_data['error']['message']