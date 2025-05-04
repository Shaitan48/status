# ManualTest-Check-PING.ps1
# Скрипт для ручного тестирования Check-PING.ps1

# --- 1. Загрузка модуля Utils ---
$ErrorActionPreference = "Stop"
try {
    # Укажи правильный путь к манифесту модуля
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1"
    Write-Host "Загрузка модуля из '$modulePath'..." -ForegroundColor Cyan
    Import-Module $modulePath -Force
    Write-Host "Модуль загружен." -ForegroundColor Green
} catch {
    Write-Error "Критическая ошибка загрузки модуля Utils: $($_.Exception.Message)"
    exit 1
} finally {
    $ErrorActionPreference = "Continue"
}

# --- 2. Путь к тестируемому скрипту ---
$checkScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Checks\Check-PING.ps1"
if (-not (Test-Path $checkScriptPath -PathType Leaf)) {
    Write-Error "Скрипт '$checkScriptPath' не найден!"
    exit 1
}
Write-Host "Тестируемый скрипт: $checkScriptPath"

# --- 3. Определение тестовых сценариев ---
$testCases = @(
    @{
        TestName = "Успешный пинг localhost (без критериев)"
        TargetIP = '127.0.0.1'
        Parameters = @{ count = 1 }
        SuccessCriteria = $null
        ExpectedIsAvailable = $true
        ExpectedCheckSuccess = $true # т.к. IsAvailable и нет критериев
        ExpectedError = $false
    }
    @{
        TestName = "Неуспешный пинг (несуществующий IP)"
        TargetIP = '192.0.2.1' # Зарезервированный немаршрутизируемый IP
        Parameters = @{ timeout_ms = 500; count = 1 }
        SuccessCriteria = $null
        ExpectedIsAvailable = $false
        ExpectedCheckSuccess = $null # т.к. IsAvailable=false
        ExpectedError = $true
    }
    @{
        TestName = "Успешный пинг с пройденным критерием RTT"
        TargetIP = 'ya.ru' # Или другой доступный хост
        Parameters = @{}
        SuccessCriteria = @{ rtt_ms = @{ '<=' = 1000 } } # Ожидаем RTT <= 1000ms
        ExpectedIsAvailable = $true
        ExpectedCheckSuccess = $true # Критерий должен пройти (если RTT < 1000)
        ExpectedError = $false
        # Ожидаем, что Test-SuccessCriteria вернет {Passed=$true}
    }
    @{
        TestName = "Успешный пинг с НЕ пройденным критерием RTT"
        TargetIP = 'ya.ru'
        Parameters = @{}
        SuccessCriteria = @{ rtt_ms = @{ '<=' = 1 } } # Заведомо невыполнимый критерий
        ExpectedIsAvailable = $true
        ExpectedCheckSuccess = $false # Критерий НЕ должен пройти
        ExpectedError = $true # Ожидаем ErrorMessage с причиной провала критерия
        # Ожидаем, что Test-SuccessCriteria вернет {Passed=$false, FailReason=...}
    }
    @{
        TestName = "Успешный пинг с некорректным критерием RTT"
        TargetIP = 'ya.ru'
        Parameters = @{}
        SuccessCriteria = @{ rtt_ms = @{ '<=' = 'не число' } } # Некорректное значение
        ExpectedIsAvailable = $true
        ExpectedCheckSuccess = $null # Ошибка обработки критерия -> null
        ExpectedError = $true # Ожидаем ErrorMessage с ошибкой критерия
        # Ожидаем, что Test-SuccessCriteria вернет {Passed=$null, FailReason=...}
    }
    @{
        TestName = "Пинг с двумя критериями (RTT и Потери, потери = 0)"
        TargetIP = 'ya.ru'
        Parameters = @{}
        SuccessCriteria = @{ rtt_ms = @{ '<=' = 1000 }; packet_loss_percent = @{ '==' = 0 } } # Оба должны пройти
        ExpectedIsAvailable = $true
        ExpectedCheckSuccess = $true
        ExpectedError = $false
    }
)

