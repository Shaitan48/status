# status/app/routes/auth_routes.py
import logging
from flask import Blueprint, request, render_template, redirect, url_for, flash, g
from flask_login import login_user, logout_user, login_required, current_user
from ..models.user import User
from ..db_connection import get_connection # Для прямого доступа к БД

logger = logging.getLogger(__name__)
bp = Blueprint('auth', __name__) # Префикс не нужен, т.к. это /login, /logout

@bp.route('/login', methods=['GET', 'POST'])
def login():
    # Если пользователь уже вошел, редирект на дашборд
    if current_user.is_authenticated:
        return redirect(url_for('html.dashboard'))

    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        # remember = True if request.form.get('remember') else False # Опционально

        if not username or not password:
            flash('Требуется имя пользователя и пароль', 'warning')
            return render_template('login.html')

        user_obj = None
        try:
            conn = get_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT id, username, password_hash, is_active FROM users WHERE username = %s", (username,))
            user_data = cursor.fetchone()
            if user_data and User(id=0, username='', password_hash=user_data['password_hash']).check_password(password):
                 if user_data['is_active']:
                     # Создаем объект User для Flask-Login
                     user_obj = User(id=user_data['id'], username=user_data['username'], password_hash=user_data['password_hash'], is_active=user_data['is_active'])
                 else:
                      flash('Учетная запись неактивна.', 'danger')
            else:
                 flash('Неверное имя пользователя или пароль.', 'danger')
        except Exception as e:
            logger.error(f"Ошибка при попытке входа пользователя {username}: {e}", exc_info=True)
            flash('Произошла ошибка при входе. Попробуйте позже.', 'danger')

        if user_obj:
            login_user(user_obj) #, remember=remember) # Логиним пользователя
            logger.info(f"Пользователь '{username}' успешно вошел.")
            # Редирект на страницу, с которой его перенаправили, или на дашборд
            next_page = request.args.get('next')
            if not next_page or url_parse(next_page).netloc != '': # Безопасный редирект
                next_page = url_for('html.dashboard')
            return redirect(next_page)
        else:
             # Ошибка уже показана через flash
             return render_template('login.html')

    # Для GET запроса просто показываем форму
    return render_template('login.html')

@bp.route('/logout')
@login_required # Выйти может только залогиненный пользователь
def logout():
    logger.info(f"Пользователь '{current_user.username}' выходит.")
    logout_user()
    flash('Вы успешно вышли.', 'success')
    return redirect(url_for('auth.login'))

# --- Вспомогательная функция для безопасного редиректа ---
from urllib.parse import urlparse, urljoin
def is_safe_url(target):
    ref_url = urlparse(request.host_url)
    test_url = urlparse(urljoin(request.host_url, target))
    return test_url.scheme in ('http', 'https') and ref_url.netloc == test_url.netloc

# Переопределение url_parse для удобства
from urllib.parse import urlparse as url_parse