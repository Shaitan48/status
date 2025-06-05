-- =============================================================================
-- Файл: 001_create_tables.sql
-- Назначение: Создание всех таблиц базы данных мониторинга (pipeline-архитектура).
-- Версия схемы: 5.0.3 (исправлено: добавлено поле check_success в node_checks)
-- =============================================================================

-- ----------------------------------------------------------------------------- 
-- Таблица: settings
-- Назначение: Хранение глобальных настроек приложения в формате ключ-значение.
-- -----------------------------------------------------------------------------
CREATE TABLE settings (
    key TEXT PRIMARY KEY,                 -- Уникальный ключ настройки (например, 'default_check_interval_seconds').
    value TEXT NOT NULL,                  -- Значение настройки (текстовое).
    description TEXT                      -- Описание назначения настройки (для администратора).
);
COMMENT ON TABLE settings IS 'Глобальные настройки приложения (ключ-значение).';
COMMENT ON COLUMN settings.key IS 'Уникальный идентификатор (ключ) настройки.';
COMMENT ON COLUMN settings.value IS 'Значение настройки (в виде текста).';
COMMENT ON COLUMN settings.description IS 'Пояснение назначения настройки.';

-- ----------------------------------------------------------------------------- 
-- Таблица: users
-- Назначение: Пользователи системы для аутентификации в UI.
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(80) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,          -- Длина для хеша (например, pbkdf2:sha256 из Werkzeug)
    is_active BOOLEAN DEFAULT TRUE NOT NULL,      -- Флаг активности пользователя
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL -- Время создания записи
);
COMMENT ON TABLE users IS 'Пользователи системы для аутентификации в веб-интерфейсе.';

-- ----------------------------------------------------------------------------- 
-- Таблица: subdivisions
-- Назначение: Хранение иерархии подразделений (объектов мониторинга).
-- -----------------------------------------------------------------------------
CREATE TABLE subdivisions (
    id SERIAL PRIMARY KEY,                        -- Внутренний ID подразделения
    object_id INTEGER NOT NULL UNIQUE,            -- Внешний ID (например, из ERP, для API и агентов)
    short_name VARCHAR(100) NOT NULL,             -- Короткое, отображаемое имя
    full_name TEXT NULL,                          -- Полное официальное наименование
    parent_id INTEGER NULL,                       -- ID родительского подразделения (для иерархии)
    domain_name TEXT NULL,                        -- Имя домена, связанного с подразделением (если применимо)
    transport_system_code VARCHAR(10) NULL,       -- Уникальный код для оффлайн-агентов (доставка конфигураций)
    priority INTEGER DEFAULT 10 NOT NULL,         -- Приоритет для сортировки в UI
    comment TEXT NULL,                            -- Произвольный комментарий
    icon_filename VARCHAR(100) NULL,              -- Имя файла иконки для UI (из static/images/subdivisions/)
    CONSTRAINT unique_subdivision_transport_code UNIQUE (transport_system_code), -- Код ТС должен быть уникален, если задан
    CONSTRAINT check_transport_system_code_format CHECK (transport_system_code IS NULL OR transport_system_code ~ '^[A-Za-z0-9_.-]{1,10}$') -- Формат кода ТС (добавлены дефис и точка)
);
COMMENT ON TABLE subdivisions IS 'Иерархическая структура подразделений (объектов мониторинга).';
COMMENT ON COLUMN subdivisions.object_id IS 'Внешний уникальный идентификатор подразделения.';
COMMENT ON COLUMN subdivisions.transport_system_code IS 'Уникальный код для связи с транспортной системой оффлайн-агентов.';

-- ----------------------------------------------------------------------------- 
-- Таблица: node_types
-- Назначение: Справочник типов узлов мониторинга (например, Сервер, АРМ, Канал).
-- -----------------------------------------------------------------------------
CREATE TABLE node_types (
    id SERIAL PRIMARY KEY,                        -- Внутренний ID типа узла
    name TEXT NOT NULL,                           -- Отображаемое имя типа (например, "Сервер Windows", "АРМ Оператора")
    description TEXT,                             -- Подробное описание типа
    parent_type_id INTEGER NULL,                  -- ID родительского типа (для иерархии типов)
    priority INTEGER DEFAULT 10 NOT NULL,         -- Приоритет для сортировки в UI
    icon_filename VARCHAR(100) NULL,              -- Имя файла иконки для UI (из static/icons/)
    CONSTRAINT unique_type_name_parent UNIQUE (name, parent_type_id) -- Имя типа должно быть уникально в пределах одного родителя (или среди корневых)
);
COMMENT ON TABLE node_types IS 'Иерархический справочник типов узлов мониторинга.';
COMMENT ON COLUMN node_types.icon_filename IS 'Имя файла иконки из директории static/icons/.';

