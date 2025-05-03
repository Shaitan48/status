# Invoke-StatusMonitorCheck.Tests.ps1 (v8 - Используем $PSScriptRoot в BeforeAll)

# --- Блок подготовки ---
# BeforeAll выполняется один раз перед всеми тестами в этом Describe блоке.
BeforeAll {
    # Используем $PSScriptRoot, который указывает на директорию текущего файла теста (.Tests.ps1)
    Write-Host "INFO: PSScriptRoot определен как: $PSScriptRoot" # Лог для отладки
    if (-not $PSScriptRoot) {
        throw "Не удалось определить директорию теста (\$PSScriptRoot). Невозможно найти модуль."
    }

    # Строим путь к манифесту относительно папки tests
    $moduleManifestRelativePath = '..\StatusMonitorAgentUtils.psd1'
    $moduleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath $moduleManifestRelativePath

    # Используем Resolve-Path для получения полного пути и проверки существования
    try {
        $resolvedModulePath = Resolve-Path -Path $moduleManifestPath -ErrorAction Stop
        Write-Host "INFO: Полный путь к манифесту модуля: $resolvedModulePath"
    } catch {
        # Добавляем более детальное сообщение об ошибке
        Write-Error "Не удалось найти/определить путь к манифесту модуля '$moduleManifestPath'. Убедитесь, что структура папок верна: tests/ находится внутри StatusMonitorAgentUtils/. Ошибка Resolve-Path: $($_.Exception.Message)"
        throw "Не удалось найти модуль для тестирования." # Прерываем выполнение
    }

    # Импортируем модуль по полному пути
    Write-Host "INFO: Загрузка модуля из $resolvedModulePath для тестов..."
    Remove-Module StatusMonitorAgentUtils -Force -ErrorAction SilentlyContinue
    Import-Module $resolvedModulePath -Force
    Write-Host "INFO: Модуль StatusMonitorAgentUtils загружен."
}

