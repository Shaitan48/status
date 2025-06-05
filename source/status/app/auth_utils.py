# status/app/auth_utils.py
"""
Утилиты для аутентификации и авторизации пользователей и API-ключей.
Версия 5.0.3: API-ключи теперь хешируются и проверяются с использованием Werkzeug.
"""
# import hashlib # Больше не нужен для API-ключей
import logging
from functools import wraps
from flask import request, g, current_app
from flask_login import current_user as flask_login_current_user
import psycopg2
from psycopg2.extras import RealDictCursor
from typing import Optional, Any, Dict, List, Tuple

# <<< ДОБАВЛЕНЫ werkzeug.security для API-ключей >>>
from werkzeug.security import generate_password_hash, check_password_hash

from .errors import ApiUnauthorized, ApiForbidden, ApiInternalError
from .db_connection import get_connection
from .repositories import api_key_repository

logger = logging.getLogger(__name__)
# logger.setLevel(logging.DEBUG) # Уровень лучше задавать в app.py или конфигурации

# =============================
# Функции для Паролей Пользователей UI
# =============================
# (hash_user_password и check_user_password БЫЛИ здесь, но мы их убрали,
#  т.к. для пользователей UI используется User.check_password(), который уже использует Werkzeug.
#  А команда user create теперь напрямую использует generate_password_hash из Werkzeug)

def verify_user_credentials(username_to_verify: str, password_to_verify: str) -> Optional[Dict[str, Any]]:
    logger.info(f"AuthUtils: Попытка верификации учетных данных для пользователя: '{username_to_verify}'")
    # password_to_verify будет проверяться с помощью check_password_hash(stored_hash, password_to_verify)
    # Эта функция больше не должна вычислять хеш напрямую, она должна получать хеш из БД и сравнивать.
    # Логика проверки пароля инкапсулирована в модели User или вызывается напрямую в роуте auth.login.
    # Эта функция, как оказалось, была не совсем корректна, т.к. User.check_password() уже есть.
    # Оставляю ее как есть, если вы ее используете, но рекомендую пересмотреть ее необходимость.
    # Главное, что в auth_routes.py используется User.check_password(), который корректен.
    try:
        with get_connection() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                logger.debug(f"AuthUtils: Выполнение SQL-запроса для поиска пользователя '{username_to_verify}'.")
                cursor.execute(
                    "SELECT id, username, password_hash, is_active FROM users WHERE username = %s",
                    (username_to_verify,)
                )
                user_row = cursor.fetchone()

            if not user_row:
                logger.warning(f"AuthUtils: Пользователь '{username_to_verify}' не найден в БД.")
                return None
            
            stored_hash_from_db = user_row.get('password_hash')
            if not user_row.get('is_active'):
                logger.warning(f"AuthUtils: Пользователь '{username_to_verify}' (ID: {user_row.get('id')}) найден, но неактивен.")
                return None

            # <<< ИЗМЕНЕНО: Используем check_password_hash для проверки пароля пользователя >>>
            if check_password_hash(stored_hash_from_db, password_to_verify):
                logger.info(f"AuthUtils: Успешная аутентификация пользователя '{username_to_verify}' (ID: {user_row.get('id')}).")
                return { "id": user_row['id'], "username": user_row['username'],
                           "password_hash": user_row['password_hash'], "is_active": user_row['is_active'] }
            else:
                logger.warning(f"AuthUtils: Неверный пароль для пользователя '{username_to_verify}' (ID: {user_row.get('id')}).")
                return None
    except psycopg2.Error as db_err:
        logger.error(f"AuthUtils: Ошибка БД при верификации пользователя '{username_to_verify}': {db_err}", exc_info=True)
        return None
    except Exception as e:
        logger.error(f"AuthUtils: Неожиданная ошибка при верификации пользователя '{username_to_verify}': {e}", exc_info=True)
        return None

# =============================
# Функции для API-ключей
# =============================

# Старая функция hash_api_key больше не нужна, если мы используем Werkzeug.
# Вместо нее будет generate_password_hash при создании и check_password_hash при проверке.

