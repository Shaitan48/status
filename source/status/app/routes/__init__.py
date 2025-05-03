# status/app/routes/__init__.py
import logging
from flask import Flask

logger = logging.getLogger(__name__)

def init_routes(app: Flask):
    """Инициализирует и регистрирует все Blueprints маршрутов."""
    logger.info("Регистрация Blueprints маршрутов...")

    try:
        # Импортируем blueprints из модулей
        from . import html_routes
        from . import node_routes
        from . import subdivision_routes
        from . import node_type_routes
        from . import node_property_routes
        from . import assignment_routes
        from . import agent_routes
        from . import check_routes
        from . import event_routes
        from . import data_routes
        from . import misc_routes # Для health и др.
        from . import auth_routes # Для аутентификации
        from . import api_key_routes # Для управления API ключами

        # Регистрируем Blueprints в приложении Flask
        # Важно использовать url_prefix, если он определен в самом blueprint
        app.register_blueprint(html_routes.bp)
        app.register_blueprint(node_routes.bp, url_prefix='/api/v1/nodes')
        app.register_blueprint(subdivision_routes.bp, url_prefix='/api/v1/subdivisions')
        app.register_blueprint(node_type_routes.bp, url_prefix='/api/v1/node_types')
        app.register_blueprint(node_property_routes.bp, url_prefix='/api/v1') # Префикс здесь, т.к. пути разные
        app.register_blueprint(assignment_routes.bp, url_prefix='/api/v1/assignments')
        app.register_blueprint(agent_routes.bp, url_prefix='/api/v1') # Префикс здесь
        app.register_blueprint(check_routes.bp, url_prefix='/api/v1') # Префикс здесь
        app.register_blueprint(event_routes.bp, url_prefix='/api/v1/events')
        app.register_blueprint(data_routes.bp, url_prefix='/api/v1') # Префикс здесь
        app.register_blueprint(misc_routes.bp) # Без префикса для /health
        app.register_blueprint(auth_routes.bp) # Для аутентификации        
        app.register_blueprint(api_key_routes.bp, url_prefix='/api/v1/api_keys') # Для управления API ключами

        logger.info("Blueprints маршрутов успешно зарегистрированы.")
    except Exception as e:
        logger.critical(f"Критическая ошибка при регистрации Blueprints: {e}", exc_info=True)
        raise # Прерываем запуск приложения, если маршруты не регистрируются

