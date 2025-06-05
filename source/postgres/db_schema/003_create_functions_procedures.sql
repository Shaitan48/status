-- =============================================================================
-- Файл: 003_create_functions_procedures.sql
-- Назначение: Создание хранимых функций и процедур.
-- Версия схемы: 5.0.2 (record_check_result_proc принимает p_check_success)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Процедура: record_check_result_proc (Версия с поддержкой p_check_success)
-- Назначение: Атомарная запись результата проверки узла (или pipeline-задания).
--             Включает запись is_available и нового check_success в node_checks.
--             Обновляет last_executed_at и last_node_check_id в node_check_assignments.
--             Логирует событие 'CHECK_RESULT_RECEIVED' в system_events.
-- Версия схемы: 5.0.2
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE record_check_result_proc(
    p_assignment_id INTEGER,
    p_is_available BOOLEAN,
    p_check_success BOOLEAN, -- <<< НОВЫЙ ПАРАМЕТР: результат выполнения критериев
    p_check_timestamp TIMESTAMPTZ,
    p_executor_object_id INTEGER,
    p_executor_host TEXT,
    p_resolution_method TEXT,
    p_detail_type TEXT DEFAULT NULL,
    p_detail_data JSONB DEFAULT NULL,
    p_assignment_version TEXT DEFAULT NULL,
    p_agent_version TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_node_id INTEGER;
    v_method_id INTEGER; -- Основной метод задания (для классификации)
    v_node_check_id INTEGER; -- ID созданной записи в node_checks
    v_node_name VARCHAR(255);
    v_parent_subdivision_id INTEGER;
BEGIN
    -- 1. Получаем информацию о задании и связанном узле
    SELECT a.node_id, a.method_id, n.name, n.parent_subdivision_id
    INTO v_node_id, v_method_id, v_node_name, v_parent_subdivision_id
    FROM node_check_assignments a
    JOIN nodes n ON a.node_id = n.id
    WHERE a.id = p_assignment_id;

    IF NOT FOUND THEN
        -- Если задание не найдено, логируем ошибку и выходим.
        -- Это может произойти, если задание было удалено, пока агент выполнял проверку.
        -- Или если агент прислал неверный assignment_id.
        -- Используем RAISE EXCEPTION с пользовательским кодом ошибки.
        RAISE EXCEPTION 'Задание с ID % не найдено.' , p_assignment_id
            USING ERRCODE = 'P0002', HINT = 'Проверьте ID задания или убедитесь, что задание существует.';
    END IF;

    -- 2. Вставляем результат в node_checks, включая новое поле check_success
    INSERT INTO node_checks (
        node_id, assignment_id, method_id,
        is_available, check_success, -- <<< ДОБАВЛЕНО check_success
        checked_at, -- Время записи в БД (серверное)
        check_timestamp, -- Время выполнения на агенте
        executor_object_id, executor_host, resolution_method,
        assignment_config_version, agent_script_version
    )
    VALUES (
        v_node_id, p_assignment_id, v_method_id,
        p_is_available, p_check_success, -- <<< ПЕРЕДАЕМ p_check_success
        CURRENT_TIMESTAMP, -- checked_at всегда текущее время сервера
        COALESCE(p_check_timestamp, CURRENT_TIMESTAMP), -- Используем время агента, если есть, иначе время сервера
        p_executor_object_id, p_executor_host, p_resolution_method,
        p_assignment_version, p_agent_version
    )
    RETURNING id INTO v_node_check_id; -- Получаем ID созданной записи

    -- 3. Если переданы детали, записываем их в node_check_details
    IF p_detail_type IS NOT NULL AND p_detail_data IS NOT NULL THEN
        INSERT INTO node_check_details (node_check_id, detail_type, data)
        VALUES (v_node_check_id, p_detail_type, p_detail_data);
    END IF;

    -- 4. Обновляем информацию о последней проверке в node_check_assignments
    --    last_executed_at - это время выполнения на агенте (p_check_timestamp), если доступно,
    --    иначе время записи результата в БД (CURRENT_TIMESTAMP из VALUES выше).
    UPDATE node_check_assignments
    SET
        last_executed_at = COALESCE(p_check_timestamp, CURRENT_TIMESTAMP),
        last_node_check_id = v_node_check_id
    WHERE id = p_assignment_id;

    -- 5. Логируем событие о получении результата проверки
    INSERT INTO system_events (
        event_type, severity, message, source,
        object_id, node_id, assignment_id, node_check_id,
        details
    )
    VALUES (
        'CHECK_RESULT_RECEIVED', 'INFO',
        format('Получен результат для узла "%s" (Задание ID %s, Метод ID %s): IsAvailable=%s, CheckSuccess=%s.',
               v_node_name, p_assignment_id, v_method_id, p_is_available, COALESCE(p_check_success::text, 'N/A')),
        'record_check_result_proc', p_executor_object_id, v_node_id, p_assignment_id, v_node_check_id,
        jsonb_build_object(
            'executor_host', p_executor_host,
            'resolution_method', p_resolution_method,
            'source_timestamp_utc', p_check_timestamp, -- Время от агента (может быть NULL)
            'has_details', (p_detail_type IS NOT NULL AND p_detail_data IS NOT NULL),
            'parent_subdivision_id', v_parent_subdivision_id, -- ID подразделения узла
            'assignment_version', p_assignment_version,
            'agent_version', p_agent_version
        )
    );

EXCEPTION
    WHEN SQLSTATE 'P0002' THEN -- Код ошибки 'Задание не найдено', который мы сами определили
        -- Логируем как WARN, т.к. это ожидаемая (хоть и нежелательная) ситуация
        INSERT INTO system_events (event_type, severity, message, source, object_id, details)
        VALUES (
            'DB_PROC_WARN', 'WARN', -- Используем новый тип события
            format('Попытка записи результата для несуществующего задания ID=%s. Исполнитель: ObjectID=%s (Хост: %s). Сообщение SQL: %s',
                   p_assignment_id, p_executor_object_id, p_executor_host, SQLERRM),
            'record_check_result_proc', p_executor_object_id,
            jsonb_build_object(
                 'original_assignment_id', p_assignment_id,
                 'original_sqlstate', SQLSTATE, -- Сохраняем исходный SQLSTATE
                 'assignment_version', p_assignment_version,
                 'agent_version', p_agent_version
            )
        );
        RAISE; -- Пробрасываем исключение дальше, чтобы Flask API мог его обработать (например, вернуть 404)
    WHEN OTHERS THEN -- Все другие ошибки SQL (ограничения, ошибки типов и т.д.)
        INSERT INTO system_events (event_type, severity, message, source, object_id, node_id, details)
        VALUES (
            'DB_PROC_ERROR', 'ERROR', -- Новый тип события для ошибок процедуры
            format('Ошибка SQL при обработке результата (Задание ID %s, Узел: %s): %s. SQLSTATE: %s',
                   COALESCE(p_assignment_id::text, 'N/A'), COALESCE(v_node_name, v_node_id::text, 'N/A'), SQLERRM, SQLSTATE),
            'record_check_result_proc', p_executor_object_id, v_node_id,
            jsonb_build_object(
                'sqlstate', SQLSTATE,
                'original_assignment_id', p_assignment_id,
                'assignment_version', p_assignment_version,
                'agent_version', p_agent_version
            )
        );
        RAISE; -- Пробрасываем исключение дальше
END;
$$;
COMMENT ON PROCEDURE record_check_result_proc(INTEGER, BOOLEAN, BOOLEAN, TIMESTAMPTZ, INTEGER, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT)
IS 'Записывает результат проверки/pipeline-задания, включая is_available и check_success. Обновляет задание и логирует событие. Версия схемы: 5.0.2.';

-- ... (остальные функции get_active_assignments_for_object, generate_offline_config, и т.д. БЕЗ ИЗМЕНЕНИЙ от предыдущей версии,
--      т.к. они уже работают с pipeline и не зависят от check_success напрямую в своих возвращаемых значениях) ...

-- Функция: get_active_assignments_for_object (Версия для pipeline-архитектуры)
-- ... (код без изменений, уже возвращает pipeline) ...
CREATE OR REPLACE FUNCTION get_active_assignments_for_object(p_executor_object_id INTEGER)
RETURNS TABLE (
    assignment_id INTEGER,
    node_id INTEGER,
    node_name VARCHAR(255),
    ip_address VARCHAR(45),
    method_name TEXT,
    pipeline JSONB, 
    check_interval_seconds INTEGER
) AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM subdivisions WHERE object_id = p_executor_object_id) THEN
        RAISE WARNING 'Подразделение с object_id % не найдено при запросе активных заданий.', p_executor_object_id;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        nca.id AS assignment_id,
        n.id AS node_id,
        n.name AS node_name,
        n.ip_address AS ip_address,
        cm.method_name AS method_name,
        nca.pipeline, 
        nca.check_interval_seconds
    FROM node_check_assignments nca
    JOIN nodes n ON nca.node_id = n.id
    JOIN subdivisions s ON n.parent_subdivision_id = s.id
    JOIN check_methods cm ON nca.method_id = cm.id
    WHERE
        nca.is_enabled = TRUE 
        AND s.object_id = p_executor_object_id
    ORDER BY
        n.name, nca.id;
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION get_active_assignments_for_object(INTEGER)
IS 'Возвращает активные (is_enabled=TRUE) pipeline-задания для агента по его executor object_id. Версия схемы: 5.0.2.';

