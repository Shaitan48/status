# status/app/routes/html_routes.py
import logging
from flask import Blueprint, render_template
from flask_login import login_required

logger = logging.getLogger(__name__)
bp = Blueprint('html', __name__) # Без префикса

# --- Маршруты для HTML страниц ---
@bp.route('/', methods=['GET'])
def dashboard():
    logger.debug("HTML Route: / (dashboard)")
    return render_template('dashboard.html')

@bp.route('/status', methods=['GET'])
def status_detailed():
    logger.debug("HTML Route: /status (status_detailed)")
    return render_template('status_detailed.html')

@bp.route('/events', methods=['GET'])
def system_events_page():
    logger.debug("HTML Route: /events (system_events_page)")
    return render_template('system_events.html')

@bp.route('/manage/subdivisions', methods=['GET'])
@login_required # Защита маршрута, только для авторизованных пользователей
def manage_subdivisions_page():
    logger.debug("HTML Route: /manage/subdivisions")
    return render_template('manage_subdivisions.html')

@bp.route('/manage/assignments', methods=['GET'])
@login_required # Защита маршрута, только для авторизованных пользователей
def manage_assignments_page():
    logger.debug("HTML Route: /manage/assignments")
    return render_template('manage_assignments.html')

@bp.route('/manage/nodes', methods=['GET'])
@login_required # Защита маршрута, только для авторизованных пользователей
def manage_nodes_page():
    logger.debug("HTML Route: /manage/nodes")
    return render_template('manage_nodes.html')

@bp.route('/manage/types', methods=['GET'])
@login_required # Защита маршрута, только для авторизованных пользователей
def manage_types_page():
    logger.debug("HTML Route: /manage/types")
    return render_template('manage_types.html')

@bp.route('/manage/api_keys', methods=['GET'])
@login_required # Управление ключами доступно только авторизованным
def manage_api_keys_page():
    logger.debug("HTML Route: /manage/api_keys")
    return render_template('manage_api_keys.html')
