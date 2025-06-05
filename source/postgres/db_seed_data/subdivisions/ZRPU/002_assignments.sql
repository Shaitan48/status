-- =============================================================================
-- Файл: ZRPU/002_assignments.sql
-- Назначение: Создание примеров заданий PING для узлов подразделения 'ПУ' (ObjectID: 1516).
-- =============================================================================
DO $$
DECLARE
    v_subdivision_id INTEGER;
    v_ping_method_id INTEGER;
    v_node_id INTEGER;
BEGIN
    -- Получаем ID подразделения
    SELECT id INTO v_subdivision_id FROM subdivisions WHERE object_id = 1516 LIMIT 1;
    -- Получаем ID метода PING
    SELECT id INTO v_ping_method_id FROM check_methods WHERE method_name = 'PING' LIMIT 1;

    IF v_subdivision_id IS NULL OR v_ping_method_id IS NULL THEN
        RAISE WARNING 'Подразделение (1516) или метод PING не найдены. Задания для ZRPU не будут добавлены.';
        RETURN;
    END IF;

    RAISE NOTICE 'Добавление PING заданий для узлов подразделения ID=% (ObjectID=1516)', v_subdivision_id;

    FOR v_node_id IN SELECT id FROM nodes WHERE parent_subdivision_id = v_subdivision_id AND id IN (13,14,15,16,39,34,35,36,37,1,2,11,38,33,5,3,6,7,9,8,10,4,17,18,19,30,12)
    LOOP
        -- Пример pipeline — один шаг: PING (без параметров, "по умолчанию" — агент подставляет IP)
        INSERT INTO node_check_assignments
            (node_id, method_id, pipeline, check_interval_seconds, description)
        VALUES
            (
                v_node_id,
                v_ping_method_id,
                '[{"type": "PING"}]',      -- Если нужно передать IP: '[{"type": "PING", "target": "1.2.3.4"}]'
                60,
                'Авто-назначение PING'
            )
        ON CONFLICT (node_id, method_id, pipeline) DO NOTHING;
    END LOOP;

    PERFORM setval(pg_get_serial_sequence('node_check_assignments', 'id'), COALESCE(max(id), 1)) FROM node_check_assignments;
END $$;