# --- 4. Выполнение тестов ---
Write-Host ("-"*50)
foreach ($testCase in $testCases) {
    Write-Host "Запуск теста: $($testCase.TestName)" -ForegroundColor Yellow
    Write-Host "Параметры:"
    Write-Host "  TargetIP: $($testCase.TargetIP)"
    Write-Host "  Parameters: $($testCase.Parameters | ConvertTo-Json -Depth 1 -Compress)"
    Write-Host "  SuccessCriteria: $($testCase.SuccessCriteria | ConvertTo-Json -Depth 2 -Compress)"

    # <<< ИСПРАВЛЕНО: Подготовка параметров для splatting >>>
    $scriptArgs = @{
        TargetIP        = $testCase.TargetIP
        Parameters      = $testCase.Parameters
        SuccessCriteria = $testCase.SuccessCriteria
        NodeName        = $testCase.TestName # Используем имя теста для логов
    }

    # Вызов скрипта через оператор '&' и splatting '@scriptArgs'
    try {
        # & вызывает скрипт в дочерней области видимости, но функции модуля будут доступны
        $result = & $checkScriptPath @scriptArgs
    } catch {
        Write-Error "Критическая ошибка при ВЫЗОВЕ скрипта '$checkScriptPath': $($_.Exception.Message)"
        $result = $null # Не удалось получить результат
    }

    # --- 5. Проверка результата (остается без изменений) ---
    Write-Host "Результат:"
    if ($result -ne $null) {
        # ... (код проверки результата) ...
        Write-Host ($result | ConvertTo-Json -Depth 4) -ForegroundColor Gray

        # Проверка IsAvailable
        if ($result.IsAvailable -eq $testCase.ExpectedIsAvailable) {
            Write-Host "  [PASS] IsAvailable: $($result.IsAvailable)" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] IsAvailable: Ожидалось $($testCase.ExpectedIsAvailable), получено $($result.IsAvailable)" -ForegroundColor Red
        }
        # Проверка CheckSuccess
        if ($result.CheckSuccess -eq $testCase.ExpectedCheckSuccess) {
            Write-Host "  [PASS] CheckSuccess: $($result.CheckSuccess)" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] CheckSuccess: Ожидалось $($testCase.ExpectedCheckSuccess), получено $($result.CheckSuccess)" -ForegroundColor Red
        }
        # Проверка ErrorMessage
        $hasError = -not [string]::IsNullOrEmpty($result.ErrorMessage)
        if ($hasError -eq $testCase.ExpectedError) {
            Write-Host "  [PASS] ErrorMessage: $($hasError) (Сообщение: '$($result.ErrorMessage)')" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] ErrorMessage: Ожидалось $($testCase.ExpectedError), получено $($hasError) (Сообщение: '$($result.ErrorMessage)')" -ForegroundColor Red
        }
        # Дополнительно можно проверить содержимое Details
        if($testCase.ExpectedIsAvailable -eq $true -and $testCase.ExpectedError -eq $false){
            # Проверяем, есть ли Details, есть ли в нем ключ rtt_ms, и значение НЕ null
            if($result.Details -ne $null -and ($result.Details.PSObject.Properties.Name -contains 'rtt_ms') -and $result.Details.rtt_ms -ne $null){
                 Write-Host "  [INFO] RTT: $($result.Details.rtt_ms)ms" -ForegroundColor DarkGray # Сделаем серым, т.к. это инфо
            } else {
                 # Выводим WARN только если RTT действительно должен был быть (т.е. ExpectedIsAvailable=true, ExpectedError=false)
                 Write-Host "  [WARN] RTT равен null или отсутствует в Details при УСПЕШНОМ результате." -ForegroundColor Yellow
            }
        }

    } else {
        Write-Host "  [FAIL] Результат выполнения скрипта равен null!" -ForegroundColor Red
    }
    Write-Host ("-"*50)
    Start-Sleep -Seconds 1 # Небольшая пауза между тестами
}

Write-Host "Тестирование завершено."