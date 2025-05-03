-- =============================================================================
-- Файл: 001_create_subdivisions.sql
-- Назначение: Создание основных записей подразделений.
--             Этот скрипт должен выполняться ПОСЛЕ создания схемы и ДО
--             заполнения узлов/заданий, зависящих от этих подразделений.
--             Использует ON CONFLICT DO UPDATE для идемпотентности.
-- =============================================================================

-- Комментарий: Создание корневых подразделений (ФЦОД и ПУ).
INSERT INTO subdivisions (id, object_id, short_name, parent_id, domain_name, priority, full_name, transport_system_code, comment, icon_filename) VALUES
-- ID 6 было в исходных данных, сохраняем для консистентности, если на него были ссылки
(2, 6, 'ФЦОД', NULL, 'zFCD', 10, NULL, 'FCD', NULL, NULL),
(1, 1516, 'ПУ', NULL, 'zRPU', 1, NULL, 'RPU', NULL, NULL)
ON CONFLICT (id) DO UPDATE SET -- Обновляем запись, если ID уже существует
    object_id=EXCLUDED.object_id, short_name=EXCLUDED.short_name, parent_id=EXCLUDED.parent_id, domain_name=EXCLUDED.domain_name, priority=EXCLUDED.priority, full_name=EXCLUDED.full_name, transport_system_code=EXCLUDED.transport_system_code, comment=EXCLUDED.comment, icon_filename=EXCLUDED.icon_filename;

-- Комментарий: Создание дочерних подразделений для 'ПУ' (ID=2).
INSERT INTO subdivisions (id, object_id, short_name, parent_id, domain_name, priority, full_name, transport_system_code, comment, icon_filename) VALUES
(7, 1060, 'ОТРПК', 1, 'zTSP', 10, NULL, 'TSP', NULL, NULL),         -- <<< Добавил transport_system_code
(13, 1000001, 'Пулково(АВИА)', 7, 'pp', 10, NULL, 'PLC', NULL, NULL), -- <<< Добавил transport_system_code (пример)
(8, 1061, 'Выборг', 1, 'pp', 15, NULL, 'TPV', NULL, NULL),            -- <<< Добавил transport_system_code
(10, 39, 'Ивангород(ЖД)', 1, 'pp', 20, NULL, '027', NULL, NULL),      -- <<< Добавил transport_system_code
(11, 792, 'Ивангород(ПАРУСИНКА)', 1, 'pp', 20, NULL, '029', NULL, NULL), -- <<< Добавил transport_system_code
(12, 38, 'Усть-Луга(МОРЕ)', 1, 'zUST', 20, NULL, '026', NULL, NULL)    -- <<< Добавил transport_system_code
ON CONFLICT (id) DO UPDATE SET
    object_id=EXCLUDED.object_id, short_name=EXCLUDED.short_name, parent_id=EXCLUDED.parent_id, domain_name=EXCLUDED.domain_name, priority=EXCLUDED.priority, full_name=EXCLUDED.full_name, transport_system_code=EXCLUDED.transport_system_code, comment=EXCLUDED.comment, icon_filename=EXCLUDED.icon_filename;

-- Сброс последовательности до максимального использованного ID.
SELECT setval(pg_get_serial_sequence('subdivisions', 'id'), COALESCE(max(id), 1)) FROM subdivisions;

-- =============================================================================
-- == КОНЕЦ СОЗДАНИЯ ПОДРАЗДЕЛЕНИЙ ==
-- =============================================================================