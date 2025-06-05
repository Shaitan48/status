# status/app/services/node_service.py
"""
Сервисный слой для бизнес-логики, связанной с Узлами (Nodes).
Основная задача: вычисление обобщенного статуса узла для отображения в UI,
адаптированное для pipeline-архитектуры (v5.x).
"""
import logging
from typing import List, Dict, Any, Optional
from datetime import datetime, timedelta, timezone
import psycopg2 # Для type hinting и обработки psycopg2.Error

# Импортируем репозиторий для получения данных из БД
from ..repositories import node_repository # Репозиторий для узлов
# Импортируем модуль для парсинга дат, если он установлен
from ..db_connection import HAS_DATEUTIL # Флаг наличия python-dateutil

# Условный импорт парсера дат
if HAS_DATEUTIL:
    from dateutil import parser as dateutil_parser
else:
    # Если dateutil не доступен, создаем "заглушку" или используем стандартные методы,
    # но логируем предупреждение, что функциональность парсинга дат может быть ограничена.
    logger_dateutil_fallback = logging.getLogger(__name__ + '.dateutil_fallback')
    logger_dateutil_fallback.warning(
        "Модуль 'python-dateutil' не найден. "
        "Парсинг дат будет осуществляться стандартными средствами Python, "
        "что может быть менее гибким для некоторых форматов ISO 8601."
    )

# Инициализация логгера для этого модуля
logger = logging.getLogger(__name__)

# Константы, используемые в модуле
DEFAULT_NODE_ICON = "other.svg"  # Имя файла иконки по умолчанию для типов узлов
DEFAULT_STATUS_TIMEOUT_MINUTES = 5 # Таймаут актуальности статуса по умолчанию (в минутах)
# Имя МЕТОДА ЗАДАНИЯ (из check_methods), который по умолчанию определяет статус доступности узла.
# Агент должен присылать результат для этого задания с соответствующим resolution_method.
PRIMARY_STATUS_CHECK_METHOD_NAME = 'PING'

