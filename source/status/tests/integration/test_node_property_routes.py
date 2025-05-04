# status/tests/integration/test_node_property_routes.py
"""
Интеграционные тесты для API эндпоинтов управления Свойствами Типов Узлов
(/api/v1/node_property_types и /api/v1/node_types/<id>/properties).
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

# --- Фикстура для создания базовых данных (тип узла и типы свойств) ---
@pytest.fixture(scope='function') # function scope для изоляции
def setup_node_properties_data(logged_in_client, db_conn):
    """Создает тип узла и несколько типов свойств для тестов."""
    log.debug("\n[Setup Node Props] Создание данных для тестов свойств...")
    created_data = {}
    cursor = db_conn.cursor()
    try:
        # 1. Создаем Тип Узла
        type_name = f"Prop Test Type {secrets.token_hex(3)}"
        cursor.execute(
            "INSERT INTO node_types (name, priority) VALUES (%s, 50) RETURNING id",
            (type_name,)
        )
        type_id = cursor.fetchone()['id']
        created_data['node_type_id'] = type_id
        log.debug(f"[Setup Node Props] Создан тип узла ID={type_id}")

        # 2. Создаем Типы Свойств (если их нет, но они должны быть из core_data)
        # Проверяем наличие 'timeout_minutes' и 'icon_color'
        prop_types_to_ensure = [
            {'name': 'timeout_minutes', 'description': 'Timeout Test'},
            {'name': 'icon_color', 'description': 'Icon Color Test'},
            {'name': 'custom_prop_test', 'description': 'Custom Prop for Test'}
        ]
        created_data['property_types'] = {}

        for pt_data in prop_types_to_ensure:
            cursor.execute(
                """
                INSERT INTO node_property_types (name, description) VALUES (%s, %s)
                ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description
                RETURNING id, name;
                """,
                (pt_data['name'], pt_data['description'])
            )
            result = cursor.fetchone()
            # Если ON CONFLICT сработал, и RETURNING пуст (для PG < 15), получаем ID
            if not result:
                 cursor.execute("SELECT id, name FROM node_property_types WHERE name = %s", (pt_data['name'],))
                 result = cursor.fetchone()
            if result:
                 created_data['property_types'][result['name']] = result['id']
                 log.debug(f"[Setup Node Props] Тип свойства '{result['name']}' ID={result['id']} создан/найден.")
            else:
                 log.error(f"[Setup Node Props] Не удалось создать/найти тип свойства '{pt_data['name']}'!")

        # Убедимся, что основные типы свойств созданы
        assert 'timeout_minutes' in created_data['property_types']
        assert 'icon_color' in created_data['property_types']
        assert 'custom_prop_test' in created_data['property_types']

        yield created_data

    except Exception as e:
        log.error(f"ОШИБКА в фикстуре setup_node_properties_data: {e}", exc_info=True)
        pytest.fail(f"Не удалось настроить данные для тестов свойств: {e}")

    # Очистка не нужна, db_conn откатит транзакцию

# --- Тесты для /api/v1/node_property_types ---

def test_get_node_property_types_success(logged_in_client):
    """Тест: Успешное получение списка всех типов свойств."""
    log.info("\nТест: GET /api/v1/node_property_types - Успех")
    response = logged_in_client.get('/api/v1/node_property_types')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200, "Ожидался статус 200 OK"
    data = response.get_json()
    assert isinstance(data, list), "Ответ должен быть списком"
    # Проверяем наличие базовых типов свойств (из core_data или фикстуры)
    assert any(pt['name'] == 'timeout_minutes' for pt in data), "Тип свойства 'timeout_minutes' не найден"
    assert any(pt['name'] == 'icon_color' for pt in data), "Тип свойства 'icon_color' не найден"
    assert any(pt['name'] == 'display_order' for pt in data), "Тип свойства 'display_order' не найден"

# --- Тесты для /api/v1/node_types/<type_id>/properties ---

def test_get_node_type_properties_success(logged_in_client, db_conn, setup_node_properties_data):
    """Тест: Успешное получение свойств для существующего типа узла (с предустановленным свойством)."""
    log.info("\nТест: GET /api/v1/node_types/{id}/properties - Успех")
    type_id = setup_node_properties_data['node_type_id']
    prop_type_id = setup_node_properties_data['property_types']['timeout_minutes']
    test_value = "15"

    # Установим одно свойство напрямую в БД для теста GET
    cursor = db_conn.cursor()
    cursor.execute(
        "INSERT INTO node_properties (node_type_id, property_type_id, property_value) VALUES (%s, %s, %s)",
        (type_id, prop_type_id, test_value)
    )

    response = logged_in_client.get(f'/api/v1/node_types/{type_id}/properties')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 200
    data = response.get_json()
    assert isinstance(data, list), "Ответ должен быть списком"
    assert len(data) >= 1, "Ожидалось как минимум одно свойство"
    found_prop = next((p for p in data if p['property_type_id'] == prop_type_id), None)
    assert found_prop is not None, "Предустановленное свойство не найдено в ответе"
    assert found_prop['property_name'] == 'timeout_minutes'
    assert found_prop['property_value'] == test_value
    cursor.close()

def test_get_node_type_properties_empty(logged_in_client, setup_node_properties_data):
    """Тест: Успешное получение пустого списка свойств для типа без свойств."""
    log.info("\nТест: GET /api/v1/node_types/{id}/properties - Успех (пустой)")
    type_id = setup_node_properties_data['node_type_id']
    # Не устанавливаем свойства для этого типа

    response = logged_in_client.get(f'/api/v1/node_types/{type_id}/properties')
    assert response.status_code == 200
    data = response.get_json()
    assert isinstance(data, list) and len(data) == 0, "Ожидался пустой список свойств"

def test_get_node_type_properties_not_found(logged_in_client):
    """Тест: Ошибка 404 при запросе свойств для несуществующего типа узла."""
    log.info("\nТест: GET /api/v1/node_types/{id}/properties - 404 Not Found (тип узла)")
    invalid_type_id = 999991
    response = logged_in_client.get(f'/api/v1/node_types/{invalid_type_id}/properties')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Node type' in error_data['error']['message']
    assert 'not found' in error_data['error']['message']

def test_set_node_type_properties_success(logged_in_client, db_conn, setup_node_properties_data):
    """Тест: Успешная установка/обновление свойств для типа узла."""
    log.info("\nТест: PUT /api/v1/node_types/{id}/properties - Успех")
    type_id = setup_node_properties_data['node_type_id']
    timeout_prop_id = setup_node_properties_data['property_types']['timeout_minutes']
    color_prop_id = setup_node_properties_data['property_types']['icon_color']
    custom_prop_id = setup_node_properties_data['property_types']['custom_prop_test']

    properties_to_set = {
        str(timeout_prop_id): "30",       # Обновляем timeout
        str(color_prop_id): "#FF0000",    # Устанавливаем цвет
        str(custom_prop_id): "CustomVal"  # Устанавливаем кастомное
        # str(another_prop_id): None # Пример удаления свойства
    }

    response = logged_in_client.put(f'/api/v1/node_types/{type_id}/properties', json=properties_to_set)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:300]}...")
    assert response.status_code == 200, "Ожидался статус 200 OK"
    updated_props_list = response.get_json()
    assert isinstance(updated_props_list, list), "Ответ должен быть списком"

    # Преобразуем список в словарь для удобства проверки
    updated_props_map = {p['property_type_id']: p['property_value'] for p in updated_props_list}

    assert updated_props_map.get(timeout_prop_id) == "30"
    assert updated_props_map.get(color_prop_id) == "#FF0000"
    assert updated_props_map.get(custom_prop_id) == "CustomVal"

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT property_type_id, property_value FROM node_properties WHERE node_type_id = %s", (type_id,))
    db_props_map = {row['property_type_id']: row['property_value'] for row in cursor.fetchall()}
    assert db_props_map.get(timeout_prop_id) == "30"
    assert db_props_map.get(color_prop_id) == "#FF0000"
    assert db_props_map.get(custom_prop_id) == "CustomVal"
    cursor.close()

def test_set_node_type_properties_delete(logged_in_client, db_conn, setup_node_properties_data):
    """Тест: Успешное удаление свойства через PUT с null."""
    log.info("\nТест: PUT /api/v1/node_types/{id}/properties - Успех (удаление)")
    type_id = setup_node_properties_data['node_type_id']
    prop_to_delete_id = setup_node_properties_data['property_types']['custom_prop_test']
    prop_to_keep_id = setup_node_properties_data['property_types']['icon_color']

    # Сначала установим оба свойства
    cursor = db_conn.cursor()
    cursor.execute("INSERT INTO node_properties (node_type_id, property_type_id, property_value) VALUES (%s, %s, %s), (%s, %s, %s)",
                   (type_id, prop_to_delete_id, 'ToDelete', type_id, prop_to_keep_id, '#ABCDEF'))

    # Теперь отправляем PUT запрос, удаляя одно свойство (value=None)
    properties_to_set = {
        str(prop_to_delete_id): None,
        str(prop_to_keep_id): "#123456" # Обновляем другое
    }
    response = logged_in_client.put(f'/api/v1/node_types/{type_id}/properties', json=properties_to_set)
    assert response.status_code == 200
    updated_props_list = response.get_json()
    updated_props_map = {p['property_type_id']: p['property_value'] for p in updated_props_list}

    assert prop_to_delete_id not in updated_props_map, "Удаленное свойство все еще присутствует"
    assert updated_props_map.get(prop_to_keep_id) == "#123456", "Оставшееся свойство не обновилось"

    # Проверка в БД
    cursor.execute("SELECT property_type_id FROM node_properties WHERE node_type_id = %s", (type_id,))
    db_prop_ids = {row['property_type_id'] for row in cursor.fetchall()}
    assert prop_to_delete_id not in db_prop_ids
    assert prop_to_keep_id in db_prop_ids
    cursor.close()


def test_set_node_type_properties_invalid_type_id(logged_in_client, setup_node_properties_data):
    """Тест: Ошибка при установке свойства для несуществующего типа свойства."""
    log.info("\nТест: PUT /api/v1/node_types/{id}/properties - Ошибка (неверный ID свойства)")
    type_id = setup_node_properties_data['node_type_id']
    invalid_prop_type_id = 999990
    properties_to_set = {str(invalid_prop_type_id): "some value"}

    response = logged_in_client.put(f'/api/v1/node_types/{type_id}/properties', json=properties_to_set)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 400 # Bad Request (т.к. ошибка в цикле)
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Errors occurred' in error_data['error']['message']
    assert str(invalid_prop_type_id) in error_data['error']['details']
    assert 'не найден' in error_data['error']['details'][str(invalid_prop_type_id)]

def test_delete_node_type_property_success(logged_in_client, db_conn, setup_node_properties_data):
    """Тест: Успешное удаление конкретного свойства."""
    log.info("\nТест: DELETE /api/v1/node_types/{id}/properties/{prop_id} - Успех")
    type_id = setup_node_properties_data['node_type_id']
    prop_id = setup_node_properties_data['property_types']['custom_prop_test']

    # Сначала добавим свойство
    cursor = db_conn.cursor()
    cursor.execute("INSERT INTO node_properties (node_type_id, property_type_id, property_value) VALUES (%s, %s, %s)", (type_id, prop_id, 'ValueToDelete'))

    # Удаляем через API
    response = logged_in_client.delete(f'/api/v1/node_types/{type_id}/properties/{prop_id}')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 204, "Ожидался статус 204 No Content"

    # Проверяем в БД
    cursor.execute("SELECT 1 FROM node_properties WHERE node_type_id = %s AND property_type_id = %s", (type_id, prop_id))
    assert cursor.fetchone() is None, "Свойство все еще существует в БД после DELETE"
    cursor.close()

def test_delete_node_type_property_not_found(logged_in_client, setup_node_properties_data):
    """Тест: Ошибка 404 при удалении несуществующего свойства у типа."""
    log.info("\nТест: DELETE /api/v1/node_types/{id}/properties/{prop_id} - 404 Not Found")
    type_id = setup_node_properties_data['node_type_id']
    non_existent_prop_id = 999989
    response = logged_in_client.delete(f'/api/v1/node_types/{type_id}/properties/{non_existent_prop_id}')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Property type' in error_data['error']['message']
    assert 'not found for node type' in error_data['error']['message']