-- ----------------------------------------------------------------------------- 
-- Таблица: node_property_types
-- Назначение: Справочник типов настраиваемых свойств для узлов (например, 'timeout_minutes').
-- -----------------------------------------------------------------------------
CREATE TABLE node_property_types (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,                    -- Системное имя типа свойства (например, 'timeout_minutes', 'icon_color')
    description TEXT                              -- Человекочитаемое описание типа свойства
);
COMMENT ON TABLE node_property_types IS 'Справочник типов настраиваемых свойств для типов узлов.';

-- ----------------------------------------------------------------------------- 
-- Таблица: check_methods
-- Назначение: Справочник доступных методов проверки (типов шагов pipeline).
-- -----------------------------------------------------------------------------
CREATE TABLE check_methods (
    id SERIAL PRIMARY KEY,
    method_name TEXT NOT NULL UNIQUE,             -- Уникальное имя метода/типа шага (например, 'PING', 'POWERSHELL_EXECUTE')
    description TEXT                              -- Описание метода/типа шага
);
COMMENT ON TABLE check_methods IS 'Справочник методов проверки узлов (используется как тип шага в pipeline).';

-- ----------------------------------------------------------------------------- 
-- Таблица: node_properties
-- Назначение: Хранение значений свойств для конкретных типов узлов.
-- -----------------------------------------------------------------------------
CREATE TABLE node_properties (
    id SERIAL PRIMARY KEY,
    node_type_id INTEGER NOT NULL,                -- Ссылка на node_types.id
    property_type_id INTEGER NOT NULL,            -- Ссылка на node_property_types.id
    property_value TEXT NOT NULL,                 -- Значение свойства (текстовое)
    CONSTRAINT fk_np_node_type FOREIGN KEY (node_type_id) REFERENCES node_types(id) ON DELETE CASCADE,
    CONSTRAINT fk_np_property_type FOREIGN KEY (property_type_id) REFERENCES node_property_types(id) ON DELETE CASCADE,
    CONSTRAINT unique_node_type_property UNIQUE (node_type_id, property_type_id) -- Свойство может быть назначено типу узла только один раз
);
COMMENT ON TABLE node_properties IS 'Значения настраиваемых свойств, присвоенные конкретным типам узлов.';

-- ----------------------------------------------------------------------------- 
-- Таблица: nodes
-- Назначение: Хранение информации о конкретных узлах мониторинга.
-- -----------------------------------------------------------------------------
CREATE TABLE nodes (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,                   -- Имя узла (например, hostname)
    parent_subdivision_id INTEGER NOT NULL,       -- Ссылка на subdivisions.id
    ip_address VARCHAR(45),                       -- IP-адрес узла (может быть IPv4 или IPv6)
    node_type_id INTEGER,                         -- Ссылка на node_types.id
    description TEXT,                             -- Описание узла
    CONSTRAINT fk_node_subdivision FOREIGN KEY (parent_subdivision_id) REFERENCES subdivisions(id) ON DELETE CASCADE, -- Узлы удаляются вместе с подразделением
    CONSTRAINT fk_node_type FOREIGN KEY (node_type_id) REFERENCES node_types(id) ON DELETE SET NULL, -- При удалении типа, у узла тип сбрасывается
    CONSTRAINT unique_node_name_parent_subdivision UNIQUE (name, parent_subdivision_id) -- Имя узла уникально в пределах подразделения
);
COMMENT ON TABLE nodes IS 'Узлы мониторинга (серверы, рабочие станции, сетевое оборудование и т.д.).';

-- ----------------------------------------------------------------------------- 
-- Таблица: api_keys
-- Назначение: Хранение API-ключей для аутентификации агентов и сервисов.
-- -----------------------------------------------------------------------------
CREATE TABLE api_keys (
    id SERIAL PRIMARY KEY,
    key_hash VARCHAR(64) NOT NULL UNIQUE,         -- SHA-256 хеш от API-ключа
    description TEXT NOT NULL,                    -- Описание назначения ключа
    role VARCHAR(50) NOT NULL DEFAULT 'agent'     -- Роль ключа (agent, loader, configurator, admin)
        CHECK (role IN ('agent', 'loader', 'configurator', 'admin')),
    object_id INTEGER NULL,                       -- Ссылка на subdivisions.object_id (для ключей агентов/конфигураторов)
    is_active BOOLEAN DEFAULT TRUE NOT NULL,      -- Флаг активности ключа
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_used_at TIMESTAMPTZ NULL,                -- Время последнего использования ключа
    CONSTRAINT fk_api_key_subdivision_object_id FOREIGN KEY (object_id) REFERENCES subdivisions(object_id) ON DELETE SET NULL -- Если подразделение удалено, object_id сбрасывается в NULL
);
COMMENT ON TABLE api_keys IS 'API ключи для аутентификации агентов и внешних скриптов/сервисов.';

