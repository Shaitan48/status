-- =============================================================================
-- Файл: OTRPK/002_assignments.sql
-- Назначение: Создание заданий PING для узлов подразделения 'ОТРПК' (ObjectID: 1060).
--             Должен выполняться ПОСЛЕ OTRPK/001_nodes.sql.
-- Версия: 1.0
-- =============================================================================
DO $$
DECLARE
    v_subdivision_id INTEGER; -- Внутренний ID ОТРПК
    v_ping_method_id INTEGER; -- ID метода PING
    v_node_record RECORD;     -- Для итерации по узлам
BEGIN
    -- 1. Получаем ID подразделения ОТРПК
    SELECT id INTO v_subdivision_id FROM subdivisions WHERE object_id = 1060 LIMIT 1;

    -- 2. Получаем ID метода PING
    SELECT id INTO v_ping_method_id FROM check_methods WHERE method_name = 'PING' LIMIT 1;

    -- Проверяем, что все найдено
    IF v_subdivision_id IS NULL OR v_ping_method_id IS NULL THEN
        RAISE WARNING '[Seed OTRPK Assignments] Подразделение ОТРПК (1060) или метод PING не найдены. Задания PING не будут добавлены.';
        RETURN; -- Выходим, если что-то не найдено
    END IF;

    RAISE NOTICE '[Seed OTRPK Assignments] Добавление PING заданий для узлов подразделения ID=% (ОТРПК)', v_subdivision_id;

    -- 3. Добавляем PING задания для ВСЕХ узлов этого подразделения,
    --    у которых есть IP-адрес.
    FOR v_node_record IN
        SELECT id, name FROM nodes
        WHERE parent_subdivision_id = v_subdivision_id AND ip_address IS NOT NULL
    LOOP
        -- Пытаемся вставить задание
        INSERT INTO node_check_assignments (
            node_id,
            method_id,
            is_enabled,
            check_interval_seconds,
            description,
            success_criteria,
            parameters
        ) VALUES (
            v_node_record.id,         -- ID текущего узла из цикла
            v_ping_method_id,         -- ID метода PING
            TRUE,                     -- Задание включено
            120,                      -- Интервал проверки (120 секунд)
            'Авто-назначение PING для ОТРПК', -- Описание
            NULL,                     -- Критерии успеха (пока нет)
            NULL                      -- Параметры (для PING пока нет)
        )
        -- Если базовое задание PING (без параметров/критериев) для этого узла уже существует,
        -- ничего не делаем (DO NOTHING), чтобы избежать дубликатов.
        ON CONFLICT (node_id, method_id) WHERE parameters IS NULL AND success_criteria IS NULL DO NOTHING;

        -- Логируем (опционально)
        -- RAISE NOTICE '[Seed OTRPK Assignments]   -> Добавлено/Пропущено PING задание для узла % (ID: %)', v_node_record.name, v_node_record.id;

    END LOOP;

    -- Обновляем счетчик последовательности node_check_assignments_id_seq
    PERFORM setval(pg_get_serial_sequence('node_check_assignments', 'id'), COALESCE(max(id), 1)) FROM node_check_assignments;

    RAISE NOTICE '[Seed OTRPK Assignments] Задания PING для узлов ОТРПК добавлены/обновлены.';

END $$;
-- =============================================================================
-- == КОНЕЦ СОЗДАНИЯ ЗАДАНИЙ ДЛЯ ОТРПК ==
-- =============================================================================