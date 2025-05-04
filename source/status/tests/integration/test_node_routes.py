# status/tests/integration/test_node_routes.py
"""
Интеграционные тесты для API эндпоинтов управления Узлами (/api/v1/nodes).
"""
import pytest
import json
import logging
import secrets # Для генерации уникальных имен

# <<< ИЗМЕНЕНО: Импорт db_connection для фикстуры модуля >>>
from flask import g
from app import db_connection

# <<< ИЗМЕНЕНО: Импорт create_test_user_cli напрямую из conftest не нужен,
#              т.к. setup_session_users использует его и выполняется автоматически.
#              logged_in_client будет взят из conftest.py >>>
# from ..conftest import create_test_user_cli # Не нужно импортировать здесь

log = logging.getLogger(__name__)

# --- Фикстура для настройки данных, специфичных для тестов узлов ---
@pytest.fixture(scope='module')
def setup_nodes_data(app): # Используем 'app' для получения контекста
    """
    Создает необходимые данные (подразделение, тип узла) один раз
    перед всеми тестами в этом модуле. Очищает их после.
    """
    log.info("\n--- Настройка данных для тестов УЗЛОВ (scope=module) ---")
    # Уникальные ID и имена для тестовых данных
    test_sub_object_id = 9010
    test_sub_short_name = "NodeTest Sub"
    test_node_type_name = "NodeTest Type"
    sub_id = None
    type_id = None
    created_ids = {} # Для хранения созданных ID

    # Получаем соединение внутри контекста приложения
    with app.app_context():
        conn_setup = None
        try:
            conn_setup = db_connection.get_connection()
            conn_setup.autocommit = True # Включаем автокоммит для setup/teardown
            cursor = conn_setup.cursor()

            # 1. Очистка (на случай падения предыдущих тестов)
            log.debug("[Setup Nodes] Очистка старых тестовых данных...")
            # Используем параметры для безопасности и читаемости
            cursor.execute("DELETE FROM nodes WHERE name LIKE %s OR name LIKE %s", (f'{test_sub_short_name}%', 'API Node%'))
            cursor.execute("DELETE FROM subdivisions WHERE object_id = %s", (test_sub_object_id,))
            cursor.execute("DELETE FROM node_types WHERE name = %s", (test_node_type_name,))
            log.debug("[Setup Nodes] Очистка завершена.")

            # 2. Создание Подразделения
            cursor.execute(
                """
                INSERT INTO subdivisions (object_id, short_name, priority)
                VALUES (%s, %s, 999)
                ON CONFLICT (object_id) DO UPDATE SET short_name = EXCLUDED.short_name
                RETURNING id;
                """,
                (test_sub_object_id, test_sub_short_name)
            )
            result_sub = cursor.fetchone()
            if not result_sub: # Обработка ON CONFLICT DO UPDATE для PG < 15
                 cursor.execute("SELECT id FROM subdivisions WHERE object_id = %s", (test_sub_object_id,))
                 result_sub = cursor.fetchone()
            if not result_sub: raise Exception(f"Не удалось создать/найти подразделение {test_sub_object_id}")
            sub_id = result_sub['id']
            created_ids['subdivision_id'] = sub_id
            log.info(f"[Setup Nodes] Тестовое подразделение ID={sub_id} создано/найдено.")

            # 3. Создание Типа Узла
            cursor.execute(
                """
                INSERT INTO node_types (name, priority)
                VALUES (%s, 999)
                ON CONFLICT (name, parent_type_id) WHERE parent_type_id IS NULL DO UPDATE SET priority=EXCLUDED.priority
                RETURNING id;
                """,
                (test_node_type_name,)
            )
            result_type = cursor.fetchone()
            if not result_type: # Обработка ON CONFLICT
                 cursor.execute("SELECT id FROM node_types WHERE name = %s AND parent_type_id IS NULL", (test_node_type_name,))
                 result_type = cursor.fetchone()
            if not result_type: raise Exception(f"Не удалось создать/найти тип узла '{test_node_type_name}'")
            type_id = result_type['id']
            created_ids['node_type_id'] = type_id
            log.info(f"[Setup Nodes] Тестовый тип узла ID={type_id} создан/найден.")

            # 4. Передаем созданные ID в тесты
            yield created_ids

        except Exception as e:
            log.error(f"ОШИБКА в фикстуре setup_nodes_data: {e}", exc_info=True)
            pytest.fail(f"Не удалось настроить данные для тестов узлов: {e}")
        finally:
            # 5. Очистка после выполнения ВСЕХ тестов в этом файле
            log.info("\n--- Очистка данных после тестов УЗЛОВ (scope=module) ---")
            if conn_setup: # Проверяем, было ли соединение создано
                try:
                    # Используем ID, сохраненные при создании
                    final_sub_id = created_ids.get('subdivision_id')
                    final_type_id = created_ids.get('node_type_id')
                    cursor = conn_setup.cursor() # Новый курсор для очистки
                    if final_sub_id is not None:
                        # Сначала удаляем узлы, потом подразделение
                        cursor.execute("DELETE FROM nodes WHERE parent_subdivision_id = %s", (final_sub_id,))
                        log.debug(f"[Teardown Nodes] Узлы в подразделении {final_sub_id} удалены.")
                        cursor.execute("DELETE FROM subdivisions WHERE id = %s", (final_sub_id,))
                        log.info(f"[Teardown Nodes] Подразделение {final_sub_id} удалено.")
                    if final_type_id is not None:
                        # Сначала удаляем свойства, связанные с типом (если они есть)
                        cursor.execute("DELETE FROM node_properties WHERE node_type_id = %s", (final_type_id,))
                        # Затем сам тип
                        cursor.execute("DELETE FROM node_types WHERE id = %s", (final_type_id,))
                        log.info(f"[Teardown Nodes] Тип узла {final_type_id} и его свойства удалены.")
                    cursor.close()
                except Exception as e:
                    log.error(f"Ошибка при очистке данных после тестов узлов: {e}", exc_info=True)
                # Соединение вернется в пул при выходе из `with app.app_context()`
            log.info("--- Очистка данных завершена ---")

