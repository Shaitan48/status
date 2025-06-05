# status/app/commands.py
"""
Модуль для определения кастомных команд Flask CLI.
Версия 5.0.4: API-ключи теперь хешируются с использованием Werkzeug (generate_password_hash).
"""
import logging
import click
from flask.cli import AppGroup
import secrets
import psycopg2
from psycopg2.extras import RealDictCursor

# <<< ИЗМЕНЕНО: Используем generate_password_hash для API-ключей тоже >>>
from werkzeug.security import generate_password_hash
# Убираем from .auth_utils import hash_api_key, если он там больше не нужен

from .db_connection import get_connection
from .repositories import user_repository, api_key_repository, subdivision_repository
# Старая функция auth_utils.hash_api_key больше не нужна, если мы перешли на Werkzeug

logger = logging.getLogger(__name__)

user_cli = AppGroup('user', help='Команды для управления пользователями UI.')
api_key_cli = AppGroup('apikey', help='Команды для управления API-ключами.')

# --- Команда для создания пользователя UI ---
@user_cli.command('create')
@click.argument('username')
@click.argument('password')
@click.option('--active/--inactive', default=True, help='Сделать пользователя активным (по умолчанию) или неактивным.')
def create_user_command(username, password, active):
    """ Создает нового пользователя для доступа к веб-интерфейсу. """
    logger.info(f"CLI: Попытка создания пользователя '{username}' (активен: {active}).")
    if not username or not password:
        click.echo(click.style("Ошибка: Имя пользователя и пароль не могут быть пустыми.", fg="red"))
        logger.warning("CLI create-user: Имя пользователя или пароль не указаны.")
        return
    try:
        # Используем generate_password_hash из Werkzeug для паролей пользователей
        password_hash = generate_password_hash(password, method='pbkdf2:sha256')
        user_data_to_create = {
            'username': username,
            'password_hash': password_hash,
            'is_active': active
        }
        with get_connection() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                new_user_id = user_repository.create_user(cursor, user_data_to_create)
                if new_user_id:
                    conn.commit()
                    click.echo(click.style(f"Пользователь '{username}' (ID: {new_user_id}) успешно создан!", fg="green"))
                    logger.info(f"CLI: Пользователь '{username}' (ID: {new_user_id}) создан.")
                else:
                    click.echo(click.style(f"Не удалось создать пользователя '{username}'. Репозиторий не вернул ID.", fg="red"))
                    logger.error(f"CLI create-user: Репозиторий user_repository.create_user не вернул ID для '{username}'.")
    except psycopg2.errors.UniqueViolation:
        click.echo(click.style(f"Ошибка: Пользователь с именем '{username}' уже существует.", fg="yellow"))
        logger.warning(f"CLI create-user: Пользователь '{username}' уже существует.")
    except psycopg2.Error as db_err:
        click.echo(click.style(f"Ошибка базы данных при создании пользователя: {db_err}", fg="red"))
        logger.error(f"CLI create-user: Ошибка БД для пользователя '{username}': {db_err}", exc_info=True)
    except Exception as e:
        click.echo(click.style(f"Непредвиденная ошибка при создании пользователя: {e}", fg="red"))
        logger.exception(f"CLI create-user: Неожиданная ошибка для пользователя '{username}'.")


