# status/app/routes/__init__.py
import logging
from flask import Flask

logger = logging.getLogger(__name__)

def init_routes(app: Flask):
    """
    Инициализирует и регистрирует все Blueprints (маршруты) приложения Flask.

    Эта функция централизованно импортирует все модули с маршрутами
    и регистрирует их в переданном экземпляре Flask-приложения.
    Использование Blueprints позволяет модульно организовать маршруты.

    Args:
        app (Flask): Экземпляр Flask-приложения.
    """
    logger.info("Регистрация Blueprints маршрутов...")

    try:
        # Импортируем blueprints из соответствующих модулей
        from . import html_routes           # Маршруты для HTML-страниц (UI)
        from . import node_routes           # Маршруты для управления Узлами
        from . import subdivision_routes    # Маршруты для управления Подразделениями
        from . import node_type_routes      # Маршруты для управления Типами Узлов
        from . import node_property_routes  # Маршруты для управления Свойствами Типов Узлов
        from . import assignment_routes     # Маршруты для управления Заданиями (pipeline)
        from . import agent_routes          # Маршруты для взаимодействия с Агентами
        from . import check_routes          # Маршруты для приема и получения Результатов Проверок
        from . import event_routes          # Маршруты для Системных Событий
        from . import data_routes           # Маршруты для агрегированных данных (dashboard, etc.)
        from . import misc_routes           # Прочие маршруты (health check)
        from . import auth_routes           # Маршруты для аутентификации пользователей UI
        from . import api_key_routes        # Маршруты для управления API-ключами

        # Регистрируем Blueprints в приложении Flask, указывая префиксы URL, где это необходимо
        app.register_blueprint(html_routes.bp) # Без префикса (т.к. '/', '/status' и т.д.)
        app.register_blueprint(auth_routes.bp) # Без префикса (т.к. '/login', '/logout')
        app.register_blueprint(misc_routes.bp) # Без префикса (т.к. '/health')

        # API v1 маршруты
        api_v1_prefix = '/api/v1'
        app.register_blueprint(node_routes.bp, url_prefix=f'{api_v1_prefix}/nodes')
        app.register_blueprint(subdivision_routes.bp, url_prefix=f'{api_v1_prefix}/subdivisions')
        app.register_blueprint(node_type_routes.bp, url_prefix=f'{api_v1_prefix}/node_types')
        # Для node_property_routes префикс /api/v1 уже включает путь /node_types/{id}/properties
        app.register_blueprint(node_property_routes.bp, url_prefix=api_v1_prefix)
        app.register_blueprint(assignment_routes.bp, url_prefix=f'{api_v1_prefix}/assignments')
        # Для agent_routes, check_routes, data_routes префикс /api/v1 общий
        app.register_blueprint(agent_routes.bp, url_prefix=api_v1_prefix)
        app.register_blueprint(check_routes.bp, url_prefix=api_v1_prefix)
        app.register_blueprint(data_routes.bp, url_prefix=api_v1_prefix)
        app.register_blueprint(event_routes.bp, url_prefix=f'{api_v1_prefix}/events')
        app.register_blueprint(api_key_routes.bp, url_prefix=f'{api_v1_prefix}/api_keys')

        logger.info("Blueprints маршрутов успешно зарегистрированы.")
    except Exception as e:
        logger.critical(f"Критическая ошибка при регистрации Blueprints: {e}", exc_info=True)
        # Прерываем запуск приложения, если маршруты не могут быть зарегистрированы,
        # так как это фундаментальная часть работы приложения.
        raise