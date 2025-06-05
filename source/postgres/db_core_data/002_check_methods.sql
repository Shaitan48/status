-- Справочник методов pipeline
TRUNCATE TABLE node_check_assignments, check_methods RESTART IDENTITY CASCADE;

INSERT INTO check_methods (method_name, description) VALUES
('PING', 'Пинг (ICMP/TCP): Проверка доступности узла по эхо-запросу.'),
('PROCESS_LIST', 'Поиск процесса по имени или маске (через PowerShell).'),
('POWERSHELL_EXECUTE', 'Выполнение PowerShell-скрипта (локально/удалённо).'),
('SQL_QUERY_EXECUTE', 'Выполнение SQL-запроса и анализ результата.'),
('KASPERSKY_STATUS', 'Анализ состояния антивируса Kaspersky.'),
('DISK_USAGE', 'Проверка занятого и свободного места на дисках.'),
('CERTIFICATES', 'Проверка SSL/TLS и локальных сертификатов.'),
('JSON_ANALYZE', 'Анализ JSON-файлов.'),
('REGISTRY_KEY', 'Контроль значения ключей реестра Windows.'),
('EVENT_LOG', 'Контроль событий в журналах Windows EventLog.'),
('LOG_FILE_ANALYZE', 'Анализ лог-файлов по паттернам/ошибкам.'),
('USB_DEVICES', 'Контроль истории USB-устройств на узле.');
