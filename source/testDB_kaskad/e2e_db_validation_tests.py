# status/tests/e2e_db_validation_tests.py
import psycopg2
import os

def test_e2e_check_results():
    # Подключаемся к ТЕСТОВОЙ БД StatusMonitor (порт 48037)
    # DATABASE_URL для этой БД можно взять из переменной окружения или захардкодить
    db_url = os.getenv('E2E_TEST_DB_URL', 'postgresql://pu_user:pu_password@localhost:48037/pu_db_test')
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # 1. Проверка результатов от Online-Агента для PS-TEST-NODE
    cursor.execute("""
        SELECT nc.*, ncd.detail_type, ncd.data
        FROM node_checks nc
        JOIN nodes n ON nc.node_id = n.id
        LEFT JOIN node_check_details ncd ON nc.id = ncd.node_check_id
        WHERE n.name = 'PS-TEST-NODE' AND nc.executor_host IS NOT NULL
        ORDER BY nc.id DESC LIMIT 5;
    """)
    online_checks = cursor.fetchall()
    assert len(online_checks) > 0, "Не найдены результаты от Online-Агента для PS-TEST-NODE"
    # ... (более детальные проверки полей: is_available, resolution_method, agent_script_version, detail_data и т.д.)
    print(f"Найдены онлайн проверки для PS-TEST-NODE: {len(online_checks)}")

    # 2. Проверка результатов от Offline-Агента (Loader) для PS-TEST-NODE
    cursor.execute("""
        SELECT nc.*, ncd.detail_type, ncd.data
        FROM node_checks nc
        JOIN nodes n ON nc.node_id = n.id
        LEFT JOIN node_check_details ncd ON nc.id = ncd.node_check_id
        WHERE n.name = 'PS-TEST-NODE' AND nc.resolution_method = 'offline_loader'
        ORDER BY nc.id DESC LIMIT 5;
    """)
    offline_checks = cursor.fetchall()
    assert len(offline_checks) > 0, "Не найдены результаты от Offline-Агента/Loader'а для PS-TEST-NODE"
    # ... (детальные проверки: assignment_config_version, agent_script_version)
    print(f"Найдены оффлайн проверки для PS-TEST-NODE: {len(offline_checks)}")

    # 3. Проверка события FILE_PROCESSED
    cursor.execute("SELECT * FROM system_events WHERE event_type = 'FILE_PROCESSED' ORDER BY id DESC LIMIT 1")
    file_event = cursor.fetchone()
    assert file_event is not None, "Не найдено событие FILE_PROCESSED"
    assert 'details' in file_event and file_event['details']['total_records_in_file'] > 0
    print(f"Найдено событие FILE_PROCESSED: {file_event['message']}")

    cursor.close()
    conn.close()