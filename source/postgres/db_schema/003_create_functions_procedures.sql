-- =============================================================================
-- Файл: 003_create_functions_procedures.sql
-- Назначение: Создание хранимых функций и процедур для инкапсуляции
--             бизнес-логики и упрощения взаимодействия с БД.
-- Версия схемы: ~4.4.0 (generate_offline_config с полным JSON и хешем)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Процедура: record_check_result (Версия с поддержкой версий агента/конфига)
-- Назначение: Атомарная запись результата проверки узла, полученного от агента.
-- ... (остальное описание) ...
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE record_check_result(
    p_assignment_id INTEGER,
    p_is_available BOOLEAN,
    p_check_timestamp TIMESTAMPTZ,
    p_executor_object_id INTEGER,
    p_executor_host TEXT,
    p_resolution_method TEXT,
    p_detail_type TEXT DEFAULT NULL,
    p_detail_data JSONB DEFAULT NULL,
    -- <<< НОВЫЕ ПАРАМЕТРЫ для версий >>>
    p_assignment_version TEXT DEFAULT NULL,
    p_agent_version TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_node_id INTEGER;
    v_method_id INTEGER;
    v_node_check_id INTEGER;
    v_node_name VARCHAR(255);
    v_parent_subdivision_id INTEGER;
BEGIN
    -- Получаем информацию о задании и узле
    SELECT a.node_id, a.method_id, n.name, n.parent_subdivision_id
    INTO v_node_id, v_method_id, v_node_name, v_parent_subdivision_id
    FROM node_check_assignments a JOIN nodes n ON a.node_id = n.id
    WHERE a.id = p_assignment_id;

    -- Обработка ненайденного задания
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Assignment with ID % not found.', p_assignment_id USING ERRCODE = 'P0002';
    END IF;

    -- Вставляем результат в node_checks, включая новые поля версий
    INSERT INTO node_checks (
        node_id, assignment_id, method_id, is_available, checked_at,
        check_timestamp, executor_object_id, executor_host, resolution_method,
        assignment_config_version, agent_script_version -- Новые колонки
    )
    VALUES (
        v_node_id, p_assignment_id, v_method_id, p_is_available, CURRENT_TIMESTAMP,
        COALESCE(p_check_timestamp, CURRENT_TIMESTAMP), p_executor_object_id, p_executor_host, p_resolution_method,
        p_assignment_version, p_agent_version -- Новые значения
    )
    RETURNING id INTO v_node_check_id; -- Получаем ID вставленной записи

    -- Вставка деталей (если есть)
    IF p_detail_type IS NOT NULL AND p_detail_data IS NOT NULL THEN
        INSERT INTO node_check_details (node_check_id, detail_type, data)
        VALUES (v_node_check_id, p_detail_type, p_detail_data);
    END IF;

    -- Обновление последнего чека в задании
    UPDATE node_check_assignments
    SET last_executed_at = CURRENT_TIMESTAMP, last_node_check_id = v_node_check_id
    WHERE id = p_assignment_id;

    -- Запись системного события (с добавлением версий в детали)
    INSERT INTO system_events (
        event_type, severity, message, source, object_id, node_id, assignment_id, node_check_id, details
    )
    VALUES (
        'CHECK_RESULT_RECEIVED', 'INFO',
        format('Получен результат для "%s" (Задание %s): Доступен=%s', v_node_name, p_assignment_id, p_is_available),
        'record_check_result_proc', p_executor_object_id, v_node_id, p_assignment_id, v_node_check_id,
        jsonb_build_object(
            'method_id', v_method_id,
            'executor_host', p_executor_host,
            'resolution_method', p_resolution_method,
            'source_timestamp', p_check_timestamp,
            'has_details', (p_detail_type IS NOT NULL),
            'parent_subdivision_id', v_parent_subdivision_id,
            'assignment_version', p_assignment_version, -- Добавлено
            'agent_version', p_agent_version         -- Добавлено
        )
    );

-- Обработка исключений
EXCEPTION
    WHEN SQLSTATE 'P0002' THEN -- Задание не найдено (no_data_found в Oracle, P0002 в PG по RAISE)
        -- <<< НАЧАЛО ИЗМЕНЕНИЯ >>>
        -- Записываем событие, но НЕ указываем assignment_id, чтобы избежать ошибки FK
        INSERT INTO system_events (
            event_type, severity, message, source, object_id, details
            -- Убираем assignment_id из INSERT
        )
        VALUES (
            'DB_WARN', 'WARN',
            format('Попытка записи результата для несуществующего задания ID=%s. Исполнитель: %s (Хост: %s)', p_assignment_id, p_executor_object_id, p_executor_host),
            'record_check_result_proc', p_executor_object_id,
            jsonb_build_object(
                 'original_assignment_id', p_assignment_id, -- Сохраняем ID в деталях
                 'assignment_version', p_assignment_version,
                 'agent_version', p_agent_version
            )
            -- Убираем p_assignment_id отсюда
        );
        -- <<< КОНЕЦ ИЗМЕНЕНИЯ >>>
        -- Вместо RAISE Exception теперь просто логируем и выходим
        -- RAISE; -- Убираем RAISE, чтобы не возвращать ошибку 500
        -- Процедура завершится без ошибки, но результат не будет записан.
        -- Route должен вернуть 404.
        -- Хотя нет, repo сейчас проверяет pgcode='P0002'. Значит надо вернуть ошибку.
        -- Вернем RAISE, но изменим INSERT в system_events

        -- <<< ВЕРНУЛИ RAISE, НО INSERT ИЗМЕНЕН >>>
         RAISE; -- Пробрасываем ошибку, чтобы репозиторий ее поймал как ValueError

    WHEN OTHERS THEN -- Другие ошибки
        -- <<< НАЧАЛО ИЗМЕНЕНИЯ (для единообразия) >>>
        INSERT INTO system_events (
            event_type, severity, message, source, object_id, node_id, details
             -- Убираем assignment_id, node_check_id
        )
        VALUES (
            'DB_ERROR', 'ERROR',
            format('Ошибка обработки результата (Задание %s, Узел: %s): %s', COALESCE(p_assignment_id, 'N/A'), COALESCE(v_node_name, 'N/A'), SQLERRM),
            'record_check_result_proc', p_executor_object_id, v_node_id,
            jsonb_build_object(
                'sqlstate', SQLSTATE,
                'original_assignment_id', p_assignment_id, -- Сохраняем ID
                'assignment_version', p_assignment_version,
                'agent_version', p_agent_version
            )
            -- Убираем assignment_id, v_node_check_id отсюда
        );
        -- <<< КОНЕЦ ИЗМЕНЕНИЯ >>>
        RAISE;
END;
$$;
COMMENT ON PROCEDURE record_check_result IS 'Записывает результат проверки узла, полученный от агента, включая версии конфигурации и скрипта.';


-- -----------------------------------------------------------------------------
-- Функция: get_active_assignments_for_object
-- Назначение: Возвращает список активных заданий для указанного подразделения (по object_id).
-- ... (остальное описание) ...
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_active_assignments_for_object(p_executor_object_id INTEGER)
RETURNS TABLE (
    assignment_id INTEGER,
    node_id INTEGER,
    node_name VARCHAR(255),
    ip_address VARCHAR(45),
    method_name TEXT,
    parameters JSONB,
    check_interval_seconds INTEGER,
    success_criteria JSONB
) AS $$
BEGIN
    -- Проверка существования подразделения (опционально)
    IF NOT EXISTS (SELECT 1 FROM subdivisions WHERE object_id = p_executor_object_id) THEN
        RAISE WARNING 'Подразделение с object_id % не найдено в таблице subdivisions.', p_executor_object_id;
        RETURN;
    END IF;

    -- Выполняем запрос на выборку активных заданий
    RETURN QUERY
    SELECT
        nca.id AS assignment_id,
        n.id AS node_id,
        n.name AS node_name,
        n.ip_address AS ip_address,
        cm.method_name AS method_name,
        nca.parameters,
        nca.check_interval_seconds,
        nca.success_criteria -- Включаем критерии
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
IS 'Возвращает активные задания для агента по его executor object_id (ID подразделения), включая критерии успеха.';


-- -----------------------------------------------------------------------------
-- Функция: generate_offline_config (Версия ~4.4 - с хешем содержимого)
-- Назначение: Генерирует ПОЛНУЮ JSON-конфигурацию с заданиями и метаданными
--             для оффлайн-агента, включая хеш содержимого.
-- Входные параметры:
--   p_executor_object_id INTEGER: Внешний ID подразделения агента.
-- Выход: JSONB - Структурированный JSON, содержащий метаданные, массив заданий и content_hash.
--             Пример: {"object_id": 1, "config_type": "...", "assignments": [...], "content_hash": "sha256..."}
--             В случае ошибки (не найдено подразделение) возвращает JSON с полем "error".
-- Возможные исключения: Нет.
-- Побочные эффекты: Может создавать запись в offline_config_versions.
-- Зависимости: Расширение pgcrypto для функции digest().
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_offline_config(p_executor_object_id INTEGER)
RETURNS JSONB AS $$
DECLARE
    v_assignments JSONB;
    v_default_interval INTEGER;
    v_config JSONB;        -- Итоговый JSON
    v_subdivision_info RECORD;
    v_assignment_version_tag TEXT;
    v_content_hash TEXT;         -- Хеш ТОЛЬКО массива заданий (для версионирования)
    v_last_version_hash TEXT;
BEGIN
    -- 1. Проверка подразделения и кода ТС (без изменений)
    SELECT s.id, s.transport_system_code INTO v_subdivision_info
    FROM subdivisions s WHERE s.object_id = p_executor_object_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Subdivision not found', 'object_id', p_executor_object_id); END IF;
    IF v_subdivision_info.transport_system_code IS NULL THEN RETURN jsonb_build_object('error', 'Subdivision transport_system_code is missing', 'object_id', p_executor_object_id); END IF;

    -- 2. Получаем интервал по умолчанию (без изменений)
    SELECT CAST(value AS INTEGER) INTO v_default_interval FROM settings WHERE key = 'default_check_interval_seconds';
    v_default_interval := COALESCE(v_default_interval, 120);

    -- 3. Собираем JSON с актуальными заданиями (без изменений)
    SELECT COALESCE(jsonb_agg(assignments_json ORDER BY node_name, assignment_id), '[]'::jsonb)
    INTO v_assignments
    FROM (
        SELECT
            nca.id AS assignment_id,
            n.name AS node_name,
            jsonb_build_object(
                'assignment_id', nca.id,
                'node_name', n.name,
                'ip_address', n.ip_address,
                'method_name', cm.method_name,
                'parameters', COALESCE(nca.parameters, '{}'::jsonb),
                'interval_seconds', COALESCE(nca.check_interval_seconds, v_default_interval),
                'success_criteria', nca.success_criteria
            ) AS assignments_json
        FROM node_check_assignments nca
        JOIN nodes n ON nca.node_id = n.id
        JOIN subdivisions s ON n.parent_subdivision_id = s.id
        JOIN check_methods cm ON nca.method_id = cm.id
        WHERE nca.is_enabled = TRUE AND s.object_id = p_executor_object_id
    ) AS sub;

    -- 4. Версионирование: Сравниваем хэш ТЕКУЩИХ ЗАДАНИЙ (только массива assignments!)
    BEGIN
        v_content_hash := encode(digest(v_assignments::text, 'sha256'), 'hex');
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Не удалось рассчитать SHA256 хэш для версионирования заданий (pgcrypto?). Версионирование пропускается.';
        v_content_hash := NULL;
    END;

    v_assignment_version_tag := NULL;

    IF v_content_hash IS NOT NULL THEN
        SELECT ocv.version_tag, ocv.content_hash INTO v_assignment_version_tag, v_last_version_hash
        FROM offline_config_versions ocv
        WHERE ocv.object_id = p_executor_object_id AND ocv.config_type = 'assignments' AND ocv.is_active = TRUE
        ORDER BY ocv.created_at DESC LIMIT 1;
        IF FOUND AND v_last_version_hash = v_content_hash THEN
             RAISE NOTICE '[Ver] Конфигурация заданий для object_id % не изменилась. Версия: %', p_executor_object_id, v_assignment_version_tag;
        ELSE
             v_assignment_version_tag := to_char(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISS') || '_' || p_executor_object_id || '_' || left(v_content_hash, 8); -- Тег включает часть хеша заданий
             RAISE NOTICE '[Ver] Конфигурация заданий для object_id % изменилась/новая. Новая версия: %', p_executor_object_id, v_assignment_version_tag;
             INSERT INTO offline_config_versions (object_id, config_type, version_tag, content_hash, description, transport_system_code, is_active)
             VALUES (p_executor_object_id, 'assignments', v_assignment_version_tag, v_content_hash, 'Авто-версия заданий', v_subdivision_info.transport_system_code, TRUE)
             ON CONFLICT (version_tag) DO NOTHING;
        END IF;
    ELSE
        v_assignment_version_tag := 'nohash_' || to_char(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISS') || '_' || p_executor_object_id;
        RAISE WARNING '[Ver] Используется временный тег версии (pgcrypto не сработал): %', v_assignment_version_tag;
    END IF;

    -- 5. Собираем итоговый JSON (БЕЗ content_hash)
    v_config := jsonb_build_object(
        'object_id', p_executor_object_id,
        'config_type', 'offline_multi_check_agent_v4.5', -- <<< Обновляем версию формата конфига
        'generated_at', CURRENT_TIMESTAMP,
        'assignment_config_version', v_assignment_version_tag, -- Тег версии самих ЗАДАНИЙ
        'transport_system_code', v_subdivision_info.transport_system_code,
        'default_check_interval_seconds', v_default_interval,
        'assignments', v_assignments -- Массив заданий
    );

    RETURN v_config; -- Возвращаем JSON без content_hash
END;
$$ LANGUAGE plpgsql VOLATILE;
COMMENT ON FUNCTION generate_offline_config(INTEGER)
IS 'Генерирует ПОЛНУЮ JSON конфигурацию (метаданные + задания) для оффлайн-агента. Тег версии включает хеш массива заданий.';


-- -----------------------------------------------------------------------------
-- Функция: get_node_base_info
-- Назначение: Возвращает базовую информацию об узлах, включая данные из
--             связанных таблиц (подразделения, типы, свойства типов).
-- ... (остальное описание) ...
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_node_base_info(node_id_filter INTEGER DEFAULT NULL)
RETURNS TABLE (
    id INTEGER,
    name VARCHAR(255),
    ip_address VARCHAR(45),
    description TEXT,
    subdivision_id INTEGER,
    subdivision_short_name VARCHAR(100),
    node_type_id INTEGER,
    node_type_name TEXT,
    node_type_path TEXT,
    node_type_priority INTEGER,
    timeout_minutes INTEGER,
    display_order INTEGER,
    icon_color TEXT,
    icon_filename VARCHAR(100)
) AS $$
DECLARE
    v_default_node_type_id INTEGER := 0;
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
IS 'Возвращает базовую информацию об узлах, их типах (включая иконку), подразделениях и вычисленных свойствах (таймаут, порядок, цвет).';


-- -----------------------------------------------------------------------------
-- Функция: get_node_ping_status
-- Назначение: Возвращает статус последней PING-проверки для узлов.
-- ... (остальное описание) ...
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_node_ping_status(node_id_filter INTEGER DEFAULT NULL)
RETURNS TABLE (
    node_id INTEGER,
    is_available BOOLEAN,
    last_checked TIMESTAMPTZ,
    last_available TIMESTAMPTZ,
    check_timestamp TIMESTAMPTZ,
    executor_object_id INTEGER,
    executor_host TEXT
) AS $$
DECLARE
    v_ping_method_id INTEGER;
BEGIN
    SELECT cm.id INTO v_ping_method_id FROM check_methods cm WHERE cm.method_name = 'PING' LIMIT 1;
    IF v_ping_method_id IS NULL THEN RAISE WARNING 'Метод PING не найден. Статус PING не может быть определен.'; RETURN; END IF;

    RETURN QUERY
    WITH ping_assignments AS (
        SELECT nca.id as assignment_id, nca.node_id
        FROM node_check_assignments nca
        WHERE nca.method_id = v_ping_method_id
          AND nca.is_enabled = TRUE
          AND (node_id_filter IS NULL OR nca.node_id = node_id_filter)
    ), last_ping_checks AS (
        SELECT DISTINCT ON (nc_inner.node_id)
            nc_inner.node_id, nc_inner.is_available, nc_inner.checked_at,
            nc_inner.check_timestamp, nc_inner.executor_object_id, nc_inner.executor_host
        FROM node_checks nc_inner JOIN ping_assignments pa ON nc_inner.assignment_id = pa.assignment_id
        ORDER BY nc_inner.node_id, nc_inner.checked_at DESC
    ), last_available_ping_checks AS (
        SELECT DISTINCT ON (nc_avail.node_id)
            nc_avail.node_id, nc_avail.checked_at AS last_available_time
        FROM node_checks nc_avail JOIN ping_assignments pa ON nc_avail.assignment_id = pa.assignment_id
        WHERE nc_avail.is_available = TRUE
        ORDER BY nc_avail.node_id, nc_avail.checked_at DESC
    )
    SELECT
        n.id as node_id,
        lpc.is_available, lpc.checked_at AS last_checked, lapc.last_available_time AS last_available,
        lpc.check_timestamp, lpc.executor_object_id, lpc.executor_host
    FROM nodes n
    LEFT JOIN last_ping_checks lpc ON n.id = lpc.node_id
    LEFT JOIN last_available_ping_checks lapc ON n.id = lapc.node_id
    WHERE node_id_filter IS NULL OR n.id = node_id_filter;
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION get_node_ping_status(INTEGER)
IS 'Возвращает статус последней PING-проверки для указанных (или всех) узлов.';


-- -----------------------------------------------------------------------------
-- Функция: get_subdivisions
-- Назначение: Возвращает список всех подразделений для использования в UI.
-- ... (остальное описание) ...
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_subdivisions()
RETURNS TABLE (
    id INTEGER,
    object_id INTEGER,
    short_name VARCHAR(100),
    full_name TEXT,
    parent_id INTEGER,
    priority INTEGER,
    icon_filename VARCHAR(100)
) AS $$
BEGIN
    RETURN QUERY
    SELECT s.id, s.object_id, s.short_name, s.full_name, s.parent_id, s.priority, s.icon_filename
    FROM subdivisions s
    ORDER BY s.priority, s.short_name;
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION get_subdivisions()
IS 'Возвращает список всех подразделений (включая иконку), отсортированный по приоритету и имени.';

-- =============================================================================
-- == КОНЕЦ СОЗДАНИЯ ФУНКЦИЙ И ПРОЦЕДУР ==
-- =============================================================================