-- =============================================================================
-- Файл: 004_node_types.sql
-- Назначение: Заполнение таблицы node_types базовыми типами узлов.
--             ID генерируются автоматически. Используется ON CONFLICT по имени/родителю.
-- =============================================================================

-- Комментарий: Создание базового типа с ID 0. Он особенный, ID фиксирован.
INSERT INTO node_types (id, name, description, parent_type_id, priority, icon_filename) VALUES
(0, '_БазовыйТип', 'Тип по умолчанию, если не указан', NULL, 9999, 'other.svg')
ON CONFLICT (id) DO UPDATE SET -- Обновляем все поля, если запись с ID 0 уже есть
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    parent_type_id = EXCLUDED.parent_type_id,
    priority = EXCLUDED.priority,
    icon_filename = EXCLUDED.icon_filename;

-- Комментарий: Создание корневых категорий типов узлов. ID генерируются.
INSERT INTO node_types (name, description, parent_type_id, priority, icon_filename) VALUES
('Сервера', 'Серверное оборудование', NULL, 10, 'server.svg'),
('АРМы', 'Автоматизированные рабочие места', NULL, 20, 'workstation.svg'),
('Сетевое оборудование', 'Сетевая инфраструктура', NULL, 30, 'network.svg'),
('Прочее оборудование', 'Дополнительное оборудование', NULL, 40, 'chip.svg')
-- Конфликт по имени и отсутствию родителя (parent_type_id IS NULL)
ON CONFLICT (name) WHERE parent_type_id IS NULL DO UPDATE SET
    description = EXCLUDED.description,
    priority = EXCLUDED.priority,
    icon_filename = EXCLUDED.icon_filename;

-- Комментарий: Добавление некоторых дочерних типов. ID генерируются.
INSERT INTO node_types (name, description, parent_type_id, priority, icon_filename) VALUES
('Физические сервера', 'Физические серверы', (SELECT id FROM node_types WHERE name='Сервера' AND parent_type_id IS NULL LIMIT 1), 5, 'server-physical.svg'),
('Виртуальные сервера', 'Виртуальные машины', (SELECT id FROM node_types WHERE name='Сервера' AND parent_type_id IS NULL LIMIT 1), 15, 'server-vm.svg'),
('АРМы(АДМ)', 'АРМ администраторов', (SELECT id FROM node_types WHERE name='АРМы' AND parent_type_id IS NULL LIMIT 1), 10, 'workstation-admin.svg'),
('АРМы(ДЛ)', 'АРМ должностных лиц', (SELECT id FROM node_types WHERE name='АРМы' AND parent_type_id IS NULL LIMIT 1), 20, 'workstation.svg'),
('АРМы(ОПК)', 'АРМ операторов', (SELECT id FROM node_types WHERE name='АРМы' AND parent_type_id IS NULL LIMIT 1), 20, 'workstation.svg')
-- Конфликт по имени и ID родителя
ON CONFLICT (name, parent_type_id) WHERE parent_type_id IS NOT NULL DO UPDATE SET
    description = EXCLUDED.description,
    priority = EXCLUDED.priority,
    icon_filename = EXCLUDED.icon_filename;

-- ===>>> НАЧАЛО ИЗМЕНЕНИЯ <<<===
-- Комментарий: Добавляем тип для каналов связи. ID генерируется.
INSERT INTO node_types (name, description, parent_type_id, priority, icon_filename) VALUES
('Каналы связи', 'Сетевые каналы (ViPNet и т.п.)', (SELECT id FROM node_types WHERE name='Сетевое оборудование' AND parent_type_id IS NULL LIMIT 1), 15, 'link.svg') -- Указали родителя ID=7 по имени
-- Конфликт по имени и ID родителя
ON CONFLICT (name, parent_type_id) WHERE parent_type_id IS NOT NULL DO UPDATE SET
    description = EXCLUDED.description,
    priority = EXCLUDED.priority,
    icon_filename = EXCLUDED.icon_filename;
-- ===>>> КОНЕЦ ИЗМЕНЕНИЯ <<<===

-- Сброс последовательности до максимального ID, который был вставлен или обновлен.
-- Важно делать это в конце, после всех вставок в этом файле.
SELECT setval(pg_get_serial_sequence('node_types', 'id'), COALESCE(max(id), 1)) FROM node_types;

-- =============================================================================
-- == КОНЕЦ ЗАПОЛНЕНИЯ node_types ==
-- =============================================================================