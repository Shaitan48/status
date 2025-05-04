-- =============================================================================
-- Файл: 002_create_indexes.sql
-- Назначение: Создание всех необходимых индексов для таблиц.
--             Включает индексы для первичных и внешних ключей (если они не
--             создаются автоматически), уникальные индексы (повторно, для
--             полноты картины, хотя они создаются с UNIQUE CONSTRAINT) и
--             индексы для оптимизации запросов (WHERE, JOIN, ORDER BY).
-- Версия схемы: ~4.3.0
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: subdivisions
-- -----------------------------------------------------------------------------
-- Индекс для внешнего ключа parent_id (ускоряет поиск дочерних элементов и JOIN'ы по иерархии).
CREATE INDEX IF NOT EXISTS idx_subdivisions_parent_id ON subdivisions(parent_id);
COMMENT ON INDEX idx_subdivisions_parent_id IS 'Ускоряет поиск дочерних подразделений и построение иерархии.';

-- Индекс для сортировки по приоритету и имени (используется в UI и функциях).
CREATE INDEX IF NOT EXISTS idx_subdivisions_priority_name ON subdivisions(priority, short_name);
COMMENT ON INDEX idx_subdivisions_priority_name IS 'Оптимизирует сортировку списка подразделений по приоритету и имени.';

-- Уникальный индекс для transport_system_code (только для не-NULL значений)
-- Именно этот индекс реализует требование уникальности только для заданных кодов.
CREATE UNIQUE INDEX IF NOT EXISTS idx_subdivisions_unique_transport_code_not_null
    ON subdivisions (transport_system_code)
    WHERE transport_system_code IS NOT NULL;
COMMENT ON INDEX idx_subdivisions_unique_transport_code_not_null
    IS 'Обеспечивает уникальность transport_system_code, если он указан (не NULL). Реализует частичное ограничение уникальности.';

-- Уникальный индекс для object_id (создается автоматически с UNIQUE CONSTRAINT, но дублируем для ясности).
-- CREATE UNIQUE INDEX IF NOT EXISTS idx_subdivisions_object_id ON subdivisions(object_id);
-- COMMENT ON INDEX idx_subdivisions_object_id IS 'Обеспечивает уникальность внешнего ID подразделения.';

-- Уникальный индекс для transport_system_code (создается автоматически с UNIQUE CONSTRAINT).
-- CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_transport_code ON subdivisions (transport_system_code) WHERE transport_system_code IS NOT NULL;
-- COMMENT ON INDEX idx_unique_transport_code IS 'Обеспечивает уникальность кода транспортной системы (если он не NULL).';

CREATE INDEX idx_users_username ON users(username);

CREATE INDEX idx_api_keys_role ON api_keys(role);
CREATE INDEX idx_api_keys_object_id ON api_keys(object_id);
CREATE INDEX idx_api_keys_is_active ON api_keys(is_active);
COMMENT ON INDEX idx_api_keys_role IS 'Оптимизирует выборку по роли в таблице api_keys.';
COMMENT ON INDEX idx_api_keys_object_id IS 'Оптимизирует выборку по объекту в таблице api_keys.';
COMMENT ON INDEX idx_api_keys_is_active IS 'Оптимизирует выборку активных ключей в таблице api_keys.';

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: check_methods
-- -----------------------------------------------------------------------------
-- Уникальный индекс для method_name (создается автоматически с UNIQUE CONSTRAINT).
-- CREATE UNIQUE INDEX IF NOT EXISTS idx_check_methods_method_name ON check_methods(method_name);
-- COMMENT ON INDEX idx_check_methods_method_name IS 'Обеспечивает уникальность имен методов проверки.';

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: node_types
-- -----------------------------------------------------------------------------
-- Индекс для внешнего ключа parent_type_id (ускоряет построение иерархии типов).
CREATE INDEX IF NOT EXISTS idx_node_types_parent ON node_types(parent_type_id);
COMMENT ON INDEX idx_node_types_parent IS 'Ускоряет поиск дочерних типов узлов и построение иерархии.';

-- Индекс для сортировки (используется при выводе списка типов).
CREATE INDEX IF NOT EXISTS idx_node_types_priority_name ON node_types(priority, name);
COMMENT ON INDEX idx_node_types_priority_name IS 'Оптимизирует сортировку списка типов узлов по приоритету и имени.';

-- Индекс для уникальности имен В ПРЕДЕЛАХ ОДНОГО РОДИТЕЛЯ (когда родитель НЕ NULL)
CREATE UNIQUE INDEX IF NOT EXISTS idx_node_types_unique_name_parent_not_null
    ON node_types (name, parent_type_id)
    WHERE parent_type_id IS NOT NULL;
COMMENT ON INDEX idx_node_types_unique_name_parent_not_null
    IS 'Обеспечивает уникальность имени типа узла внутри одного родительского типа.';

-- Индекс для уникальности имен КОРНЕВЫХ типов (когда родитель NULL)
CREATE UNIQUE INDEX IF NOT EXISTS idx_node_types_unique_name_parent_is_null
    ON node_types (name) -- Индекс только по имени
    WHERE parent_type_id IS NULL; -- Но только для строк, где родитель NULL
COMMENT ON INDEX idx_node_types_unique_name_parent_is_null
    IS 'Обеспечивает уникальность имени типа узла среди корневых типов (без родителя).';

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: node_property_types
-- -----------------------------------------------------------------------------
-- Уникальный индекс для name (создается автоматически с UNIQUE CONSTRAINT).
-- CREATE UNIQUE INDEX IF NOT EXISTS idx_node_property_types_name ON node_property_types(name);
-- COMMENT ON INDEX idx_node_property_types_name IS 'Обеспечивает уникальность имен типов свойств.';

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: node_properties
-- -----------------------------------------------------------------------------
-- Индекс для внешнего ключа node_type_id (ускоряет поиск свойств для конкретного типа узла).
CREATE INDEX IF NOT EXISTS idx_node_properties_node_type ON node_properties(node_type_id);
COMMENT ON INDEX idx_node_properties_node_type IS 'Ускоряет выборку свойств для заданного типа узла.';

-- Индекс для внешнего ключа property_type_id (может быть полезен для поиска всех значений конкретного свойства).
CREATE INDEX IF NOT EXISTS idx_node_properties_property_type ON node_properties(property_type_id);
COMMENT ON INDEX idx_node_properties_property_type IS 'Ускоряет поиск значений определенного типа свойства по всем типам узлов.';

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: nodes
-- -----------------------------------------------------------------------------
-- Индекс для внешнего ключа parent_subdivision_id (ускоряет поиск узлов в подразделении и JOIN с subdivisions).
CREATE INDEX IF NOT EXISTS idx_nodes_parent_subdivision ON nodes(parent_subdivision_id);
COMMENT ON INDEX idx_nodes_parent_subdivision IS 'Оптимизирует выборку узлов для конкретного подразделения и JOIN с таблицей subdivisions.';

-- Индекс для внешнего ключа node_type_id (ускоряет поиск узлов определенного типа и JOIN с node_types).
CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(node_type_id);
COMMENT ON INDEX idx_nodes_type IS 'Оптимизирует выборку узлов по их типу и JOIN с таблицей node_types.';

-- Индекс для поиска по имени узла.
CREATE INDEX IF NOT EXISTS idx_nodes_name ON nodes(name);
COMMENT ON INDEX idx_nodes_name IS 'Ускоряет поиск узлов по имени (например, в UI управления).';
-- CREATE INDEX IF NOT EXISTS idx_nodes_name_trgm ON nodes USING gin (name gin_trgm_ops); -- Для ILIKE поиска, если расширение pg_trgm установлено

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: node_check_assignments
-- -----------------------------------------------------------------------------
-- Индекс для внешнего ключа node_id (ускоряет поиск заданий для конкретного узла).
CREATE INDEX IF NOT EXISTS idx_node_check_assignments_node ON node_check_assignments(node_id);
COMMENT ON INDEX idx_node_check_assignments_node IS 'Ускоряет поиск всех заданий, назначенных конкретному узлу.';

-- Индекс для внешнего ключа method_id (ускоряет поиск заданий по методу проверки).
CREATE INDEX IF NOT EXISTS idx_node_check_assignments_method ON node_check_assignments(method_id);
COMMENT ON INDEX idx_node_check_assignments_method IS 'Ускоряет поиск заданий, использующих определенный метод проверки.';

-- Индекс по флагу is_enabled (используется при выборке активных заданий для агентов).
CREATE INDEX IF NOT EXISTS idx_node_check_assignments_enabled ON node_check_assignments(is_enabled);
COMMENT ON INDEX idx_node_check_assignments_enabled IS 'Оптимизирует выборку активных (is_enabled = TRUE) заданий.';

-- GIN-индекс для поля parameters (JSONB) для возможности поиска по содержимому JSON.
CREATE INDEX IF NOT EXISTS idx_node_check_assignments_params ON node_check_assignments USING gin (parameters);
COMMENT ON INDEX idx_node_check_assignments_params IS 'Позволяет эффективно искать задания по содержимому поля parameters (JSONB).';

-- Индекс для внешнего ключа last_node_check_id (ускоряет JOIN с node_checks для получения последнего статуса).
CREATE INDEX IF NOT EXISTS idx_node_check_assignments_last_check ON node_check_assignments(last_node_check_id);
COMMENT ON INDEX idx_node_check_assignments_last_check IS 'Ускоряет JOIN с таблицей node_checks для получения последнего результата проверки по заданию.';

-- GIN-индекс для поля success_criteria (JSONB).
CREATE INDEX IF NOT EXISTS idx_node_check_assignments_criteria ON node_check_assignments USING gin (success_criteria);
COMMENT ON INDEX idx_node_check_assignments_criteria IS 'Позволяет эффективно искать задания по содержимому поля success_criteria (JSONB).';

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: node_checks
-- -----------------------------------------------------------------------------
-- Составной индекс для поиска истории проверок конкретного узла, отсортированной по времени.
CREATE INDEX IF NOT EXISTS idx_node_checks_node_id_checked_at ON node_checks(node_id, checked_at DESC);
COMMENT ON INDEX idx_node_checks_node_id_checked_at IS 'Оптимизирует выборку истории проверок для конкретного узла с сортировкой по времени.';

-- Индекс для внешнего ключа assignment_id (ускоряет поиск истории проверок по конкретному заданию).
CREATE INDEX IF NOT EXISTS idx_node_checks_assignment_id ON node_checks(assignment_id);
COMMENT ON INDEX idx_node_checks_assignment_id IS 'Ускоряет поиск всех результатов проверок, выполненных по конкретному заданию.';

-- Индекс для внешнего ключа method_id (ускоряет поиск истории проверок по методу).
CREATE INDEX IF NOT EXISTS idx_node_checks_method_id ON node_checks(method_id);
COMMENT ON INDEX idx_node_checks_method_id IS 'Ускоряет поиск всех результатов проверок, выполненных определенным методом.';

-- Индекс по времени получения результата (для общей сортировки и выборки последних проверок).
CREATE INDEX IF NOT EXISTS idx_node_checks_checked_at ON node_checks(checked_at DESC);
COMMENT ON INDEX idx_node_checks_checked_at IS 'Оптимизирует сортировку и выборку последних результатов проверок по всему множеству узлов.';

-- Индекс по времени проверки на агенте (если часто фильтруется/сортируется по нему).
CREATE INDEX IF NOT EXISTS idx_node_checks_check_timestamp ON node_checks(check_timestamp DESC NULLS LAST);
COMMENT ON INDEX idx_node_checks_check_timestamp IS 'Оптимизирует фильтрацию/сортировку по времени проверки на агенте.';

-- Индексы по версиям (если часто ищут результаты по конкретной версии конфига/скрипта).
CREATE INDEX IF NOT EXISTS idx_node_checks_assignment_config_version ON node_checks(assignment_config_version);
COMMENT ON INDEX idx_node_checks_assignment_config_version IS 'Ускоряет поиск результатов, полученных с определенной версией конфигурации заданий.';
CREATE INDEX IF NOT EXISTS idx_node_checks_agent_script_version ON node_checks(agent_script_version);
COMMENT ON INDEX idx_node_checks_agent_script_version IS 'Ускоряет поиск результатов, полученных с определенной версией скрипта агента.';

-- Индекс для предотвращения дублирования базовых заданий (без параметров и критериев) для одного узла и метода
CREATE UNIQUE INDEX IF NOT EXISTS idx_assignment_unique_basic
    ON node_check_assignments (node_id, method_id)
    WHERE parameters IS NULL AND success_criteria IS NULL;
COMMENT ON INDEX idx_assignment_unique_basic IS 'Обеспечивает уникальность базовых назначений (без JSON-параметров/критериев) для пары узел+метод.';

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: node_check_details
-- -----------------------------------------------------------------------------
-- Индекс для внешнего ключа node_check_id (ускоряет поиск деталей для конкретного результата проверки).
CREATE INDEX IF NOT EXISTS idx_node_check_details_node_check_id ON node_check_details(node_check_id);
COMMENT ON INDEX idx_node_check_details_node_check_id IS 'Обязателен для быстрого поиска деталей, относящихся к конкретному результату проверки (JOIN с node_checks).';

-- Индекс по типу детализации (если часто ищут детали определенного типа).
CREATE INDEX IF NOT EXISTS idx_node_check_details_type ON node_check_details(detail_type);
COMMENT ON INDEX idx_node_check_details_type IS 'Может быть полезен для выборки всех деталей определенного типа (например, всех KASPERSKY_STATUS).';

-- GIN-индекс для поля data (JSONB) для поиска по содержимому деталей.
CREATE INDEX IF NOT EXISTS idx_node_check_details_data ON node_check_details USING gin (data);
COMMENT ON INDEX idx_node_check_details_data IS 'Позволяет эффективно искать записи по содержимому поля data (JSONB), например, найти все проверки, где статус KES был "Ошибка".';

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: system_events
-- -----------------------------------------------------------------------------
-- Индекс по времени события (основной для просмотра лога).
CREATE INDEX IF NOT EXISTS idx_system_events_event_time ON system_events(event_time DESC);
COMMENT ON INDEX idx_system_events_event_time IS 'Основной индекс для отображения и фильтрации системных событий по времени.';

-- Индекс по типу события (для фильтрации).
CREATE INDEX IF NOT EXISTS idx_system_events_event_type ON system_events(event_type);
COMMENT ON INDEX idx_system_events_event_type IS 'Ускоряет фильтрацию системных событий по их типу.';

-- Индекс по уровню важности (для фильтрации).
CREATE INDEX IF NOT EXISTS idx_system_events_severity ON system_events(severity);
COMMENT ON INDEX idx_system_events_severity IS 'Ускоряет фильтрацию системных событий по уровню важности.';

-- Индекс по ID объекта (для фильтрации событий, связанных с подразделением).
CREATE INDEX IF NOT EXISTS idx_system_events_object_id ON system_events(object_id);
COMMENT ON INDEX idx_system_events_object_id IS 'Ускоряет поиск событий, относящихся к конкретному объекту/подразделению.';

-- Индекс по ID узла (для фильтрации событий, связанных с узлом).
CREATE INDEX IF NOT EXISTS idx_system_events_node_id ON system_events(node_id);
COMMENT ON INDEX idx_system_events_node_id IS 'Ускоряет поиск событий, относящихся к конкретному узлу.';

-- Индекс по ID задания (для фильтрации событий, связанных с заданием).
CREATE INDEX IF NOT EXISTS idx_system_events_assignment_id ON system_events(assignment_id);
COMMENT ON INDEX idx_system_events_assignment_id IS 'Ускоряет поиск событий, относящихся к конкретному заданию.';

-- Индекс по ID результата проверки (для фильтрации событий, связанных с проверкой).
CREATE INDEX IF NOT EXISTS idx_system_events_node_check_id ON system_events(node_check_id);
COMMENT ON INDEX idx_system_events_node_check_id IS 'Ускоряет поиск событий, относящихся к конкретному результату проверки.';

-- Составной индекс по связанной сущности (для фильтрации, например, по файлам).
CREATE INDEX IF NOT EXISTS idx_system_events_related ON system_events(related_entity, related_entity_id);
COMMENT ON INDEX idx_system_events_related IS 'Ускоряет поиск событий, связанных с определенной сущностью (например, файлом).';

-- GIN-индекс для поля details (JSONB) для поиска по содержимому деталей события.
CREATE INDEX IF NOT EXISTS idx_system_events_details_gin ON system_events USING gin (details);
COMMENT ON INDEX idx_system_events_details_gin IS 'Позволяет эффективно искать события по содержимому поля details (JSONB).';

-- -----------------------------------------------------------------------------
-- Индексы для таблицы: offline_config_versions
-- -----------------------------------------------------------------------------
-- Индекс для поиска последней активной версии заданий для объекта.
CREATE INDEX IF NOT EXISTS idx_offline_config_last_active_obj
    ON offline_config_versions (object_id, config_type, created_at DESC)
    WHERE is_active = TRUE AND config_type = 'assignments'; -- Уточнили тип
COMMENT ON INDEX idx_offline_config_last_active_obj IS 'Оптимизирует поиск последней активной версии ЗАДАНИЙ для конкретного объекта.';

-- Индекс для поиска последней активной версии скрипта (object_id IS NULL).
CREATE INDEX IF NOT EXISTS idx_offline_config_last_active_script
    ON offline_config_versions (config_type, created_at DESC)
    WHERE is_active = TRUE AND object_id IS NULL AND config_type = 'script'; -- Уточнили тип и NULL
COMMENT ON INDEX idx_offline_config_last_active_script IS 'Оптимизирует поиск последней активной версии СКРИПТА агента.';

-- Уникальный индекс для version_tag (создается автоматически с UNIQUE CONSTRAINT).
-- CREATE UNIQUE INDEX IF NOT EXISTS idx_offline_config_versions_version_tag ON offline_config_versions(version_tag);
-- COMMENT ON INDEX idx_offline_config_versions_version_tag IS 'Обеспечивает уникальность тегов версий конфигураций.';

-- =============================================================================
-- == КОНЕЦ СОЗДАНИЯ ИНДЕКСОВ ==
-- =============================================================================