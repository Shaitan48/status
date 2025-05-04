-- =============================================================================
-- Файл: 001_create_tables.sql
-- Назначение: Создание всех таблиц базы данных мониторинга.
--             Включает первичные ключи, базовые ограничения (NOT NULL, CHECK),
--             но НЕ включает внешние ключи и индексы (кроме первичных).
-- Версия схемы: ~4.3.0
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Таблица: settings
-- Назначение: Хранение глобальных настроек приложения в формате ключ-значение.
-- -----------------------------------------------------------------------------
CREATE TABLE settings (
    key TEXT PRIMARY KEY,                 -- Уникальный ключ настройки (например, 'default_check_interval_seconds'). Является первичным ключом.
    value TEXT NOT NULL,                  -- Значение настройки (текстовое). Обязательно к заполнению.
    description TEXT                      -- Описание назначения настройки (для понимания администратором). Необязательно.
);
-- Комментарий к таблице: Используется для хранения конфигурационных параметров, которые могут меняться без переразвертывания приложения.
COMMENT ON TABLE settings IS 'Глобальные настройки приложения (ключ-значение).';
COMMENT ON COLUMN settings.key IS 'Уникальный идентификатор (ключ) настройки.';
COMMENT ON COLUMN settings.value IS 'Значение настройки (в виде текста).';
COMMENT ON COLUMN settings.description IS 'Пояснение назначения настройки.';

-- -----------------------------------------------------------------------------
-- Таблица: subdivisions
-- Назначение: Хранение иерархической структуры подразделений (объектов мониторинга).
-- -----------------------------------------------------------------------------
CREATE TABLE subdivisions (
    id SERIAL PRIMARY KEY,                -- Уникальный внутренний ID подразделения (автоинкремент). Первичный ключ.
    object_id INTEGER NOT NULL UNIQUE,    -- Уникальный ВНЕШНИЙ идентификатор подразделения (из другой системы). Обязателен и уникален. Используется агентами и API для идентификации. Отсутствие ограничения UNIQUE грозит путаницей в привязке агентов и заданий.
    short_name VARCHAR(100) NOT NULL,     -- Короткое, отображаемое имя подразделения. Обязательно.
    full_name TEXT NULL,                  -- Полное наименование подразделения. Необязательно.
    parent_id INTEGER NULL,               -- ID родительского подразделения (ссылка на subdivisions.id). NULL для корневых. Внешний ключ будет добавлен позже.
    domain_name TEXT NULL,                -- Доменное имя, ассоциированное с подразделением (если применимо). Необязательно.
    transport_system_code VARCHAR(10) NULL, -- Уникальный код транспортной системы (для именования файлов конфигурации оффлайн-агентов). Должен быть уникальным, если не NULL.
    priority INTEGER DEFAULT 10 NOT NULL, -- Приоритет отображения (меньше = выше). Используется для сортировки. Обязателен, по умолчанию 10.
    comment TEXT NULL,                    -- Произвольный комментарий. Необязательно.
    icon_filename VARCHAR(100) NULL,      -- Имя файла иконки для подразделения (в static/images/subdivisions/). Необязательно.

    
    -- Ограничение уникальности: Код транспортной системы должен быть уникальным среди всех подразделений, если он указан (не NULL). Отсутствие грозит конфликтами имен файлов конфигурации.
     CONSTRAINT unique_subdivision_transport_code UNIQUE (transport_system_code), -- Уникальность теперь проверяется индексом ниже, а не напрямую здесь для NULL

    -- Ограничение формата: Код транспортной системы должен содержать только латинские буквы и цифры (если указан).
    CONSTRAINT check_transport_system_code_format CHECK (transport_system_code IS NULL OR transport_system_code ~ '^[A-Za-z0-9]{1,10}$')
);
-- Комментарий к таблице: Определяет организационную структуру, к которой привязываются узлы мониторинга.
COMMENT ON TABLE subdivisions IS 'Иерархическая структура подразделений.';
COMMENT ON COLUMN subdivisions.id IS 'Внутренний уникальный идентификатор подразделения (PK).';
COMMENT ON COLUMN subdivisions.object_id IS 'Внешний уникальный идентификатор подразделения (например, из системы учета). Используется для связи с агентами.';
COMMENT ON COLUMN subdivisions.short_name IS 'Короткое имя для отображения.';
COMMENT ON COLUMN subdivisions.full_name IS 'Полное наименование.';
COMMENT ON COLUMN subdivisions.parent_id IS 'Ссылка на ID родительского подразделения (для иерархии). NULL для корневых.';
COMMENT ON COLUMN subdivisions.domain_name IS 'Ассоциированное доменное имя (если есть).';
COMMENT ON COLUMN subdivisions.transport_system_code IS 'Уникальный код для транспортной системы (для файлов оффлайн-агента). NULL, если не используется.';
COMMENT ON COLUMN subdivisions.priority IS 'Приоритет сортировки (меньше = выше).';
COMMENT ON COLUMN subdivisions.comment IS 'Произвольный комментарий.';
COMMENT ON COLUMN subdivisions.icon_filename IS 'Имя файла иконки подразделения (опционально).';

