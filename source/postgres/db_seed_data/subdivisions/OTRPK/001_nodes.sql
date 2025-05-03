-- =============================================================================
-- Файл: OTRPK/001_nodes.sql
-- Назначение: Создание узлов мониторинга для подразделения 'ОТРПК' (ObjectID: 1060).
--             Должен выполняться ПОСЛЕ 001_create_subdivisions.sql.
-- Версия: 1.0
-- =============================================================================

DO $$
DECLARE
    v_subdivision_id INTEGER; -- Внутренний ID подразделения ОТРПК
    -- Переменные для хранения ID типов узлов
    v_type_server_vm INTEGER;
    v_type_arm_opk INTEGER;
    v_type_network INTEGER;
    v_type_link INTEGER;
    v_type_other INTEGER;
BEGIN
    -- 1. Получаем внутренний ID подразделения ОТРПК по его внешнему object_id
    SELECT id INTO v_subdivision_id
    FROM subdivisions
    WHERE object_id = 1060
    LIMIT 1;

    -- Проверяем, найдено ли подразделение
    IF v_subdivision_id IS NULL THEN
        RAISE WARNING '[Seed OTRPK Nodes] Подразделение с object_id=1060 (ОТРПК) не найдено. Узлы не будут добавлены.';
        RETURN; -- Выход из блока DO, если подразделения нет
    END IF;

    RAISE NOTICE '[Seed OTRPK Nodes] Добавление узлов для подразделения ID=% (ОТРПК)', v_subdivision_id;

    -- 2. Получаем ID необходимых типов узлов по их именам
    --    (Предполагаем, что базовые типы уже созданы скриптом db_core_data/004_node_types.sql)
    SELECT id INTO v_type_server_vm FROM node_types WHERE name = 'Виртуальные сервера' LIMIT 1;
    SELECT id INTO v_type_arm_opk FROM node_types WHERE name = 'АРМы(ОПК)' LIMIT 1;
    SELECT id INTO v_type_network FROM node_types WHERE name = 'Сетевое оборудование' LIMIT 1;
    SELECT id INTO v_type_link FROM node_types WHERE name = 'Каналы связи' LIMIT 1;
    SELECT id INTO v_type_other FROM node_types WHERE name = 'Прочее оборудование' LIMIT 1; -- На случай, если что-то не подойдет

    -- Проверка, что все типы найдены (опционально, но полезно для отладки)
    IF v_type_server_vm IS NULL OR v_type_arm_opk IS NULL OR v_type_network IS NULL OR v_type_link IS NULL THEN
        RAISE WARNING '[Seed OTRPK Nodes] Не найден ID для одного или нескольких типов узлов (Виртуальные сервера, АРМы(ОПК), Сетевое оборудование, Каналы связи). Проверьте скрипт 004_node_types.sql.';
        -- Не прерываем выполнение, попробуем использовать базовый тип или Прочее
    END IF;

    -- 3. Вставляем узлы для ОТРПК
    --    Используем ON CONFLICT для идемпотентности: если узел с таким именем
    --    в этом подразделении уже есть, он будет обновлен.
    INSERT INTO nodes (name, ip_address, parent_subdivision_id, node_type_id, description) VALUES
    -- Серверы
    ('OTRPK-SRV-APP01', '10.10.60.10', v_subdivision_id, COALESCE(v_type_server_vm, 0), 'Сервер приложений ОТРПК (ВМ)'),
    ('OTRPK-SRV-DB01', '10.10.60.11', v_subdivision_id, COALESCE(v_type_server_vm, 0), 'Сервер БД ОТРПК (ВМ)'),
    -- АРМы Операторов
    ('OTRPK-ARM-OPK-01', '10.10.60.101', v_subdivision_id, COALESCE(v_type_arm_opk, 0), 'АРМ оператора ОТРПК 1'),
    ('OTRPK-ARM-OPK-02', '10.10.60.102', v_subdivision_id, COALESCE(v_type_arm_opk, 0), 'АРМ оператора ОТРПК 2'),
    ('OTRPK-ARM-OPK-03', '10.10.60.103', v_subdivision_id, COALESCE(v_type_arm_opk, 0), 'АРМ оператора ОТРПК 3'),
    -- Сетевое оборудование
    ('OTRPK-SW-CORE', '10.10.60.1', v_subdivision_id, COALESCE(v_type_network, 0), 'Коммутатор ядра ОТРПК'),
    ('OTRPK-ROUTER', '10.10.60.254', v_subdivision_id, COALESCE(v_type_network, 0), 'Маршрутизатор ОТРПК'),
    -- Каналы связи (как узлы)
    ('OTRPK-Link-FCOD', '3.78.7.9', v_subdivision_id, COALESCE(v_type_link, 0), 'Канал связи ОТРПК - ФЦОД (ViPNet координатор?)'),
    ('OTRPK-Link-ZRPU', '10.10.60.250', v_subdivision_id, COALESCE(v_type_link, 0), 'Канал связи ОТРПК - ЗРПУ (ViPNet координатор?)')
    -- Добавьте другие узлы по необходимости
    ON CONFLICT (name, parent_subdivision_id) DO UPDATE SET
        ip_address = EXCLUDED.ip_address,
        node_type_id = EXCLUDED.node_type_id,
        description = EXCLUDED.description;

    -- Обновляем счетчик последовательности nodes_id_seq
    -- Это важно, если вставка вызвала конфликты и не все ID были сгенерированы последовательно
    PERFORM setval(pg_get_serial_sequence('nodes', 'id'), COALESCE(max(id), 1)) FROM nodes;

    RAISE NOTICE '[Seed OTRPK Nodes] Узлы для ОТРПК добавлены/обновлены.';

END $$;
-- =============================================================================
-- == КОНЕЦ СОЗДАНИЯ УЗЛОВ ДЛЯ ОТРПК ==
-- =============================================================================