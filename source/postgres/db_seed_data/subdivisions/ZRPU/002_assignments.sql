-- =============================================================================
-- Файл: ZRPU/002_assignments.sql
-- Назначение: Создание примеров заданий PING для узлов подразделения 'ПУ' (ObjectID: 1516).
--             Использует подзапросы для получения ID узлов и метода PING.
--             Должен выполняться ПОСЛЕ ZRPU/001_nodes.sql.
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

    -- Проверяем, что все необходимое найдено
    IF v_subdivision_id IS NULL OR v_ping_method_id IS NULL THEN
        RAISE WARNING 'Подразделение (1516) или метод PING не найдены. Задания для ZRPU не будут добавлены.';
        RETURN;
    END IF;

    RAISE NOTICE 'Добавление PING заданий для узлов подразделения ID=% (ObjectID=1516)', v_subdivision_id;

    -- Добавляем PING задания для узлов, указанных в оригинальном скрипте
    -- Используем цикл или перечисление с подзапросами
    FOR v_node_id IN SELECT id FROM nodes WHERE parent_subdivision_id = v_subdivision_id AND id IN (13,14,15,16,39,34,35,36,37,1,2,11,38,33,5,3,6,7,9,8,10,4,17,18,19,30,12)
    LOOP
        -- Вставляем задание, если такого же задания (узел+метод) еще нет
        INSERT INTO node_check_assignments (node_id, method_id, check_interval_seconds, description, is_enabled, success_criteria)
        VALUES (v_node_id, v_ping_method_id, 60, 'Авто-назначение PING', TRUE, NULL)
        -- Предотвращаем дублирование одинаковых заданий PING для одного узла
        ON CONFLICT (node_id, method_id) WHERE parameters IS NULL AND success_criteria IS NULL DO NOTHING;
    END LOOP;

    -- Обновляем последовательность node_check_assignments_id_seq
    PERFORM setval(pg_get_serial_sequence('node_check_assignments', 'id'), COALESCE(max(id), 1)) FROM node_check_assignments;

END $$;