-- Users table <<< НОВАЯ ТАБЛИЦА >>>
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(80) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL, -- Длина для хеша (bcrypt/sha256)
    is_active BOOLEAN DEFAULT TRUE NOT NULL, -- Для блокировки пользователя
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL
);
COMMENT ON TABLE users IS 'Пользователи системы для аутентификации в UI.';

-- API Keys table
CREATE TABLE api_keys (
    id SERIAL PRIMARY KEY,
    key_hash VARCHAR(64) NOT NULL UNIQUE, -- Хеш SHA-256 ключа (64 hex символа)
    description TEXT NOT NULL,            -- Описание (кто/что использует ключ)
    role VARCHAR(50) NOT NULL DEFAULT 'agent' CHECK (role IN ('agent', 'loader', 'configurator', 'admin')), -- Роль для возможного разделения прав
    object_id INTEGER NULL REFERENCES subdivisions(object_id) ON DELETE SET NULL, -- Опциональная привязка к объекту (для агентов)
    is_active BOOLEAN DEFAULT TRUE NOT NULL, -- Активен ли ключ
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_used_at TIMESTAMPTZ NULL           -- Время последнего успешного использования
);
COMMENT ON TABLE api_keys IS 'API ключи для аутентификации агентов и скриптов.';

-- -----------------------------------------------------------------------------
-- Таблица: check_methods
-- Назначение: Справочник доступных методов проверки узлов.
-- -----------------------------------------------------------------------------
CREATE TABLE check_methods (
    id SERIAL PRIMARY KEY,                 -- Уникальный ID метода проверки. Первичный ключ.
    method_name TEXT NOT NULL UNIQUE,      -- Системное имя метода (например, 'PING', 'SERVICE_STATUS'). Обязательно и уникально. Используется агентами и логикой приложения. Отсутствие UNIQUE грозит неоднозначностью методов.
    description TEXT                       -- Описание метода проверки. Необязательно.
);
-- Комментарий к таблице: Определяет, какие типы проверок могут быть назначены узлам. Расширяется при добавлении новых возможностей мониторинга.
COMMENT ON TABLE check_methods IS 'Справочник методов проверки узлов.';
COMMENT ON COLUMN check_methods.id IS 'Уникальный идентификатор метода проверки (PK).';
COMMENT ON COLUMN check_methods.method_name IS 'Системное имя метода проверки (например, PING, HTTP_CHECK). Должно быть уникальным.';
COMMENT ON COLUMN check_methods.description IS 'Человекочитаемое описание метода.';

