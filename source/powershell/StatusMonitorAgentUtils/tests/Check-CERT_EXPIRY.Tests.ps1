# Check-CERT_EXPIRY.Tests.ps1
# Тесты для Check-CERT_EXPIRY.ps1 v2.0.3 с моками

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

# Определяем New-CheckResultObject локально
function New-CheckResultObject { [CmdletBinding()] param([bool]$IsAvailable,[nullable[bool]]$CheckSuccess=$null,[hashtable]$Details=$null,[string]$ErrorMessage=$null); $r=[ordered]@{IsAvailable=$IsAvailable;CheckSuccess=$CheckSuccess;Timestamp=(Get-Date).ToUniversalTime().ToString("o");Details=$Details;ErrorMessage=$ErrorMessage}; if($r.IsAvailable){if($r.CheckSuccess-eq$null){$r.CheckSuccess=$true}}else{$r.CheckSuccess=$null}; if([string]::IsNullOrEmpty($r.ErrorMessage)){if(-not $r.IsAvailable){$r.ErrorMessage="Ошибка выполнения проверки (IsAvailable=false)."}}; return $r }

Describe 'Check-CERT_EXPIRY.ps1 (v2.0.3)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils'

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-CERT_EXPIRY.ps1') -EA Stop
        try { Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop } catch { throw "..." }
    }

    # Базовое задание
    $baseAssignment = @{ method_name = 'CERT_EXPIRY'; node_name = 'TestNode-Cert'; ip_address = $null; parameters = @{}; success_criteria = $null }

    # Общие моки
    BeforeEach {
        Mock New-CheckResultObject { param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage); return @{ Mocked=$true; M_IsAvailable=$IsAvailable; M_CheckSuccess=$CheckSuccess; M_Details=$Details; M_ErrorMessage=$ErrorMessage } } -ModuleName $script:utilsModuleName
        Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName
        # --- Мок Get-ChildItem Cert:\... ---
        # Имитируем несколько сертификатов с разным сроком действия
        $mockCerts = @(
            [PSCustomObject]@{ Thumbprint='CERT1'; Subject='CN=ok.example.com'; Issuer='CN=Test CA'; NotAfter=(Get-Date).AddDays(100); HasPrivateKey=$true; PSParentPath='Cert:\LocalMachine\My' }
            [PSCustomObject]@{ Thumbprint='CERT2'; Subject='CN=warn.example.com'; Issuer='CN=Test CA'; NotAfter=(Get-Date).AddDays(20); HasPrivateKey=$true; PSParentPath='Cert:\LocalMachine\My' } # Истекает через 20 дней (попадет в Warning)
            [PSCustomObject]@{ Thumbprint='CERT3'; Subject='CN=expired.example.com'; Issuer='CN=Test CA'; NotAfter=(Get-Date).AddDays(-5); HasPrivateKey=$true; PSParentPath='Cert:\CurrentUser\My' } # Истек 5 дней назад
            [PSCustomObject]@{ Thumbprint='CERT4'; Subject='CN=nokeys.example.com'; Issuer='CN=Test CA'; NotAfter=(Get-Date).AddDays(300); HasPrivateKey=$false; PSParentPath='Cert:\LocalMachine\WebHosting' } # Без ключа
        )
        Mock Get-ChildItem {
            param($Path)
            Write-Verbose "Mock Get-ChildItem called for Path: $Path"
            $storeName = ($Path -split '\\')[-1]
            # Возвращаем сертификаты в зависимости от пути
            switch -Wildcard ($Path) {
                'Cert:\LocalMachine\My' { return $using:mockCerts | Where-Object {$_.PSParentPath -eq $Path} }
                'Cert:\CurrentUser\My' { return $using:mockCerts | Where-Object {$_.PSParentPath -eq $Path} }
                'Cert:\LocalMachine\WebHosting' { return $using:mockCerts | Where-Object {$_.PSParentPath -eq $Path} }
                Default { return @() } # Пусто для других путей
            }
        } -ModuleName Microsoft.PowerShell.Security
    }

    Context 'Получение данных о сертификатах' {
        It 'Должен вернуть IsAvailable=true и 4 сертификата без фильтров' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $result = & $script:scriptPath @assignment
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and # Нет критериев - успех
                ($Details.certificates.Count -eq 4) -and
                [string]::IsNullOrEmpty($ErrorMessage)
            }
            Should -Invoke Test-SuccessCriteria -Times 0 # Нет критериев
        }

        It 'Должен вернуть 1 сертификат по точному отпечатку' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ thumbprint = 'CERT2' }
            $result = & $script:scriptPath @assignment
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $Details.certificates.Count -eq 1 -and $Details.certificates[0].thumbprint -eq 'CERT2'
            }
        }

        It 'Должен вернуть 3 сертификата с приватным ключом' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters = @{ require_private_key = $true }
            $result = & $script:scriptPath @assignment
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $Details.certificates.Count -eq 3 -and ($Details.certificates | Where-Object {-not $_.has_private_key}).Count -eq 0
            }
        }
         It 'Должен правильно рассчитать статус (OK, Warn, Expired)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters = @{ min_days_warning = 25 } # Предупреждать, если <= 25 дней
             $result = & $script:scriptPath @assignment
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 ($cert1 = $Details.certificates |? {$_.thumbprint -eq 'CERT1'}) -and $cert1.status -eq 'OK' -and
                 ($cert2 = $Details.certificates |? {$_.thumbprint -eq 'CERT2'}) -and $cert2.status -eq 'Expiring (Warn)' -and # 20 дней <= 25 дней
                 ($cert3 = $Details.certificates |? {$_.thumbprint -eq 'CERT3'}) -and $cert3.status -eq 'Expired' -and
                 ($cert4 = $Details.certificates |? {$_.thumbprint -eq 'CERT4'}) -and $cert4.status -eq 'OK'
             }
         }
    } # Конец Context 'Получение данных'

    Context 'Проверка Критериев Успеха' {
         It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=true, если критерий пройден (mock=true)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             # Критерий: все сертификаты > 10 дней
             $assignment.success_criteria = @{ certificates=@{_condition_='all';_criteria_=@{days_left=@{'>'=10}}} }
             Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName -Scope It
             $result = & $script:scriptPath @assignment
             Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $true -and [string]::IsNullOrEmpty($ErrorMessage) }
         }
         It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=false, если критерий НЕ пройден (mock=false)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             # Критерий: все сертификаты > 25 дней (не пройдет из-за CERT2 и CERT3)
             $assignment.success_criteria = @{ certificates=@{_condition_='all';_criteria_=@{days_left=@{'>'=25}}} }
             $failReasonMock = "Сертификат CERT2 истекает через 20 дней"
             Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It
             $result = & $script:scriptPath @assignment
             Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $false -and $ErrorMessage -eq $using:failReasonMock }
         }
    } # Конец Context 'Критерии Успеха'

     Context 'Ошибки Доступа к Хранилищам' {
         BeforeEach {
             # Мокируем Get-ChildItem так, чтобы для LocalMachine\My возникала ошибка
             Mock Get-ChildItem {
                 param($Path)
                 if ($Path -eq 'Cert:\LocalMachine\My') { throw "Отказано в доступе (Mock Store Error)" }
                 else { return $using:mockCerts | Where-Object {$_.PSParentPath -eq $Path} } # Возвращаем остальные
             } -ModuleName Microsoft.PowerShell.Security
         }
         It 'Должен вернуть IsAvailable=true, но содержать ошибку доступа в Details' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $result = & $script:scriptPath @assignment
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $IsAvailable -eq $true -and $CheckSuccess -eq $true -and # Нет критериев -> успех
                 ($Details.certificates.Count -eq 2) -and # Только из CurrentUser и WebHosting
                 ($Details.access_errors -is [array] -and $Details.access_errors.Count -eq 1 -and $Details.access_errors[0] -match 'Отказано в доступе') -and
                 # ErrorMessage должен быть null, т.к. CheckSuccess=true
                 [string]::IsNullOrEmpty($ErrorMessage)
             }
         }
          It 'Должен вернуть CheckSuccess=false, если критерии не пройдены ДЛЯ НАЙДЕННЫХ сертификатов, даже если были ошибки доступа' {
              $assignment = $script:baseAssignment.PSObject.Copy()
              # Критерий: Все найденные должны иметь > 400 дней (не пройдет для CERT4)
              $assignment.success_criteria = @{ certificates=@{_condition_='all';_criteria_=@{days_left=@{'>'=400}}} }
              $failReasonMock = "Срок CERT4 < 400 дней"
              Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It
              $result = & $script:scriptPath @assignment
              Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                   $IsAvailable -eq $true -and $CheckSuccess -eq $false -and
                   ($Details.certificates.Count -eq 2) -and
                   ($Details.access_errors.Count -eq 1) -and
                   # ErrorMessage содержит причину провала критерия
                   $ErrorMessage -eq $using:failReasonMock
              }
          }
     } # Конец Context 'Ошибки Доступа'

} # Конец Describe