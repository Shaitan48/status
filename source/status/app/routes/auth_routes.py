# status/app/routes/auth_routes.py
"""
Маршруты для аутентификации пользователей веб-интерфейса (UI).
Версия 5.0.2: Добавлен импорт Optional для type hints.
"""
import logging
from flask import Blueprint, request, render_template, redirect, url_for, flash, g, current_app
from flask_login import login_user, logout_user, login_required, current_user
from typing import Optional # <<< ДОБАВЛЕН ИМПОРТ Optional
from ..models.user import User
from ..db_connection import psycopg2

from urllib.parse import urlparse as urllib_urlparse
from urllib.parse import urljoin as urllib_urljoin

logger = logging.getLogger(__name__)
bp = Blueprint('auth', __name__)

# --- Вспомогательная функция для безопасного редиректа (адаптированная) ---
def is_safe_url(target_url: Optional[str]) -> bool: # Теперь Optional определен
    """
    Проверяет, является ли URL для редиректа безопасным (т.е. указывает на тот же хост).
    Использует urllib.parse.
    """
    if not target_url:
        return False
    host_url = request.host_url
    absolute_redirect_url = urllib_urljoin(host_url, target_url)
    host_url_parts = urllib_urlparse(host_url)
    redirect_url_parts = urllib_urlparse(absolute_redirect_url)
    return (redirect_url_parts.scheme in ('http', 'https') and
            host_url_parts.netloc == redirect_url_parts.netloc)

# --- Маршруты ---
@bp.route('/login', methods=['GET', 'POST'])
def login():
    # (Логика функции login без изменений)
    if current_user.is_authenticated:
        logger.debug(f"Пользователь '{current_user.username}' уже аутентифицирован, редирект на дашборд.")
        return redirect(url_for('html.dashboard'))

    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        logger.info(f"Попытка входа пользователя: '{username}'")

        if not username or not password:
            logger.warning(f"Попытка входа с пустыми полями.")
            flash('Требуется ввести имя пользователя и пароль.', 'warning')
            return render_template('login.html'), 400

        user_from_db: Optional[User] = None
        try:
            if not hasattr(g, 'db_cursor') or g.db_cursor is None or g.db_cursor.closed:
                logger.error("login: g.db_cursor отсутствует или закрыт! Невозможно выполнить запрос к БД.")
                flash('Ошибка сервера при попытке входа (нет курсора БД).', 'danger')
                return render_template('login.html'), 500

            cursor = g.db_cursor
            cursor.execute(
                "SELECT id, username, password_hash, is_active FROM users WHERE username = %s",
                (username,)
            )
            user_data_row = cursor.fetchone()

            if user_data_row:
                temp_user_for_check = User(
                    id=user_data_row['id'],
                    username=user_data_row['username'],
                    password_hash=user_data_row['password_hash'],
                    is_active=user_data_row['is_active']
                )
                if temp_user_for_check.check_password(password):
                    if temp_user_for_check.is_active:
                        user_from_db = temp_user_for_check
                        logger.info(f"Пароль для '{username}' успешно проверен.")
                    else:
                        logger.warning(f"Попытка входа неактивного пользователя: '{username}'.")
                        flash('Учетная запись неактивна. Обратитесь к администратору.', 'danger')
                else:
                    logger.warning(f"Неверный пароль для пользователя: '{username}'.")
                    flash('Неверное имя пользователя или пароль.', 'danger')
            else:
                logger.warning(f"Пользователь с именем '{username}' не найден.")
                flash('Неверное имя пользователя или пароль.', 'danger')
        except psycopg2.Error as db_err:
            logger.error(f"Ошибка БД при попытке входа '{username}': {db_err}", exc_info=True)
            flash('Ошибка сервера при попытке входа.', 'danger')
        except Exception as e:
            logger.error(f"Неожиданная ошибка при входе '{username}': {e}", exc_info=True)
            flash('Непредвиденная ошибка.', 'danger')

        if user_from_db:
            login_user(user_from_db)
            logger.info(f"Пользователь '{username}' (ID: {user_from_db.id}) успешно вошел.")
            next_page_url = request.args.get('next')
            if not next_page_url or not is_safe_url(next_page_url):
                next_page_url = url_for('html.dashboard')
            logger.debug(f"Редирект после входа на: {next_page_url}")
            return redirect(next_page_url)
        else:
            return render_template('login.html'), 401

    return render_template('login.html')

@bp.route('/logout')
@login_required
def logout():
    # (Без изменений)
    user_id_before_logout = current_user.id if current_user.is_authenticated else None
    username_before_logout = current_user.username if current_user.is_authenticated else 'Аноним'
    logger.info(f"Пользователь '{username_before_logout}' (ID: {user_id_before_logout}) выполняет выход.")
    logout_user()
    flash('Вы успешно вышли из системы.', 'success')
    logger.info(f"Пользователь '{username_before_logout}' успешно вышел. Редирект на страницу входа.")
    return redirect(url_for('auth.login'))