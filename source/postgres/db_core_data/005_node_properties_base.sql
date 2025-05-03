-- =============================================================================
-- Файл: 005_node_properties_base.sql
-- Назначение: Заполнение таблицы node_properties значениями по умолчанию
--             для базового типа узла (ID=0).
--             Использует ON CONFLICT DO UPDATE для идемпотентности.
-- =============================================================================

-- Комментарий: Установка таймаута PING по умолчанию (5 минут) для базового типа.
INSERT INTO node_properties (node_type_id, property_type_id, property_value) VALUES
(0, (SELECT id FROM node_property_types WHERE name='timeout_minutes' LIMIT 1), '5')
ON CONFLICT (node_type_id, property_type_id) DO UPDATE SET property_value = EXCLUDED.property_value;

-- Комментарий: Установка порядка отображения по умолчанию (999 - в конце) для базового типа.
INSERT INTO node_properties (node_type_id, property_type_id, property_value) VALUES
(0, (SELECT id FROM node_property_types WHERE name='display_order' LIMIT 1), '999')
ON CONFLICT (node_type_id, property_type_id) DO UPDATE SET property_value = EXCLUDED.property_value;

-- Комментарий: Установка цвета иконки по умолчанию (серый) для базового типа.
INSERT INTO node_properties (node_type_id, property_type_id, property_value) VALUES
(0, (SELECT id FROM node_property_types WHERE name='icon_color' LIMIT 1), '#95a5a6')
ON CONFLICT (node_type_id, property_type_id) DO UPDATE SET property_value = EXCLUDED.property_value;

-- =============================================================================
-- == КОНЕЦ ЗАПОЛНЕНИЯ node_properties ДЛЯ БАЗОВОГО ТИПА ==
-- =============================================================================