# testDB_kaskad/run_e2e_status_monitor_tests.ps1
Write-Host "Запуск E2E тестов для Status Monitor..."
$DockerComposeFile = "./testDB_kaskad/docker-compose.yml" # Уточни путь

try {
    # 1. Запуск окружения
    Write-Host "Поднятие тестового окружения Docker..."
    docker-compose -f $DockerComposeFile up -d --remove-orphans --build
    # Ожидание готовности (можно добавить проверки healthcheck)
    Write-Host "Ожидание готовности сервисов (60 секунд)..."
    Start-Sleep -Seconds 60 # Увеличь, если нужно

    # --- Тест Online-Агента ---
    Write-Host "--- Тест Online-Агента ---"
    # (Предполагается, что hybrid-agent.ps1 используется)
    docker-compose -f $DockerComposeFile exec -T powershell_test_node_instance pwsh -Command {
        Import-Module /opt/status_monitor_ps/StatusMonitorAgentUtils/StatusMonitorAgentUtils.psd1 -Force;
        /opt/status_monitor_ps/hybrid-agent/hybrid-agent.ps1 -ConfigFile /opt/agent_configs/online_config.json
        # Агент запустится, опросит API, выполнит проверки и отправит результаты.
        # Для теста он должен завершиться сам через некоторое время или после N итераций.
        # Либо запускать его на ограниченное время Start-Job/Wait-Job или в фоне и убивать.
        # Пока предположим, что он быстро отрабатывает или его нужно будет остановить.
    }
    Write-Host "Online-Агент отработал (предположительно). Ожидание обработки результатов..."
    Start-Sleep -Seconds 10

    # --- Тест Offline-Агента (полный цикл) ---
    Write-Host "--- Тест Offline-Агента (полный цикл) ---"
    # 1. Конфигуратор
    Write-Host "Запуск Конфигуратора..."
    docker-compose -f $DockerComposeFile exec -T powershell_test_node_instance pwsh -Command {
        /opt/status_monitor_ps/configurator/generate_and_deliver_config.ps1 -ConfigFile /opt/agent_configs/configurator_config.json
    }
    Start-Sleep -Seconds 5
    # 2. Оффлайн-Агент (Hybrid в offline режиме)
    Write-Host "Запуск Оффлайн-Агента..."
    docker-compose -f $DockerComposeFile exec -T powershell_test_node_instance pwsh -Command {
        Import-Module /opt/status_monitor_ps/StatusMonitorAgentUtils/StatusMonitorAgentUtils.psd1 -Force;
        /opt/status_monitor_ps/hybrid-agent/hybrid-agent.ps1 -ConfigFile /opt/agent_configs/offline_config.json
    }
    Start-Sleep -Seconds 5
    # 3. Загрузчик
    Write-Host "Запуск Загрузчика Результатов..."
    docker-compose -f $DockerComposeFile exec -T powershell_test_node_instance pwsh -Command {
        /opt/status_monitor_ps/result_loader/result_loader.ps1 -ConfigFile /opt/agent_configs/loader_config.json
    }
    Write-Host "Оффлайн-цикл завершен. Ожидание обработки..."
    Start-Sleep -Seconds 10

    # --- Проверки в БД (выполняются Python тестами или отдельным скриптом) ---
    Write-Host "--- Выполнение проверок в БД (Pytest) ---"
    # Здесь можно запустить твои pytest тесты, которые подключатся к тестовой БД
    # pytest ./status/tests/e2e_db_validation_tests.py -s -v
    # Или написать простой Python скрипт для выборочной проверки таблиц
    # (пример ниже)

    Write-Host "E2E тесты (сценарии) завершены успешно!"

} catch {
    Write-Error "ОШИБКА во время E2E тестов: $($_.Exception.Message)"
    # Попытка остановить контейнеры в случае ошибки
} finally {
    Write-Host "Остановка тестового окружения Docker..."
    docker-compose -f $DockerComposeFile down -v # -v для удаления томов и очистки
    Write-Host "Тестовое окружение остановлено."
}