-- -----------------------------------------------------------------------------
-- Таблица: node_types
-- Назначение: Иерархический справочник типов узлов мониторинга (Сервер, АРМ и т.д.).
-- -----------------------------------------------------------------------------
CREATE TABLE node_types (
    id SERIAL PRIMARY KEY,                 -- Уникальный ID типа узла. Первичный ключ.
    name TEXT NOT NULL,                    -- Название типа узла (например, 'Сервер', 'АРМ Пользователя'). Обязательно.
    description TEXT,                      -- Описание типа узла. Необязательно.
    parent_type_id INTEGER REFERENCES node_types(id) ON DELETE SET NULL, -- ID родительского типа (ссылка на node_types.id). NULL для корневых типов. Внешний ключ будет добавлен позже. При удалении родителя тип становится корневым (SET NULL).
    priority INTEGER DEFAULT 10 NOT NULL,  -- Приоритет отображения/сортировки типов. Обязателен, по умолчанию 10.
    icon_filename VARCHAR(100) NULL       -- Имя файла иконки для типа узла (в static/icons/). Необязательно.

    -- Ограничение уникальности: Имя типа должно быть уникально В ПРЕДЕЛАХ ОДНОГО родителя.
    -- CONSTRAINT unique_type_name_parent UNIQUE (name, parent_type_id) -- Уникальность имени типа узла в пределах одного родителя (если задан). Отсутствие UNIQUE грозит путаницей в типах узлов.
);
-- Комментарий к таблице: Позволяет классифицировать узлы, что используется для группировки, определения свойств по умолчанию и отображения.
COMMENT ON TABLE node_types IS 'Иерархический справочник типов узлов.';
COMMENT ON COLUMN node_types.id IS 'Уникальный идентификатор типа узла (PK).';
COMMENT ON COLUMN node_types.name IS 'Название типа узла.';
COMMENT ON COLUMN node_types.description IS 'Описание типа узла.';
COMMENT ON COLUMN node_types.parent_type_id IS 'Ссылка на ID родительского типа (для иерархии). NULL для корневых.';
COMMENT ON COLUMN node_types.priority IS 'Приоритет сортировки (меньше = выше).';
COMMENT ON COLUMN node_types.icon_filename IS 'Имя файла иконки типа узла (в static/icons/).';

-- -----------------------------------------------------------------------------
-- Таблица: node_property_types
-- Назначение: Справочник типов настраиваемых свойств для узлов (например, 'timeout', 'иконка').
-- -----------------------------------------------------------------------------
CREATE TABLE node_property_types (
    id SERIAL PRIMARY KEY,                 -- Уникальный ID типа свойства. Первичный ключ.
    name TEXT NOT NULL UNIQUE,             -- Системное имя типа свойства (например, 'timeout_minutes', 'display_order'). Обязательно и уникально. Используется в логике приложения.
    description TEXT                       -- Описание типа свойства. Необязательно.
);
-- Комментарий к таблице: Определяет, какие дополнительные атрибуты можно задавать для ТИПОВ узлов (не для конкретных узлов).
COMMENT ON TABLE node_property_types IS 'Справочник типов настраиваемых свойств для ТИПОВ узлов.';
COMMENT ON COLUMN node_property_types.id IS 'Уникальный идентификатор типа свойства (PK).';
COMMENT ON COLUMN node_property_types.name IS 'Уникальное системное имя типа свойства.';
COMMENT ON COLUMN node_property_types.description IS 'Описание типа свойства.';

