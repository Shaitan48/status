-- =============================================================================
-- Файл: 005_add_foreign_keys.sql
-- Назначение: Добавление всех ограничений внешних ключей (FOREIGN KEY).
--             Вынесено в отдельный файл для управления зависимостями при
--             создании/удалении таблиц и для ясности схемы.
-- Версия схемы: 5.0.2 (исправлен порядок FK, добавлены все FK)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: subdivisions
-- -----------------------------------------------------------------------------
-- Связь иерархии подразделений (ссылка на саму себя).
ALTER TABLE subdivisions
    ADD CONSTRAINT fk_subdivisions_parent
    FOREIGN KEY (parent_id) REFERENCES subdivisions(id)
    ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_subdivisions_parent ON subdivisions IS 'Связь для построения иерархии подразделений. При удалении родителя, дочерние становятся корневыми.';

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: node_types
-- -----------------------------------------------------------------------------
-- Связь иерархии типов узлов.
ALTER TABLE node_types
    ADD CONSTRAINT fk_node_types_parent
    FOREIGN KEY (parent_type_id) REFERENCES node_types(id)
    ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_node_types_parent ON node_types IS 'Связь для построения иерархии типов узлов. При удалении родителя, дочерние становятся корневыми.';

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: node_properties
-- -----------------------------------------------------------------------------
-- Ссылка на тип узла, к которому относится свойство.
ALTER TABLE node_properties
    ADD CONSTRAINT fk_node_properties_node_type
    FOREIGN KEY (node_type_id) REFERENCES node_types(id)
    ON DELETE CASCADE;
COMMENT ON CONSTRAINT fk_node_properties_node_type ON node_properties IS 'Ссылка на тип узла. Свойства удаляются вместе с типом (CASCADE).';

-- Ссылка на тип свойства.
ALTER TABLE node_properties
    ADD CONSTRAINT fk_node_properties_property_type
    FOREIGN KEY (property_type_id) REFERENCES node_property_types(id)
    ON DELETE CASCADE;
COMMENT ON CONSTRAINT fk_node_properties_property_type ON node_properties IS 'Ссылка на тип свойства. Значения удаляются вместе с типом свойства (CASCADE).';

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: nodes
-- -----------------------------------------------------------------------------
-- Ссылка на родительское подразделение.
ALTER TABLE nodes
    ADD CONSTRAINT fk_nodes_subdivision
    FOREIGN KEY (parent_subdivision_id) REFERENCES subdivisions(id)
    ON DELETE CASCADE;
COMMENT ON CONSTRAINT fk_nodes_subdivision ON nodes IS 'Ссылка на родительское подразделение. Узлы удаляются вместе с подразделением (CASCADE).';

-- Ссылка на тип узла.
ALTER TABLE nodes
    ADD CONSTRAINT fk_nodes_node_type
    FOREIGN KEY (node_type_id) REFERENCES node_types(id)
    ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_nodes_node_type ON nodes IS 'Ссылка на тип узла. При удалении типа, у узла тип сбрасывается в NULL (SET NULL).';

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: api_keys
-- -----------------------------------------------------------------------------
ALTER TABLE api_keys
    ADD CONSTRAINT fk_api_keys_object_id_subdivisions
    FOREIGN KEY (object_id) REFERENCES subdivisions(object_id) ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_api_keys_object_id_subdivisions ON api_keys IS 'Ссылка на object_id подразделения, к которому может быть привязан ключ.';

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: node_check_assignments
-- -----------------------------------------------------------------------------
-- Ссылка на узел, к которому привязано задание.
ALTER TABLE node_check_assignments
    ADD CONSTRAINT fk_assignments_node
    FOREIGN KEY (node_id) REFERENCES nodes(id)
    ON DELETE CASCADE;
COMMENT ON CONSTRAINT fk_assignments_node ON node_check_assignments IS 'Ссылка на узел. Задания удаляются вместе с узлом (CASCADE).';

-- Ссылка на метод проверки.
ALTER TABLE node_check_assignments
    ADD CONSTRAINT fk_assignments_method
    FOREIGN KEY (method_id) REFERENCES check_methods(id)
    ON DELETE RESTRICT;
COMMENT ON CONSTRAINT fk_assignments_method ON node_check_assignments IS 'Ссылка на основной метод задания. Запрещает удаление метода, если он используется (RESTRICT).';

