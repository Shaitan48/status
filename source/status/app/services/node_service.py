# status/app/services/node_service.py
import logging
from typing import List, Dict, Any, Optional
from datetime import datetime, timedelta, timezone

# Импортируем репозиторий для получения данных из БД
from ..repositories import node_repository
# Импортируем модуль для парсинга дат, если он установлен
from ..db_connection import HAS_DATEUTIL

# Условный импорт парсера дат
if HAS_DATEUTIL:
    from dateutil import parser as dateutil_parser

# Инициализация логгера для этого модуля
logger = logging.getLogger(__name__)

# Константа для имени иконки по умолчанию
DEFAULT_ICON = "other.svg"
# Таймаут PING по умолчанию в минутах (если не найден в настройках/свойствах)
DEFAULT_PING_TIMEOUT_MINUTES = 5

def get_processed_node_status(cursor) -> List[Dict[str, Any]]:
    """
    Получает базовую информацию об узлах и их последний статус PING,
    затем вычисляет и добавляет обобщенный статус ('status_class', 'status_text')
    для каждого узла.

    Эта функция является ключевой для отображения состояния узлов в UI.

    Args:
        cursor: Активный курсор базы данных psycopg2.

    Returns:
        Список словарей, где каждый словарь представляет узел с добавленными
        полями 'status_class' и 'status_text'.
        Возвращает пустой список, если узлы не найдены или произошла ошибка.

    Raises:
        psycopg2.Error: В случае ошибок при взаимодействии с базой данных.
        Exception: В случае других непредвиденных ошибок.
    """
    try:
        # --- Шаг 1: Получение базовой информации об узлах ---
        # Используем функцию репозитория, которая вызывает get_node_base_info() в БД.
        # Эта функция возвращает данные узла, его типа (с путем иерархии),
        # подразделения и ВЫЧИСЛЕННЫЕ свойства типа (timeout_minutes, display_order, icon_color).
        logger.debug("get_processed_node_status: Запрос базовой информации об узлах...")
        base_nodes = node_repository.fetch_node_base_info(cursor)
        if not base_nodes:
            logger.warning("get_processed_node_status: Базовая информация об узлах не найдена.")
            return []
        logger.debug(f"get_processed_node_status: Получено {len(base_nodes)} узлов с базовой информацией.")

        # --- Шаг 2: Получение последнего статуса PING для узлов ---
        # Используем функцию репозитория, которая вызывает get_node_ping_status() в БД.
        # Эта функция возвращает последнюю запись PING-проверки для каждого узла,
        # включая is_available, checked_at (время сервера), check_timestamp (время агента),
        # last_available (время последнего успешного пинга).
        logger.debug("get_processed_node_status: Запрос последних статусов PING...")
        ping_statuses_raw = node_repository.fetch_node_ping_status(cursor)
        # Преобразуем список статусов в словарь для быстрого доступа по node_id
        ping_status_map = {status['node_id']: status for status in ping_statuses_raw}
        logger.debug(f"Создана карта PING статусов для {len(ping_status_map)} узлов.")

        # --- Шаг 3: Получение текущего времени UTC ---
        # Используем время сервера приложения для сравнения.
        # ВАЖНО: Для большей точности можно получать время из БД (SELECT CURRENT_TIMESTAMP),
        # но это потребует дополнительного запроса.
        current_utc_time = datetime.now(timezone.utc)
        logger.info(f"Текущее UTC время для расчета статуса (app server): {current_utc_time.isoformat()}")

        # --- Шаг 4: Обработка каждого узла и вычисление статуса ---
        processed_nodes = []
        for node_base_dict in base_nodes:
            node_id = node_base_dict.get('id')
            if not node_id:
                logger.warning("Обнаружен узел без ID в базовой информации, пропускаем.")
                continue # Пропускаем узел без ID

            # Объединяем базовую информацию с информацией о PING
            node_ping_dict = ping_status_map.get(node_id, {}) # Получаем статус PING или пустой словарь
            node_combined = {**node_base_dict, **node_ping_dict}

            # --- Вычисление status_class и status_text ---
            status_class = "unknown"  # Статус по умолчанию
            status_text = "Нет данных PING"

            # Получаем таймаут PING для этого узла (из свойств его типа или дефолтный)
            ping_timeout_minutes = node_combined.get('timeout_minutes', DEFAULT_PING_TIMEOUT_MINUTES)
            try: # Преобразуем в число, обрабатываем ошибку, если значение некорректно
                ping_timeout_minutes = int(ping_timeout_minutes)
                if ping_timeout_minutes <= 0: raise ValueError("Таймаут должен быть положительным")
            except (ValueError, TypeError):
                logger.warning(f"Node ID {node_id}: Некорректное значение timeout_minutes ('{node_combined.get('timeout_minutes')}'), используется значение по умолчанию {DEFAULT_PING_TIMEOUT_MINUTES} мин.")
                ping_timeout_minutes = DEFAULT_PING_TIMEOUT_MINUTES
            ping_timeout_delta = timedelta(minutes=ping_timeout_minutes)

            # Получаем время последней проверки (приоритет у времени агента) и статус доступности
            # Используем check_timestamp (время агента), если оно есть, иначе используем last_checked (время сервера)
            timestamp_to_check_str = node_combined.get('check_timestamp') or node_combined.get('last_checked')
            is_available = node_combined.get('is_available') # Может быть True, False или None

            logger.debug(f"Node ID {node_id}: Обработка... is_available={is_available}, timestamp_str='{timestamp_to_check_str}', timeout_minutes={ping_timeout_minutes}")

            # Если есть информация о времени последней проверки
            if timestamp_to_check_str:
                 try:
                     timestamp_to_check: Optional[datetime] = None
                     # --- Парсинг времени ---
                     if isinstance(timestamp_to_check_str, str):
                         try:
                             # Пытаемся распарсить ISO строку
                             if HAS_DATEUTIL:
                                 timestamp_to_check = dateutil_parser.isoparse(timestamp_to_check_str)
                                 logger.debug(f"  -> Node ID {node_id}: Распарсено время (dateutil): {timestamp_to_check.isoformat()}")
                             else:
                                 # Стандартный парсер (менее гибкий)
                                 ts_str_clean = timestamp_to_check_str.replace('Z', '+00:00')
                                 # Обрезаем микросекунды до 6 знаков
                                 if '.' in ts_str_clean:
                                     parts = ts_str_clean.split('.')
                                     if len(parts) == 2:
                                         microsecond_part = parts[1].split('+')[0].split('-')[0]
                                         if len(microsecond_part) > 6:
                                             timezone_part = parts[1][len(microsecond_part):]
                                             ts_str_clean = f"{parts[0]}.{microsecond_part[:6]}{timezone_part}"
                                 timestamp_to_check = datetime.fromisoformat(ts_str_clean)
                                 logger.debug(f"  -> Node ID {node_id}: Распарсено время (std lib): {timestamp_to_check.isoformat()}")
                         except ValueError as parse_error:
                             logger.warning(f"Node ID {node_id}: Не удалось распарсить время '{timestamp_to_check_str}'. Ошибка: {parse_error}")
                             raise # Передаем ошибку парсинга выше в блок except Exception

                     elif isinstance(timestamp_to_check_str, datetime):
                          timestamp_to_check = timestamp_to_check_str # Уже объект datetime
                     else:
                         raise ValueError(f"Неподдерживаемый тип времени: {type(timestamp_to_check_str)}")

                     # --- Приведение к UTC ---
                     if timestamp_to_check.tzinfo is None:
                         # Если нет таймзоны, предполагаем, что это UTC
                         timestamp_to_check = timestamp_to_check.replace(tzinfo=timezone.utc)
                         logger.debug(f"  -> Node ID {node_id}: Добавлена UTC таймзона к наивному времени.")
                     elif timestamp_to_check.tzinfo.utcoffset(timestamp_to_check) != timedelta(0):
                         # Если есть таймзона, но не UTC, конвертируем в UTC
                         timestamp_to_check_utc = timestamp_to_check.astimezone(timezone.utc)
                         logger.debug(f"  -> Node ID {node_id}: Время сконвертировано из {timestamp_to_check.tzinfo} в UTC: {timestamp_to_check_utc.isoformat()}")
                         timestamp_to_check = timestamp_to_check_utc

                     # --- Расчет разницы и определение статуса ---
                     time_diff = current_utc_time - timestamp_to_check # Разница во времени
                     is_outdated = time_diff > ping_timeout_delta      # Флаг устаревания данных
                     logger.debug(f"  -> Node ID {node_id}: Parsed check_timestamp={timestamp_to_check.isoformat()}, time_diff={time_diff}, ping_timeout_delta={ping_timeout_delta}, is_outdated={is_outdated}")

                     # Определяем статус на основе доступности и устаревания
                     if is_available is True:
                         status_class = "warning" if is_outdated else "available"
                         status_text = f"Устарело (PING > {ping_timeout_minutes} мин)" if is_outdated else "Доступен (PING)"
                         logger.debug(f"  -> Node ID {node_id}: Статус расчитан (available=True, outdated={is_outdated}) -> status_class='{status_class}'")
                     elif is_available is False:
                         status_class = "unavailable"
                         status_text = "Недоступен (PING)"
                         logger.debug(f"  -> Node ID {node_id}: Статус расчитан (available=False) -> status_class='{status_class}'")
                     else: # is_available is None
                         status_class = "unknown" # Если пинг был, но статус не True/False
                         status_text = "Статус PING не определен"
                         logger.debug(f"  -> Node ID {node_id}: Статус расчитан (available=None) -> status_class='{status_class}'")

                 except Exception as e_dt:
                      # Ловим ошибки парсинга времени или другие ошибки при обработке
                      logger.warning(f"Node ID {node_id}: Ошибка обработки времени/статуса для timestamp '{timestamp_to_check_str}': {e_dt}", exc_info=True)
                      status_class = "unknown"
                      status_text = "Ошибка данных PING"
                      logger.debug(f"  -> Node ID {node_id}: Статус расчитан (ошибка обработки) -> status_class='{status_class}'")

            # Если времени последней проверки нет ВООБЩЕ
            elif is_available is False: # Но при этом статус ТОЧНО False
                status_class = "unavailable"
                status_text = "Недоступен (PING)"
                logger.debug(f"Node ID {node_id}: Нет времени проверки, но is_available=False -> status_class='{status_class}'")
            else: # Если нет ни времени, ни статуса False -> статус unknown
                 logger.debug(f"Node ID {node_id}: Нет времени проверки, is_available != False -> status_class='{status_class}' (unknown)")

            # Добавляем рассчитанные статус и текст в итоговый словарь узла
            node_combined['status_class'] = status_class
            node_combined['status_text'] = status_text
            # Устанавливаем иконку по умолчанию, если она не пришла из БД
            if not node_combined.get('icon_filename'):
                 node_combined['icon_filename'] = DEFAULT_ICON

            # Форматируем все даты в ISO строки для JSON ответа (если они еще объекты datetime)
            for key in ['last_checked', 'last_available', 'check_timestamp']:
                 if key in node_combined and isinstance(node_combined[key], datetime):
                     node_combined[key] = node_combined[key].isoformat()

            processed_nodes.append(node_combined) # Добавляем обработанный узел в список

        logger.info(f"Успешно обработаны данные для {len(processed_nodes)} узлов.")
        return processed_nodes
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД в get_processed_node_status: {db_err}", exc_info=True)
        raise # Пробрасываем ошибку БД выше
    except Exception as e_main:
        logger.error(f"Неожиданная ошибка при обработке статуса узлов: {e_main}", exc_info=True)
        raise # Пробрасываем другие ошибки выше