-- -----------------------------------------------------------------------------
-- Таблица: node_properties
-- Назначение: Хранение значений конкретных свойств для конкретных ТИПОВ узлов.
-- -----------------------------------------------------------------------------
CREATE TABLE node_properties (
    id SERIAL PRIMARY KEY,                 -- Уникальный ID записи свойства. Первичный ключ.
    node_type_id INTEGER NOT NULL,         -- Ссылка на ID типа узла (node_types.id). Обязательно. Внешний ключ будет добавлен позже. Определяет, к какому ТИПУ узла относится свойство.
    property_type_id INTEGER NOT NULL,     -- Ссылка на ID типа свойства (node_property_types.id). Обязательно. Внешний ключ будет добавлен позже. Определяет, КАКОЕ свойство задается.
    property_value TEXT NOT NULL,          -- Значение свойства (в виде текста). Обязательно.

    -- Ограничение уникальности: Для одного типа узла не может быть двух записей с одним и тем же типом свойства.
    CONSTRAINT unique_node_type_property UNIQUE (node_type_id, property_type_id)
);
-- Комментарий к таблице: Позволяет задавать значения по умолчанию или специфические атрибуты (таймаут, цвет иконки и т.д.) для целых категорий узлов.
COMMENT ON TABLE node_properties IS 'Значения настраиваемых свойств для конкретных ТИПОВ узлов.';
COMMENT ON COLUMN node_properties.id IS 'Уникальный идентификатор записи свойства (PK).';
COMMENT ON COLUMN node_properties.node_type_id IS 'Ссылка на тип узла (FK к node_types.id).';
COMMENT ON COLUMN node_properties.property_type_id IS 'Ссылка на тип свойства (FK к node_property_types.id).';
COMMENT ON COLUMN node_properties.property_value IS 'Значение свойства (текстовое).';

-- -----------------------------------------------------------------------------
-- Таблица: nodes
-- Назначение: Хранение информации о конкретных узлах мониторинга (серверы, АРМы).
-- -----------------------------------------------------------------------------
CREATE TABLE nodes (
    id SERIAL PRIMARY KEY,                 -- Уникальный ID узла. Первичный ключ.
    name VARCHAR(255) NOT NULL,            -- Отображаемое имя узла (Hostname). Обязательно.
    parent_subdivision_id INTEGER NOT NULL,-- Ссылка на ID родительского подразделения (subdivisions.id). Обязательно. Внешний ключ будет добавлен позже. Определяет принадлежность узла к подразделению.
    ip_address VARCHAR(45),                -- IP-адрес узла (IPv4 или IPv6). Необязателен (например, для логических объектов).
    node_type_id INTEGER,                  -- Ссылка на ID типа узла (node_types.id). Необязателен (если не задан, используется тип по умолчанию). Внешний ключ будет добавлен позже.
    description TEXT,                      -- Описание узла. Необязательно.

    -- Ограничение уникальности: Имя узла должно быть уникально В ПРЕДЕЛАХ ОДНОГО подразделения.
    CONSTRAINT unique_node_name_parent_subdivision UNIQUE (name, parent_subdivision_id)
);
-- Комментарий к таблице: Основная таблица сущностей, состояние которых отслеживается системой.
COMMENT ON TABLE nodes IS 'Узлы мониторинга (серверы, АРМы и т.д.).';
COMMENT ON COLUMN nodes.id IS 'Уникальный идентификатор узла (PK).';
COMMENT ON COLUMN nodes.name IS 'Отображаемое имя узла (Hostname).';
COMMENT ON COLUMN nodes.parent_subdivision_id IS 'Ссылка на родительское подразделение (FK к subdivisions.id).';
COMMENT ON COLUMN nodes.ip_address IS 'IP-адрес узла (если применимо).';
COMMENT ON COLUMN nodes.node_type_id IS 'Ссылка на тип узла (FK к node_types.id).';
COMMENT ON COLUMN nodes.description IS 'Описание узла.';