-- Ссылка на последнюю проверку (исправленная ошибка)
ALTER TABLE node_check_assignments
    ADD CONSTRAINT fk_assignments_last_check
    FOREIGN KEY (last_node_check_id) REFERENCES node_checks(id) ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_assignments_last_check ON node_check_assignments IS 'Ссылка на ID последней проверки (из node_checks), выполненной по этому заданию.';

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: node_checks
-- -----------------------------------------------------------------------------
-- Ссылка на узел, для которого получен результат.
ALTER TABLE node_checks
    ADD CONSTRAINT fk_node_checks_node
    FOREIGN KEY (node_id) REFERENCES nodes(id)
    ON DELETE CASCADE;
COMMENT ON CONSTRAINT fk_node_checks_node ON node_checks IS 'Ссылка на узел. История проверок удаляется вместе с узлом (CASCADE).';

-- Ссылка на задание, по которому выполнена проверка.
ALTER TABLE node_checks
    ADD CONSTRAINT fk_node_checks_assignment
    FOREIGN KEY (assignment_id) REFERENCES node_check_assignments(id)
    ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_node_checks_assignment ON node_checks IS 'Ссылка на задание. При удалении задания, ссылка в истории сбрасывается в NULL (SET NULL).';

-- Ссылка на метод проверки.
ALTER TABLE node_checks
    ADD CONSTRAINT fk_node_checks_method
    FOREIGN KEY (method_id) REFERENCES check_methods(id)
    ON DELETE RESTRICT;
COMMENT ON CONSTRAINT fk_node_checks_method ON node_checks IS 'Ссылка на метод проверки. Запрещает удаление метода, если он есть в истории проверок (RESTRICT).';

-- Ссылка на подразделение-исполнитель
ALTER TABLE node_checks
    ADD CONSTRAINT fk_node_checks_executor_subdivision
    FOREIGN KEY (executor_object_id) REFERENCES subdivisions(object_id) ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_node_checks_executor_subdivision ON node_checks IS 'Ссылка на подразделение-исполнитель по object_id.';

/* -- Закомментированные FK для версий - если будут использоваться, нужно раскомментировать
ALTER TABLE node_checks
    ADD CONSTRAINT fk_node_checks_assignment_version
    FOREIGN KEY (assignment_config_version) REFERENCES offline_config_versions(version_tag)
    ON DELETE SET NULL;
ALTER TABLE node_checks
    ADD CONSTRAINT fk_node_checks_agent_version
    FOREIGN KEY (agent_script_version) REFERENCES offline_config_versions(version_tag)
    ON DELETE SET NULL;
*/

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: node_check_details
-- -----------------------------------------------------------------------------
-- Ссылка на основную запись о проверке.
ALTER TABLE node_check_details
    ADD CONSTRAINT fk_node_check_details_check
    FOREIGN KEY (node_check_id) REFERENCES node_checks(id)
    ON DELETE CASCADE;
COMMENT ON CONSTRAINT fk_node_check_details_check ON node_check_details IS 'Ссылка на основную запись проверки. Детали удаляются вместе с проверкой (CASCADE).';

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: system_events
-- -----------------------------------------------------------------------------
ALTER TABLE system_events
    ADD CONSTRAINT fk_system_events_node
    FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_system_events_node ON system_events IS 'Ссылка на связанный узел. Сбрасывается в NULL при удалении узла.';

ALTER TABLE system_events
    ADD CONSTRAINT fk_system_events_assignment
    FOREIGN KEY (assignment_id) REFERENCES node_check_assignments(id) ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_system_events_assignment ON system_events IS 'Ссылка на связанное задание. Сбрасывается в NULL при удалении задания.';

ALTER TABLE system_events
    ADD CONSTRAINT fk_system_events_check
    FOREIGN KEY (node_check_id) REFERENCES node_checks(id) ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_system_events_check ON system_events IS 'Ссылка на связанный результат проверки. Сбрасывается в NULL при удалении проверки.';

-- -----------------------------------------------------------------------------
-- Внешние ключи для таблицы: offline_config_versions
-- -----------------------------------------------------------------------------
-- Ссылка на подразделение (по object_id).
ALTER TABLE offline_config_versions
    ADD CONSTRAINT fk_offline_config_subdivision
    FOREIGN KEY (object_id) REFERENCES subdivisions(object_id)
    ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_offline_config_subdivision ON offline_config_versions IS 'Ссылка на подразделение по object_id. Сбрасывается в NULL при удалении подразделения.';

-- =============================================================================
-- == КОНЕЦ ДОБАВЛЕНИЯ ВНЕШНИХ КЛЮЧЕЙ ==
-- =============================================================================