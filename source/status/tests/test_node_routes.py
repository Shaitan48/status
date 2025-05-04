# status/tests/integration/test_node_routes.py
import pytest
import json
import logging
from flask import g # Импортируем g для доступа к db_conn в фикстуре

# <<< ИЗМЕНЕНО: Импорт db_connection для получения соединения в фикстуре модуля >>>
from app import db_connection

# <<< ИЗМЕНЕНО: Импорт хелпера из conftest >>>
from ..conftest import create_test_user_cli # Импортируем хелпер из conftest
from .test_api_key_routes import login_test_user # Оставляем пока здесь

log = logging.getLogger(__name__)

# --- Фикстура для настройки данных, специфичных для тестов узлов ---
@pytest.fixture(scope='module')
# <<< ИЗМЕНЕНО: Убираем db_conn из аргументов, используем app >>>
def setup_nodes_data(app):
    """Создает необходимые данные (подразделение, тип узла) перед тестами узлов."""
    log.info("\n--- Настройка данных для тестов УЗЛОВ (scope=module) ---")
    test_sub_object_id = 9010
    test_sub_short_name = "NodeTest Sub"
    test_node_type_name = "NodeTest Type"
    sub_id = None
    type_id = None

    # <<< НАЧАЛО ИЗМЕНЕНИЙ: Получаем соединение через app_context >>>
    with app.app_context(): # Создаем контекст приложения
        conn_setup = None # Соединение для setup/teardown
        try:
            conn_setup = db_connection.get_connection() # Получаем соединение
            conn_setup.autocommit = True # Включаем автокоммит ДЛЯ ЭТОЙ фикстуры
            cursor = conn_setup.cursor()
            # <<< КОНЕЦ ИЗМЕНЕНИЙ >>>

            # 1. Очистка (на всякий случай)
            log.debug("[Setup Nodes] Очистка старых данных...")
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
            # ON CONFLICT DO UPDATE не возвращает ID в PostgreSQL < 15, если обновление произошло
            # Поэтому, если ID не вернулся, запросим его снова
            if not result_sub:
                 cursor.execute("SELECT id FROM subdivisions WHERE object_id = %s", (test_sub_object_id,))
                 result_sub = cursor.fetchone()
            if not result_sub: # Если и теперь нет - ошибка
                 raise Exception(f"Не удалось создать или найти подразделение с object_id {test_sub_object_id}")
            sub_id = result_sub['id']
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
            if not result_type: # Обработка ON CONFLICT для типа
                 cursor.execute("SELECT id FROM node_types WHERE name = %s AND parent_type_id IS NULL", (test_node_type_name,))
                 result_type = cursor.fetchone()
            if not result_type:
                 raise Exception(f"Не удалось создать или найти тип узла '{test_node_type_name}'")
            type_id = result_type['id']
            log.info(f"[Setup Nodes] Тестовый тип узла ID={type_id} создан/найден.")

            # 4. Передаем созданные ID в тесты через yield
            yield {'subdivision_id': sub_id, 'node_type_id': type_id}

        except Exception as e:
            log.error(f"ОШИБКА в фикстуре setup_nodes_data: {e}", exc_info=True)
            pytest.fail(f"Не удалось настроить данные для тестов узлов: {e}")
        finally:
            # 5. Очистка после выполнения ВСЕХ тестов в этом файле
            log.info("\n--- Очистка данных после тестов УЗЛОВ (scope=module) ---")
            if conn_setup: # Проверяем, что соединение было установлено
                try:
                    cursor = conn_setup.cursor()
                    # Удаляем созданные в этой фикстуре записи
                    # Используем sub_id и type_id, сохраненные ранее
                    if sub_id is not None:
                        cursor.execute("DELETE FROM nodes WHERE parent_subdivision_id = %s", (sub_id,))
                        log.debug(f"[Teardown Nodes] Узлы в подразделении {sub_id} удалены.")
                        cursor.execute("DELETE FROM subdivisions WHERE id = %s", (sub_id,))
                        log.info(f"[Teardown Nodes] Подразделение {sub_id} удалено.")
                    if type_id is not None:
                        cursor.execute("DELETE FROM node_types WHERE id = %s", (type_id,))
                        log.info(f"[Teardown Nodes] Тип узла {type_id} удален.")
                    cursor.close()
                except Exception as e:
                    log.error(f"Ошибка при очистке данных после тестов узлов: {e}", exc_info=True)
                # Возвращаем соединение в пул (вызовется автоматически при выходе из app_context)
            log.info("--- Очистка данных завершена ---")

@pytest.fixture(scope='module')
def logged_in_client(client, runner, setup_session_users):
     """Фикстура для получения залогиненного клиента."""
     # Используем пользователя 'key_admin', т.к. он уже создан для сессии
     login_test_user(client, username='key_admin')
     return client


def test_create_node_success(logged_in_client, db_conn, setup_module_data):
    """Тест: Успешное создание узла через API."""
    print("\nТест: POST /api/v1/nodes - Успех")
    parent_sub_id = setup_module_data['subdivision_id']
    node_type_id = setup_module_data['node_type_id']
    node_data = {
        "name": "Test API Node Create",
        "parent_subdivision_id": parent_sub_id,
        "ip_address": "10.1.1.1",
        "node_type_id": node_type_id,
        "description": "API Created Node"
    }
    response = logged_in_client.post('/api/v1/nodes', json=node_data)
    print(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)[:200]}...")

    assert response.status_code == 201
    created_node = response.get_json(); assert created_node and 'id' in created_node
    assert created_node['name'] == node_data['name']
    assert created_node['parent_subdivision_id'] == parent_sub_id
    assert created_node['ip_address'] == node_data['ip_address']
    assert created_node['node_type_id'] == node_type_id
    assert created_node['description'] == node_data['description']

    # Проверка в БД
    cursor = db_conn.cursor()
    cursor.execute("SELECT * FROM nodes WHERE id = %s", (created_node['id'],))
    db_node = cursor.fetchone()
    assert db_node is not None
    assert db_node['name'] == node_data['name']

def test_create_node_missing_fields(logged_in_client):
    """Тест: Ошибка создания узла (отсутствуют обязательные поля)."""
    print("\nТест: POST /api/v1/nodes - Ошибка (нет полей)")
    response = logged_in_client.post('/api/v1/nodes', json={})
    print(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 422 # Validation Failure
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Отсутствуют обязательные поля' in error_data['error']['message']

def test_create_node_invalid_parent(logged_in_client):
    """Тест: Ошибка создания узла (неверный ID родителя)."""
    print("\nТест: POST /api/v1/nodes - Ошибка (неверный родитель)")
    node_data = {"name": "Test Invalid Parent", "parent_subdivision_id": 99999}
    response = logged_in_client.post('/api/v1/nodes', json=node_data)
    print(f"Ответ API: {response.status_code}, Тело: {response.get_data(as_text=True)}")
    assert response.status_code == 422
    error_data = response.get_json(); assert error_data and 'error' in error_data
    assert 'Родительское подразделение' in error_data['error']['message']

# ... тесты для GET /nodes, GET /nodes/ID, PUT /nodes/ID, DELETE /nodes/ID ...
# ... тесты для GET /nodes/<id>/assignments_status ...