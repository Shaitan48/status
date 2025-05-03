# status/app/services/node_service.py
import logging
from typing import List, Dict, Any, Optional
from datetime import datetime, timedelta, timezone
from ..repositories import node_repository # Импорт репозитория
from .. import db_connection # Для получения времени из БД

logger = logging.getLogger(__name__)

def get_processed_node_status(cursor) -> List[Dict[str, Any]]:
    """
    Получает и обрабатывает данные узлов для дашборда/детального статуса.
    Заменяет fetch_and_process_node_status из старого db.py.
    """
    try:
        # Шаг 1: Получаем базовую информацию через репозиторий
        base_nodes = node_repository.fetch_node_base_info(cursor)
        if not base_nodes:
            logger.warning("get_processed_node_status: Базовая информация об узлах не найдена.")
            return []

        # Шаг 2: Получаем статусы PING через репозиторий
        ping_statuses_raw = node_repository.fetch_node_ping_status(cursor)
        ping_status_map = {status['node_id']: status for status in ping_statuses_raw}
        logger.debug(f"Создана карта PING статусов для {len(ping_status_map)} узлов.")

        # Шаг 3: Получаем текущее время UTC из БД
        # Нужен новый курсор или передача соединения, если транзакционность важна
        # В данном случае, для получения времени, можно использовать тот же курсор
        # current_utc_time = db_connection.get_current_utc_time(cursor) # get_current_utc_time нужно перенести или сделать доступным
        # Проще пока использовать время сервера приложения (менее точно)
        current_utc_time = datetime.now(timezone.utc)
        logger.info(f"Текущее UTC время для расчета статуса (app server): {current_utc_time}")

        # Шаг 4: Объединение и вычисление статуса (логика как была)
        processed_nodes = []
        for node_base_dict in base_nodes:
            node_id = node_base_dict.get('id')
            if not node_id: continue

            node_ping_dict = ping_status_map.get(node_id, {})
            node_combined = {**node_base_dict, **node_ping_dict}

            # Вычисляем статус PING... (вся логика расчета status_class, status_text)
            status_class = "unknown"; status_text = "Нет данных PING"
            ping_timeout_minutes = node_combined.get('timeout_minutes', 5)
            ping_timeout_delta = timedelta(minutes=ping_timeout_minutes)
            last_checked_str = node_combined.get('last_checked') # Может быть datetime или ISO строка
            is_available = node_combined.get('is_available')

            if last_checked_str:
                 try:
                     # Преобразуем в datetime, если это строка
                     if isinstance(last_checked_str, str):
                         last_checked_ts = datetime.fromisoformat(last_checked_str.replace('Z', '+00:00'))
                     elif isinstance(last_checked_str, datetime):
                          last_checked_ts = last_checked_str
                     else: raise ValueError("Неверный тип last_checked")

                     if last_checked_ts.tzinfo is None: last_checked_ts = last_checked_ts.replace(tzinfo=timezone.utc)
                     elif last_checked_ts.tzinfo.utcoffset(last_checked_ts) != timedelta(0): last_checked_ts = last_checked_ts.astimezone(timezone.utc)

                     time_diff = current_utc_time - last_checked_ts
                     # ... (дальнейшая логика if is_available...) ...
                     if is_available is True:
                         status_class = "available" if time_diff <= ping_timeout_delta else "warning"
                         status_text = "Доступен (PING)" if status_class == "available" else f"Устарело (PING > {ping_timeout_minutes} мин)"
                     elif is_available is False:
                         status_class = "unavailable"; status_text = "Недоступен (PING)"

                 except ValueError as e_dt:
                      logger.warning(f"Не удалось распарсить last_checked '{last_checked_str}' для узла {node_id}: {e_dt}")
                      status_class = "unknown"; status_text = "Ошибка данных PING"
            elif is_available is False: status_class = "unavailable"; status_text = "Недоступен (PING)"

            node_combined['status_class'] = status_class
            node_combined['status_text'] = status_text
            # Форматируем даты в строки перед возвратом из сервиса
            for key in ['last_checked', 'last_available', 'check_timestamp']:
                 if key in node_combined and isinstance(node_combined[key], datetime):
                     node_combined[key] = node_combined[key].isoformat()

            processed_nodes.append(node_combined)

        logger.info(f"Успешно обработаны данные для {len(processed_nodes)} узлов.")
        return processed_nodes
    except Exception as e_main:
        logger.error(f"Неожиданная ошибка при обработке статуса узлов: {e_main}", exc_info=True)
        # В сервисе лучше не возвращать [], а пробрасывать ошибку дальше
        raise