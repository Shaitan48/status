# user.py — Модель пользователя для Flask-Login и работы с БД PostgreSQL (таблица users)
# Используется только для UI (аутентификация по логину/паролю).
# Для API и агентов смотри api_keys.

from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

class User(UserMixin):
    """
    Класс пользователя, совместимый с Flask-Login.
    Хранит основные поля пользователя из таблицы users.
    """

    def __init__(self, id, username, password_hash, is_active=True):
        self.id = id
        self.username = username
        self.password_hash = password_hash
        self.active = is_active  # В БД поле называется is_active

    @property
    def is_active(self):
        """
        Flask-Login требует свойство is_active для определения, разрешен ли логин.
        """
        return self.active

    # is_authenticated, is_anonymous и get_id реализуются через UserMixin

    def set_password(self, password):
        """
        Захешировать и сохранить пароль пользователя.
        Используется только при создании/смене пароля.
        """
        self.password_hash = generate_password_hash(password, method='pbkdf2:sha256')

    def check_password(self, password):
        """
        Проверить пароль пользователя по хешу.
        Используется для логина.
        """
        return check_password_hash(self.password_hash, password)

    @staticmethod
    def from_db_row(row):
        """
        Создать объект User из строки, возвращаемой cursor.fetchone().
        Пример row: (id, username, password_hash, is_active)
        """
        if not row:
            return None
        return User(id=row[0], username=row[1], password_hash=row[2], is_active=row[3])

    # --- Примеры функций для загрузки пользователя из БД (вызывать из db_helpers) ---

    # @staticmethod
    # def get_by_id(user_id, db_conn):
    #     """
    #     Получить пользователя по ID (используется Flask-Login user_loader).
    #     """
    #     cur = db_conn.cursor()
    #     cur.execute("SELECT id, username, password_hash, is_active FROM users WHERE id=%s", (user_id,))
    #     row = cur.fetchone()
    #     return User.from_db_row(row)

    # @staticmethod
    # def get_by_username(username, db_conn):
    #     """
    #     Получить пользователя по логину.
    #     """
    #     cur = db_conn.cursor()
    #     cur.execute("SELECT id, username, password_hash, is_active FROM users WHERE username=%s", (username,))
    #     row = cur.fetchone()
    #     return User.from_db_row(row)

# Можно использовать этот класс как простую обертку, все реальные запросы к БД лучше делать через отдельные функции/репозиторий.
