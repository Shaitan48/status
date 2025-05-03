# status/wsgi.py
import os
import logging

# Абсолютный импорт пакета 'app', затем модуля 'app' (файла app.py), затем фабрики
from app.app import create_app

# Настраиваем базовое логирование на случай, если create_app еще не настроил
# Уровень можно брать из переменной окружения для гибкости
log_level_str = os.getenv('LOG_LEVEL', 'INFO').upper()
log_level = getattr(logging, log_level_str, logging.INFO)
logging.basicConfig(level=log_level)

log = logging.getLogger(__name__)
log.info(f"Запуск WSGI entrypoint (уровень логирования: {log_level_str})...")

# Создаем экземпляр приложения Flask с помощью фабрики
# Gunicorn ищет эту переменную по умолчанию
application = create_app()
log.info("Экземпляр Flask приложения успешно создан через WSGI entrypoint.")