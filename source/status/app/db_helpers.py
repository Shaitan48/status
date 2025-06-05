# db_helpers.py
"""
Вспомогательные функции для работы с базой данных Status Monitor (PostgreSQL).
- Поддержка новой архитектуры pipeline-заданий (conveyor tasks)
- Гибридный агент (одна логика для всех агентов)
- CRUD для всех сущностей: узлы, методы, задания (assignments), проверки, детали, события, пользователи, API-ключи

!!! Все функции возвращают списки dict или dict (для удобства сериализации в API/Flask)
"""

import json
from .db_connection import get_db_connection

# =========================
# Узлы (Nodes)
# =========================

def get_all_nodes():
    """Вернуть все узлы (серверы, АРМы и пр)."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, name, parent_subdivision_id, ip_address, node_type_id, description
            FROM nodes
            ORDER BY id
        """)
        columns = [desc[0] for desc in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]

def get_node_by_id(node_id):
    """Вернуть один узел по id."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, name, parent_subdivision_id, ip_address, node_type_id, description
            FROM nodes
            WHERE id = %s
        """, (node_id,))
        row = cur.fetchone()
        if not row:
            return None
        columns = [desc[0] for desc in cur.description]
        return dict(zip(columns, row))

# =========================
# Методы проверки (Check Methods)
# =========================

def get_all_check_methods():
    """Вернуть справочник всех методов проверки."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, method_name, description
            FROM check_methods
            ORDER BY id
        """)
        columns = [desc[0] for desc in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]

# =========================
# Assignments (pipeline задания)
# =========================

def get_assignments_for_node(node_id):
    """Вернуть pipeline-задания для данного узла."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, node_id, method_id, pipeline, check_interval_seconds, description, is_enabled
            FROM node_check_assignments
            WHERE node_id = %s
            ORDER BY id
        """, (node_id,))
        columns = [desc[0] for desc in cur.description]
        results = []
        for row in cur.fetchall():
            d = dict(zip(columns, row))
            # pipeline всегда хранится как JSON-строка — десериализуем
            d['pipeline'] = json.loads(d['pipeline']) if d['pipeline'] else None
            results.append(d)
        return results

def get_assignment_by_id(assignment_id):
    """Вернуть одно pipeline-задание по id."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, node_id, method_id, pipeline, check_interval_seconds, description, is_enabled
            FROM node_check_assignments
            WHERE id = %s
        """, (assignment_id,))
        row = cur.fetchone()
        if not row:
            return None
        columns = [desc[0] for desc in cur.description]
        d = dict(zip(columns, row))
        d['pipeline'] = json.loads(d['pipeline']) if d['pipeline'] else None
        return d

def create_assignment(node_id, method_id, pipeline, check_interval_seconds, description=None, is_enabled=True):
    """Создать pipeline-задание для узла. pipeline — список шагов (будет сериализован как JSON)."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO node_check_assignments (node_id, method_id, pipeline, check_interval_seconds, description, is_enabled)
            VALUES (%s, %s, %s, %s, %s, %s)
            RETURNING id
        """, (
            node_id,
            method_id,
            json.dumps(pipeline) if isinstance(pipeline, list) else pipeline,
            check_interval_seconds,
            description,
            is_enabled
        ))
        conn.commit()
        return cur.fetchone()[0]

def update_assignment(assignment_id, pipeline=None, check_interval_seconds=None, description=None, is_enabled=None):
    """Обновить pipeline-задание по id. Меняем только указанные поля."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        fields = []
        values = []
        if pipeline is not None:
            fields.append("pipeline=%s")
            values.append(json.dumps(pipeline) if isinstance(pipeline, list) else pipeline)
        if check_interval_seconds is not None:
            fields.append("check_interval_seconds=%s")
            values.append(check_interval_seconds)
        if description is not None:
            fields.append("description=%s")
            values.append(description)
        if is_enabled is not None:
            fields.append("is_enabled=%s")
            values.append(is_enabled)
        if not fields:
            return False
        values.append(assignment_id)
        sql = f"UPDATE node_check_assignments SET {', '.join(fields)} WHERE id=%s"
        cur.execute(sql, tuple(values))
        conn.commit()
        return cur.rowcount > 0

def delete_assignment(assignment_id):
    """Удалить pipeline-задание по id."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM node_check_assignments WHERE id=%s", (assignment_id,))
        conn.commit()
        return cur.rowcount > 0