-- -----------------------------------------------------------------------------
-- Таблица: node_check_assignments
-- Назначение: Задания на проверку конкретных узлов конкретными методами.
--             Это ядро системы мониторинга.
-- -----------------------------------------------------------------------------
CREATE TABLE node_check_assignments (
    id SERIAL PRIMARY KEY,                -- Уникальный ID задания (assignment_id). Первичный ключ. Используется агентами для идентификации выполненной работы.
    node_id INTEGER NOT NULL,             -- Ссылка на ID узла (nodes.id), который нужно проверить. Обязательно. Внешний ключ будет добавлен позже.
    method_id INTEGER NOT NULL,           -- Ссылка на ID метода проверки (check_methods.id). Обязательно. Внешний ключ будет добавлен позже.
    is_enabled BOOLEAN DEFAULT TRUE NOT NULL, -- Флаг, включено ли задание. Используется для временного отключения проверок без удаления. Обязателен.
    parameters JSONB NULL,                -- Параметры, специфичные для метода проверки (например, имя службы, URL). Хранятся в формате JSONB для гибкости. Необязательны.
    check_interval_seconds INTEGER NULL,  -- Интервал проверки в секундах. NULL означает использование интервала по умолчанию из настроек. Необязателен.
    last_assigned_at TIMESTAMPTZ NULL,     -- Время последнего назначения/изменения задания (информационно). Не используется активно.
    last_executed_at TIMESTAMPTZ NULL,     -- Время последнего ФАКТИЧЕСКОГО выполнения проверки по этому заданию (обновляется процедурой). Используется для мониторинга "зависших" агентов.
    last_node_check_id INTEGER NULL,      -- Ссылка на ID последней записи о результате проверки (node_checks.id) по этому заданию. Внешний ключ будет добавлен позже. Используется для быстрого доступа к последнему статусу.
    description TEXT,                     -- Описание конкретного задания (почему оно назначено). Необязательно.
    success_criteria JSONB NULL           -- Критерии для определения успешности проверки (JSONB). Формат зависит от метода. Необязательны. Позволяет более гибко определять статус "available", чем просто булево значение.
);
-- Комментарий к таблице: Определяет, ЧТО, ГДЕ и КАК должно проверяться системой мониторинга. Позволяет гибко настраивать проверки для разных узлов.
COMMENT ON TABLE node_check_assignments IS 'Задания на проверку узлов.';
COMMENT ON COLUMN node_check_assignments.id IS 'Уникальный идентификатор задания (assignment_id, PK).';
COMMENT ON COLUMN node_check_assignments.node_id IS 'Ссылка на проверяемый узел (FK к nodes.id).';
COMMENT ON COLUMN node_check_assignments.method_id IS 'Ссылка на метод проверки (FK к check_methods.id).';
COMMENT ON COLUMN node_check_assignments.is_enabled IS 'Флаг активности задания.';
COMMENT ON COLUMN node_check_assignments.parameters IS 'Параметры для метода проверки (JSONB).';
COMMENT ON COLUMN node_check_assignments.check_interval_seconds IS 'Интервал проверки в секундах (NULL - по умолчанию).';
COMMENT ON COLUMN node_check_assignments.last_assigned_at IS 'Время последнего назначения/изменения (информационно).';
COMMENT ON COLUMN node_check_assignments.last_executed_at IS 'Время последнего выполнения проверки по этому заданию.';
COMMENT ON COLUMN node_check_assignments.last_node_check_id IS 'Ссылка на последний результат проверки (FK к node_checks.id).';
COMMENT ON COLUMN node_check_assignments.description IS 'Описание задания.';
COMMENT ON COLUMN node_check_assignments.success_criteria IS 'Критерии для определения успешности проверки (JSONB). Формат зависит от метода.';

