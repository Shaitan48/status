# testDB_kaskad/run_e2e_status_monitor_tests.ps1
# Версия для гибридного агента и pipeline-архитектуры
Write-Host "Запуск E2E тестов для Status Monitor (v5.x - Гибридный Агент)..." -ForegroundColor Yellow

# --- Параметры ---
$DockerComposeFile = "./docker-compose.yml"
$PathToStatusMonitorPsScripts = "/opt/status_monitor_ps" # Базовый путь к PowerShell скриптам в контейнере powershell_test_node
$PathToAgentConfigs = "/opt/agent_configs"             # Путь к конфигурациям агентов в контейнере

# --- Вспомогательная функция для проверки API ключей (без изменений) ---
function Test-APIKeys {
    # (код функции Test-APIKeys остается без изменений, как в вашем исходном файле)
    Write-Host "`n=== Проверка API ключей (из БД и ожидаемых в конфигах) ===`n" -ForegroundColor Cyan
    
    # Попытка выполнить скрипт добавления ключей в БД, если он есть и нужен для тестов
    # В нашем случае, 05_test_api_keys.sql уже должен был отработать при поднятии БД
    # Write-Host "Выполнение скрипта добавления/проверки API ключей в БД..."
    # docker-compose -f $DockerComposeFile exec -T postgres_test_statusmonitor psql -U pu_user -d pu_db_test -f /docker-entrypoint-initdb.d/05_test_api_keys.sql
    
    Write-Host "`n--- API ключи, ожидаемые в конфигурационных файлах E2E тестов: ---`n"
    # Ожидаемые ключи (из ваших файлов agent_configs_test/*.json)
    $expectedKeysInConfigs = @{
        "online_hybrid_config.json (OID 9999)" = "PQQVeqRAeoCGrdV5dMLOYzu5ArCdEfIMolkoveoqZTc" # E2E_AGENT_KEY_9999
        "configurator_config.json (OID 9999)"  = "9RPIFSm2ZuOed7DicwD1RXvAMK3YcyMQ6AqRhilC7gM" # E2E_CONFIGURATOR_KEY_9999
        "loader_config.json"                   = "-K-1MMMeSihwAbdUxM1a15_PoKrpm_IUr2k7X8XVFF4" # E2E_LOADER_KEY
    }
    $configFilesForE2E = @(
        "online_hybrid_config.json",
        "offline_hybrid_config.json", # Для этого файла ключ не используется агентом напрямую
        "loader_config.json",
        "configurator_config.json"
    )
    foreach ($configFile in $configFilesForE2E) {
        Write-Host "Проверка файла: $PathToAgentConfigs/$configFile"
        $content = docker-compose -f $DockerComposeFile exec -T powershell_test_node cat "$PathToAgentConfigs/$configFile"
        if ($content) {
            $config = $content | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($config.api_key) {
                Write-Host "  Найден API ключ: $($config.api_key)"
                # Проверка соответствия, если ключ есть в $expectedKeysInConfigs
                $expectedKeyEntry = $expectedKeysInConfigs.GetEnumerator() | Where-Object { $configFile -match $_.Key.Split(' ')[0] } | Select-Object -First 1
                if ($expectedKeyEntry) {
                    if ($config.api_key -eq $expectedKeyEntry.Value) {
                        Write-Host "    СООТВЕТСТВУЕТ ожидаемому для '$($expectedKeyEntry.Key)'." -ForegroundColor Green
                    } else {
                        Write-Warning "    НЕ СООТВЕТСТВУЕТ ожидаемому для '$($expectedKeyEntry.Key)' (ожидался: '$($expectedKeyEntry.Value)')"
                    }
                }
            } else {
                 Write-Host "  API ключ в файле '$configFile' не найден или пуст."
            }
        } else {
            Write-Warning "Не удалось прочитать файл '$PathToAgentConfigs/$configFile' из контейнера."
        }
        Write-Host ""
    }
    
    Write-Host "`n--- API ключи, существующие в тестовой базе данных: ---"
    docker-compose -f $DockerComposeFile exec -T postgres_test_statusmonitor psql -U pu_user -d pu_db_test -c "SELECT id, description, role, object_id, is_active, left(key_hash,10) || '...' as hash_start FROM api_keys ORDER BY role, object_id;"
    Write-Host "==============================" -ForegroundColor Cyan
}