# --- Тесты ---
Describe 'Invoke-StatusMonitorCheck (Диспетчер проверок)' {

    # --- Mocking (без изменений) ---
    Mock New-CheckResultObject { Param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage)
        return @{ Mocked = $true; IsAvailable = $IsAvailable; CheckSuccess = $CheckSuccess; ErrorMessage = $ErrorMessage; Details = $Details }
    } -ModuleName StatusMonitorAgentUtils

    Mock Test-Path { Param($Path)
        if ($Path -like "*Checks\Check-*.ps1") { return $true }
        return Test-Path @using:PSBoundParameters
    } -ModuleName Microsoft.PowerShell.Management

    Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
        Write-Verbose "Мок Invoke-CheckScript: Перехвачен вызов '$ScriptPath'"
        return @{ IsAvailable = $true; CheckSuccess = $true; Timestamp = (Get-Date).ToUniversalTime().ToString("o"); Details = @{ CalledScript = $ScriptPath; ParamsPassed = $ParametersForScript }; ErrorMessage = $null }
    } -ModuleName StatusMonitorAgentUtils

    # --- Тестовые данные (без изменений) ---
    $baseAssignment = @{
        assignment_id = 101; node_id = 1; node_name = 'TestNode'; ip_address = '127.0.0.1'
        parameters = @{ timeout = 500 }; success_criteria = @{ max_rtt_ms = 100 }
    }

    # --- Тесты (без изменений) ---

    It 'Должен вызывать Invoke-CheckScript для метода PING с правильными параметрами' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'PING'
        Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
            $ScriptPath | Should -EndWith '\Checks\Check-PING.ps1'
            $ParametersForScript | Should -Not -BeNull
            $ParametersForScript.TargetIP | Should -Be $using:assignment.ip_address
            $ParametersForScript.Parameters | Should -Be $using:assignment.parameters
            $ParametersForScript.SuccessCriteria | Should -Be $using:assignment.success_criteria
            $ParametersForScript.NodeName | Should -Be $using:assignment.node_name
            return @{ IsAvailable = $true; CheckSuccess = $true; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=@{mocked_call_for='PING'}; ErrorMessage=$null }
        } -ModuleName StatusMonitorAgentUtils -Verifiable
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        $result.IsAvailable | Should -BeTrue
        $result.Details.mocked_call_for | Should -Be 'PING'
        Should -Invoke Invoke-CheckScript -Times 1 -ModuleName StatusMonitorAgentUtils
    }

    It 'Должен вызывать Invoke-CheckScript для SERVICE_STATUS с правильными параметрами' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'SERVICE_STATUS'
        $assignment.parameters = @{ service_name = 'Spooler' }
        $assignment.success_criteria = @{ status = 'Running' }
        Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
            $ScriptPath | Should -EndWith '\Checks\Check-SERVICE_STATUS.ps1'
            $ParametersForScript.TargetIP | Should -Be $using:assignment.ip_address
            $ParametersForScript.Parameters.service_name | Should -Be 'Spooler'
            $ParametersForScript.SuccessCriteria.status | Should -Be 'Running'
            return @{ IsAvailable = $true; CheckSuccess = $true; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=@{mocked_call_for='SERVICE'}; ErrorMessage=$null }
        } -ModuleName StatusMonitorAgentUtils -Verifiable
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        $result.IsAvailable | Should -BeTrue
        $result.Details.mocked_call_for | Should -Be 'SERVICE'
        Should -Invoke Invoke-CheckScript -Times 1 -ModuleName StatusMonitorAgentUtils
    }

    It 'Должен возвращать ошибку, если скрипт проверки не найден (Test-Path вернул false)' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'NON_EXISTENT_METHOD'
        Mock Test-Path { Param($Path)
            if ($Path -like "*Check-NON_EXISTENT_METHOD.ps1") { return $false }
            return $true
        } -ModuleName Microsoft.PowerShell.Management -Verifiable
        Mock Invoke-CheckScript { throw "Invoke-CheckScript не должен был вызваться!" } -ModuleName StatusMonitorAgentUtils -Verifiable -Scope It
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        Should -Invoke Test-Path -Times 1 -ModuleName Microsoft.PowerShell.Management
        Should -Invoke Invoke-CheckScript -Times 0 -ModuleName StatusMonitorAgentUtils
        $result.Mocked | Should -BeTrue
        $result.IsAvailable | Should -BeFalse
        $result.ErrorMessage | Should -Contain 'не найден'
        $result.ErrorMessage | Should -Contain 'Check-NON_EXISTENT_METHOD.ps1'
    }

    It 'Должен возвращать ошибку, если метод не указан в задании' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.PSObject.Properties.Remove('method_name')
        Mock Invoke-CheckScript { throw "Не должно было дойти до вызова скрипта" } -ModuleName StatusMonitorAgentUtils -Verifiable -Scope It
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        Should -Invoke Invoke-CheckScript -Times 0 -ModuleName StatusMonitorAgentUtils
        $result.Mocked | Should -BeTrue
        $result.IsAvailable | Should -BeFalse
        $result.ErrorMessage | Should -Contain 'Некорректный объект задания'
    }

     It 'Должен возвращать ошибку, если Invoke-CheckScript выбрасывает исключение' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'SCRIPT_WITH_ERROR'
        $errorMessageFromInvoke = "Критическая ошибка при вызове скрипта"
        Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
            if ($ScriptPath -like "*Check-SCRIPT_WITH_ERROR.ps1") {
                throw $errorMessageFromInvoke
            }
        } -ModuleName StatusMonitorAgentUtils -Verifiable
        Mock Test-Path { return $true } -ModuleName Microsoft.PowerShell.Management
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        Should -Invoke Invoke-CheckScript -Times 1 -ModuleName StatusMonitorAgentUtils
        $result.Mocked | Should -BeTrue
        $result.IsAvailable | Should -BeFalse
        $result.ErrorMessage | Should -Contain $errorMessageFromInvoke
        $result.ErrorMessage | Should -Contain 'Ошибка выполнения скрипта проверки'
    }

     It 'Должен возвращать ошибку, если Invoke-CheckScript вернул некорректный формат' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'BAD_FORMAT_SCRIPT'
        Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
            if ($ScriptPath -like "*Check-BAD_FORMAT_SCRIPT.ps1") {
                return "Это просто строка, а не хеш-таблица"
            }
        } -ModuleName StatusMonitorAgentUtils -Verifiable
        Mock Test-Path { return $true } -ModuleName Microsoft.PowerShell.Management
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        Should -Invoke Invoke-CheckScript -Times 1 -ModuleName StatusMonitorAgentUtils
        $result.Mocked | Should -BeTrue
        $result.IsAvailable | Should -BeFalse
        $result.ErrorMessage | Should -Contain 'вернул некорректный формат'
    }
}