-- Пример pipeline для Windows-узла
DO $$
DECLARE
    v_node_id INTEGER := 1; -- пример id
    v_ping_method_id INTEGER := (SELECT id FROM check_methods WHERE method_name = 'PING');
    v_disk_method_id INTEGER := (SELECT id FROM check_methods WHERE method_name = 'DISK_USAGE');
BEGIN
    -- Пример задания PING через pipeline
    INSERT INTO node_check_assignments (node_id, method_id, is_enabled, pipeline, check_interval_seconds, description)
    VALUES (
        v_node_id,
        v_ping_method_id,
        TRUE,
        '["POWERSHELL_EXECUTE", {"command": "Test-Connection -ComputerName 127.0.0.1 -Count 2"}, {"type": "ANALYZE_RESULT", "success_condition": {"Status": "Success"}}]'::jsonb,
        120,
        'PING localhost через pipeline'
    );
    -- Аналогично для других методов, см. документацию
END $$;