# =========================
# История проверок (Checks)
# =========================

def get_check_results_for_node(node_id):
    """История результатов по узлу (ограничено 100 последних)."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, assignment_id, method_id, is_available, checked_at, executor_object_id, executor_host, resolution_method
            FROM node_checks
            WHERE node_id = %s
            ORDER BY checked_at DESC
            LIMIT 100
        """, (node_id,))
        columns = [desc[0] for desc in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]

def get_assignment_checks(assignment_id):
    """История результатов по заданию (ограничено 100)."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, node_id, method_id, is_available, checked_at, executor_object_id, executor_host, resolution_method
            FROM node_checks
            WHERE assignment_id = %s
            ORDER BY checked_at DESC
            LIMIT 100
        """, (assignment_id,))
        columns = [desc[0] for desc in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]

def add_check_result(**kwargs):
    """
    Добавить основной результат проверки в node_checks (см. поля в БД).
    kwargs: node_id, assignment_id, method_id, is_available, check_timestamp, executor_object_id, executor_host, resolution_method, assignment_config_version, agent_script_version
    """
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO node_checks
                (node_id, assignment_id, method_id, is_available, check_timestamp, executor_object_id, executor_host, resolution_method, assignment_config_version, agent_script_version)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
        """, (
            kwargs['node_id'],
            kwargs.get('assignment_id'),
            kwargs['method_id'],
            kwargs['is_available'],
            kwargs.get('check_timestamp'),
            kwargs.get('executor_object_id'),
            kwargs.get('executor_host'),
            kwargs.get('resolution_method'),
            kwargs.get('assignment_config_version'),
            kwargs.get('agent_script_version'),
        ))
        conn.commit()
        return cur.fetchone()[0]

def add_check_details(node_check_id, detail_type, data):
    """Добавить детализацию к результату (напр., список процессов). data — JSON/dict/list."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO node_check_details (node_check_id, detail_type, data)
            VALUES (%s, %s, %s)
        """, (
            node_check_id,
            detail_type,
            json.dumps(data) if not isinstance(data, str) else data
        ))
        conn.commit()

# =========================
# События (Events)
# =========================

def get_events(filters=None):
    """
    Вернуть события системы (ограничено 200 последних, с фильтрами).
    filters: dict(event_type, severity)
    """
    with get_db_connection() as conn:
        cur = conn.cursor()
        sql = "SELECT id, event_time, event_type, severity, message, source, object_id, node_id, assignment_id, details FROM system_events WHERE TRUE"
        params = []
        if filters:
            if filters.get('event_type'):
                sql += " AND event_type = %s"
                params.append(filters['event_type'])
            if filters.get('severity'):
                sql += " AND severity = %s"
                params.append(filters['severity'])
        sql += " ORDER BY event_time DESC LIMIT 200"
        cur.execute(sql, tuple(params))
        columns = [desc[0] for desc in cur.description]
        events = []
        for row in cur.fetchall():
            d = dict(zip(columns, row))
            d['details'] = json.loads(d['details']) if d['details'] else None
            events.append(d)
        return events

def create_event(data):
    """Добавить системное событие (лог). details — dict/list/string."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO system_events
                (event_type, severity, message, source, object_id, node_id, assignment_id, details)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
        """, (
            data.get('event_type'),
            data.get('severity', 'INFO'),
            data.get('message'),
            data.get('source'),
            data.get('object_id'),
            data.get('node_id'),
            data.get('assignment_id'),
            json.dumps(data.get('details')) if data.get('details') else None,
        ))
        conn.commit()
        return cur.fetchone()[0]

# =========================
# Пользователи (Users)
# =========================

def get_all_users():
    """Вернуть всех пользователей UI."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, username, is_active, created_at
            FROM users
            ORDER BY id
        """)
        columns = [desc[0] for desc in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]

def create_user(data):
    """Создать пользователя (username, password_hash, is_active)."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO users (username, password_hash, is_active)
            VALUES (%s, %s, %s)
            RETURNING id
        """, (
            data['username'],
            data['password_hash'],
            data.get('is_active', True)
        ))
        conn.commit()
        return cur.fetchone()[0]

def get_user_by_id(user_id):
    """Вернуть одного пользователя по id."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, username, is_active, created_at
            FROM users
            WHERE id = %s
        """, (user_id,))
        row = cur.fetchone()
        if not row:
            return None
        columns = [desc[0] for desc in cur.description]
        return dict(zip(columns, row))

def update_user(user_id, data):
    """Обновить пользователя (username, password_hash, is_active)."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        fields = []
        values = []
        if 'username' in data:
            fields.append("username=%s")
            values.append(data['username'])
        if 'password_hash' in data:
            fields.append("password_hash=%s")
            values.append(data['password_hash'])
        if 'is_active' in data:
            fields.append("is_active=%s")
            values.append(data['is_active'])
        if not fields:
            return False
        values.append(user_id)
        sql = f"UPDATE users SET {', '.join(fields)} WHERE id=%s"
        cur.execute(sql, tuple(values))
        conn.commit()
        return cur.rowcount > 0

