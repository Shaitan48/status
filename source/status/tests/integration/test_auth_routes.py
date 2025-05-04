# status/tests/integration/test_auth_routes.py
"""
Интеграционные тесты для маршрутов аутентификации (/login, /logout).
"""
import pytest
import logging
from flask import session # Для проверки сессии

# Используем фикстуры из conftest.py
# client - тестовый клиент Flask
# runner - для CLI (здесь не нужен, т.к. пользователи создаются в сессионной фикстуре)
# app - экземпляр приложения
# db_conn - для возможных проверок пользователя (здесь не нужен)
# logged_in_client - НЕ ИСПОЛЬЗУЕМ ЗДЕСЬ, т.к. тестируем сам процесс логина/логаута

log = logging.getLogger(__name__)

# Имя пользователя и пароль, созданные в conftest.py фикстурой setup_session_users
TEST_USERNAME = 'key_admin'
TEST_PASSWORD = 'password'
WRONG_PASSWORD = 'wrongpassword'
WRONG_USERNAME = 'nonexistentuser'

# --- Тесты для /login ---

def test_login_page_get(client):
    """Тест: Успешная загрузка страницы входа (GET /login)."""
    log.info("\nТест: GET /login - Успешная загрузка страницы")
    response = client.get('/login')
    log.info(f"Ответ API: {response.status_code}")
    assert response.status_code == 200, "Страница входа должна возвращать статус 200"
    response_text = response.get_data(as_text=True)
    assert '<form method="POST"' in response_text, "На странице должна быть форма входа"
    assert 'name="username"' in response_text, "На странице должно быть поле username"
    assert 'name="password"' in response_text, "На странице должно быть поле password"
    assert 'Войти</button>' in response_text, "На странице должна быть кнопка 'Войти'"

def test_login_success(client):
    """Тест: Успешный вход пользователя (POST /login)."""
    log.info("\nТест: POST /login - Успешный вход")
    # Выполняем POST запрос с правильными данными
    response = client.post('/login', data={
        'username': TEST_USERNAME,
        'password': TEST_PASSWORD
    }, follow_redirects=True) # follow_redirects=True чтобы перейти на дашборд

    log.info(f"Ответ API: {response.status_code}, URL: {response.request.path}")
    assert response.status_code == 200, "Ожидался статус 200 после успешного входа и редиректа"
    # Проверяем, что мы на дашборде (или другой странице после логина)
    # Путь '/' соответствует эндпоинту 'html.dashboard'
    assert response.request.path == '/', f"Ожидался редирект на '/', а не на {response.request.path}"
    response_text = response.get_data(as_text=True)
    assert f"Пользователь: {TEST_USERNAME}" in response_text, "Имя пользователя не отображается после входа"
    assert 'Выход</a>' in response_text, "Ссылка 'Выход' не найдена после входа"

    # Проверяем сессию
    with client.session_transaction() as sess:
        assert '_user_id' in sess, "ID пользователя не найден в сессии после успешного входа"


def test_login_wrong_password(client):
    """Тест: Ошибка входа - неверный пароль."""
    log.info("\nТест: POST /login - Неверный пароль")
    response = client.post('/login', data={
        'username': TEST_USERNAME,
        'password': WRONG_PASSWORD
    }, follow_redirects=True) # Редиректа не будет, останемся на /login

    log.info(f"Ответ API: {response.status_code}, URL: {response.request.path}")
    assert response.status_code == 200, "Ожидался статус 200 (перерисовка страницы входа)"
    # <<< ПРОВЕРКА ОСТАЕТСЯ ПРЕЖНЕЙ, т.к. редиректа быть не должно >>>
    assert response.request.path == '/login', "Должны были остаться на странице /login"
    response_text = response.get_data(as_text=True)
    
    # Проверяем, что пользователь НЕ залогинен
    assert 'Неверное имя пользователя или пароль.' in response_text, "Сообщение об ошибке не найдено"
    with client.session_transaction() as sess:
        assert '_user_id' not in sess, "ID пользователя не должен быть в сессии при неверном пароле"


