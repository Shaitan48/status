-- =============================================================================
-- Файл: OTRPK/002_assignments.sql
-- Назначение: Создание заданий PING для узлов подразделения 'ОТРПК' (ObjectID: 1060).
-- =============================================================================
DO $$
DECLARE
    v_subdivision_id INTEGER;
    v_ping_method_id INTEGER;
    v_node_record RECORD;
BEGIN
    -- 1. Получаем ID подразделения ОТРПК
    SELECT id INTO v_subdivision_id FROM subdivisions WHERE object_id = 1060 LIMIT 1;
    -- 2. Получаем ID метода PING
    SELECT id INTO v_ping_method_id FROM check_methods WHERE method_name = 'PING' LIMIT 1;

    IF v_subdivision_id IS NULL OR v_ping_method_id IS NULL THEN
        RAISE WARNING '[Seed OTRPK Assignments] Подразделение ОТРПК (1060) или метод PING не найдены. Задания PING не будут добавлены.';
        RETURN;
    END IF;

    RAISE NOTICE '[Seed OTRPK Assignments] Добавление PING заданий для узлов подразделения ID=% (ОТРПК)', v_subdivision_id;

    -- Для каждого узла с IP добавляем pipeline
    FOR v_node_record IN
        SELECT id, name, ip_address FROM nodes
        WHERE parent_subdivision_id = v_subdivision_id AND ip_address IS NOT NULL
    LOOP
        INSERT INTO node_check_assignments (
            node_id,
            method_id,
            pipeline,
            check_interval_seconds,
            description
        ) VALUES (
            v_node_record.id,
            v_ping_method_id,
            ('[{"type": "PING", "target": "' || v_node_record.ip_address || '"}]')::jsonb,  -- <== вот так!
            120,
            'Авто-назначение PING для ОТРПК'
        )
        ON CONFLICT (node_id, method_id, pipeline) DO NOTHING;

        RAISE NOTICE '[Seed OTRPK Assignments] Добавлено/обновлено задание PING для узла ID=% (IP: %)', v_node_record.id, v_node_record.ip_address;

    END LOOP;

    PERFORM setval(pg_get_serial_sequence('node_check_assignments', 'id'), COALESCE(max(id), 1)) FROM node_check_assignments;
    RAISE NOTICE '[Seed OTRPK Assignments] Задания PING для узлов ОТРПК добавлены/обновлены.';
END $$;