# --- Команда для создания API-ключа ---
@api_key_cli.command('create')
@click.option('--description', '-d', required=True, help='Описание назначения API-ключа.')
@click.option('--role', '-r', required=True, type=click.Choice(['agent', 'loader', 'configurator', 'admin'], case_sensitive=False), help='Роль API-ключа.')
@click.option('--object-id', '-o', type=int, default=None, help='ID объекта (подразделения), к которому привязан ключ.')
@click.option('--length', '-l', type=int, default=32, show_default=True, help='Длина генерируемого ключа (до хеширования).')
def create_api_key_command(description, role, object_id, length):
    """ Создает новый API-ключ и выводит его в консоль. Хеш ключа создается с помощью Werkzeug. """
    logger.info(f"CLI: Попытка создания API-ключа (Werkzeug). Описание: '{description}', Роль: '{role}', ObjectID: {object_id or 'N/A'}.")
    if length < 24 or length > 64: # Длина самого токена до хеширования
        click.echo(click.style("Ошибка: Длина ключа (до хеширования) должна быть от 24 до 64 символов.", fg="red")); return
    
    try:
        if object_id is not None: # Проверка существования подразделения, если object_id указан
            with get_connection() as conn_check_sub:
                with conn_check_sub.cursor(cursor_factory=RealDictCursor) as cursor_check_sub:
                    if not subdivision_repository.check_subdivision_exists_by_object_id(cursor_check_sub, object_id):
                        click.echo(click.style(f"Ошибка: Подразделение с object_id={object_id} не найдено.", fg="red")); return
        
        # 1. Генерируем сам API-ключ в открытом виде (он будет показан пользователю)
        api_key_plain_text = secrets.token_urlsafe(length)
        
        # 2. Хешируем этот ключ с помощью Werkzeug для безопасного хранения в БД
        # <<< ИЗМЕНЕНО ЗДЕСЬ: Используем generate_password_hash >>>
        # Метод можно выбрать, но pbkdf2:sha256 - хороший дефолт.
        api_key_hashed_to_store = generate_password_hash(api_key_plain_text, method='pbkdf2:sha256')
        
        with get_connection() as conn_create_key:
            with conn_create_key.cursor(cursor_factory=RealDictCursor) as cursor_create_key:
                new_api_key_id = api_key_repository.create_api_key(
                    cursor_create_key,
                    key_hash=api_key_hashed_to_store, # Передаем хеш Werkzeug
                    description=description,
                    role=role.lower(),
                    object_id=object_id
                )
                if new_api_key_id:
                    conn_create_key.commit()
                    click.echo(click.style("API Ключ успешно создан (с использованием Werkzeug хеширования)!", fg="green"))
                    click.echo(click.style("ВАЖНО: Сохраните этот ключ. Он больше НЕ БУДЕТ ПОКАЗАН:", bold=True, fg="red"))
                    click.echo(click.style(api_key_plain_text, fg="yellow", bold=True))
                    click.echo(f"(ID ключа в базе: {new_api_key_id}. Хеш в БД (начало): {api_key_hashed_to_store[:20]}...)")
                    logger.info(f"CLI: API-ключ ID={new_api_key_id} (роль: {role.lower()}) создан с хешем Werkzeug.")
                else:
                    click.echo(click.style("Не удалось создать API-ключ (репозиторий не вернул ID).", fg="red"))
                    logger.error("CLI create-api-key: api_key_repository.create_api_key не вернул ID.")
    except psycopg2.errors.UniqueViolation: # Этого не должно быть, если generate_password_hash используется, т.к. он соленый
        click.echo(click.style(f"Критическая ошибка: Конфликт уникальности при создании API-ключа с Werkzeug хешем. Этого не должно было произойти.", fg="red"))
        logger.critical("CLI create-api-key: Неожиданный UniqueViolation для Werkzeug хеша API-ключа.")
    except psycopg2.Error as db_err_create_key:
        click.echo(click.style(f"Ошибка базы данных при создании API-ключа: {db_err_create_key}", fg="red"))
        logger.error(f"CLI create-api-key: Ошибка БД: {db_err_create_key}", exc_info=True)
    except ValueError as val_err_create_key:
        click.echo(click.style(f"Ошибка валидации при создании API-ключа: {val_err_create_key}", fg="red"))
        logger.warning(f"CLI create-api-key: Ошибка валидации: {val_err_create_key}")
    except Exception as e_create_key:
        click.echo(click.style(f"Непредвиденная ошибка при создании API-ключа: {e_create_key}", fg="red"))
        logger.exception("CLI create-api-key: Неожиданная ошибка.")