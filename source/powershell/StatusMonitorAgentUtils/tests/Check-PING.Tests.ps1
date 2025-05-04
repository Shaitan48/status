# F:\status\source\powershell\StatusMonitorAgentUtils\tests\Check-PING.Tests.ps1
# Pester тесты для скрипта Checks\Check-PING.ps1

# <<< ИСПРАВЛЕНО: Указываем RequiredVersion для Pester >>>
#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

# --- Начало тестов ---

# Импортируем функции из основного модуля (особенно New-CheckResultObject)
# Используем BeforeAll, чтобы загрузить один раз перед всеми тестами в этом файле
BeforeAll {
    try {
        # Определяем путь к основному файлу модуля .psm1 относительно этого тестового файла
        $modulePsm1Path = Join-Path -Path $PSScriptRoot -ChildPath '..\StatusMonitorAgentUtils.psm1'
        # Проверяем существование файла
        if (-not (Test-Path $modulePsm1Path -PathType Leaf)) {
            throw "Не найден основной файл модуля: $modulePsm1Path"
        }
        # Загружаем функции из модуля в текущую область видимости через dot-sourcing
        # Это сделает New-CheckResultObject доступной для тестируемого скрипта
        . $modulePsm1Path
        Write-Host "INFO: Функции из StatusMonitorAgentUtils.psm1 загружены для тестов Check-PING." -ForegroundColor Green
    } catch {
        Write-Error "КРИТИЧЕСКАЯ ОШИБКА в BeforeAll: Не удалось загрузить '$modulePsm1Path'. $($_.Exception.Message)"
        # Прерываем выполнение тестов, если модуль не загружен
        throw "Не удалось загрузить необходимые функции."
    }
}

# Описываем тестируемый скрипт
Describe 'Check-PING.ps1' {

    # Определяем путь к самому скрипту Check-PING.ps1
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-PING.ps1'

    # --- Тестовые сценарии ---

    Context 'При успешном пинге' {

        # Мокируем Test-Connection, чтобы он возвращал успешный результат
        # Mock будет действовать в пределах этого Context блока
        BeforeEach {
             Mock Test-Connection {
                 # Возвращаем объект, похожий на результат Test-Connection в PS 5.1
                 # (В PS Core поля могут называться иначе, но скрипт должен это учитывать)
                 [PSCustomObject]@{
                     StatusCode            = 0 # Success
                     Status                = 'Success'
                     IPV4Address           = [System.Net.IPAddress]::Parse('192.168.1.1') # Пример IP
                     IPV6Address           = $null
                     InterfaceIndex        = 12
                     Source                = $env:COMPUTERNAME
                     Destination           = '192.168.1.1' # Адрес назначения
                     BufferSize            = 32
                     ReplySize             = 32
                     TimeToLive            = 128
                     RoundTripTime         = 15 # RTT в мс
                     ResponseTime          = 15 # Альтернативное имя для RTT в PS 5.1
                     Latency               = 15 # Имя RTT в PS Core
                     ProtocolAddress       = '192.168.1.1'
                     Options               = $null
                     PrimaryInterfaceStatus= 'Up'
                 }
             } -ModuleName Microsoft.PowerShell.Management # Указываем модуль для мока
        }

        It 'Должен вернуть IsAvailable=$true и CheckSuccess=$true, если критерии не заданы' {
            # Входные параметры для скрипта
            $testParams = @{
                TargetIP        = '192.168.1.1'
                Parameters      = @{ count = 1 } # Параметры для Test-Connection
                SuccessCriteria = $null         # Нет критериев
                NodeName        = 'TestNode-PingOK'
            }
            # Выполняем скрипт через оператор вызова '&' со splatting'ом параметров '@'
            $result = & $scriptPath @testParams

            # Проверяем результат с помощью Pester Should
            $result | Should -Not -BeNull
            $result.IsAvailable | Should -BeTrue
            $result.CheckSuccess | Should -BeTrue
            $result.Details | Should -Not -BeNull
            $result.Details.response_time_ms | Should -Be 15
            $result.Details.ip_address | Should -Be '192.168.1.1'
            $result.ErrorMessage | Should -BeNullOrEmpty
        }

        It 'Должен вернуть CheckSuccess=$true, если RTT меньше или равно max_rtt_ms' {
            $testParams = @{
                TargetIP        = '192.168.1.1'
                Parameters      = @{ count = 1 }
                SuccessCriteria = @{ max_rtt_ms = 100 } # Критерий: RTT <= 100ms
                NodeName        = 'TestNode-PingCriteriaOK'
            }
            $result = & $scriptPath @testParams
            $result.IsAvailable | Should -BeTrue
            $result.CheckSuccess | Should -BeTrue # Ожидаем успех
            $result.ErrorMessage | Should -BeNullOrEmpty
        }

        It 'Должен вернуть CheckSuccess=$false, если RTT больше max_rtt_ms' {
            $testParams = @{
                TargetIP        = '192.168.1.1'
                Parameters      = @{ count = 1 }
                SuccessCriteria = @{ max_rtt_ms = 10 } # Критерий: RTT <= 10ms (наш мок вернет 15ms)
                NodeName        = 'TestNode-PingCriteriaFail'
            }
            $result = & $scriptPath @testParams
            $result.IsAvailable | Should -BeTrue # Пинг прошел
            $result.CheckSuccess | Should -BeFalse # Но критерий не пройден
            $result.ErrorMessage | Should -Contain 'превышает' # Проверяем сообщение об ошибке
        }
    }

    Context 'При ошибке пинга' {

        # Мокируем Test-Connection, чтобы он выбрасывал исключение
        BeforeEach {
            Mock Test-Connection {
                 throw "Сбой удаленного вызова процедуры. (Timeout)"
             } -ModuleName Microsoft.PowerShell.Management
        }

        It 'Должен вернуть IsAvailable=$false и содержать ErrorMessage' {
            $testParams = @{
                TargetIP        = '10.255.255.1' # Несуществующий адрес
                Parameters      = @{ timeout_ms = 500 }
                SuccessCriteria = $null
                NodeName        = 'TestNode-PingFail'
            }
            $result = & $scriptPath @testParams

            $result | Should -Not -BeNull
            $result.IsAvailable | Should -BeFalse # Пинг не прошел
            $result.CheckSuccess | Should -BeNull # Успех не определен
            $result.ErrorMessage | Should -Not -BeNullOrEmpty
            $result.ErrorMessage | Should -Contain 'Timeout' # Проверяем часть сообщения об ошибке
            $result.Details | Should -HaveProperty 'error' # Детали должны содержать ошибку
        }
    }

    Context 'Обработка некорректных критериев' {

         # Используем успешный мок Test-Connection
         BeforeEach { Mock Test-Connection { [PSCustomObject]@{ ResponseTime = 15 } } -ModuleName Microsoft.PowerShell.Management }

         It 'Должен вернуть CheckSuccess=$false, если max_rtt_ms не является числом' {
            $testParams = @{
                TargetIP        = '192.168.1.1'
                Parameters      = @{}
                SuccessCriteria = @{ max_rtt_ms = 'десять' } # Некорректное значение
                NodeName        = 'TestNode-BadCriteria'
            }
            $result = & $scriptPath @testParams

            $result.IsAvailable | Should -BeTrue # Пинг прошел
            $result.CheckSuccess | Should -BeFalse # Но критерий не может быть применен корректно
            $result.ErrorMessage | Should -Contain 'Некорректное значение'
            $result.Details.success_criteria_error | Should -Not -BeNullOrEmpty
        }
    }
}
# --- Конец тестов ---