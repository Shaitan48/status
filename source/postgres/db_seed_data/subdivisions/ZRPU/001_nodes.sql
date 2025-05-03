-- =============================================================================
-- Файл: ZRPU/001_nodes.sql
-- Назначение: Создание примеров узлов для подразделения 'ПУ' (ObjectID: 1516).
--             Использует подзапрос для получения ID подразделения.
--             Должен выполняться ПОСЛЕ 001_create_subdivisions.sql.
-- =============================================================================
DO $$
DECLARE
    v_subdivision_id INTEGER;
BEGIN
    -- Получаем внутренний ID подразделения по его внешнему object_id
    SELECT id INTO v_subdivision_id FROM subdivisions WHERE object_id = 1516 LIMIT 1;

    -- Проверяем, найдено ли подразделение
    IF v_subdivision_id IS NULL THEN
        RAISE WARNING 'Подразделение с object_id=1516 не найдено. Узлы для ZRPU не будут добавлены.';
        RETURN;
    END IF;

    RAISE NOTICE 'Добавление узлов для подразделения ID=% (ObjectID=1516)', v_subdivision_id;

    -- Вставляем узлы, используя полученный v_subdivision_id
    -- Используем ON CONFLICT(id) DO UPDATE для идемпотентности, если запускаем повторно
    -- Или ON CONFLICT(name, parent_subdivision_id) DO UPDATE / DO NOTHING
    INSERT INTO nodes (id, name, ip_address, parent_subdivision_id, node_type_id, description) VALUES
    (39,'FCOD','1.77.2.246', v_subdivision_id, (SELECT id FROM node_types WHERE name='Каналы связи' LIMIT 1), NULL),       -- Прочее
    (34,'Ivangorod(JD)','3.47.6.4', v_subdivision_id, (SELECT id FROM node_types WHERE name='АКаналы связи)' LIMIT 1), NULL),  -- Прочее
    (35,'Ivangorod(Parusinka)','3.47.9.4', v_subdivision_id, (SELECT id FROM node_types WHERE name='Каналы связи' LIMIT 1), NULL), -- Прочее
    (36,'OTRPK(COD)','3.78.7.9', v_subdivision_id, (SELECT id FROM node_types WHERE name='Каналы связи' LIMIT 1), NULL),     -- Прочее
    (37,'Pulkovo(AVIA)','3.78.8.4', v_subdivision_id, (SELECT id FROM node_types WHERE name='Каналы связи' LIMIT 1), NULL),   -- Прочее
    (1,'SRV1','172.16.0.247', v_subdivision_id, (SELECT id FROM node_types WHERE name='Физические сервера' LIMIT 1), NULL),       -- Физические сервера
    (2,'SRV2','172.16.0.248', v_subdivision_id, (SELECT id FROM node_types WHERE name='Физические сервера' LIMIT 1), NULL),       -- Физические сервера
    (11,'SRVSEC','172.16.0.103', v_subdivision_id, (SELECT id FROM node_types WHERE name='Физические сервера' LIMIT 1), NULL),      -- Физические сервера
    (38,'UstLuga(SEA)','3.47.20.2', v_subdivision_id, (SELECT id FROM node_types WHERE name='Физические сервера' LIMIT 1), NULL),   -- Прочее
    (33,'Viborg(COD)','3.47.10.4', v_subdivision_id, (SELECT id FROM node_types WHERE name='Физические сервера' LIMIT 1), NULL),    -- Прочее
    (5,'VSRVAPP','172.16.0.251', v_subdivision_id, (SELECT id FROM node_types WHERE name='Виртуальные сервера' LIMIT 1), NULL),       -- Виртуальные сервера
    (3,'VSRVCLS','172.16.0.100', v_subdivision_id, (SELECT id FROM node_types WHERE name='Виртуальные сервера' LIMIT 1), NULL),       -- Виртуальные сервера
    (6,'VSRVDC01','172.16.0.101', v_subdivision_id, (SELECT id FROM node_types WHERE name='Виртуальные сервера' LIMIT 1), NULL),      -- Виртуальные сервера
    (7,'VSRVDC02','172.16.0.102', v_subdivision_id, (SELECT id FROM node_types WHERE name='Виртуальные сервера' LIMIT 1), NULL),      -- Виртуальные сервера
    (9,'VSRVMAIL','172.16.0.113', v_subdivision_id, (SELECT id FROM node_types WHERE name='Виртуальные сервера' LIMIT 1), NULL),      -- Виртуальные сервера
    (8,'VSRVMON1','172.16.0.111', v_subdivision_id, (SELECT id FROM node_types WHERE name='Виртуальные сервера' LIMIT 1), NULL),      -- Виртуальные сервера
    (10,'VSRVRS','172.16.0.115', v_subdivision_id, (SELECT id FROM node_types WHERE name='Виртуальные сервера' LIMIT 1), NULL),       -- Виртуальные сервера
    (4,'VSRVSQL','172.16.0.249', v_subdivision_id, (SELECT id FROM node_types WHERE name='Виртуальные сервера' LIMIT 1), NULL),       -- Виртуальные сервера
    (13,'ADMBD1','192.168.1.31', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(АДМ)' LIMIT 1), NULL),  -- АРМы(АДМ)
    (14,'ADMSEC','192.168.1.32', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(АДМ)' LIMIT 1), NULL),  -- АРМы(АДМ)
    (15,'ARMADM01','192.168.1.35', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(АДМ)' LIMIT 1), NULL),  -- АРМы(АДМ)
    (16,'ARMADM02','192.168.1.36', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(АДМ)' LIMIT 1), NULL),  -- АРМы(АДМ)
    (17,'ARMADM03','192.168.1.37', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(АДМ)' LIMIT 1), NULL),  -- АРМы(АДМ)
    (18,'ARMADM04','192.168.1.38', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(АДМ)' LIMIT 1), NULL),  -- АРМы(АДМ)
    (19,'ARMADM05','192.168.1.39', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(АДМ)' LIMIT 1), NULL),  -- АРМы(АДМ)
    (30,'ViPNet100','192.168.1.30', v_subdivision_id, (SELECT id FROM node_types WHERE name='Сетевое оборудование' LIMIT 1), NULL),   -- Каналы связи
    (12,'ViPNet(CLS)','172.16.0.21', v_subdivision_id, (SELECT id FROM node_types WHERE name='Сетевое оборудование' LIMIT 1), NULL),    -- Каналы связи
    (20,'DL01','192.168.2.101', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL),       -- Сетевое оборудование (?) - оставил ID 7 как в оригинале
    (21,'DL02','192.168.2.102', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL),
    (22,'DL03','192.168.2.103', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL),
    (23,'DL04','192.168.2.104', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL),
    (24,'DL05','192.168.2.105', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL),
    (25,'DL06','192.168.2.106', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL),
    (26,'DL07','192.168.2.107', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL),
    (27,'DL08','192.168.2.108', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL),
    (28,'DL09','192.168.2.109', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL),
    (29,'DL10','192.168.2.110', v_subdivision_id, (SELECT id FROM node_types WHERE name='АРМы(ДЛ)' LIMIT 1), NULL)
    -- Используем ON CONFLICT (id) для обновления существующих записей при повторном запуске.
    -- Это сохраняет существующие ID узлов, что может быть важно.
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        ip_address = EXCLUDED.ip_address,
        parent_subdivision_id = EXCLUDED.parent_subdivision_id,
        node_type_id = EXCLUDED.node_type_id,
        description = EXCLUDED.description;

    -- Обновляем последовательность nodes_id_seq
    PERFORM setval(pg_get_serial_sequence('nodes', 'id'), COALESCE(max(id), 1)) FROM nodes;

END $$;