-- =============================================================================
-- Файл: 001_settings.sql
-- Назначение: Заполнение таблицы settings базовыми настройками.
--             Использует ON CONFLICT DO UPDATE для идемпотентности.
-- =============================================================================

-- Комментарий: Устанавливает интервал проверки по умолчанию для заданий, если он не указан явно в самом задании.
INSERT INTO settings (key, value, description) VALUES
('default_check_interval_seconds', '120', 'Интервал проверки по умолчанию для заданий (сек).')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- Комментарий: Определяет таймаут в минутах, после которого PING-статус узла переходит в состояние "warning" (устарел).
INSERT INTO settings (key, value, description) VALUES
('ping_timeout_minutes', '5', 'Таймаут PING для статуса warning (мин).')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- Комментарий: Устарел? Используется ли этот параметр где-либо? (Пометка для разработчика)
INSERT INTO settings (key, value, description) VALUES
('recent_check_interval_minutes', '2', 'Таймаут "недавних" проверок (устар.?).')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- =============================================================================
-- == КОНЕЦ ЗАПОЛНЕНИЯ settings ==
-- =============================================================================