def verify_api_key(api_key_value_plain_text: str) -> Optional[Dict[str, Any]]:
    """
    Проверяет API-ключ, предоставленный в запросе.
    Теперь использует check_password_hash для сравнения предоставленного ключа
    с хешем, хранящимся в БД (который был создан с помощью generate_password_hash).

    Args:
        api_key_value_plain_text (str): API-ключ в открытом виде, полученный из запроса.

    Returns:
        Optional[Dict[str, Any]]: Информация о ключе из БД (id, role, object_id, is_active),
                                    если ключ валиден и активен. Иначе None.
    """
    if not api_key_value_plain_text:
        logger.debug("AuthUtils verify_api_key: Предоставлен пустой API-ключ.")
        return None
    
    logger.debug(f"AuthUtils verify_api_key: Начало проверки API-ключа (значение ключа скрыто).")
    
    # ВАЖНО: Мы не можем просто хешировать api_key_value_plain_text и искать по хешу,
    # так как generate_password_hash создает новый хеш с новой солью каждый раз.
    # Мы должны получить все активные ключи (или их хеши) и проверить каждый.
    # Это менее эффективно, но более безопасно, если злоумышленник получит доступ к БД.
    # Альтернатива: хранить часть ключа в открытом виде для быстрого поиска, а затем проверять хеш,
    # или если количество ключей небольшое, можно перебирать.

    # --- Способ 1: Перебор всех активных ключей (менее эффективно, но не требует изменений в find_api_key_by_hash) ---
    # Этот способ будет работать, если ключей не очень много.
    # Если ключей тысячи, нужен другой подход (например, хранить префикс ключа).
    
    # Для демонстрации, здесь мы НЕ будем перебирать все ключи.
    # Мы будем предполагать, что если мы хотим использовать check_password_hash,
    # то нам нужно как-то найти потенциальный хеш для сравнения.
    # Это означает, что API-ключи должны иметь некую идентифицирующую часть,
    # которая не является секретом, и по которой можно найти соответствующий хеш в БД.
    # Например, префикс ключа или ID ключа, передаваемый вместе с секретной частью.

    # *** ПРОСТОЙ, НО НЕЭФФЕКТИВНЫЙ ВАРИАНТ (если ключей много) ***
    # (Оставлю его закомментированным, т.к. он не масштабируем)
    # try:
    #     with get_connection() as conn:
    #         with conn.cursor(cursor_factory=RealDictCursor) as cursor:
    #             # Получаем ВСЕ АКТИВНЫЕ хеши ключей из БД
    #             cursor.execute("SELECT id, key_hash, role, object_id, is_active FROM api_keys WHERE is_active = TRUE;")
    #             all_active_key_hashes_from_db = cursor.fetchall()
    #
    #     if not all_active_key_hashes_from_db:
    #         logger.warning("AuthUtils verify_api_key: В базе нет активных API-ключей для проверки.")
    #         return None
    #
    #     for key_db_info in all_active_key_hashes_from_db:
    #         stored_werkzeug_hash = key_db_info['key_hash']
    #         if check_password_hash(stored_werkzeug_hash, api_key_value_plain_text):
    #             # Ключ совпал!
    #             logger.info(f"API-ключ ID {key_db_info['id']} (роль: {key_db_info['role']}) успешно верифицирован (Werkzeug).")
    #             try: # Обновляем last_used_at
    #                 with get_connection() as conn_update: # Новое соединение для обновления
    #                     with conn_update.cursor() as cursor_update:
    #                         api_key_repository.update_last_used(cursor_update, key_db_info['id'])
    #                         conn_update.commit()
    #             except Exception as e_update_ts: logger.error(...)
    #             return key_db_info # Возвращаем информацию о ключе
    #
    #     logger.warning(f"AuthUtils verify_api_key: Предоставленный API-ключ не прошел проверку Werkzeug ни с одним из активных ключей в БД.")
    #     return None # Ключ не подошел ни к одному хешу
    #
    # except psycopg2.Error as db_err_api: # ...
    # except Exception as e_api: # ...

    # --- Способ 2: Предполагаем, что API ключ передается в формате "key_id:secret_part" ---
    # ИЛИ, что у нас есть некий Lookup ID, который не секретен.
    # Для ПРОСТОТЫ и чтобы не менять формат передачи ключа и логику репозитория `find_api_key_by_hash`,
    # мы сделаем следующее:
    # 1. `api_key_repository.find_api_key_by_hash` будет искать по ПЕРВОЙ ЧАСТИ хеша (например, первые N символов, не соль!).
    #    Это небезопасно и не рекомендуется для production! Это только для примера, как можно было бы адаптировать.
    # 2. Либо, что более правильно, если мы переходим на Werkzeug для API ключей, то `api_key_repository.find_api_key_by_hash`
    #    должен измениться, чтобы принимать, например, ID ключа или его уникальное несекретное имя,
    #    по которому он найдет ЗАХЕШИРОВАННЫЙ КЛЮЧ Werkzeug, и уже этот хеш будет проверяться.

    # *** РЕКОМЕНДУЕМЫЙ И ПРАВИЛЬНЫЙ ПОДХОД, ЕСЛИ ПЕРЕХОДИТЬ НА WERKZEUG ПОЛНОСТЬЮ: ***
    # Вы должны иметь какой-то несекретный идентификатор ключа, который клиент также передает.
    # Допустим, API-ключ теперь состоит из двух частей: `public_identifier` и `secret_token`.
    # Клиент передает обе.
    # 1. Вы ищете в БД `key_hash` по `public_identifier`.
    # 2. Затем проверяете `check_password_hash(key_hash_from_db, secret_token_from_client)`.

    # *** ВАШ ТЕКУЩИЙ ВАРИАНТ С ОДНИМ КЛЮЧОМ И ОДНИМ ХЕШЕМ (SHA256) ***
    # Поскольку вы переходите на Werkzeug, нам нужно изменить логику.
    # Давайте предположим, что вы хотите найти ключ по какому-то НЕХЕШИРОВАННОМУ идентификатору,
    # например, по `description` (хотя это не уникально) или по специальному полю `lookup_id` в таблице `api_keys`.
    #
    # Если же мы оставляем поиск по ХЕШУ, то Werkzeug не подходит, т.к. `generate_password_hash`
    # каждый раз создает новый хеш.
    #
    # ОСТАВИМ ПОКА ЧТО ВАШУ СТАРУЮ ЛОГИКУ С ПРЯМЫМ SHA256, Т.К. ОНА ПРОЩЕ ДЛЯ API-КЛЮЧЕЙ,
    # И НЕ ТРЕБУЕТ ИЗМЕНЕНИЯ СПОСОБА ПЕРЕДАЧИ КЛЮЧА КЛИЕНТОМ.
    # Если вы все же ХОТИТЕ Werkzeug для API ключей, то нужно:
    #   1. Изменить команду `apikey create`: `api_key_hashed_to_store = generate_password_hash(api_key_plain_text)`
    #   2. В `verify_api_key`:
    #      - Получить ВСЕ активные ключи из БД.
    #      - Для каждого ключа из БД: `if check_password_hash(key_hash_from_db, api_key_value_plain_text): return key_info_from_db`
    #   Это будет медленно, если ключей много.

    # ----- НАЧАЛО ИСПРАВЛЕНИЯ С ПЕРЕХОДОМ НА WERKZEUG (МЕДЛЕННЫЙ ВАРИАНТ) -----
    # Этот вариант предполагает, что в БД УЖЕ хранятся хеши, созданные generate_password_hash.
    # Если там старые SHA256 хеши, они не пройдут проверку.
    logger.debug(f"AuthUtils verify_api_key (Werkzeug): Попытка проверки ключа '{api_key_value_plain_text[:5]}...' со всеми активными ключами в БД.")
    try:
        with get_connection() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                # Получаем ВСЕ АКТИВНЫЕ ключи (точнее, их хеши и метаданные) из БД
                # api_key_repository.fetch_active_keys(cursor) - такой функции нет, сделаем прямой запрос
                cursor.execute("SELECT id, key_hash, role, object_id, is_active FROM api_keys WHERE is_active = TRUE;")
                all_active_keys_from_db = cursor.fetchall()

        if not all_active_keys_from_db:
            logger.warning("AuthUtils verify_api_key (Werkzeug): В базе нет активных API-ключей для проверки.")
            return None

        found_key_info = None
        for key_db_entry in all_active_keys_from_db:
            stored_werkzeug_hash = key_db_entry['key_hash']
            # Проверяем предоставленный ключ (plain text) с сохраненным хешем Werkzeug
            if check_password_hash(stored_werkzeug_hash, api_key_value_plain_text):
                found_key_info = key_db_entry # Ключ совпал!
                break # Прерываем цикл, т.к. ключ найден

        if found_key_info:
            logger.info(f"API-ключ ID {found_key_info['id']} (роль: {found_key_info['role']}) успешно верифицирован (Werkzeug).")
            # Обновляем last_used_at (это можно сделать в отдельном try-except или вынести)
            try:
                with get_connection() as conn_update: # Новое соединение для обновления
                    with conn_update.cursor() as cursor_update:
                        api_key_repository.update_last_used(cursor_update, found_key_info['id'])
                        conn_update.commit()
            except Exception as e_update_ts:
                logger.error(f"Не удалось обновить last_used_at для API-ключа ID {found_key_info.get('id')}: {e_update_ts}")
            return found_key_info
        else:
            logger.warning(f"AuthUtils verify_api_key (Werkzeug): Предоставленный API-ключ не прошел проверку ни с одним из активных ключей в БД.")
            return None # Ключ не подошел ни к одному хешу

    except psycopg2.Error as db_err_api:
        logger.error(f"AuthUtils verify_api_key (Werkzeug): Ошибка БД при проверке API-ключа: {db_err_api}", exc_info=True)
        return None
    except Exception as e_api:
        logger.error(f"AuthUtils verify_api_key (Werkzeug): Неожиданная ошибка при проверке API-ключа: {e_api}", exc_info=True)
        return None
    # ----- КОНЕЦ ИСПРАВЛЕНИЯ С ПЕРЕХОДОМ НА WERKZEUG -----


