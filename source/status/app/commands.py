# status/app/commands.py
import logging
import click
import psycopg2
import secrets # Для генерации безопасных ключей
import hashlib # Для хеширования
from flask.cli import with_appcontext
from werkzeug.security import generate_password_hash
from .db_connection import get_connection # Импортируем функцию получения соединения

logger = logging.getLogger(__name__)

@click.command('create-user')
@click.argument('username')
@click.argument('password')
@with_appcontext # Обеспечивает доступ к контексту приложения (для БД)
def create_user_command(username, password):
    """Создает нового пользователя системы."""
    conn = None
    try:
        conn = get_connection()
        cursor = conn.cursor()

        # 1. Проверяем, существует ли пользователь
        cursor.execute("SELECT id FROM users WHERE username = %s", (username,))
        existing_user = cursor.fetchone()
        if existing_user:
            click.echo(click.style(f"Ошибка: Пользователь '{username}' уже существует.", fg='red'))
            return # Выходим, если пользователь есть

        # 2. Хешируем пароль
        # Убедитесь, что метод хеширования совпадает с тем, что используется
        # при проверке пароля в модели User и маршруте login
        hashed_password = generate_password_hash(password, method='pbkdf2:sha256')

        # 3. Вставляем нового пользователя
        cursor.execute(
            "INSERT INTO users (username, password_hash) VALUES (%s, %s)",
            (username, hashed_password)
        )
        # conn.commit() # Раскомментируйте, если autocommit=False в db_connection.py

        click.echo(click.style(f"Пользователь '{username}' успешно создан.", fg='green'))

    except psycopg2.Error as db_err:
        # conn.rollback() # Раскомментируйте, если autocommit=False
        logger.error(f"Ошибка БД при создании пользователя {username}: {db_err}", exc_info=True)
        click.echo(click.style(f"Ошибка базы данных: {db_err}", fg='red'))
    except Exception as e:
        # conn.rollback() # Раскомментируйте, если autocommit=False
        logger.error(f"Неожиданная ошибка при создании пользователя {username}: {e}", exc_info=True)
        click.echo(click.style(f"Неожиданная ошибка: {e}", fg='red'))
    # finally:
        # Соединение вернется в пул через teardown_appcontext, нет необходимости закрывать conn/cursor явно
        # pass

# --- НОВАЯ Команда create-api-key ---
@click.command('create-api-key')
@click.option('--description', prompt='Описание ключа (например, "Online Agent - Object 1516")', help='Описание назначения ключа.')
@click.option('--role', type=click.Choice(['agent', 'loader', 'configurator', 'admin'], case_sensitive=False), default='agent', help='Роль ключа.')
@click.option('--object-id', type=int, default=None, help='(Опционально) ID объекта/подразделения (subdivisions.object_id), к которому привязан ключ.')
@with_appcontext
def create_api_key_command(description, role, object_id):
    """Генерирует новый API ключ и сохраняет его хеш в БД."""
    conn = None
    try:
        conn = get_connection()
        cursor = conn.cursor()

        # Проверяем существование object_id, если он указан
        if object_id is not None:
            cursor.execute("SELECT EXISTS (SELECT 1 FROM subdivisions WHERE object_id = %s)", (object_id,))
            if not cursor.fetchone()['exists']:
                click.echo(click.style(f"Ошибка: Подразделение с object_id={object_id} не найдено.", fg='red'))
                return

        # 1. Генерируем сам ключ (достаточно длинный и случайный)
        #    secrets.token_urlsafe(32) даст примерно 43 символа base64
        api_key = secrets.token_urlsafe(32)

        # 2. Хешируем ключ с помощью SHA-256
        key_hash = hashlib.sha256(api_key.encode('utf-8')).hexdigest()

        # 3. Проверяем, не сгенерировался ли случайно уже существующий хеш (крайне маловероятно)
        cursor.execute("SELECT id FROM api_keys WHERE key_hash = %s", (key_hash,))
        if cursor.fetchone():
            # Если коллизия (почти невозможно), просто просим повторить
            click.echo(click.style("Произошла редкая коллизия хешей. Пожалуйста, повторите команду.", fg='yellow'))
            return

        # 4. Вставляем хеш и метаданные в базу
        cursor.execute(
            """
            INSERT INTO api_keys (key_hash, description, role, object_id, is_active)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id
            """,
            (key_hash, description, role.lower(), object_id, True) # Роль в нижнем регистре
        )
        new_key_id = cursor.fetchone()['id']
        # conn.commit() # Если не autocommit

        click.echo("-----------------------------------------------------")
        click.echo(click.style("API Ключ успешно создан!", fg='green'))
        click.echo(f"ID ключа в БД: {new_key_id}")
        click.echo(f"Описание: {description}")
        click.echo(f"Роль: {role.lower()}")
        if object_id is not None:
            click.echo(f"Привязан к Object ID: {object_id}")
        click.echo(click.style("ВАЖНО: Скопируйте и сохраните сам API ключ.", fg='yellow', bold=True))
        click.echo("Он больше не будет показан:")
        click.echo(click.style(api_key, fg='cyan')) # <<< Показываем сгенерированный ключ
        click.echo("-----------------------------------------------------")

    except psycopg2.Error as db_err:
        # conn.rollback() # Если не autocommit
        logger.error(f"Ошибка БД при создании API ключа: {db_err}", exc_info=True)
        click.echo(click.style(f"Ошибка базы данных: {db_err}", fg='red'))
    except Exception as e:
        # conn.rollback() # Если не autocommit
        logger.error(f"Неожиданная ошибка при создании API ключа: {e}", exc_info=True)
        click.echo(click.style(f"Неожиданная ошибка: {e}", fg='red'))