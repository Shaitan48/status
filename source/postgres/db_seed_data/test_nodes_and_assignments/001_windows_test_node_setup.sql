-- F:\status\source\postgres\db_seed_data\test_nodes_and_assignments\001_windows_test_node_setup.sql
-- Назначение: Добавление тестового Linux узла с PowerShell и проверок для него в тестовую БД.
-- =============================================================================

DO $$
DECLARE
    v_test_lab_sub_id INTEGER;
    v_linux_server_type_id INTEGER; -- Можно использовать 'Физические сервера' или создать 'Linux Server'
    v_ps_test_node_id INTEGER;
    v_ping_method_id INTEGER;
    -- v_service_status_method_id INTEGER; -- Службы WinRM тут не будет
    v_disk_usage_method_id INTEGER;
BEGIN
    RAISE NOTICE '[Seed Test PowerShell Node] Начало настройки тестового Linux узла с PowerShell...';

    -- 1. Тестовое подразделение
    INSERT INTO subdivisions (object_id, short_name, full_name, priority, transport_system_code)
    VALUES (9999, 'Test Lab PowerShell Nodes', 'Подразделение для тестовых PowerShell узлов', 950, 'TESTPS')
    ON CONFLICT (object_id) DO UPDATE SET short_name = EXCLUDED.short_name
    RETURNING id INTO v_test_lab_sub_id;
    IF v_test_lab_sub_id IS NULL THEN
        SELECT id INTO v_test_lab_sub_id FROM subdivisions WHERE object_id = 9999;
    END IF;
    RAISE NOTICE '[Seed Test PowerShell Node] Тестовое подразделение ID: %', v_test_lab_sub_id;

    -- 2. Тип узла
    SELECT id INTO v_linux_server_type_id FROM node_types WHERE name = 'Физические сервера' LIMIT 1;
    IF v_linux_server_type_id IS NULL THEN
        RAISE WARNING '[Seed Test PowerShell Node] Тип узла "Физические сервера" не найден. Используется ID 0.';
        v_linux_server_type_id := 0;
    END IF;
    RAISE NOTICE '[Seed Test PowerShell Node] ID типа узла для PowerShell машины: %', v_linux_server_type_id;

    -- 3. Тестовый PowerShell узел
    INSERT INTO nodes (name, ip_address, parent_subdivision_id, node_type_id, description)
    VALUES ('PS-TEST-NODE', 'ps-test-node', v_test_lab_sub_id, v_linux_server_type_id, 'Тестовый Linux узел с PowerShell Core')
    ON CONFLICT (name, parent_subdivision_id) DO UPDATE SET ip_address = EXCLUDED.ip_address, description = EXCLUDED.description
    RETURNING id INTO v_ps_test_node_id;
    IF v_ps_test_node_id IS NULL THEN
        SELECT id INTO v_ps_test_node_id FROM nodes WHERE name = 'PS-TEST-NODE' AND parent_subdivision_id = v_test_lab_sub_id;
    END IF;
    RAISE NOTICE '[Seed Test PowerShell Node] Тестовый PowerShell узел ID: %', v_ps_test_node_id;

    -- 4. Методы проверки
    SELECT id INTO v_ping_method_id FROM check_methods WHERE method_name = 'PING';
    SELECT id INTO v_disk_usage_method_id FROM check_methods WHERE method_name = 'DISK_USAGE';
    -- Убираем SERVICE_STATUS для WinRM
    IF v_ping_method_id IS NULL OR v_disk_usage_method_id IS NULL THEN
        RAISE EXCEPTION '[Seed Test PowerShell Node] Один или несколько методов проверки (PING, DISK_USAGE) не найдены!';
    END IF;
    RAISE NOTICE '[Seed Test PowerShell Node] ID методов: PING=%, DISK_USAGE=%', v_ping_method_id, v_disk_usage_method_id;

    -- 5. Задания
    -- PING
    INSERT INTO node_check_assignments (node_id, method_id, is_enabled, check_interval_seconds, description)
    VALUES (v_ps_test_node_id, v_ping_method_id, TRUE, 120, 'PING для PS-TEST-NODE')
    ON CONFLICT (node_id, method_id) WHERE parameters IS NULL AND success_criteria IS NULL DO NOTHING;

    -- DISK_USAGE (для корневого раздела '/')
    -- Сначала проверяем, есть ли уже такое задание с нужными параметрами
    IF EXISTS (
        SELECT 1 FROM node_check_assignments
        WHERE node_id = v_ps_test_node_id
          AND method_id = v_disk_usage_method_id
          AND parameters->'drives' @> '["/"]'::jsonb -- Проверяем, что в массиве 'drives' есть '/'
    ) THEN
        RAISE NOTICE '[Seed Test PowerShell Node] Задание DISK_USAGE для ''/'' уже существует для узла ID %, обновляем.', v_ps_test_node_id;
        UPDATE node_check_assignments
        SET
            is_enabled = TRUE,
            check_interval_seconds = 600,
            description = 'Использование диска / на PS-TEST-NODE (обновлено)',
            success_criteria = jsonb_build_object('disks', jsonb_build_object('_condition_', 'all', '_where_', jsonb_build_object('drive_letter', '/'), '_criteria_', jsonb_build_object('percent_free', jsonb_build_object('>=', 5))))
        WHERE node_id = v_ps_test_node_id
          AND method_id = v_disk_usage_method_id
          AND parameters->'drives' @> '["/"]'::jsonb;
    ELSE
        RAISE NOTICE '[Seed Test PowerShell Node] Задание DISK_USAGE для ''/'' не найдено для узла ID %, создаем новое.', v_ps_test_node_id;
        INSERT INTO node_check_assignments (node_id, method_id, is_enabled, parameters, check_interval_seconds, description, success_criteria)
        VALUES (v_ps_test_node_id, v_disk_usage_method_id, TRUE, jsonb_build_object('drives', jsonb_build_array('/')), 600, 'Использование диска / на PS-TEST-NODE', jsonb_build_object('disks', jsonb_build_object('_condition_', 'all', '_where_', jsonb_build_object('drive_letter', '/'), '_criteria_', jsonb_build_object('percent_free', jsonb_build_object('>=', 5)))));
    END IF;

    RAISE NOTICE '[Seed Test PowerShell Node] Задания для тестового PowerShell узла добавлены/обновлены.';
END $$;


-- Устанавливаем transport_system_code для подразделения 9999
DO $$
DECLARE
    v_sub_id INTEGER;
BEGIN
    SELECT id INTO v_sub_id FROM subdivisions WHERE object_id = 9999;
    IF v_sub_id IS NOT NULL THEN
        UPDATE subdivisions SET transport_system_code = 'TESTPS' WHERE id = v_sub_id;
        RAISE NOTICE '[Seed Test PowerShell Node] Установлен transport_system_code=TESTPS для подразделения object_id=9999 (ID=%)', v_sub_id;
    ELSE
        RAISE WARNING '[Seed Test PowerShell Node] Подразделение object_id=9999 не найдено для установки transport_system_code.';
    END IF;
END $$;
-- =============================================================================