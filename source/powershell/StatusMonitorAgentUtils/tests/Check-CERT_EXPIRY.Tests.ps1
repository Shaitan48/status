# F:\status\source\powershell\StatusMonitorAgentUtils\tests\Check-CERT_EXPIRY.Tests.ps1
# --- Версия с попыткой импорта Microsoft.PowerShell.Security ---

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' } # Pester 5+

# Локальное определение New-CheckResultObject для изоляции от мока основной функции
# Убедитесь, что эта версия соответствует той, что используется в вашем StatusMonitorAgentUtils.psm1 (возвращает Hashtable)
function New-CheckResultObjectLocalPester { 
    [CmdletBinding()] 
    param(
        [Parameter(Mandatory = $true)] [bool]$IsAvailable,
        [Parameter(Mandatory = $false)] [nullable[bool]]$CheckSuccess = $null, 
        [Parameter(Mandatory = $false)] $Details = $null,
        [Parameter(Mandatory = $false)] [string]$ErrorMessage = $null
    )
    $processedDetails = $null
    if ($null -ne $Details) {
        if ($Details -is [hashtable]) { $processedDetails = $Details }
        elseif ($Details -is [System.Management.Automation.PSCustomObject]) {
            $processedDetails = @{}
            $Details.PSObject.Properties | ForEach-Object { $processedDetails[$_.Name] = $_.Value }
        } else { $processedDetails = @{ Value = $Details } }
    }
    $finalCheckSuccess = $CheckSuccess 
    if (-not $IsAvailable) { $finalCheckSuccess = $null }
    # Важно: если $IsAvailable = $true и $CheckSuccess пришел как $null (ошибка критерия), он должен остаться $null.
    # Если $IsAvailable = $true и $CheckSuccess не был передан (подразумевается, что критерии не применялись или прошли),
    # то Check-*.ps1 сам должен был установить $checkSuccess в $true перед вызовом New-CheckResultObject.
    # Таким образом, здесь мы не меняем $finalCheckSuccess на $true по умолчанию, если $IsAvailable.
    
    $finalErrorMessage = $ErrorMessage
    if ([string]::IsNullOrEmpty($finalErrorMessage)) {
        if (-not $IsAvailable) { $finalErrorMessage = "Ошибка выполнения проверки (IsAvailable=false)." }
        elseif ($finalCheckSuccess -eq $false) { $finalErrorMessage = "Проверка не прошла по критериям (CheckSuccess=false)." }
        elseif ($finalCheckSuccess -eq $null -and $IsAvailable) { $finalErrorMessage = "Не удалось оценить критерии успеха (CheckSuccess=null), хотя проверка доступности прошла."}
    }
    return @{ # Возвращаем Hashtable
        IsAvailable  = $IsAvailable
        CheckSuccess = $finalCheckSuccess
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        Details      = $processedDetails 
        ErrorMessage = $finalErrorMessage
    }
}

