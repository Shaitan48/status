-- testDB_kaskad/05_test_api_keys.sql
-- Хеши нужно сгенерировать заранее и вставить сюда.
-- Пример: ключ 'test_agent_key_for_9999' -> хеш '...'
-- Пример: ключ 'test_loader_key' -> хеш '...'
-- Пример: ключ 'test_configurator_key_for_9999' -> хеш '...'

INSERT INTO api_keys (key_hash, description, role, object_id, is_active)
VALUES
-- Замени 'HASH_AGENT_9999' на реальный SHA256 хеш от 'test_agent_key_for_9999'
('3a9f9e1a...', 'E2E Test Agent Key for PowerShell Node (OID 9999)', 'agent', 9999, TRUE),
-- Замени 'HASH_LOADER' на реальный SHA256 хеш от 'test_loader_key'
('b4c0d2f3...', 'E2E Test Loader Key', 'loader', NULL, TRUE),
-- Замени 'HASH_CONFIGURATOR_9999' на реальный SHA256 хеш от 'test_configurator_key_for_9999'
('e5g6h7i8...', 'E2E Test Configurator Key for PowerShell Node (OID 9999)', 'configurator', 9999, TRUE)
ON CONFLICT (key_hash) DO NOTHING;

-- Можно добавить ключ администратора для тестов API, если нужно
-- ('hash_admin_key', 'E2E Test Admin Key', 'admin', NULL, TRUE)

-- Запись события о создании тестовых ключей
INSERT INTO system_events (event_type, severity, message, source)
VALUES ('DB_INIT_TEST_KEYS', 'INFO', 'Тестовые API ключи для E2E сценариев созданы/проверены.', '05_test_api_keys.sql');