-- -----------------------------------------------------------------------------
-- Таблица: node_checks
-- Назначение: Хранение истории результатов выполнения проверок.
-- -----------------------------------------------------------------------------
CREATE TABLE node_checks (
    id SERIAL PRIMARY KEY,                -- Уникальный ID записи о результате проверки. Первичный ключ.
    node_id INTEGER NOT NULL,             -- Ссылка на ID узла (nodes.id), для которого получен результат. Обязательно. Внешний ключ будет добавлен позже.
    assignment_id INTEGER NULL,           -- Ссылка на ID задания (node_check_assignments.id), по которому выполнена проверка. NULL, если проверка выполнена вне рамок задания (маловероятно в текущей схеме). Внешний ключ будет добавлен позже.
    method_id INTEGER NOT NULL,           -- Ссылка на ID метода проверки (check_methods.id). Дублируется из задания для удобства анализа истории. Обязательно. Внешний ключ будет добавлен позже.
    is_available BOOLEAN NOT NULL,        -- Основной результат проверки: доступен/недоступен (или соответствует/не соответствует success_criteria). Обязательно.
    checked_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL, -- Серверное время получения результата. Обязательно, по умолчанию текущее время сервера.
    check_timestamp TIMESTAMPTZ,          -- Время выполнения проверки на стороне АГЕНТА. Может отличаться от серверного. Необязательно.
    executor_object_id INTEGER NULL,      -- ID подразделения (subdivisions.object_id) агента, выполнившего проверку. Полезно для отладки.
    executor_host TEXT NULL,              -- Имя хоста агента, выполнившего проверку. Полезно для отладки.
    resolution_method TEXT NULL,          -- Как был получен результат (например, 'online-agent', 'offline-loader', 'manual'). Информационно.
    -- Новые поля для версионирования (добавлены в init.sql v4.3.0, перенесены сюда)
    assignment_config_version VARCHAR(100) NULL, -- Тег версии конфигурации заданий, с которой получен результат (FK к offline_config_versions.version_tag).
    agent_script_version VARCHAR(100) NULL      -- Тег версии скрипта агента, который прислал результат (FK к offline_config_versions.version_tag).
);
-- Комментарий к таблице: Лог всех полученных результатов проверок. Основная таблица для анализа истории состояния узлов. Ожидается быстрый рост данных.
COMMENT ON TABLE node_checks IS 'История результатов выполнения проверок узлов.';
COMMENT ON COLUMN node_checks.id IS 'Уникальный идентификатор результата проверки (PK).';
COMMENT ON COLUMN node_checks.node_id IS 'Ссылка на узел (FK к nodes.id).';
COMMENT ON COLUMN node_checks.assignment_id IS 'Ссылка на задание (FK к node_check_assignments.id). NULL, если проверка вне задания.';
COMMENT ON COLUMN node_checks.method_id IS 'Ссылка на использованный метод проверки (FK к check_methods.id).';
COMMENT ON COLUMN node_checks.is_available IS 'Результат проверки (доступен/недоступен или по критериям).';
COMMENT ON COLUMN node_checks.checked_at IS 'Серверное время получения результата.';
COMMENT ON COLUMN node_checks.check_timestamp IS 'Время выполнения проверки на агенте.';
COMMENT ON COLUMN node_checks.executor_object_id IS 'ID подразделения агента-исполнителя.';
COMMENT ON COLUMN node_checks.executor_host IS 'Имя хоста агента-исполнителя.';
COMMENT ON COLUMN node_checks.resolution_method IS 'Способ получения результата (online, offline, manual).';
--COMMENT ON COLUMN node_checks.assignment_config_version IS 'Тег версии файла конфигурации заданий (для оффлайн).';
--COMMENT ON COLUMN node_checks.agent_script_version IS 'Тег версии скрипта агента (для оффлайн).';

-- -----------------------------------------------------------------------------
-- Таблица: node_check_details
-- Назначение: Хранение детализированных результатов проверок (списки процессов, данные WMI и т.д.).
-- -----------------------------------------------------------------------------
CREATE TABLE node_check_details (
    id SERIAL PRIMARY KEY,                -- Уникальный ID записи детализации. Первичный ключ.
    node_check_id INTEGER NOT NULL,       -- Ссылка на ID основного результата проверки (node_checks.id), к которому относятся эти детали. Обязательно. Внешний ключ будет добавлен позже.
    detail_type TEXT NOT NULL,            -- Тип детализации (например, 'PROCESS_LIST', 'KASPERSKY_STATUS', 'DISK_C'). Используется для группировки и интерпретации данных. Обязательно.
    data JSONB NOT NULL                   -- Детализированные данные в формате JSONB. Позволяет хранить структурированную информацию любой сложности. Обязательно.
);
-- Комментарий к таблице: Позволяет сохранять специфичные для метода проверки данные, не перегружая основную таблицу node_checks. JSONB обеспечивает гибкость и возможность индексации.
COMMENT ON TABLE node_check_details IS 'Детализированные результаты проверок в формате JSON.';
COMMENT ON COLUMN node_check_details.id IS 'Уникальный идентификатор записи детализации (PK).';
COMMENT ON COLUMN node_check_details.node_check_id IS 'Ссылка на основную запись проверки (FK к node_checks.id).';
COMMENT ON COLUMN node_check_details.detail_type IS 'Тип детализированных данных (определяется методом проверки).';
COMMENT ON COLUMN node_check_details.data IS 'Детализированные данные в формате JSONB.';