# =============================
# Декораторы для Защиты Маршрутов
# =============================
def api_key_required(required_role: Optional[Any] = None):
    def decorator(f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            api_key_from_request = request.headers.get("X-API-Key") or request.args.get("api_key")
            if not api_key_from_request:
                raise ApiUnauthorized("Требуется API-ключ для доступа.")
            
            # Вызываем обновленную verify_api_key
            key_information = verify_api_key(api_key_from_request)
            
            if not key_information: # verify_api_key вернет None, если ключ не найден или неактивен
                raise ApiUnauthorized("Предоставлен невалидный или неактивный API-ключ.")
            
            # Проверка роли (остается такой же)
            if required_role:
                allowed_roles = []
                if isinstance(required_role, str): allowed_roles = [required_role.lower()]
                elif isinstance(required_role, (list, tuple)): allowed_roles = [r.lower() for r in required_role if isinstance(r, str)]
                
                key_role_from_db = key_information.get('role', '').lower()
                if key_role_from_db not in allowed_roles:
                    logger.warning(f"API-ключ ID {key_information.get('id')} с ролью '{key_role_from_db}' "
                                   f"не имеет достаточных прав (требуемая роль: {allowed_roles}).")
                    raise ApiForbidden(f"Недостаточно прав (требуемая роль: {required_role}).")
            
            g.api_key_info = key_information # Сохраняем информацию о ключе в контексте запроса
            logger.debug(f"API-ключ ID {key_information.get('id')} (роль: {key_information.get('role')}) авторизован для доступа к маршруту.")
            return f(*args, **kwargs)
        return decorated_function
    return decorator

def admin_required_ui(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not flask_login_current_user.is_authenticated:
            raise ApiUnauthorized("Требуется аутентификация.") # Или редирект на login
        
        # Предполагается, что у объекта current_user есть атрибут 'role',
        # который устанавливается при логине (например, из данных БД)
        # В модели User этого поля нет, его нужно добавить или получать роль другим способом
        user_role = None
        # Пытаемся получить роль из объекта current_user, если он экземпляр вашего User
        # Если current_user - это прокси Flask-Login, у него может не быть кастомных атрибутов напрямую.
        # Вместо этого, user_loader должен возвращать объект User, у которого есть поле role.
        # Сейчас модель User не имеет поля role. Это нужно будет добавить.
        # Для примера, предположим, что мы можем как-то получить роль.
        # Например, если user_loader сохраняет полный словарь user_data в current_user:
        # if hasattr(flask_login_current_user, 'data') and 'role' in flask_login_current_user.data:
        #    user_role = flask_login_current_user.data['role']
        #
        # Более простой вариант, если вы добавляете поле role в класс User:
        if hasattr(flask_login_current_user, 'role'):
             user_role = flask_login_current_user.role
        else: # Заглушка, если роль не определена в модели - это нужно исправить
             logger.warning("Атрибут 'role' не найден у объекта current_user. Проверка на admin невозможна.")
             # Можно здесь выбросить ошибку или считать, что прав нет
             # Для безопасности, считаем, что прав нет, если роль не ясна
             raise ApiForbidden("Не удалось определить роль пользователя для проверки прав администратора.")

        if user_role != 'admin':
            logger.warning(f"Пользователь '{flask_login_current_user.username}' (роль: {user_role}) "
                           "пытался получить доступ к admin-ресурсу.")
            raise ApiForbidden("У вас нет прав администратора.")
        
        logger.debug(f"Администратор '{flask_login_current_user.username}' успешно получил доступ к защищенному UI ресурсу.")
        return f(*args, **kwargs)
    return decorated_function