-- Функция: generate_offline_config (Версия для pipeline-архитектуры)
-- ... (код без изменений, уже генерирует с pipeline) ...
CREATE OR REPLACE FUNCTION generate_offline_config(p_executor_object_id INTEGER)
RETURNS JSONB AS $$
DECLARE
    v_assignments_jsonb JSONB;
    v_default_interval INTEGER;
    v_config_jsonb JSONB;
    v_subdivision_info RECORD;
    v_assignment_version_tag TEXT;
    v_content_hash TEXT;
    v_last_version_hash TEXT;
BEGIN
    SELECT s.id, s.transport_system_code INTO v_subdivision_info
    FROM subdivisions s WHERE s.object_id = p_executor_object_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Subdivision not found', 'message', 'Подразделение с указанным object_id не найдено.', 'object_id', p_executor_object_id); END IF;
    IF v_subdivision_info.transport_system_code IS NULL THEN RETURN jsonb_build_object('error', 'Transport system code missing', 'message', 'Для подразделения не указан код транспортной системы (transport_system_code).', 'object_id', p_executor_object_id); END IF;

    SELECT CAST(value AS INTEGER) INTO v_default_interval FROM settings WHERE key = 'default_check_interval_seconds';
    v_default_interval := COALESCE(v_default_interval, 300); -- Увеличил стандартный интервал по умолчанию

    SELECT COALESCE(jsonb_agg(assignment_item ORDER BY node_name, assignment_id), '[]'::jsonb)
    INTO v_assignments_jsonb
    FROM (
        SELECT
            nca.id AS assignment_id,
            n.name AS node_name,
            jsonb_build_object(
                'assignment_id', nca.id,
                'node_id', n.id,
                'node_name', n.name,
                'ip_address', n.ip_address,
                'method_name', cm.method_name, 
                'pipeline', nca.pipeline,
                'interval_seconds', COALESCE(nca.check_interval_seconds, v_default_interval)
            ) AS assignment_item
        FROM node_check_assignments nca
        JOIN nodes n ON nca.node_id = n.id
        JOIN subdivisions s ON n.parent_subdivision_id = s.id
        JOIN check_methods cm ON nca.method_id = cm.id
        WHERE nca.is_enabled = TRUE AND s.object_id = p_executor_object_id
    ) AS sub_assignments;

    BEGIN
        v_content_hash := encode(digest(v_assignments_jsonb::text, 'sha256'), 'hex');
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Не удалось рассчитать SHA256 хэш для версионирования заданий (pgcrypto?). Версионирование пропускается. Ошибка: %', SQLERRM;
        v_content_hash := NULL;
    END;

    v_assignment_version_tag := NULL;
    IF v_content_hash IS NOT NULL THEN
        SELECT ocv.version_tag, ocv.content_hash INTO v_assignment_version_tag, v_last_version_hash
        FROM offline_config_versions ocv
        WHERE ocv.object_id = p_executor_object_id AND ocv.config_type = 'assignments' AND ocv.is_active = TRUE
        ORDER BY ocv.created_at DESC LIMIT 1;
        IF FOUND AND v_last_version_hash = v_content_hash THEN
             RAISE NOTICE '[Ver OfflineCfg] Конфигурация заданий для object_id % не изменилась. Версия: %', p_executor_object_id, v_assignment_version_tag;
        ELSE
             v_assignment_version_tag := to_char(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISSMS') || '_' || p_executor_object_id || '_' || left(v_content_hash, 8); -- Добавил MS для большей уникальности
             RAISE NOTICE '[Ver OfflineCfg] Конфигурация заданий для object_id % изменилась/новая. Новая версия: %', p_executor_object_id, v_assignment_version_tag;
             INSERT INTO offline_config_versions (object_id, config_type, version_tag, content_hash, description, transport_system_code, is_active)
             VALUES (p_executor_object_id, 'assignments', v_assignment_version_tag, v_content_hash, 'Авто-версия pipeline-заданий', v_subdivision_info.transport_system_code, TRUE)
             ON CONFLICT (version_tag) DO NOTHING;
        END IF;
    ELSE
        v_assignment_version_tag := 'nohash_' || to_char(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISSMS') || '_' || p_executor_object_id;
        RAISE WARNING '[Ver OfflineCfg] Используется временный тег версии (pgcrypto не сработал): %', v_assignment_version_tag;
    END IF;

    v_config_jsonb := jsonb_build_object(
        'object_id', p_executor_object_id,
        'config_type', 'offline_hybrid_agent_pipeline_v5.0.2', -- Обновляем версию формата конфига
        'generated_at_utc', CURRENT_TIMESTAMP, -- Добавляем _utc для ясности
        'assignment_config_version', v_assignment_version_tag,
        'transport_system_code', v_subdivision_info.transport_system_code,
        'default_check_interval_seconds', v_default_interval,
        'assignments', v_assignments_jsonb
    );
    RETURN v_config_jsonb;
END;
$$ LANGUAGE plpgsql VOLATILE;
COMMENT ON FUNCTION generate_offline_config(INTEGER)
IS 'Генерирует JSON конфигурацию (метаданные + активные pipeline-задания) для оффлайн-агента. Версия схемы: 5.0.2.';

-- Функция: get_node_base_info (Без изменений, т.к. не зависит от check_success напрямую)
-- ... (код без изменений) ...
CREATE OR REPLACE FUNCTION get_node_base_info(node_id_filter INTEGER DEFAULT NULL)
RETURNS TABLE (
    id INTEGER, name VARCHAR(255), ip_address VARCHAR(45), description TEXT,
    subdivision_id INTEGER, subdivision_short_name VARCHAR(100),
    node_type_id INTEGER, node_type_name TEXT, node_type_path TEXT,
    node_type_priority INTEGER,
    timeout_minutes INTEGER, display_order INTEGER, icon_color TEXT, icon_filename VARCHAR(100)
) AS $$
-- ... (тело функции без изменений) ...
DECLARE v_default_node_type_id INTEGER := 0;
BEGIN
    RETURN QUERY
    WITH RECURSIVE type_hierarchy AS (
        SELECT nt.id, nt.name, nt.parent_type_id, nt.name::TEXT AS path, nt.priority, nt.icon_filename
        FROM node_types nt WHERE nt.parent_type_id IS NULL
        UNION ALL
        SELECT nt.id, nt.name, nt.parent_type_id, th.path || ' > ' || nt.name, nt.priority, nt.icon_filename
        FROM node_types nt JOIN type_hierarchy th ON nt.parent_type_id = th.id
    ),
    node_type_properties AS (
         SELECT
            p.node_type_id,
            MAX(CASE WHEN pt.name = 'timeout_minutes' THEN p.property_value END) AS timeout_minutes,
            MAX(CASE WHEN pt.name = 'display_order' THEN p.property_value END) AS display_order,
            MAX(CASE WHEN pt.name = 'icon_color' THEN p.property_value END) AS icon_color
         FROM node_properties p JOIN node_property_types pt ON p.property_type_id = pt.id
         WHERE pt.name IN ('timeout_minutes', 'display_order', 'icon_color')
         GROUP BY p.node_type_id
    ),
    default_type_info AS (
        SELECT nt.id, nt.name, nt.priority, nt.icon_filename, ntp.timeout_minutes, ntp.display_order, ntp.icon_color
        FROM node_types nt LEFT JOIN node_type_properties ntp ON ntp.node_type_id = nt.id
        WHERE nt.id = v_default_node_type_id LIMIT 1
    )
    SELECT
        n.id, n.name, n.ip_address, n.description,
        n.parent_subdivision_id AS subdivision_id,
        s.short_name AS subdivision_short_name,
        COALESCE(n.node_type_id, v_default_node_type_id) AS node_type_id,
        COALESCE(th.name, (SELECT dti.name FROM default_type_info dti)) AS node_type_name,
        COALESCE(th.path, (SELECT dti.name FROM default_type_info dti)) AS node_type_path,
        COALESCE(th.priority, (SELECT dti.priority FROM default_type_info dti)) AS node_type_priority,
        CAST(COALESCE(ntp_actual.timeout_minutes, (SELECT dti.timeout_minutes FROM default_type_info dti), '5') AS INTEGER) AS timeout_minutes,
        CAST(COALESCE(ntp_actual.display_order, (SELECT dti.display_order FROM default_type_info dti), '999') AS INTEGER) AS display_order,
        COALESCE(ntp_actual.icon_color, (SELECT dti.icon_color FROM default_type_info dti), '#95a5a6') AS icon_color,
        COALESCE(th.icon_filename, (SELECT dti.icon_filename FROM default_type_info dti), 'other.svg') AS icon_filename
    FROM nodes n
    JOIN subdivisions s ON n.parent_subdivision_id = s.id
    LEFT JOIN type_hierarchy th ON n.node_type_id = th.id
    LEFT JOIN node_type_properties ntp_actual ON ntp_actual.node_type_id = COALESCE(n.node_type_id, v_default_node_type_id)
    WHERE node_id_filter IS NULL OR n.id = node_id_filter
    ORDER BY s.priority, s.short_name, node_type_priority, display_order, n.name;
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION get_node_base_info(INTEGER)
IS 'Возвращает базовую информацию об узлах, их типах, подразделениях и вычисленных свойствах. Версия схемы: 5.0.2.';


-- Функция: get_node_ping_status (ВАЖНО: теперь должна возвращать и check_success)
-- Назначение: Возвращает статус последней PING-проверки для узлов.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_node_ping_status(node_id_filter INTEGER DEFAULT NULL)
RETURNS TABLE (
    node_id INTEGER,
    is_available BOOLEAN,
    check_success BOOLEAN, -- <<< ДОБАВЛЕНО: поле для результата критериев
    last_checked TIMESTAMPTZ, -- Время записи в БД
    last_available TIMESTAMPTZ, -- Время последнего УСПЕШНОГО (is_available=true, check_success=true) пинга
    check_timestamp TIMESTAMPTZ, -- Время на агенте
    executor_object_id INTEGER,
    executor_host TEXT
) AS $$
DECLARE
    v_ping_method_id INTEGER;
BEGIN
    SELECT cm.id INTO v_ping_method_id FROM check_methods cm WHERE cm.method_name = 'PING' LIMIT 1;
    IF v_ping_method_id IS NULL THEN
        RAISE WARNING 'Метод PING не найден в check_methods. Статус PING не может быть определен.';
        RETURN;
    END IF;

    RETURN QUERY
    WITH ping_assignments AS (
        -- Находим все активные PING-задания
        SELECT nca.id as assignment_id, nca.node_id
        FROM node_check_assignments nca
        WHERE nca.method_id = v_ping_method_id
          AND nca.is_enabled = TRUE -- Учитываем только включенные задания
          AND (node_id_filter IS NULL OR nca.node_id = node_id_filter)
    ),
    last_ping_checks AS (
        -- Последняя проверка PING для каждого узла, выполненная по активному заданию
        SELECT DISTINCT ON (nc_inner.node_id)
            nc_inner.node_id,
            nc_inner.is_available,
            nc_inner.check_success, -- <<< ВЫБИРАЕМ check_success
            nc_inner.checked_at,    -- Время записи в БД
            nc_inner.check_timestamp, -- Время на агенте
            nc_inner.executor_object_id,
            nc_inner.executor_host
        FROM node_checks nc_inner
        JOIN ping_assignments pa ON nc_inner.assignment_id = pa.assignment_id -- Только по активным PING-заданиям
        ORDER BY nc_inner.node_id, nc_inner.checked_at DESC -- checked_at (БД) для определения "последней"
    ),
    last_truly_available_ping_checks AS (
        -- Последняя УСПЕШНАЯ проверка PING (is_available=TRUE И check_success=TRUE)
        SELECT DISTINCT ON (nc_avail.node_id)
            nc_avail.node_id,
            nc_avail.checked_at AS last_available_time -- Время записи в БД
        FROM node_checks nc_avail
        JOIN ping_assignments pa_avail ON nc_avail.assignment_id = pa_avail.assignment_id
        WHERE nc_avail.is_available = TRUE AND nc_avail.check_success = TRUE -- Условие успешности
        ORDER BY nc_avail.node_id, nc_avail.checked_at DESC
    )
    SELECT
        n.id as node_id,
        lpc.is_available,
        lpc.check_success, -- <<< ВОЗВРАЩАЕМ check_success
        lpc.checked_at AS last_checked,
        lapc.last_available_time AS last_available, -- Время последней полной доступности
        lpc.check_timestamp,
        lpc.executor_object_id,
        lpc.executor_host
    FROM nodes n
    LEFT JOIN last_ping_checks lpc ON n.id = lpc.node_id
    LEFT JOIN last_truly_available_ping_checks lapc ON n.id = lapc.node_id
    WHERE node_id_filter IS NULL OR n.id = node_id_filter;
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION get_node_ping_status(INTEGER)
IS 'Возвращает статус последней PING-проверки для узлов, включая is_available и check_success. Учитывает is_enabled в заданиях. Версия схемы: 5.0.2.';

-- Функция: get_subdivisions (Без изменений)
-- ... (код без изменений) ...
CREATE OR REPLACE FUNCTION get_subdivisions()
RETURNS TABLE (
    id INTEGER, object_id INTEGER, short_name VARCHAR(100), full_name TEXT,
    parent_id INTEGER, priority INTEGER, icon_filename VARCHAR(100)
) AS $$
BEGIN
    RETURN QUERY
    SELECT s.id, s.object_id, s.short_name, s.full_name, s.parent_id, s.priority, s.icon_filename
    FROM subdivisions s
    ORDER BY s.priority, s.short_name;
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION get_subdivisions()
IS 'Возвращает список всех подразделений (включая иконку), отсортированный по приоритету и имени. Версия схемы: 5.0.2.';

-- =============================================================================
-- == КОНЕЦ СОЗДАНИЯ ФУНКЦИЙ И ПРОЦЕДУР ==
-- =============================================================================