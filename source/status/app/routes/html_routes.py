# status/app/routes/html_routes.py
"""
Маршруты, отвечающие за рендеринг HTML-страниц пользовательского интерфейса.
"""
import logging
from flask import Blueprint, render_template
from flask_login import login_required # Для защиты страниц управления

logger = logging.getLogger(__name__)
bp = Blueprint('html', __name__) # Имя Blueprint, префикс URL не задается здесь

# --- Маршруты для HTML страниц ---

@bp.route('/', methods=['GET'])
def dashboard():
    """Рендерит главную страницу (Сводка/Dashboard)."""
    logger.debug("HTML Route: Запрос / (dashboard)")
    return render_template('dashboard.html')

@bp.route('/status', methods=['GET'])
def status_detailed():
    """Рендерит страницу с детальным статусом всех узлов."""
    logger.debug("HTML Route: Запрос /status (status_detailed)")
    return render_template('status_detailed.html')

@bp.route('/events', methods=['GET'])
# @login_required # Раскомментировать, если просмотр событий требует логина
def system_events_page():
    """Рендерит страницу с журналом системных событий."""
    logger.debug("HTML Route: Запрос /events (system_events_page)")
    return render_template('system_events.html')

# --- Страницы управления (требуют аутентификации) ---

@bp.route('/manage/subdivisions', methods=['GET'])
@login_required # Защита маршрута: только для авторизованных пользователей
def manage_subdivisions_page():
    """Рендерит страницу управления Подразделениями."""
    logger.debug("HTML Route: Запрос /manage/subdivisions")
    return render_template('manage_subdivisions.html')

@bp.route('/manage/assignments', methods=['GET'])
@login_required
def manage_assignments_page():
    """Рендерит страницу управления Заданиями (pipeline)."""
    logger.debug("HTML Route: Запрос /manage/assignments")
    return render_template('manage_assignments.html')

@bp.route('/manage/nodes', methods=['GET'])
@login_required
def manage_nodes_page():
    """Рендерит страницу управления Узлами."""
    logger.debug("HTML Route: Запрос /manage/nodes")
    return render_template('manage_nodes.html')

@bp.route('/manage/types', methods=['GET'])
@login_required
def manage_types_page():
    """Рендерит страницу управления Типами Узлов и их Свойствами."""
    logger.debug("HTML Route: Запрос /manage/types")
    return render_template('manage_types.html')

@bp.route('/manage/api_keys', methods=['GET'])
@login_required # Управление API-ключами доступно только авторизованным пользователям
def manage_api_keys_page():
    """Рендерит страницу управления API-ключами."""
    logger.debug("HTML Route: Запрос /manage/api_keys")
    return render_template('manage_api_keys.html')