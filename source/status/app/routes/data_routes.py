# status/app/routes/data_routes.py
import logging
import psycopg2
from flask import Blueprint, jsonify, g
from ..services import node_service # Используем сервисный слой
from ..repositories import subdivision_repository
from ..errors import ApiInternalError, ApiException # Добавляем ApiException

logger = logging.getLogger(__name__)
bp = Blueprint('data', __name__) # Префикс /api/v1 в __init__.py

@bp.route('/dashboard', methods=['GET'])
def api_dashboard_data():
    """Отдает данные для страницы Сводки."""
    logger.info("API Data: Запрос GET /dashboard")
    try:
        cursor = g.db_conn.cursor() # Получаем курсор из контекста g

        # Используем сервисный слой для получения обработанных данных узлов
        # Эта функция уже должна возвращать список словарей узлов со всеми нужными полями
        nodes_with_status = node_service.get_processed_node_status(cursor)

        # Получаем плоский список подразделений через репозиторий
        all_subdivisions_flat, _ = subdivision_repository.fetch_subdivisions(cursor, limit=None)

        if not all_subdivisions_flat:
            logger.warning("API Data: Нет подразделений для отображения на дашборде.")
            return jsonify([]) # Возвращаем пустой массив, если нет подразделений

        # Создаем карту подразделений: Ключ - ID, Значение - объект подразделения
        subdivision_map = { s['id']: {**s, 'nodes': []} for s in all_subdivisions_flat }
        nodes_without_valid_subdivision = []

        # ===>>> ВОТ ЭТОТ ЦИКЛ БЫЛ ПРОПУЩЕН РАНЕЕ <<<===
        for node in nodes_with_status:
            # Получаем ID подразделения из данных узла
            subdivision_id_raw = node.get('subdivision_id')
            subdivision_id = None
            node_id = node.get('id') # Для логгирования

            # Пытаемся привести ID к числу и проверяем его наличие
            if subdivision_id_raw is not None:
                try:
                    subdivision_id = int(subdivision_id_raw)
                except (ValueError, TypeError):
                    logger.warning(f"Node {node_id} has invalid subdivision_id format: {subdivision_id_raw}")
                    nodes_without_valid_subdivision.append(node_id)
                    continue # Переходим к следующему узлу

            logger.debug(f"Processing node {node_id} - subdivision_id: {subdivision_id} (type: {type(subdivision_id)})")

            # Проверяем, что ID корректный и существует в нашей карте подразделений
            if subdivision_id is not None and subdivision_id in subdivision_map:
                logger.debug(f"  Node {node_id} attempting to add to subdivision {subdivision_id}")
                # Формируем объект узла только с нужными для дашборда полями
                node_display_data = {
                    'id': node_id,
                    'name': node.get('name'),
                    'ip_address': node.get('ip_address'),
                    'status_class': node.get('status_class', 'unknown'),
                    'status_text': node.get('status_text', 'Нет данных'),
                    'node_type_path': node.get('node_type_path'),
                    'icon_filename': node.get('icon_filename', 'other.svg'), # Используем дефолтное имя
                    'check_timestamp': node.get('check_timestamp'), # Уже ISO строка из сервиса
                    'last_checked': node.get('last_checked'),       # Уже ISO строка из сервиса
                    'last_available': node.get('last_available'),   # Уже ISO строка из сервиса
                    'display_order': node.get('display_order')
                }
                subdivision_map[subdivision_id]['nodes'].append(node_display_data)
            else:
                # Если узел не попал ни в одно подразделение
                nodes_without_valid_subdivision.append(node_id)
                logger.warning(f"  Node {node.get('name')} (ID: {node_id}) with subdivision_id {subdivision_id} NOT FOUND in subdivision_map keys: {list(subdivision_map.keys())}")

        # ===>>> КОНЕЦ ПРОПУЩЕННОГО ЦИКЛА <<<===

        # Сортируем узлы внутри каждого подразделения
        for sub_id in subdivision_map:
            subdivision_map[sub_id]['nodes'].sort(
                key=lambda n: (n.get('display_order', float('inf')), n.get('name', '').lower())
            )

        # Собираем результат и сортируем подразделения
        result_list = list(subdivision_map.values())
        result_list.sort(key=lambda s: (s.get('priority', float('inf')), s.get('short_name', '').lower()))

        logger.info(f"API Data: Успешно сформированы данные для дашборда, подразделений: {len(result_list)}. Нераспределенных узлов: {len(nodes_without_valid_subdivision)}")
        return jsonify(result_list), 200

    # --- Обработка ошибок ---
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при формировании данных дашборда: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при подготовке данных дашборда.")
    except ApiException as api_err:
        raise api_err
    except Exception as e:
        logger.exception("Неожиданная ошибка при формировании данных дашборда")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {e}")


@bp.route('/status_detailed', methods=['GET'])
def api_detailed_status():
    """Отдает данные для страницы Детального статуса."""
    logger.info("API Data: Запрос GET /status_detailed")
    try:
        cursor = g.db_conn.cursor()
        # Получаем обработанные узлы через сервис
        nodes_with_status = node_service.get_processed_node_status(cursor)
        # Получаем плоский список подразделений
        subdivisions, _ = subdivision_repository.fetch_subdivisions(cursor, limit=None)

        response_data = {"nodes": nodes_with_status, "subdivisions": subdivisions}
        logger.info(f"API Data: Сформированы данные для детального статуса.")
        return jsonify(response_data), 200
    # --- Обработка ошибок ---
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при подготовке детального статуса: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при подготовке детального статуса.")
    except ApiException as api_err:
         raise api_err
    except Exception as e:
        logger.exception("Неожиданная ошибка при подготовке детального статуса")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {e}")


@bp.route('/check_methods', methods=['GET'])
def api_get_check_methods():
    """Получает список всех методов проверки."""
    from ..repositories import method_repository # Импорт здесь или наверху
    logger.info("API Data: Запрос GET /check_methods")
    try:
        cursor = g.db_conn.cursor()
        methods = method_repository.fetch_check_methods(cursor)
        logger.info(f"API Data: Успешно получено {len(methods)} методов проверки.")
        return jsonify(methods)
    except psycopg2.Error as db_err:
        logger.error(f"Ошибка БД при получении методов проверки: {db_err}", exc_info=True)
        raise ApiInternalError("Ошибка базы данных при получении методов проверки.")
    except Exception as e:
        logger.exception("Неожиданная ошибка при получении методов проверки")
        raise ApiInternalError(f"Внутренняя ошибка сервера: {e}")