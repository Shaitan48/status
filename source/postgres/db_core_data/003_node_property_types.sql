-- =============================================================================
-- Файл: 003_node_property_types.sql
-- Назначение: Заполнение справочника типов настраиваемых свойств узлов
--             (node_property_types).
--             Использует ON CONFLICT DO NOTHING, так как описание не так важно.
-- =============================================================================

-- Комментарий: Таймаут в минутах, после которого PING-статус считается устаревшим (warning).
INSERT INTO node_property_types (name, description) VALUES
('timeout_minutes', 'Таймаут (мин) для статуса PING warning')
ON CONFLICT (name) DO NOTHING;

-- Комментарий: Числовой приоритет для сортировки узлов одного типа внутри группы.
INSERT INTO node_property_types (name, description) VALUES
('display_order', 'Порядок отображения узла в группе')
ON CONFLICT (name) DO NOTHING;

-- Комментарий: Цвет иконки узла в формате HEX (например, '#ff0000'). Используется для визуализации на дашборде.
INSERT INTO node_property_types (name, description) VALUES
('icon_color', 'Цвет иконки узла в dashboard (hex)')
ON CONFLICT (name) DO NOTHING;

-- Комментарий: Имя критичной службы, специфичной для данного типа узла (например, 'wuauserv' для АРМов). Может использоваться для автоматического назначения проверок SERVICE_STATUS.
INSERT INTO node_property_types (name, description) VALUES
('critical_service_name', 'Имя критичной службы для этого типа узла')
ON CONFLICT (name) DO NOTHING;

-- Сброс последовательности (если нужно)
-- SELECT setval(pg_get_serial_sequence('node_property_types', 'id'), COALESCE(max(id), 1)) FROM node_property_types;

-- =============================================================================
-- == КОНЕЦ ЗАПОЛНЕНИЯ node_property_types ==
-- =============================================================================