def delete_user(user_id):
    """Удалить пользователя по id."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM users WHERE id=%s", (user_id,))
        conn.commit()
        return cur.rowcount > 0

# =========================
# API-ключи (API Keys)
# =========================

def get_all_api_keys():
    """Вернуть все API-ключи."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, key_hash, description, role, object_id, is_active, created_at, last_used_at
            FROM api_keys
            ORDER BY id
        """)
        columns = [desc[0] for desc in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]

def create_api_key(data):
    """Создать API-ключ (key_hash, description, role, object_id, is_active)."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO api_keys (key_hash, description, role, object_id, is_active)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id
        """, (
            data['key_hash'],
            data['description'],
            data.get('role', 'agent'),
            data.get('object_id'),
            data.get('is_active', True)
        ))
        conn.commit()
        return cur.fetchone()[0]

def get_api_key_by_id(api_key_id):
    """Вернуть API-ключ по id."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, key_hash, description, role, object_id, is_active, created_at, last_used_at
            FROM api_keys
            WHERE id = %s
        """, (api_key_id,))
        row = cur.fetchone()
        if not row:
            return None
        columns = [desc[0] for desc in cur.description]
        return dict(zip(columns, row))

def update_api_key(api_key_id, data):
    """Обновить API-ключ (description, role, object_id, is_active)."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        fields = []
        values = []
        if 'description' in data:
            fields.append("description=%s")
            values.append(data['description'])
        if 'role' in data:
            fields.append("role=%s")
            values.append(data['role'])
        if 'object_id' in data:
            fields.append("object_id=%s")
            values.append(data['object_id'])
        if 'is_active' in data:
            fields.append("is_active=%s")
            values.append(data['is_active'])
        if not fields:
            return False
        values.append(api_key_id)
        sql = f"UPDATE api_keys SET {', '.join(fields)} WHERE id=%s"
        cur.execute(sql, tuple(values))
        conn.commit()
        return cur.rowcount > 0

def delete_api_key(api_key_id):
    """Удалить API-ключ по id."""
    with get_db_connection() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM api_keys WHERE id=%s", (api_key_id,))
        conn.commit()
        return cur.rowcount > 0

# =========================
# Конец файла
# =========================
