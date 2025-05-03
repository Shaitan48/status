# status/tests/integration/test_misc_routes.py
import pytest

def test_health_check_ok(client, db_conn): # Используем фикстуру db_conn для проверки доступности БД
    """Тест: эндпоинт /health возвращает 200 OK, когда БД доступна."""
    # Простая проверка соединения через фикстуру
    try:
        cursor = db_conn.cursor()
        cursor.execute("SELECT 1;")
        cursor.fetchone()
        db_available = True
    except Exception:
        db_available = False
        pytest.skip("Пропуск теста, т.к. тестовая БД недоступна") # Пропускаем тест, если БД упала

    response = client.get('/health')

    assert response.status_code == 200
    json_data = response.get_json()
    assert json_data is not None
    assert json_data.get('status') == 'ok'
    assert json_data.get('database_connected') is True

# Опционально: Тест на случай недоступности БД (сложнее имитировать)
# def test_health_check_db_error(client):
#     """Тест: эндпоинт /health возвращает 503, когда БД недоступна."""
#     # Здесь нужно как-то имитировать недоступность БД
#     # Например, временно изменить DATABASE_URL на невалидный перед вызовом client.get()
#     # или использовать мокирование db_connection.get_connection
#     pass