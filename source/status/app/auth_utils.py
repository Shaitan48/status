# status/app/auth_utils.py
import logging
import hashlib
import psycopg2
from functools import wraps
from typing import Optional, Union, List, Tuple
from flask import request, g, current_app
from werkzeug.exceptions import Unauthorized, Forbidden
from .db_connection import get_connection
from .errors import ApiException, ApiInternalError, ApiUnauthorized, ApiForbidden # Импортируем наши кастомные

logger = logging.getLogger(__name__)

# <<< ИЗМЕНЕНИЕ: required_role может быть строкой, списком/кортежем или None >>>
def api_key_required(required_role: Optional[Union[str, List[str], Tuple[str]]] = None):
    """
    Декоратор для защиты API эндпоинтов с помощью API ключей.

    :param required_role: Допустимая роль или список/кортеж допустимых ролей.
                          Если None, любая валидная активная роль разрешена.
    """
    # Преобразуем required_role в множество для быстрой проверки (если это список/кортеж)
    allowed_roles = set()
    if isinstance(required_role, (list, tuple)):
        allowed_roles = set(r.lower() for r in required_role)
    elif isinstance(required_role, str):
        allowed_roles = {required_role.lower()}
    # Если required_role is None, allowed_roles остается пустым (проверка роли не выполняется)

    def decorator(f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            api_key = request.headers.get('X-API-Key')
            if not api_key:
                raise ApiUnauthorized("Требуется API ключ в заголовке 'X-API-Key'")

            conn = None
            try:
                # --- Блок проверки ключа ---
                conn = get_connection()
                cursor = conn.cursor()
                key_hash = hashlib.sha256(api_key.encode('utf-8')).hexdigest()
                from .repositories import api_key_repository # Импорт внутри функции
                key_data = api_key_repository.find_api_key_by_hash(cursor, key_hash)

                if not key_data:
                    raise ApiUnauthorized("Invalid API key")
                if not key_data['is_active']:
                    # <<< ИЗМЕНЕНО СООБЩЕНИЕ >>>
                    raise ApiForbidden("API key is inactive") # Используем английский

                key_role = key_data.get('role')

                if allowed_roles and (not key_role or key_role.lower() not in allowed_roles):
                    logger.warning(f"Access denied for key ID={key_data.get('id')} (Role: {key_role}). Required: {allowed_roles}. Path: {request.path}")
                    # <<< ИЗМЕНЕНО СООБЩЕНИЕ >>>
                    raise ApiForbidden("Insufficient permissions for this operation (key role mismatch)")
                
                g.api_key_data = key_data
                logger.debug(f"API Key Auth: Успешная аутентификация ключа ID={key_data['id']} (Роль: {key_role}) для {request.path}")

                # Обновляем last_used_at
                try:
                    cursor.execute("UPDATE api_keys SET last_used_at = CURRENT_TIMESTAMP WHERE id = %s", (key_data['id'],))
                except Exception as update_err:
                    logger.error(f"Не удалось обновить last_used_at для ключа ID={key_data['id']}: {update_err}")
                # --- Конец блока проверки ключа ---

                return f(*args, **kwargs) # Выполняем сам обработчик маршрута

            except psycopg2.Error as db_err:
                logger.error(f"API Key Auth: Ошибка БД при ПРОВЕРКЕ ключа: {db_err}", exc_info=True)
                raise ApiInternalError("Ошибка сервера при проверке API ключа (DB)")
            # ApiUnauthorized/ApiForbidden/ApiInternalError будут обработаны глобально

        return decorated_function
    return decorator

# <<< Добавлен импорт для аннотации >>>
from typing import Optional, Union, List, Tuple