-- -----------------------------------------------------------------------------
-- Таблица: system_events
-- Назначение: Журнал системных событий приложения (ошибки, предупреждения, информационные сообщения).
-- -----------------------------------------------------------------------------
CREATE TABLE system_events (
    id SERIAL PRIMARY KEY,                 -- Уникальный ID события. Первичный ключ.
    event_time TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL, -- Время возникновения события (серверное). Обязательно.
    event_type VARCHAR(50) NOT NULL,       -- Тип события (например, 'APP_START', 'DB_ERROR', 'FILE_PROCESSED', 'CHECK_RESULT_RECEIVED'). Обязательно.
    severity VARCHAR(10) NOT NULL DEFAULT 'INFO' CHECK (severity IN ('INFO', 'WARN', 'ERROR', 'CRITICAL')), -- Уровень важности события. Обязателен. Ограничен списком значений.
    message TEXT NOT NULL,                 -- Текст сообщения о событии. Обязательно.
    source VARCHAR(100),                   -- Источник события (имя функции, скрипта, компонента). Необязательно.
    object_id INTEGER,                     -- ID объекта (подразделения), связанного с событием (если применимо).
    node_id INTEGER,                       -- Ссылка на ID узла (nodes.id), связанного с событием. Внешний ключ будет добавлен позже.
    assignment_id INTEGER,                 -- Ссылка на ID задания (node_check_assignments.id), связанного с событием. Внешний ключ будет добавлен позже.
    node_check_id INTEGER,                 -- Ссылка на ID результата проверки (node_checks.id), связанного с событием. Внешний ключ будет добавлен позже.
    related_entity VARCHAR(50),            -- Тип связанной сущности (например, 'FILE', 'USER').
    related_entity_id TEXT,                -- Идентификатор связанной сущности (например, имя файла, логин пользователя).
    details JSONB                          -- Дополнительные детали события в формате JSONB.
);
-- Комментарий к таблице: Используется для логирования работы системы, отладки и анализа инцидентов.
COMMENT ON TABLE system_events IS 'Журнал системных событий.';
COMMENT ON COLUMN system_events.id IS 'Уникальный идентификатор события (PK).';
COMMENT ON COLUMN system_events.event_time IS 'Время возникновения события.';
COMMENT ON COLUMN system_events.event_type IS 'Тип события (категория).';
COMMENT ON COLUMN system_events.severity IS 'Уровень важности события (INFO, WARN, ERROR, CRITICAL).';
COMMENT ON COLUMN system_events.message IS 'Текст сообщения о событии.';
COMMENT ON COLUMN system_events.source IS 'Источник события (компонент системы).';
COMMENT ON COLUMN system_events.object_id IS 'ID связанного объекта/подразделения (если применимо).';
COMMENT ON COLUMN system_events.node_id IS 'Ссылка на связанный узел (FK к nodes.id, ON DELETE SET NULL).';
COMMENT ON COLUMN system_events.assignment_id IS 'Ссылка на связанное задание (FK к node_check_assignments.id, ON DELETE SET NULL).';
COMMENT ON COLUMN system_events.node_check_id IS 'Ссылка на связанный результат проверки (FK к node_checks.id, ON DELETE SET NULL).';
COMMENT ON COLUMN system_events.related_entity IS 'Тип другой связанной сущности (например, FILE).';
COMMENT ON COLUMN system_events.related_entity_id IS 'Идентификатор другой связанной сущности (например, имя файла).';
COMMENT ON COLUMN system_events.details IS 'Дополнительные детали события в формате JSONB.';

