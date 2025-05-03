-- =============================================================================
-- Файл: 002_check_methods.sql
-- Назначение: Заполнение справочника методов проверки (check_methods).
--             Использует ON CONFLICT DO UPDATE для идемпотентности.
--             Важно, чтобы ID оставались стабильными, если на них есть ссылки.
-- =============================================================================

-- Комментарий: Базовая проверка доступности узла с помощью ICMP или TCP эхо-запросов.
INSERT INTO check_methods (id, method_name, description) VALUES
(1, 'PING', 'Проверка доступности ICMP/TCP эхо-запросом.')
ON CONFLICT (id) DO UPDATE SET method_name = EXCLUDED.method_name, description = EXCLUDED.description;

-- Комментарий: Получение списка запущенных процессов на удаленном узле. Требует соответствующих прав и настроек (например, WinRM).
INSERT INTO check_methods (id, method_name, description) VALUES
(2, 'PROCESS_LIST', 'Получение списка запущенных процессов.')
ON CONFLICT (id) DO UPDATE SET method_name = EXCLUDED.method_name, description = EXCLUDED.description;

-- Комментарий: Проверка статуса и версии антивируса Kaspersky Endpoint Security. Требует специфичной реализации на агенте.
INSERT INTO check_methods (id, method_name, description) VALUES
(3, 'KASPERSKY_STATUS', 'Получение статуса антивируса Kaspersky Endpoint Security.')
ON CONFLICT (id) DO UPDATE SET method_name = EXCLUDED.method_name, description = EXCLUDED.description;

-- Комментарий: Проверка статуса конкретной системной службы Windows/Linux. Требует передачи имени службы в параметрах задания.
INSERT INTO check_methods (id, method_name, description) VALUES
(4, 'SERVICE_STATUS', 'Проверка статуса указанной системной службы.')
ON CONFLICT (id) DO UPDATE SET method_name = EXCLUDED.method_name, description = EXCLUDED.description;

-- Комментарий: Получение информации об использовании дискового пространства (свободно/занято). Может требовать указания дисков в параметрах.
INSERT INTO check_methods (id, method_name, description) VALUES
(5, 'DISK_USAGE', 'Получение информации о свободном/занятом дисковом пространстве.')
ON CONFLICT (id) DO UPDATE SET method_name = EXCLUDED.method_name, description = EXCLUDED.description;

-- Комментарий: Проверка доступности веб-ресурса по URL. Обычно проверяет код ответа HTTP (например, 200 OK). Может требовать URL и ожидаемый код в параметрах.
INSERT INTO check_methods (id, method_name, description) VALUES
(6, 'HTTP_CHECK', 'Проверка доступности веб-страницы по URL и коду ответа.')
ON CONFLICT (id) DO UPDATE SET method_name = EXCLUDED.method_name, description = EXCLUDED.description;

-- Комментарий: Проверка срока действия SSL/TLS сертификата для указанного хоста и порта. Требует хост/порт в параметрах.
INSERT INTO check_methods (id, method_name, description) VALUES
(7, 'CERT_EXPIRY', 'Проверка срока действия SSL/TLS сертификата.')
ON CONFLICT (id) DO UPDATE SET method_name = EXCLUDED.method_name, description = EXCLUDED.description;

-- Сброс последовательности, чтобы следующий INSERT начал с нужного ID
SELECT setval(pg_get_serial_sequence('check_methods', 'id'), COALESCE(max(id), 1)) FROM check_methods;

-- =============================================================================
-- == КОНЕЦ ЗАПОЛНЕНИЯ check_methods ==
-- =============================================================================