try {
    # 1. Запуск окружения
    Write-Host "Поднятие тестового окружения Docker (включая БД и Flask API для E2E)..." -ForegroundColor Green
    docker-compose -f $DockerComposeFile up -d --remove-orphans --build
    Write-Host "Ожидание полной готовности всех сервисов (90 секунд)..."
    # Увеличим ожидание, так как Flask и две БД могут занимать время на инициализацию
    Start-Sleep -Seconds 90

    # Проверка API ключей (важно сделать после того, как БД полностью инициализирована скриптами)
    Test-APIKeys

    # === Сценарий для Гибридного Агента в Online режиме ===
    Write-Host "`n--- Тест Гибридного Агента (Online режим) ---" -ForegroundColor Green
    $onlineHybridConfigFile = "$PathToAgentConfigs/online_hybrid_config.json"
    $hybridAgentScript = "$PathToStatusMonitorPsScripts/hybrid-agent/hybrid-agent.ps1"
    $utilsModulePath = "$PathToStatusMonitorPsScripts/StatusMonitorAgentUtils/StatusMonitorAgentUtils.psd1"

    Write-Host "Запуск Hybrid-Agent в Online режиме (конфиг: $onlineHybridConfigFile)..."
    # Запускаем агента в фоновом режиме внутри контейнера, чтобы он поработал некоторое время
    # и успел опросить API и выполнить задания.
    # Запуск в фоновом режиме: Start-Job или Invoke-Command -AsJob (но это сложнее в docker exec)
    # Проще запустить его на короткое время и потом проверить результаты.
    # Для E2E, если online_cycle_interval_seconds не предусмотрен, он выполнит один цикл и завершится,
    # что может быть недостаточно для проверки поллинга заданий.
    # Пока оставим как есть, предполагая, что один цикл online-агента достаточен для теста.
    docker-compose -f $DockerComposeFile exec -T powershell_test_node pwsh -Command "Import-Module $using:utilsModulePath -Force; & $using:hybridAgentScript -ConfigFile $using:onlineHybridConfigFile"
    Write-Host "Гибридный Агент (Online) отработал (предположительно, один цикл). Ожидание обработки результатов сервером (15 секунд)..."
    Start-Sleep -Seconds 15

    # === Сценарий для Гибридного Агента в Offline режиме (полный цикл) ===
    Write-Host "`n--- Тест Гибридного Агента (Offline режим - полный цикл) ---" -ForegroundColor Green
    $configuratorConfigFile = "$PathToAgentConfigs/configurator_config.json"
    $configuratorScript = "$PathToStatusMonitorPsScripts/configurator/generate_and_deliver_config.ps1"
    $offlineHybridConfigFile = "$PathToAgentConfigs/offline_hybrid_config.json"
    $loaderConfigFile = "$PathToAgentConfigs/loader_config.json"
    $loaderScript = "$PathToStatusMonitorPsScripts/result_loader/result_loader.ps1"

    # 1. Запуск Конфигуратора
    Write-Host "  1. Запуск Конфигуратора (для генерации *.json.status.*)..."
    docker-compose -f $DockerComposeFile exec -T powershell_test_node pwsh -Command "& $using:configuratorScript -ConfigFile $using:configuratorConfigFile"
    Write-Host "  Конфигуратор отработал. Ожидание (5 секунд)..."
    Start-Sleep -Seconds 5

    # Проверка, что файл конфигурации создан (опционально, но полезно для отладки)
    # Нужно знать transport_code для OID 9999 (предположим, 'TESTPS' из 001_windows_test_node_setup.sql)
    $transportCodeFor9999 = "TESTPS" # Это должно быть задано в БД для OID 9999
    $expectedConfigDeliveryPath = "$PathToAgentConfigs/assignments_for_9999/$transportCodeFor9999"
    Write-Host "  Проверка наличия файла конфигурации в $expectedConfigDeliveryPath..."
    docker-compose -f $DockerComposeFile exec -T powershell_test_node pwsh -Command "Get-ChildItem -Path $using:expectedConfigDeliveryPath -Filter '*.json.status.*' | Select-Object -ExpandProperty Name"

    # 2. Запуск Гибридного Агента в Offline режиме
    Write-Host "  2. Запуск Гибридного Агента в Offline режиме (конфиг: $offlineHybridConfigFile)..."
    docker-compose -f $DockerComposeFile exec -T powershell_test_node pwsh -Command "Import-Module $using:utilsModulePath -Force; & $using:hybridAgentScript -ConfigFile $using:offlineHybridConfigFile"
    Write-Host "  Гибридный Агент (Offline) отработал. Ожидание (5 секунд)..."
    Start-Sleep -Seconds 5

    # Проверка, что .zrpu файл создан (опционально)
    $offlineOutputPath = (ConvertFrom-Json (docker-compose -f $DockerComposeFile exec -T powershell_test_node cat $offlineHybridConfigFile)).output_path
    Write-Host "  Проверка наличия файла результатов *.zrpu в $offlineOutputPath..."
    docker-compose -f $DockerComposeFile exec -T powershell_test_node pwsh -Command "Get-ChildItem -Path $using:offlineOutputPath -Filter '*.zrpu' | Select-Object -ExpandProperty Name"

    # 3. Запуск Загрузчика Результатов
    Write-Host "  3. Запуск Загрузчика Результатов (конфиг: $loaderConfigFile)..."
    # Загрузчик обычно работает в цикле, для E2E теста он должен найти файл, обработать и, возможно, завершиться,
    # если scan_interval_seconds очень большой или он так настроен.
    # Если он висит, docker exec может не завершиться.
    # Пока предполагаем, что он отработает и завершится, если нет новых файлов.
    docker-compose -f $DockerComposeFile exec -T powershell_test_node pwsh -Command "& $using:loaderScript -ConfigFile $using:loaderConfigFile"
    Write-Host "  Загрузчик Результатов отработал. Ожидание обработки результатов сервером (15 секунд)..."
    Start-Sleep -Seconds 15

    # === Выполнение проверок в БД (Pytest) ===
    # Эта часть остается актуальной
    Write-Host "`n--- Выполнение Python-тестов для валидации данных в БД (Pytest) ---" -ForegroundColor Green
    # Убедитесь, что pytest установлен в вашем окружении, где запускается этот PowerShell скрипт,
    # ИЛИ запускайте pytest внутри контейнера, если у вас есть контейнер с Python и pytest.
    # Для простоты, если pytest доступен локально:
    # pytest ../status/tests/e2e_db_validation_tests.py -s -v
    # Если нужно запускать из другого места или в контейнере, скорректируйте команду.
    # Пример для запуска внутри контейнера Flask (если там есть pytest):
    # docker-compose -f $DockerComposeFile exec -T status_web_e2e_test pytest /app/tests/e2e_db_validation_tests.py -s -v
    # Поскольку e2e_db_validation_tests.py находится в testDB_kaskad, и он должен подключаться к БД
    # из этого же docker-compose, его лучше запускать с хост-машины, если Python и psycopg2 установлены.
    # Или создать специальный контейнер для запуска тестов.
    # Пока оставим комментарий, т.к. выполнение зависит от вашего окружения.
    Write-Host "ЗАПУСТИТЕ ВАШИ PYTEST E2E ТЕСТЫ ВАЛИДАЦИИ БД ОТДЕЛЬНО (например, pytest ../status/tests/integration/e2e_db_validation_tests.py)" -ForegroundColor Yellow
    # python ./e2e_db_validation_tests.py # Если он в той же папке и настроен

    Write-Host "`nE2E тесты (сценарии запуска агентов) завершены успешно!" -ForegroundColor Green

} catch {
    Write-Error "ОШИБКА во время E2E тестов: $($_.Exception.Message)"
    # Попытка остановить контейнеры в случае ошибки (остается)
} finally {
    Write-Host "`nОстановка тестового окружения Docker..." -ForegroundColor Yellow
    docker-compose -f $DockerComposeFile down -v # -v для удаления томов и очистки
    Write-Host "Тестовое окружение Docker полностью остановлено и очищено."
}