-- -----------------------------------------------------------------------------
-- Таблица: offline_config_versions
-- Назначение: Хранение версий конфигураций оффлайн-агентов (задания и скрипты).
--             Позволяет отслеживать, с какой версией конфига/скрипта пришел результат.
-- -----------------------------------------------------------------------------
CREATE TABLE offline_config_versions (
    version_id SERIAL PRIMARY KEY,         -- Уникальный ID версии конфигурации. Первичный ключ.
    object_id INT NULL,                    -- Внешний ID подразделения (ссылка на subdivisions.object_id). NULL для общих конфигов (скриптов). Внешний ключ будет добавлен позже.
    config_type VARCHAR(20) NOT NULL CHECK (config_type IN ('assignments', 'script')), -- Тип конфигурации: 'assignments' (задания) или 'script' (сам скрипт агента). Обязательно.
    version_tag VARCHAR(100) NOT NULL UNIQUE, -- Уникальный тег версии (генерируется, например, timestamp + type + obj_id). Используется для связи с node_checks. Отсутствие UNIQUE грозит невозможностью однозначно определить версию.
    content_hash VARCHAR(64) NOT NULL,       -- SHA-256 хэш содержимого файла конфигурации/скрипта. Используется для определения реальных изменений и предотвращения создания дублирующих версий. Обязателен.
    description TEXT NULL,                 -- Описание изменений в этой версии. Необязательно.
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL, -- Время создания записи о версии. Обязательно.
    is_active BOOLEAN DEFAULT TRUE NOT NULL, -- Флаг, активна ли эта версия (можно деактивировать старые). Обязателен.
    file_path VARCHAR(255) NULL,           -- Опциональный путь к "эталонному" файлу этой версии (в системе контроля версий и т.д.).
    transport_system_code VARCHAR(10) NULL -- Код транспортной системы (дублируется из subdivisions для версий 'assignments' на момент создания). Используется для формирования имени файла конфигурации.
);
-- Комментарий к таблице: Необходима для реализации версионирования конфигураций оффлайн-агентов и связи результатов проверок с конкретной версией заданий/скрипта.
COMMENT ON TABLE offline_config_versions IS 'Версии конфигураций оффлайн-агентов (задания, скрипты).';
COMMENT ON COLUMN offline_config_versions.version_id IS 'Уникальный идентификатор версии (PK).';
COMMENT ON COLUMN offline_config_versions.object_id IS 'Ссылка на подразделение (FK к subdivisions.object_id, ON DELETE SET NULL). NULL для общих версий (скриптов).';
COMMENT ON COLUMN offline_config_versions.config_type IS 'Тип конфигурации (''assignments'' или ''script'').';
COMMENT ON COLUMN offline_config_versions.version_tag IS 'Уникальный тег версии (например, дата_тип_объект).';
COMMENT ON COLUMN offline_config_versions.content_hash IS 'SHA-256 хэш содержимого файла конфигурации/скрипта.';
COMMENT ON COLUMN offline_config_versions.description IS 'Описание изменений в версии.';
COMMENT ON COLUMN offline_config_versions.created_at IS 'Время создания записи о версии.';
COMMENT ON COLUMN offline_config_versions.is_active IS 'Флаг активности версии (для возможности отключения).';
COMMENT ON COLUMN offline_config_versions.file_path IS 'Путь к эталонному файлу версии (опционально).';
COMMENT ON COLUMN offline_config_versions.transport_system_code IS 'Код транспортной системы (из subdivisions на момент создания версии заданий).';

-- =============================================================================
-- == КОНЕЦ СОЗДАНИЯ ТАБЛИЦ ==
-- =============================================================================