# <<< Убрана фикстура logged_in_client, теперь она общая в conftest.py >>>

# --- Тесты CRUD для Узлов ---

# Используем общую фикстуру logged_in_client из conftest.py
def test_create_node_success(logged_in_client, db_conn, setup_nodes_data):
    """Тест: Успешное создание узла через API."""
    log.info("\nТест: POST /api/v1/nodes - Успех")
    parent_sub_id = setup_nodes_data['subdivision_id']
    node_type_id = setup_nodes_data['node_type_id']
    node_name = f"API Node Success {secrets.token_hex(4)}" # Уникальное имя
    node_data = {
        "name": node_name,
        "parent_subdivision_id": parent_sub_id,
        "ip_address": "10.2.2.2",
        "node_type_id": node_type_id,
        "description": "API Created Node - Success"
    }

    response = logged_in_client.post('/api/v1/nodes', json=node_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")

    assert response.status_code == 201, "Ожидался статус 201 Created"
    created_node = response.get_json()
    assert created_node and 'id' in created_node, "Ответ не содержит JSON с ID созданного узла"
    # Проверка полей в ответе
    assert created_node['name'] == node_name
    assert created_node['subdivision_id'] == parent_sub_id # Поле в ответе называется subdivision_id
    assert created_node['ip_address'] == node_data['ip_address']
    assert created_node['node_type_id'] == node_type_id
    assert created_node['description'] == node_data['description']
    # Проверка данных, приходящих через JOIN'ы
    assert created_node.get('node_type_name') == "NodeTest Type", "Имя типа узла не совпадает"
    assert created_node.get('subdivision_short_name') == "NodeTest Sub", "Имя подразделения не совпадает"

    # Дополнительная проверка в БД (в рамках транзакции теста)
    cursor = db_conn.cursor()
    cursor.execute("SELECT name, ip_address, parent_subdivision_id, node_type_id, description FROM nodes WHERE id = %s", (created_node['id'],))
    db_node = cursor.fetchone()
    assert db_node is not None, "Узел не найден в БД после создания"
    assert db_node['name'] == node_name
    assert db_node['ip_address'] == node_data['ip_address']
    assert db_node['parent_subdivision_id'] == parent_sub_id
    assert db_node['node_type_id'] == node_type_id
    assert db_node['description'] == node_data['description']
    cursor.close()

def test_create_node_missing_name(logged_in_client, setup_nodes_data):
    """Тест: Ошибка создания узла (отсутствует обязательное поле 'name')."""
    log.info("\nТест: POST /api/v1/nodes - Ошибка (нет имени)")
    parent_sub_id = setup_nodes_data['subdivision_id']
    node_data = {"parent_subdivision_id": parent_sub_id, "ip_address": "10.2.2.3"} # Нет 'name'

    response = logged_in_client.post('/api/v1/nodes', json=node_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 422, "Ожидался статус 422 Validation Failure"
    error_data = response.get_json()
    assert error_data and 'error' in error_data, "Ответ не содержит структуру ошибки JSON"
    assert error_data['error']['code'] == 'VALIDATION_FAILURE'
    assert 'Отсутствуют обязательные поля' in error_data['error']['message']
    assert 'name' in error_data['error']['message']

def test_create_node_missing_parent(logged_in_client):
    """Тест: Ошибка создания узла (отсутствует обязательное поле 'parent_subdivision_id')."""
    log.info("\nТест: POST /api/v1/nodes - Ошибка (нет родителя)")
    node_data = {"name": "API Node No Parent", "ip_address": "10.2.2.4"} # Нет 'parent_subdivision_id'

    response = logged_in_client.post('/api/v1/nodes', json=node_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 422, "Ожидался статус 422 Validation Failure"
    error_data = response.get_json()
    assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'VALIDATION_FAILURE'
    assert 'Отсутствуют обязательные поля' in error_data['error']['message']
    assert 'parent_subdivision_id' in error_data['error']['message']

def test_create_node_invalid_parent_id(logged_in_client):
    """Тест: Ошибка создания узла (передан несуществующий 'parent_subdivision_id')."""
    log.info("\nТест: POST /api/v1/nodes - Ошибка (неверный ID родителя)")
    invalid_parent_id = 999999 # ID, которого точно нет
    node_data = {"name": "API Node Invalid Parent", "parent_subdivision_id": invalid_parent_id}

    response = logged_in_client.post('/api/v1/nodes', json=node_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")

    assert response.status_code == 422, "Ожидался статус 422 Validation Failure"
    error_data = response.get_json()
    assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'VALIDATION_FAILURE'
    assert 'Родительское подразделение' in error_data['error']['message']
    assert str(invalid_parent_id) in error_data['error']['message']

def test_create_node_duplicate_name(logged_in_client, db_conn, setup_nodes_data):
    """Тест: Ошибка создания узла (дубликат имени в том же подразделении)."""
    log.info("\nТест: POST /api/v1/nodes - Ошибка (дубликат имени)")
    parent_sub_id = setup_nodes_data['subdivision_id']
    node_name = f"API Node Duplicate {secrets.token_hex(3)}"

    # Создаем первый узел успешно
    node_data1 = {"name": node_name, "parent_subdivision_id": parent_sub_id}
    response1 = logged_in_client.post('/api/v1/nodes', json=node_data1)
    assert response1.status_code == 201, "Первый узел для теста на дубликат не создался"

    # Пытаемся создать второй с тем же именем и родителем
    node_data2 = {"name": node_name, "parent_subdivision_id": parent_sub_id, "ip_address": "1.1.1.1"}
    response2 = logged_in_client.post('/api/v1/nodes', json=node_data2)
    log.info(f"Ответ API (дубликат): {response2.status_code}, Тело: {response2.get_data(as_text=True)}")

    assert response2.status_code == 409, "Ожидался статус 409 Conflict"
    error_data = response2.get_json()
    assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'CONFLICT'
    assert 'уже существует' in error_data['error']['message']

# --- Тесты для GET ---

def test_get_node_list_success(logged_in_client, setup_nodes_data):
     """Тест: Успешное получение списка узлов (без фильтров, базовая проверка)."""
     log.info("\nТест: GET /api/v1/nodes - Успех")
     response = logged_in_client.get('/api/v1/nodes')
     log.info(f"Ответ API: {response.status_code}")
     assert response.status_code == 200, "Ожидался статус 200 OK"
     data = response.get_json()
     assert data is not None, "Ответ не содержит JSON"
     assert 'items' in data and isinstance(data['items'], list), "Ответ не содержит массив 'items'"
     assert 'total_count' in data and isinstance(data['total_count'], int), "Ответ не содержит 'total_count'"
     # Можно добавить проверку, что созданный в setup узел присутствует, если нет пагинации по умолчанию
     # assert any(item['name'].startswith("API Node") for item in data['items'])

def test_get_node_detail_success(logged_in_client, db_conn, setup_nodes_data):
     """Тест: Успешное получение деталей существующего узла по ID."""
     log.info("\nТест: GET /api/v1/nodes/{id} - Успех")
     # Сначала создадим узел, чтобы получить его ID
     parent_sub_id = setup_nodes_data['subdivision_id']
     node_name = f"API Node Detail Get {secrets.token_hex(3)}"
     create_resp = logged_in_client.post('/api/v1/nodes', json={"name": node_name, "parent_subdivision_id": parent_sub_id})
     assert create_resp.status_code == 201, "Не удалось создать узел для GET-теста"
     node_id = create_resp.get_json()['id']

     # Теперь запрашиваем детали
     response = logged_in_client.get(f'/api/v1/nodes/{node_id}')
     log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
     assert response.status_code == 200, "Ожидался статус 200 OK"
     data = response.get_json()
     assert data is not None, "Ответ не содержит JSON"
     assert data['id'] == node_id
     assert data['name'] == node_name
     assert data['subdivision_id'] == parent_sub_id

def test_get_node_detail_not_found(logged_in_client):
     """Тест: Ошибка 404 при запросе деталей несуществующего узла."""
     log.info("\nТест: GET /api/v1/nodes/{id} - 404 Not Found")
     node_id = 999999 # Несуществующий ID
     response = logged_in_client.get(f'/api/v1/nodes/{node_id}')
     log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
     assert response.status_code == 404, "Ожидался статус 404 Not Found"
     error_data = response.get_json()
     assert error_data and 'error' in error_data
     assert error_data['error']['code'] == 'NOT_FOUND'
     assert 'не найден' in error_data['error']['message']

# --- Тесты для PUT ---

def test_update_node_success(logged_in_client, db_conn, setup_nodes_data):
    """Тест: Успешное обновление существующего узла."""
    log.info("\nТест: PUT /api/v1/nodes/{id} - Успех")
    # 1. Создаем узел
    parent_sub_id = setup_nodes_data['subdivision_id']
    node_type_id = setup_nodes_data['node_type_id']
    node_name_orig = f"API Node Update Orig {secrets.token_hex(3)}"
    create_resp = logged_in_client.post('/api/v1/nodes', json={"name": node_name_orig, "parent_subdivision_id": parent_sub_id})
    assert create_resp.status_code == 201, "Не удалось создать узел для PUT-теста"
    node_id = create_resp.get_json()['id']

    # 2. Обновляем узел
    updated_name = f"API Node Updated Name {secrets.token_hex(3)}"
    updated_ip = "10.99.99.99"
    updated_desc = "Updated Description"
    # Обновляем все возможные поля
    update_data = {
        "name": updated_name,
        "ip_address": updated_ip,
        "description": updated_desc,
        "node_type_id": node_type_id # Оставляем тот же тип
        # parent_subdivision_id не меняем в этом тесте
    }
    response = logged_in_client.put(f'/api/v1/nodes/{node_id}', json=update_data)
    log.info(f"Ответ API (Update): {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 200, "Ожидался статус 200 OK"
    updated_node = response.get_json()
    assert updated_node is not None, "Ответ не содержит JSON"
    assert updated_node['id'] == node_id
    assert updated_node['name'] == updated_name
    assert updated_node['ip_address'] == updated_ip
    assert updated_node['description'] == updated_desc
    assert updated_node['node_type_id'] == node_type_id
    assert updated_node['subdivision_id'] == parent_sub_id # Родитель не менялся

    # 3. Проверяем в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT name, ip_address, description, node_type_id FROM nodes WHERE id = %s", (node_id,))
    db_node = cursor.fetchone()
    assert db_node is not None, "Обновленный узел не найден в БД"
    assert db_node['name'] == updated_name
    assert db_node['ip_address'] == updated_ip
    assert db_node['description'] == updated_desc
    assert db_node['node_type_id'] == node_type_id
    cursor.close()

def test_update_node_not_found(logged_in_client):
    """Тест: Ошибка 404 при попытке обновления несуществующего узла."""
    log.info("\nТест: PUT /api/v1/nodes/{id} - 404 Not Found")
    node_id = 999998 # Несуществующий ID
    update_data = {"name": "Trying to update non-existent"}
    response = logged_in_client.put(f'/api/v1/nodes/{node_id}', json=update_data)
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404, "Ожидался статус 404 Not Found"
    error_data = response.get_json()
    assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'NOT_FOUND'
    assert 'не найден для обновления' in error_data['error']['message']

# --- Тесты для DELETE ---

def test_delete_node_success(logged_in_client, db_conn, setup_nodes_data):
     """Тест: Успешное удаление существующего узла."""
     log.info("\nТест: DELETE /api/v1/nodes/{id} - Успех")
     # 1. Создаем узел
     parent_sub_id = setup_nodes_data['subdivision_id']
     node_name_del = f"API Node To Delete {secrets.token_hex(3)}"
     create_resp = logged_in_client.post('/api/v1/nodes', json={"name": node_name_del, "parent_subdivision_id": parent_sub_id})
     assert create_resp.status_code == 201, "Не удалось создать узел для DELETE-теста"
     node_id = create_resp.get_json()['id']

     # 2. Удаляем узел
     response = logged_in_client.delete(f'/api/v1/nodes/{node_id}')
     log.info(f"Ответ API (Delete): {response.status_code}")
     assert response.status_code == 204, "Ожидался статус 204 No Content"

     # 3. Проверяем в БД, что узел удален
     cursor = db_conn.cursor()
     cursor.execute("SELECT 1 FROM nodes WHERE id = %s", (node_id,))
     db_node = cursor.fetchone()
     assert db_node is None, "Узел все еще существует в БД после DELETE"
     cursor.close()

def test_delete_node_not_found(logged_in_client):
     """Тест: Ошибка 404 при попытке удаления несуществующего узла."""
     log.info("\nТест: DELETE /api/v1/nodes/{id} - 404 Not Found")
     node_id = 999997 # Несуществующий ID
     response = logged_in_client.delete(f'/api/v1/nodes/{node_id}')
     log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
     assert response.status_code == 404, "Ожидался статус 404 Not Found"
     error_data = response.get_json()
     assert error_data and 'error' in error_data
     assert error_data['error']['code'] == 'NOT_FOUND'
     assert 'не найден' in error_data['error']['message']

# --- Тест для GET /nodes/{id}/assignments_status ---

def test_get_node_assignments_status_success(logged_in_client, db_conn, setup_nodes_data):
    """Тест: Успешное получение статуса заданий для узла (ожидаем пустой список)."""
    log.info("\nТест: GET /nodes/{id}/assignments_status - Успех (пустой список)")
    # 1. Создаем узел
    parent_sub_id = setup_nodes_data['subdivision_id']
    node_name = f"API Node Assignments {secrets.token_hex(3)}"
    create_resp = logged_in_client.post('/api/v1/nodes', json={"name": node_name, "parent_subdivision_id": parent_sub_id})
    assert create_resp.status_code == 201, "Не удалось создать узел для теста assignments_status"
    node_id = create_resp.get_json()['id']

    # 2. Запрашиваем статус заданий (ожидаем пустой список, т.к. задания не создавали)
    response = logged_in_client.get(f'/api/v1/nodes/{node_id}/assignments_status')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")
    assert response.status_code == 200, "Ожидался статус 200 OK"
    data = response.get_json()
    assert isinstance(data, list), "Ответ должен быть массивом"
    assert len(data) == 0, "Ожидался пустой массив заданий"

def test_get_node_assignments_status_not_found(logged_in_client):
    """Тест: Ошибка 404 при запросе статуса заданий для несуществующего узла."""
    log.info("\nТест: GET /nodes/{id}/assignments_status - 404 Not Found")
    node_id = 999996 # Несуществующий ID
    response = logged_in_client.get(f'/api/v1/nodes/{node_id}/assignments_status')
    log.info(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 404, "Ожидался статус 404 Not Found"
    error_data = response.get_json()
    assert error_data and 'error' in error_data
    assert error_data['error']['code'] == 'NOT_FOUND'
    assert 'не найден' in error_data['error']['message']