def test_login_wrong_username(client):
    """Тест: Ошибка входа - неверное имя пользователя."""
    log.info("\nТест: POST /login - Неверное имя пользователя")
    response = client.post('/login', data={
        'username': WRONG_USERNAME,
        'password': TEST_PASSWORD
    }, follow_redirects=True)

    log.info(f"Ответ API: {response.status_code}, URL: {response.request.path}")
    assert response.status_code == 200, "Ожидался статус 200"
    # <<< ПРОВЕРКА ОСТАЕТСЯ ПРЕЖНЕЙ >>>
    assert response.request.path == '/login', "Должны были остаться на /login"
    response_text = response.get_data(as_text=True)
    assert 'Неверное имя пользователя или пароль.' in response_text, "Сообщение об ошибке не найдено"
    with client.session_transaction() as sess:
        assert '_user_id' not in sess, "ID пользователя не должен быть в сессии при неверном имени"

def test_login_missing_fields(client):
    """Тест: Ошибка входа - отсутствуют поля."""
    log.info("\nТест: POST /login - Отсутствуют поля")

    # Нет пароля
    response1 = client.post('/login', data={'username': TEST_USERNAME}, follow_redirects=True)
    assert response1.status_code == 200 and response1.request.path == '/login'
    assert 'Требуется имя пользователя и пароль' in response1.get_data(as_text=True)
    with client.session_transaction() as sess: assert '_user_id' not in sess

    # Нет имени пользователя
    response2 = client.post('/login', data={'password': TEST_PASSWORD}, follow_redirects=True)
    assert response2.status_code == 200 and response2.request.path == '/login'
    assert 'Требуется имя пользователя и пароль' in response2.get_data(as_text=True)
    with client.session_transaction() as sess: assert '_user_id' not in sess

    # Пустые поля
    response3 = client.post('/login', data={'username': '', 'password': ''}, follow_redirects=True)
    assert response3.status_code == 200 and response3.request.path == '/login'
    assert 'Требуется имя пользователя и пароль' in response3.get_data(as_text=True)
    with client.session_transaction() as sess: assert '_user_id' not in sess

def test_login_when_already_logged_in(logged_in_client): # client не нужен, используем logged_in_client
    """Тест: Попытка доступа к /login, когда пользователь уже вошел."""
    log.info("\nТест: Доступ к /login после входа")
    client = logged_in_client # Используем переданный залогиненный клиент
    # Сессия уже есть
    with client.session_transaction() as sess: assert '_user_id' in sess

    # Пытаемся зайти на /login через GET
    get_resp = client.get('/login', follow_redirects=True)
    assert get_resp.status_code == 200, "GET /login после входа не вернул 200"
    assert get_resp.request.path == '/', "GET /login после входа не редиректнул на дашборд"

    # Пытаемся залогиниться снова через POST
    post_resp = client.post('/login', data={'username': TEST_USERNAME, 'password': TEST_PASSWORD}, follow_redirects=True)
    assert post_resp.status_code == 200, "POST /login после входа не вернул 200"
    assert post_resp.request.path == '/', "POST /login после входа не редиректнул на дашборд"

# --- Тесты для /logout ---

def test_logout_success(logged_in_client): # client не нужен
    """Тест: Успешный выход пользователя."""
    log.info("\nТест: GET /logout - Успешный выход")
    client = logged_in_client # Используем переданный залогиненный клиент
    # Сессия уже есть
    with client.session_transaction() as sess: assert '_user_id' in sess

    # Выполняем выход
    response = client.get('/logout', follow_redirects=True)
    log.info(f"Ответ API: {response.status_code}, URL: {response.request.path}")
    assert response.status_code == 200, "Ожидался статус 200 после выхода и редиректа"
    assert response.request.path == '/login', "Ожидался редирект на /login после выхода"
    response_text = response.get_data(as_text=True)
    assert 'Вы успешно вышли.' in response_text, "Сообщение об успешном выходе не найдено"

    # Проверяем, что сессия пуста
    with client.session_transaction() as sess:
        assert '_user_id' not in sess, "ID пользователя все еще в сессии после выхода"

def test_logout_when_not_logged_in(client): # Используем чистый клиент
    """Тест: Попытка выхода, когда пользователь не вошел."""
    log.info("\nТест: GET /logout - Когда не залогинен")
    response = client.get('/logout', follow_redirects=False) # Не следуем редиректу
    log.info(f"Ответ API: {response.status_code}, Location: {response.location}")
    assert response.status_code == 302, "Ожидался редирект (302) при выходе без логина"
    # <<< ИЗМЕНЕНА ПРОВЕРКА LOCATION >>>
    assert response.location.startswith('/login'), "Ожидался редирект на /login (возможно, с параметром next)"
    # <<< КОНЕЦ ИЗМЕНЕНИЯ >>>

    with client.session_transaction() as sess:
        assert '_user_id' not in sess