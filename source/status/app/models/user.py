# status/app/models/user.py
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

class User(UserMixin):
    def __init__(self, id, username, password_hash, is_active=True):
        self.id = id
        self.username = username
        self.password_hash = password_hash
        self.active = is_active

    # Методы, необходимые Flask-Login
    @property
    def is_active(self):
        # Убедитесь, что свойство is_active соответствует полю в БД
        return self.active

    # Остальные свойства is_authenticated, is_anonymous предоставляются UserMixin

    # Методы для работы с паролем
    def set_password(self, password):
        # Мы не будем использовать это напрямую при создании из БД,
        # но полезно для команды создания пользователя.
        self.password_hash = generate_password_hash(password, method='pbkdf2:sha256')

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    # Метод для получения данных пользователя из БД (можно вынести в репозиторий)
    # Этот метод пока не используется user_loader, т.к. user_loader сам ищет.
    # Но может быть полезен в других местах.
    # @staticmethod
    # def get(user_id):
    #    # Логика получения пользователя из БД по ID
    #    # ... (вернуть объект User или None) ...
    #    pass

    # @staticmethod
    # def get_by_username(username):
    #    # Логика получения пользователя из БД по username
    #    # ... (вернуть объект User или None) ...
    #    pass