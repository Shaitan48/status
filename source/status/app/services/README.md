# Status Monitor — Сервисный Слой (`status/app/services/`)

Эта директория содержит модули, реализующие бизнес-логику приложения, которая не привязана напрямую к HTTP-запросам или работе с базой данных. Сервисы могут использовать функции из репозиториев для получения данных и выполнять их обработку, агрегацию или вычисления.

## `node_service.py`

Основной сервис для работы с узлами мониторинга.

### Функция `get_processed_node_status(cursor)`

**Назначение:**

Ключевая функция, отвечающая за формирование обобщенного статуса каждого узла для отображения в пользовательском интерфейсе (например, на Дашборде или в Детальном списке узлов).

**Принцип работы:**

1.  **Получение базовых данных:** Через `node_repository.fetch_node_base_info(cursor)` запрашиваются основные сведения о всех узлах, включая:
    *   ID, имя, IP-адрес.
    *   Информацию о родительском подразделении.
    *   Информацию о типе узла (включая иерархический путь типа, например, "Сервера > Виртуальные сервера").
    *   Свойства, унаследованные от типа узла, такие как `timeout_minutes` (таймаут актуальности статуса), `display_order` (порядок отображения), `icon_filename` (имя файла иконки).

2.  **Получение данных о последней основной проверке:**
    *   В текущей реализации, для определения доступности узла используется результат последней проверки типа `PING` (константа `PRIMARY_STATUS_CHECK_METHOD_NAME`). Данные запрашиваются через `node_repository.fetch_node_ping_status(cursor)`.
    *   Эта функция возвращает `is_available` (True/False/None), `check_timestamp` (время проверки на агенте, если есть), `last_checked` (время записи в БД), `last_available` (время последнего успешного пинга).
    *   **План на будущее:** Этот шаг должен быть обобщен для поддержки определения статуса на основе результатов выполнения **pipeline-заданий**. Это может потребовать:
        *   Введения специального флага для заданий, результат которых является основным для статуса узла.
        *   Анализа `resolution_method` или типа последнего шага в pipeline, чтобы определить, какая проверка дала итоговый статус.

3.  **Расчет отображаемого статуса:** Для каждого узла вычисляются два поля:
    *   `status_class`: CSS-класс, определяющий цвет индикатора статуса (например, 'available', 'unavailable', 'warning', 'unknown').
    *   `status_text`: Текстовое описание статуса (например, "Доступен (PING)", "Недоступен (PING)", "Устарело (PING > 5 мин)", "Нет данных PING").

    Логика расчета (на данный момент, основана на `PING`):
    *   Берется `timeout_minutes` для узла (из свойств его типа или значение по умолчанию `DEFAULT_STATUS_TIMEOUT_MINUTES`).
    *   Берется время последней проверки (`check_timestamp` или `last_checked`).
    *   **`available` (Зеленый):** `is_available` равно `True` И время последней проверки **не превышает** `timeout_minutes`.
    *   **`unavailable` (Красный):** `is_available` равно `False` (независимо от времени проверки).
    *   **`warning` (Желтый):** `is_available` равно `True`, НО время последней проверки **превышает** `timeout_minutes`.
    *   **`unknown` (Серый):** Нет данных о проверках (`is_available` равно `None`), ИЛИ произошла ошибка при парсинге/обработке времени или статуса.

4.  **Форматирование данных:**
    *   Все поля с датами (`check_timestamp`, `last_checked`, `last_available`) преобразуются в строки формата ISO 8601 для корректной передачи в JSON.
    *   Устанавливается иконка по умолчанию (`DEFAULT_NODE_ICON`), если она не определена для типа узла.

**Возвращаемое значение:**

Список словарей, где каждый словарь представляет узел со всеми исходными и добавленными полями (`status_class`, `status_text`, отформатированные даты, иконка по умолчанию).

**Зависимости:**

*   `app.repositories.node_repository`
*   Модуль `python-dateutil` (опционально, для более гибкого парсинга дат). Если он не установлен, используется стандартный `datetime.fromisoformat`, что может потребовать более строгого формата дат от агентов.