-- ----------------------------------------------------------------------------- 
-- Таблица: node_checks
-- Назначение: Хранение истории результатов выполнения проверок/pipeline-заданий.
--             Версия 5.0.3: Добавлено поле check_success.
-- -----------------------------------------------------------------------------
CREATE TABLE node_checks (
    id SERIAL PRIMARY KEY,
    node_id INTEGER NOT NULL,                     -- Ссылка на nodes.id (будет добавлена в 005_add_foreign_keys.sql)
    assignment_id INTEGER NULL,                   -- Ссылка на node_check_assignments.id (будет добавлена)
    method_id INTEGER NOT NULL,                   -- Ссылка на check_methods.id (основной метод задания, будет добавлена)
    is_available BOOLEAN NOT NULL,                -- Результат доступности проверки/pipeline (True/False)
    check_success BOOLEAN NULL,                   -- <<< ДОБАВЛЕНО ПОЛЕ >>> Результат выполнения критериев (True/False/Null)
    checked_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL, -- Время записи результата в БД (серверное)
    check_timestamp TIMESTAMPTZ,                  -- Время фактического выполнения проверки на агенте (если передано)
    executor_object_id INTEGER NULL,              -- ID объекта (подразделения) исполнителя (агента)
    executor_host TEXT NULL,                      -- Имя хоста исполнителя (агента)
    resolution_method TEXT NULL,                  -- Имя метода/типа проверки, как его определил агент/загрузчик
    assignment_config_version VARCHAR(100) NULL,  -- Версия конфигурации заданий (для оффлайн-агентов)
    agent_script_version VARCHAR(100) NULL        -- Версия скрипта агента
);
COMMENT ON TABLE node_checks IS 'История результатов выполнения проверок/pipeline-заданий узлов.';
COMMENT ON COLUMN node_checks.is_available IS 'Указывает, удалось ли успешно выполнить саму проверку/pipeline (True) или произошла ошибка выполнения (False).';
COMMENT ON COLUMN node_checks.check_success IS 'Результат выполнения критериев успеха для данной проверки/pipeline (True - критерии пройдены, False - не пройдены, Null - критерии не применялись или ошибка их оценки).';
COMMENT ON COLUMN node_checks.checked_at IS 'Серверное время UTC записи результата проверки в базу данных.';
COMMENT ON COLUMN node_checks.check_timestamp IS 'Время UTC фактического выполнения проверки на агенте (если предоставлено агентом).';

-- ----------------------------------------------------------------------------- 
-- Таблица: node_check_assignments (ЗАДАНИЯ)
-- Назначение: Задания на проверку узлов (pipeline-архитектура).
-- -----------------------------------------------------------------------------
CREATE TABLE node_check_assignments (
    id SERIAL PRIMARY KEY,
    node_id INTEGER NOT NULL,                     -- Ссылка на nodes.id (будет добавлена в 005_add_foreign_keys.sql)
    method_id INTEGER NOT NULL,                   -- Ссылка на check_methods.id (основной метод для классификации задания)
    pipeline JSONB NOT NULL,                      -- Описание pipeline (массив шагов в JSONB)
    check_interval_seconds INTEGER DEFAULT 300 NOT NULL, -- Периодичность выполнения задания (агентом)
    is_enabled BOOLEAN DEFAULT TRUE NOT NULL,     -- Флаг активности задания
    description TEXT,                             -- Описание назначения задания
    last_executed_at TIMESTAMPTZ NULL,            -- Время последнего выполнения (или записи результата)
    last_node_check_id INTEGER NULL               -- Ссылка на последнюю запись в node_checks по этому заданию
);
COMMENT ON TABLE node_check_assignments IS 'Задания на проверку узлов (pipeline-архитектура).';
COMMENT ON COLUMN node_check_assignments.pipeline IS 'JSONB-массив, описывающий последовательность шагов (конвейер) проверки. Каждый шаг имеет свой тип (из check_methods), параметры и, возможно, критерии успеха.';
COMMENT ON COLUMN node_check_assignments.is_enabled IS 'Флаг, указывающий, активно ли данное задание и должно ли оно запрашиваться и выполняться агентами.';
COMMENT ON COLUMN node_check_assignments.method_id IS 'Ссылка на основной метод/тип проверки (из check_methods), к которому относится это задание (для общей классификации и UI). Реальная логика выполнения определяется полем pipeline.';
COMMENT ON COLUMN node_check_assignments.last_node_check_id IS 'Ссылка на ID последней записи о проверке (из таблицы node_checks), выполненной по этому заданию.';