Describe 'Check-CERT_EXPIRY.ps1 (текущая версия после рефакторинга)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils' # Имя вашего модуля

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-CERT_EXPIRY.ps1') -ErrorAction Stop
        if (-not $script:scriptPath) { throw "Не удалось найти скрипт Check-CERT_EXPIRY.ps1" }

        # Загружаем основной модуль StatusMonitorAgentUtils, чтобы мокать его функции
        try {
            Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -ErrorAction Stop
        } catch {
            throw "Критическая ошибка: Не удалось загрузить основной модуль '$($script:utilsModuleName)' для тестов. Ошибка: $($_.Exception.Message)"
        }

        # --- ПОПЫТКА ИСПРАВЛЕНИЯ: Явный импорт модуля Microsoft.PowerShell.Security ---
        try {
            Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
            Write-Host "INFO (Pester BeforeAll): Модуль Microsoft.PowerShell.Security успешно импортирован." -ForegroundColor Cyan
        } catch {
            Write-Warning "ПРЕДУПРЕЖДЕНИЕ (Pester BeforeAll): Не удалось импортировать модуль Microsoft.PowerShell.Security. Моки для Get-ChildItem могут не работать корректно. Ошибка: $($_.Exception.Message)"
        }
        # --- КОНЕЦ ПОПЫТКИ ИСПРАВЛЕНИЯ ---
    }

    # Базовый объект задания для тестов
    $baseAssignment = @{ 
        method_name = 'CERT_EXPIRY'
        node_name   = 'TestNode-CertExpiry'
        ip_address  = $null # Для Check-CERT_EXPIRY TargetIP не используется для выполнения
        parameters  = @{}
        success_criteria = $null 
    }

    # Общие моки для большинства тестов
    BeforeEach {
    Mock -CommandName Get-ChildItem -MockWith { return $script:mockCertificates }

        # Мокируем функции из НАШЕГО модуля StatusMonitorAgentUtils
        Mock New-CheckResultObject -ModuleName $script:utilsModuleName {
            # Используем локальную копию функции, чтобы не мокать саму себя в бесконечном цикле,
            # если бы мы мокали ее для проверки вызова с параметрами.
            # В данном случае, мы просто хотим, чтобы скрипт Check-*.ps1 ее использовал.
            # А проверять будем уже возвращенный результат.
            # Поэтому важно, чтобы New-CheckResultObjectLocalPester вела себя так же, как реальная.
            param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage)
            return New-CheckResultObjectLocalPester -IsAvailable $IsAvailable -CheckSuccess $CheckSuccess -Details $Details -ErrorMessage $ErrorMessage
        }

        Mock Test-SuccessCriteria -ModuleName $script:utilsModuleName {
            # По умолчанию считаем, что критерии пройдены, если они вызываются
            param($DetailsObject, $CriteriaObject, $Path) # Добавляем Path для соответствия сигнатуре
            Write-Verbose "Mock Test-SuccessCriteria CALLED with Path: $Path, Criteria: $($CriteriaObject | ConvertTo-Json -Depth 1 -Compress)"
            return @{ Passed = $true; FailReason = $null } 
        }

        # --- Мок для Get-ChildItem из Microsoft.PowerShell.Security ---
        # Имитируем набор сертификатов
        $commonTestDate = Get-Date
        $script:mockCertificates = @(
            [PSCustomObject]@{ Thumbprint='CERT_OK_LONG'; Subject='CN=ok-long.example.com'; Issuer='CN=Test CA'; NotAfter=$commonTestDate.AddDays(200); HasPrivateKey=$true;  PSParentPath='Cert:\LocalMachine\My'; Extensions=@([PSCustomObject]@{Oid=[PSCustomObject]@{FriendlyName='Enhanced Key Usage'; Value='1.3.6.1.5.5.7.3.1'}; EnhancedKeyUsages=@([PSCustomObject]@{Oid='1.3.6.1.5.5.7.3.1'})}) } # SSL
            [PSCustomObject]@{ Thumbprint='CERT_OK_SHORT'; Subject='CN=ok-short.example.com'; Issuer='CN=Test CA'; NotAfter=$commonTestDate.AddDays(45);  HasPrivateKey=$true;  PSParentPath='Cert:\LocalMachine\My'; Extensions=@() }
            [PSCustomObject]@{ Thumbprint='CERT_WARN_SOON'; Subject='CN=warn.example.com';   Issuer='CN=Test CA'; NotAfter=$commonTestDate.AddDays(15);  HasPrivateKey=$true;  PSParentPath='Cert:\CurrentUser\My'; Extensions=@() } # Истекает через 15 дней
            [PSCustomObject]@{ Thumbprint='CERT_EXPIRED'; Subject='CN=expired.example.com'; Issuer='CN=Test CA'; NotAfter=$commonTestDate.AddDays(-5); HasPrivateKey=$false; PSParentPath='Cert:\LocalMachine\My'; Extensions=@() } # Истек
            [PSCustomObject]@{ Thumbprint='CERT_NO_PK'; Subject='CN=no-pk.example.com';   Issuer='CN=Test CA'; NotAfter=$commonTestDate.AddDays(100); HasPrivateKey=$false; PSParentPath='Cert:\LocalMachine\WebHosting'; Extensions=@() }
            [PSCustomObject]@{ Thumbprint='CERT_OTHER_EKU'; Subject='CN=other-eku.example.com'; Issuer='CN=Test CA'; NotAfter=$commonTestDate.AddDays(180); HasPrivateKey=$true;  PSParentPath='Cert:\LocalMachine\My'; Extensions=@([PSCustomObject]@{Oid=[PSCustomObject]@{FriendlyName='Enhanced Key Usage'; Value='1.3.6.1.5.5.7.3.2'}; EnhancedKeyUsages=@([PSCustomObject]@{Oid='1.3.6.1.5.5.7.3.2'})}) } # Client Auth
        )
        
        # Мокируем Get-ChildItem. Pester должен найти команду, если модуль загружен.
        Mock Get-ChildItem -ModuleName Microsoft.PowerShell.Security {
            param($Path)
            Write-Verbose "Mock Get-ChildItem called for Path: $Path"
            $storeName = ($Path -split '\\')[-1]
            $storeLocation = ($Path -split '\\')[-2]
            # Возвращаем сертификаты в зависимости от пути
            # Важно, чтобы PSParentPath в мок-сертификатах соответствовал этим путям
            return $script:mockCertificates | Where-Object {$_.PSParentPath -eq $Path}
        }
        
        # Мокируем Test-Path, чтобы он всегда возвращал true для путей к хранилищам из нашего мока
        Mock Test-Path {
            param($Path)
            if ($Path -like "Cert:\*") {
                # Проверяем, есть ли такое хранилище в наших мок-сертификатах
                if (($script:mockCertificates.PSParentPath | Select-Object -Unique) -contains $Path) {
                    Write-Verbose "Mock Test-Path for '$Path' returning True (store exists in mock)"
                    return $true
                } else {
                     Write-Verbose "Mock Test-Path for '$Path' returning False (store does not exist in mock or specified by test)"
                    return $false # Для хранилищ, которых нет в моке, возвращаем false
                }
            }
            # Для других путей вызываем реальный Test-Path
            return Test-Path @using:PSBoundParameters 
        } -ModuleName Microsoft.PowerShell.Management
    }

    Context 'Получение данных о сертификатах (с новой обработкой параметров и хранилищ)' {
        It 'Должен вернуть IsAvailable=true и все 6 мок-сертификатов, если параметры фильтрации и хранилища не указаны (стандартные хранилища)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            # Параметры не указаны, скрипт должен использовать стандартный список хранилищ
            
            $result = & $script:scriptPath @assignment
            
            $result.IsAvailable | Should -BeTrue
            $result.Details.certificates | Should -HaveCount 6
            ($result.Details.stores_checked -contains 'Cert:\LocalMachine\My') | Should -BeTrue
            ($result.Details.stores_checked -contains 'Cert:\LocalMachine\WebHosting') | Should -BeTrue
            ($result.Details.stores_checked -contains 'Cert:\CurrentUser\My') | Should -BeTrue
            $result.Details.parameters_used.min_days_warning | Should -Be 30 # Дефолтное значение
            $result.ErrorMessage | Should -BeNullOrEmpty
        }

        It 'Должен искать только в указанном хранилище LocalMachine\My' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ store_location = 'LocalMachine'; store_name = 'My' }
            
            $result = & $script:scriptPath @assignment
            
            $result.IsAvailable | Should -BeTrue
            # В LocalMachine\My у нас 3 сертификата по моку (OK_LONG, OK_SHORT, EXPIRED, OTHER_EKU) - всего 4
            $result.Details.certificates | Should -HaveCount 4 
            $result.Details.stores_checked | Should -HaveCount 1
            ($result.Details.stores_checked[0] -eq 'Cert:\LocalMachine\My') | Should -BeTrue
        }

        It 'Должен корректно фильтровать по отпечатку' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ thumbprint = 'CERT_WARN_SOON' } # Этот в CurrentUser\My
            
            $result = & $script:scriptPath @assignment
            
            $result.IsAvailable | Should -BeTrue
            $result.Details.certificates | Should -HaveCount 1
            $result.Details.certificates[0].thumbprint | Should -Be 'CERT_WARN_SOON'
            $result.Details.filter_applied | Should -BeTrue
        }

        It 'Должен корректно фильтровать по EKU (SSL Server Auth)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ eku_oid = @('1.3.6.1.5.5.7.3.1') } # SSL Server Auth
            
            $result = & $script:scriptPath @assignment
            
            $result.IsAvailable | Should -BeTrue
            $result.Details.certificates | Should -HaveCount 1
            $result.Details.certificates[0].thumbprint | Should -Be 'CERT_OK_LONG'
            $result.Details.filter_applied | Should -BeTrue
        }

        It 'Должен корректно рассчитывать статус ExpiringSoon с учетом min_days_warning' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ min_days_warning = 20 } # Устанавливаем порог
            
            $result = & $script:scriptPath @assignment
            
            $certWarnSoon = $result.Details.certificates | Where-Object {$_.thumbprint -eq 'CERT_WARN_SOON'}
            $certWarnSoon.status | Should -Be 'ExpiringSoon' # days_left = 15, min_days_warning = 20
            $certOkShort = $result.Details.certificates | Where-Object {$_.thumbprint -eq 'CERT_OK_SHORT'}
            $certOkShort.status | Should -Be 'OK' # days_left = 45, min_days_warning = 20
        }
    }

    Context 'Проверка Критериев Успеха' {
        It 'Критерий "все > 30 дней": должен пройти, если все отфильтрованные сертификаты > 30 дней' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            # Фильтруем, чтобы остались только 'CERT_OK_LONG' (200 дней) и 'CERT_OK_SHORT' (45 дней)
            $assignment.parameters = @{ subject_like = 'ok-*.example.com' }
            $assignment.success_criteria = @{ 
                certificates = @{ _condition_ = 'all'; _criteria_ = @{ days_left = @{'>'=30} } } 
            }
            # Мок Test-SuccessCriteria по умолчанию возвращает Passed = $true, что подходит
            
            $result = & $script:scriptPath @assignment
            
            $result.IsAvailable | Should -BeTrue
            $result.Details.certificates | Should -HaveCount 2 # Убедимся, что фильтр сработал
            $result.CheckSuccess | Should -BeTrue
            $result.ErrorMessage | Should -BeNullOrEmpty
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
        }

        It 'Критерий "все > 50 дней": должен НЕ пройти, если CERT_OK_SHORT (45 дней) найден' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ subject_like = 'ok-*.example.com' } # Найдет CERT_OK_LONG и CERT_OK_SHORT
            $assignment.success_criteria = @{ 
                certificates = @{ _condition_ = 'all'; _criteria_ = @{ days_left = @{'>'=50} } } 
            }
            # Переопределяем мок Test-SuccessCriteria, чтобы имитировать провал
            $failReason = "Сертификат CERT_OK_SHORT имеет 45 дней, что не > 50"
            Mock Test-SuccessCriteria -ModuleName $script:utilsModuleName -MockWith { 
                return @{ Passed = $false; FailReason = $using:failReason } 
            } -Scope It
            
            $result = & $script:scriptPath @assignment
            
            $result.IsAvailable | Should -BeTrue
            $result.CheckSuccess | Should -BeFalse
            $result.ErrorMessage | Should -Be $failReason
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
        }

        It 'Критерий "ни один не Expired": должен пройти, если нет просроченных среди отфильтрованных' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            # Фильтруем все, КРОМЕ CERT_EXPIRED (у него hasPrivateKey = $false)
            $assignment.parameters = @{ require_private_key = $true } 
            $assignment.success_criteria = @{ 
                certificates = @{ _condition_ = 'none'; _where_ = @{ status = 'Expired' } } 
            }
            # Мок Test-SuccessCriteria (Passed=$true) подходит
            
            $result = & $script:scriptPath @assignment
            
            $result.IsAvailable | Should -BeTrue
            # Ожидаем 3 сертификата с приватным ключом из мока
            $result.Details.certificates | Should -HaveCount 3 
            ($result.Details.certificates.status -contains 'Expired') | Should -BeFalse
            $result.CheckSuccess | Should -BeTrue
            $result.ErrorMessage | Should -BeNullOrEmpty
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
        }
    }

    Context 'Обработка ошибок хранилищ и параметров' {
        It 'Должен вернуть IsAvailable=false, если указано несуществующее хранилище' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ store_location = 'InvalidStore'; store_name = 'NonExistent' }
            
            # Test-Path вернет false для этого пути
            Mock Test-Path { param($Path) if ($Path -eq 'Cert:\InvalidStore\NonExistent') { return $false } else { return $true } } -ModuleName Microsoft.PowerShell.Management -Scope It
            
            $result = & $script:scriptPath @assignment
            
            $result.IsAvailable | Should -BeFalse
            $result.CheckSuccess | Should -BeNull
            $result.ErrorMessage | Should -Contain "Не удалось получить доступ ни к одному из указанных/стандартных хранилищ"
        }

        It 'Должен вернуть IsAvailable=true и ошибку в ErrorMessage/Details, если одно из стандартных хранилищ недоступно' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            # Параметры не указаны, используются стандартные
            
            # Мокируем Test-Path, чтобы WebHosting был недоступен
            Mock Test-Path { 
                param($Path) 
                if ($Path -eq 'Cert:\LocalMachine\WebHosting') { return $false } 
                return $true # Остальные доступны
            } -ModuleName Microsoft.PowerShell.Management -Scope It
            
            $result = & $script:scriptPath @assignment
            
            $result.IsAvailable | Should -BeTrue # Доступ к другим хранилищам был
            $result.Details.store_access_errors | Should -HaveCount 1
            $result.Details.store_access_errors[0] | Should -Contain 'Cert:\LocalMachine\WebHosting'
            $result.ErrorMessage | Should -Contain 'ошибки доступа к некоторым хранилищам'
            # CheckSuccess должен быть true, если критериев нет и другие хранилища отработали
            $result.CheckSuccess | Should -BeTrue 
        }
    }
}
