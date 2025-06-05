-- testDB_kaskad/05_test_api_keys.sql
-- Тестовые API ключи для E2E тестов
-- Хеши сгенерированы с помощью SHA256

INSERT INTO api_keys (key_hash, description, role, object_id, is_active)
VALUES
-- Хеш для 'test_agent_key_for_9999'
('e5aea609f2e4a5aeafe91db45a14c5dd255575881a656832118941a014c214c4', 'E2E Test Agent Key for PowerShell Node (OID 9999)', 'agent', 9999, TRUE),
-- Хеш для 'test_loader_key'
('9913f0f573af0225427a8b82b2ce20874051dcb1f27d6e14e21242ffd1ddde09', 'E2E Test Loader Key', 'loader', NULL, TRUE),
-- Хеш для 'test_configurator_key_for_9999'
('f4fc7303a6cf2c4fc032ebceacf2f9bb27da859d21c40d95f9e1ad9b6a8aed8e', 'E2E Test Configurator Key for PowerShell Node (OID 9999)', 'configurator', 9999, TRUE)
ON CONFLICT (key_hash) DO NOTHING;

-- Можно добавить ключ администратора для тестов API, если нужно
-- ('hash_admin_key', 'E2E Test Admin Key', 'admin', NULL, TRUE)

-- Запись события о создании тестовых ключей
INSERT INTO system_events (event_type, severity, message, source)
VALUES ('DB_INIT_TEST_KEYS', 'INFO', 'Тестовые API ключи для E2E сценариев созданы/проверены.', '05_test_api_keys.sql');