-- ----------------------------------------------------------------------------- 
-- Таблица: node_check_details
-- Назначение: Детализированные результаты проверок (например, вывод команды, список файлов).
-- -----------------------------------------------------------------------------
CREATE TABLE node_check_details (
    id SERIAL PRIMARY KEY,
    node_check_id INTEGER NOT NULL,               -- Ссылка на node_checks.id (будет добавлена)
    detail_type TEXT NOT NULL,                    -- Тип детализации (например, 'PING_REPLY', 'PROCESS_INFO_RAW', 'STEPS_RESULTS')
    data JSONB NOT NULL                           -- Сами детали в формате JSONB
);
COMMENT ON TABLE node_check_details IS 'Детализированные результаты отдельных проверок или шагов pipeline в формате JSONB.';

-- ----------------------------------------------------------------------------- 
-- Таблица: system_events
-- Назначение: Журнал системных событий приложения (логи).
-- -----------------------------------------------------------------------------
CREATE TABLE system_events (
    id SERIAL PRIMARY KEY,
    event_time TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL, -- Время возникновения события (серверное UTC)
    event_type VARCHAR(50) NOT NULL,              -- Тип события (например, 'USER_LOGIN', 'API_KEY_CREATED', 'FILE_PROCESSED')
    severity VARCHAR(10) NOT NULL DEFAULT 'INFO'  -- Уровень важности события
        CHECK (severity IN ('INFO', 'WARN', 'ERROR', 'CRITICAL')),
    message TEXT NOT NULL,                        -- Основное сообщение события
    source VARCHAR(100),                          -- Источник события (например, имя модуля, IP-адрес)
    object_id INTEGER NULL,                       -- ID связанного объекта (подразделения)
    node_id INTEGER NULL,                         -- ID связанного узла
    assignment_id INTEGER NULL,                   -- ID связанного задания
    node_check_id INTEGER NULL,                   -- ID связанного результата проверки
    related_entity VARCHAR(50),                   -- Тип другой связанной сущности (например, 'FILE', 'USER')
    related_entity_id TEXT,                       -- ID или имя этой связанной сущности
    details JSONB                                 -- Дополнительные детали события в JSONB
);
COMMENT ON TABLE system_events IS 'Журнал системных событий (логирование действий пользователей, ошибок приложения, важных операций).';

-- ----------------------------------------------------------------------------- 
-- Таблица: offline_config_versions
-- Назначение: Хранение версий конфигураций для оффлайн-агентов.
-- -----------------------------------------------------------------------------
CREATE TABLE offline_config_versions (
    version_id SERIAL PRIMARY KEY,
    object_id INT NULL,                           -- ID объекта (подразделения), для которого эта версия конфигурации (если применимо)
    config_type VARCHAR(20) NOT NULL              -- Тип конфигурации ('assignments' для заданий, 'script' для скрипта агента)
        CHECK (config_type IN ('assignments', 'script')),
    version_tag VARCHAR(100) NOT NULL UNIQUE,     -- Уникальный тег версии (например, YYYYMMDDHHMMSS_ObjectID_hash)
    content_hash VARCHAR(64) NOT NULL,            -- SHA-256 хеш содержимого конфигурации (для отслеживания изменений)
    description TEXT NULL,                        -- Описание этой версии конфигурации
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL, -- Время создания версии
    is_active BOOLEAN DEFAULT TRUE NOT NULL,      -- Является ли эта версия текущей активной для данного object_id и config_type
    file_path VARCHAR(255) NULL,                  -- Путь к файлу конфигурации на сервере (если он сохраняется)
    transport_system_code VARCHAR(10) NULL        -- Код ТС, для которого эта конфигурация (для удобства поиска)
);
COMMENT ON TABLE offline_config_versions IS 'Версии конфигураций (заданий или скриптов) для оффлайн-агентов, позволяет отслеживать изменения.';

-- =============================================================================
-- == КОНЕЦ СОЗДАНИЯ ТАБЛИЦ ==
-- =============================================================================