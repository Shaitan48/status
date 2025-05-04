# status/tests/unit/repositories/test_node_repository.py
import pytest
from unittest.mock import MagicMock
from app.repositories import node_repository
import psycopg2 # Для типов ошибок

def test_get_node_by_id_found(mocker):
    """Тест: get_node_by_id находит узел."""
    # Мокируем fetch_node_base_info, т.к. get_node_by_id использует его
    mock_fetch = mocker.patch('app.repositories.node_repository.fetch_node_base_info')
    mock_cursor = MagicMock() # Мок курсора не нужен напрямую, т.к. мокаем fetch

    expected_node_data = [{'id': 1, 'name': 'TestNode1', 'ip_address': '1.1.1.1', 'subdivision_id': 10}]
    mock_fetch.return_value = expected_node_data

    node = node_repository.get_node_by_id(mock_cursor, 1)

    mock_fetch.assert_called_once_with(mock_cursor, node_id=1) # Проверяем вызов fetch_node_base_info
    assert node is not None
    assert node['id'] == 1
    assert node['name'] == 'TestNode1'

def test_get_node_by_id_not_found(mocker):
    """Тест: get_node_by_id не находит узел."""
    mock_fetch = mocker.patch('app.repositories.node_repository.fetch_node_base_info')
    mock_cursor = MagicMock()
    mock_fetch.return_value = [] # Возвращаем пустой список

    node = node_repository.get_node_by_id(mock_cursor, 99)

    mock_fetch.assert_called_once_with(mock_cursor, node_id=99)
    assert node is None

# ... другие тесты для create_node, update_node, delete_node (могут быть сложнее, т.к. меняют состояние)
# Для create/update/delete лучше использовать интеграционные тесты с тестовой БД.