def get_processed_node_status(cursor: psycopg2.extensions.cursor) -> List[Dict[str, Any]]:
    """
    Получает базовую информацию об узлах и данные их последних "ключевых" проверок (по PRIMARY_STATUS_CHECK_METHOD_NAME),
    затем вычисляет и добавляет обобщенный отображаемый статус ('status_class', 'status_text')
    для каждого узла.

    В этой версии (v5.x) статус определяется на основе:
    1. `is_available` из последней ключевой проверки.
    2. `check_success` из последней ключевой проверки (отражает результат выполнения критериев pipeline-задания).
    3. Времени последней ключевой проверки и настроенного таймаута.

    Args:
        cursor: Активный курсор базы данных psycopg2 (предполагается, что он RealDictCursor).

    Returns:
        Список словарей, где каждый словарь представляет узел с добавленными
        полями 'status_class' (CSS-класс для цвета) и 'status_text' (текстовое описание статуса).
        Возвращает пустой список, если узлы не найдены или произошла ошибка.

    Raises:
        psycopg2.Error: В случае ошибок при взаимодействии с базой данных.
        Exception: В случае других непредвиденных ошибок при обработке данных.
    """
    logger.info("Service: Начало расчета обработанных статусов узлов (v5.x - pipeline)...")
    try:
        # --- Шаг 1: Получение базовой информации обо всех узлах ---
        logger.debug("Service: Запрос базовой информации об узлах через node_repository.fetch_node_base_info...")
        base_nodes_list: List[Dict[str, Any]] = node_repository.fetch_node_base_info(cursor)
        if not base_nodes_list:
            logger.info("Service: Базовая информация об узлах не найдена (список пуст). Возвращаем пустой список.")
            return []
        logger.debug(f"Service: Получено {len(base_nodes_list)} узлов с базовой информацией.")

        # --- Шаг 2: Получение данных о последних проверках, определяющих статус ---
        # Используем PRIMARY_STATUS_CHECK_METHOD_NAME для определения "ключевой" проверки.
        # Функция fetch_node_primary_check_status должна возвращать is_available и check_success.
        logger.debug(f"Service: Запрос статусов основной проверки (метод задания: '{PRIMARY_STATUS_CHECK_METHOD_NAME}')...")
        # Предполагаем, что fetch_node_ping_status уже адаптирована или есть новая функция,
        # которая возвращает также поле 'check_success' из таблицы node_checks.
        # Если такой функции нет, ее нужно будет создать/доработать в node_repository.
        # Для примера, будем считать, что fetch_node_ping_status теперь возвращает и check_success.
        primary_check_statuses_raw: List[Dict[str, Any]] = node_repository.fetch_node_ping_status(cursor)
        
        
        
        # --- ОТЛАДОЧНОЕ ЛОГИРОВАНИЕ ---
        if primary_check_statuses_raw:
            logger.debug(f"Service get_processed_node_status: Тип первого элемента в primary_check_statuses_raw: {type(primary_check_statuses_raw[0])}")
            if isinstance(primary_check_statuses_raw[0], tuple):
                logger.error("Service get_processed_node_status: КРИТИЧЕСКАЯ ОШИБКА - primary_check_statuses_raw содержит КОРТЕЖИ!")
        elif primary_check_statuses_raw is not None: # Пустой список
             logger.debug("Service get_processed_node_status: primary_check_statuses_raw является пустым списком.")
        else: # None
             logger.error("Service get_processed_node_status: КРИТИЧЕСКАЯ ОШИБКА - primary_check_statuses_raw is None!")
        # --- КОНЕЦ ОТЛАДОЧНОГО ЛОГИРОВАНИЯ ---
        
        primary_check_status_map: Dict[int, Dict[str, Any]] = {
            status['node_id']: status for status in primary_check_statuses_raw if status.get('node_id') is not None
        }
        logger.debug(f"Service: Создана карта статусов основной проверки для {len(primary_check_status_map)} узлов.")

        # --- Шаг 3: Получение текущего времени UTC ---
        current_server_utc_time = datetime.now(timezone.utc)
        logger.debug(f"Service: Текущее UTC время сервера для расчета статуса: {current_server_utc_time.isoformat()}")

        # --- Шаг 4: Обработка каждого узла и вычисление статуса ---
        processed_nodes_list: List[Dict[str, Any]] = []
        for node_base_info_dict in base_nodes_list:
            node_id = node_base_info_dict.get('id')
            if not node_id:
                logger.warning("Service: Обнаружен узел без ID в базовой информации, узел пропущен.")
                continue

            node_primary_check_dict = primary_check_status_map.get(node_id, {})
            node_combined_data = {**node_base_info_dict, **node_primary_check_dict}

            # --- Вычисление отображаемого статуса ---
            current_status_class = "unknown"
            current_status_text = f"Нет данных ({PRIMARY_STATUS_CHECK_METHOD_NAME})" # Обновлено сообщение по умолчанию

            status_timeout_minutes_config = node_combined_data.get('timeout_minutes', DEFAULT_STATUS_TIMEOUT_MINUTES)
            try:
                status_timeout_minutes = int(status_timeout_minutes_config)
                if status_timeout_minutes <= 0: raise ValueError("Таймаут должен быть > 0.")
            except (ValueError, TypeError):
                logger.warning(f"Node ID {node_id}: Некорректный 'timeout_minutes' ('{status_timeout_minutes_config}'). Используется: {DEFAULT_STATUS_TIMEOUT_MINUTES} мин.")
                status_timeout_minutes = DEFAULT_STATUS_TIMEOUT_MINUTES
            status_timeout_delta = timedelta(minutes=status_timeout_minutes)

            # Время последней проверки (приоритет у времени агента)
            timestamp_of_last_check_str = node_combined_data.get('check_timestamp') or node_combined_data.get('last_checked')
            # Статус доступности от агента/задания (True, False, или None)
            is_node_available = node_combined_data.get('is_available')
            # Статус выполнения критериев задания (True, False, или None)
            is_check_successful = node_combined_data.get('check_success') # Это поле должно приходить из fetch_node_ping_status

            logger.debug(f"Node ID {node_id}: Расчет статуса... "
                         f"is_available={is_node_available}, check_success={is_check_successful}, "
                         f"timestamp_str='{timestamp_of_last_check_str}', timeout_min={status_timeout_minutes}")

            if timestamp_of_last_check_str: # Если есть информация о времени последней проверки
                parsed_check_time_utc: Optional[datetime] = None
                try:
                    # (Логика парсинга времени timestamp_of_last_check_str остается такой же, как в v7.0.5)
                    # ... (код парсинга с HAS_DATEUTIL и fallback) ...
                    if isinstance(timestamp_of_last_check_str, str):
                        if HAS_DATEUTIL: parsed_check_time_utc = dateutil_parser.isoparse(timestamp_of_last_check_str)
                        else:
                            ts_clean = timestamp_of_last_check_str.replace('Z', '+00:00')
                            if '.' in ts_clean:
                                parts = ts_clean.split('.', 1)
                                micro_part = parts[1].split('+', 1)[0].split('-', 1)[0]; tz_suffix = parts[1][len(micro_part):]
                                if len(micro_part) > 6: micro_part = micro_part[:6]
                                ts_clean = f"{parts[0]}.{micro_part}{tz_suffix}"
                            parsed_check_time_utc = datetime.fromisoformat(ts_clean)
                    elif isinstance(timestamp_of_last_check_str, datetime): parsed_check_time_utc = timestamp_of_last_check_str
                    else: raise ValueError(f"Неподдерживаемый тип для времени: {type(timestamp_of_last_check_str)}")

                    if parsed_check_time_utc.tzinfo is None: parsed_check_time_utc = parsed_check_time_utc.replace(tzinfo=timezone.utc)
                    elif parsed_check_time_utc.tzinfo.utcoffset(parsed_check_time_utc) != timedelta(0): parsed_check_time_utc = parsed_check_time_utc.astimezone(timezone.utc)
                    logger.debug(f"  Node ID {node_id}: Распарсено время проверки (UTC): {parsed_check_time_utc.isoformat()}")

                    time_difference = current_server_utc_time - parsed_check_time_utc
                    data_is_outdated = time_difference > status_timeout_delta
                    logger.debug(f"  Node ID {node_id}: Разница={time_difference}, Таймаут={status_timeout_delta}, Устарело={data_is_outdated}")

                    # --- Новая логика определения статуса с учетом is_node_available и is_check_successful ---
                    if is_node_available is True:
                        if is_check_successful is True: # Задание выполнено и критерии пройдены
                            current_status_class = "warning" if data_is_outdated else "available"
                            status_key = PRIMARY_STATUS_CHECK_METHOD_NAME
                            current_status_text = f"Устарело ({status_key} > {status_timeout_minutes} мин)" if data_is_outdated else f"Доступен ({status_key})"
                        elif is_check_successful is False: # Задание выполнено, но критерии НЕ пройдены
                            current_status_class = "unavailable" # Считаем это серьезной проблемой
                            current_status_text = f"Ошибка ({PRIMARY_STATUS_CHECK_METHOD_NAME}: критерии не пройдены)"
                        else: # is_check_successful is None (ошибка оценки критериев или они не применялись, но is_available=true)
                            current_status_class = "warning" # Неопределенность или нужны доп. данные
                            status_key_warn = PRIMARY_STATUS_CHECK_METHOD_NAME
                            current_status_text = f"Предупреждение ({status_key_warn}: статус критериев не ясен)"
                            if data_is_outdated: current_status_text += f", данные устарели (> {status_timeout_minutes} мин)"
                    elif is_node_available is False: # Само задание/pipeline не удалось выполнить
                        current_status_class = "unavailable"
                        current_status_text = f"Недоступен ({PRIMARY_STATUS_CHECK_METHOD_NAME}: ошибка выполнения)"
                    else: # is_node_available is None (статус доступности не определен)
                        current_status_class = "unknown"
                        current_status_text = f"Статус {PRIMARY_STATUS_CHECK_METHOD_NAME} не определен"
                    logger.debug(f"  Node ID {node_id}: Статус (is_available/is_successful/outdated) -> class='{current_status_class}'")

                except Exception as e_time_proc:
                    logger.warning(f"Node ID {node_id}: Ошибка обработки времени/статуса для '{timestamp_of_last_check_str}': {e_time_proc}", exc_info=True)
                    current_status_class = "unknown"
                    current_status_text = f"Ошибка данных ({PRIMARY_STATUS_CHECK_METHOD_NAME})"
            
            # Если нет timestamp_of_last_check_str, но есть явный is_available=False
            elif is_node_available is False:
                current_status_class = "unavailable"
                current_status_text = f"Недоступен ({PRIMARY_STATUS_CHECK_METHOD_NAME}: ошибка выполнения, время не определено)"
                logger.debug(f"Node ID {node_id}: Нет времени, но is_available=False -> class='{current_status_class}'")
            # Во всех остальных случаях (нет времени и is_available не False, или is_available=None) - статус "unknown"
            else:
                 logger.debug(f"Node ID {node_id}: Недостаточно данных для определения статуса (нет времени, is_available не False). Статус '{current_status_class}'.")

            # --- Завершение формирования данных узла ---
            node_combined_data['status_class'] = current_status_class
            node_combined_data['status_text'] = current_status_text
            if not node_combined_data.get('icon_filename'):
                 node_combined_data['icon_filename'] = DEFAULT_NODE_ICON

            # Форматирование дат (остается без изменений)
            for date_key in ['last_checked', 'last_available', 'check_timestamp']:
                 timestamp_value = node_combined_data.get(date_key)
                 if isinstance(timestamp_value, datetime):
                     node_combined_data[date_key] = timestamp_value.isoformat()
                 # ... (остальная логика переформатирования строк дат, если они уже строки) ...
                 elif isinstance(timestamp_value, str):
                     try:
                         dt_obj = None
                         if HAS_DATEUTIL: dt_obj = dateutil_parser.isoparse(timestamp_value)
                         else: # Fallback
                             ts_clean_fmt = timestamp_value.replace('Z', '+00:00')
                             if '.' in ts_clean_fmt:
                                 parts_fmt = ts_clean_fmt.split('.', 1)
                                 micro_fmt = parts_fmt[1].split('+', 1)[0].split('-', 1)[0]
                                 tz_suf_fmt = parts_fmt[1][len(micro_fmt):]
                                 if len(micro_fmt) > 6: micro_fmt = micro_fmt[:6]
                                 ts_clean_fmt = f"{parts_fmt[0]}.{micro_fmt}{tz_suf_fmt}"
                             dt_obj = datetime.fromisoformat(ts_clean_fmt)
                         
                         if dt_obj.tzinfo is None: dt_obj = dt_obj.replace(tzinfo=timezone.utc)
                         else: dt_obj = dt_obj.astimezone(timezone.utc)
                         node_combined_data[date_key] = dt_obj.isoformat()
                     except ValueError:
                         logger.warning(f"Node ID {node_id}: Не удалось переформатировать строку даты '{timestamp_value}' для '{date_key}'. Оставляем как есть.")


            processed_nodes_list.append(node_combined_data)
            logger.debug(f"Node ID {node_id}: Обработан. Итоговый статус-класс: '{current_status_class}', текст: '{current_status_text}'")

        logger.info(f"Service: Успешно обработаны статусы для {len(processed_nodes_list)} узлов.")
        return processed_nodes_list

    except psycopg2.Error as db_err:
        logger.error(f"Service: Ошибка базы данных при расчете статусов узлов: {db_err}", exc_info=True)
        raise
    except Exception as e_main:
        logger.error(f"Service: Неожиданная ошибка при расчете статусов узлов: {e_main}", exc_info=True)
        raise