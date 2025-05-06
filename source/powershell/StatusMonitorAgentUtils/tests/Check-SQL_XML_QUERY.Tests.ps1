# Check-SQL_XML_QUERY.Tests.ps1
# Тесты для Check-SQL_XML_QUERY.ps1 v2.0.1 с моками Invoke-Sqlcmd

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

# Локальная New-CheckResultObject
function New-CheckResultObject { [CmdletBinding()] param([bool]$IsAvailable,[nullable[bool]]$CheckSuccess=$null,[hashtable]$Details=$null,[string]$ErrorMessage=$null); $r=[ordered]@{IsAvailable=$IsAvailable;CheckSuccess=$CheckSuccess;Timestamp=(Get-Date).ToUniversalTime().ToString("o");Details=$Details;ErrorMessage=$ErrorMessage}; if($r.IsAvailable){if($r.CheckSuccess-eq$null){$r.CheckSuccess=$true}}else{$r.CheckSuccess=$null}; if([string]::IsNullOrEmpty($r.ErrorMessage)){if(-not $r.IsAvailable){$r.ErrorMessage="Ошибка выполнения проверки (IsAvailable=false)."}}; return $r }

Describe 'Check-SQL_XML_QUERY.ps1 (v2.0.1)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils'

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-SQL_XML_QUERY.ps1') -EA Stop
        try { Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop } catch { throw "..." }
        Mock Get-Command { param($Name) if($Name -eq 'Invoke-Sqlcmd'){ return $true } else { Get-Command @PSBoundParameters } }
    }

    # Базовое задание
    $baseAssignment = @{ method_name = 'SQL_XML_QUERY'; node_name = 'TestNode-SQLXML'; ip_address = 'TestSQLServer'; parameters = @{sql_database='TestDB'}; success_criteria = $null }

    # Общие моки
    BeforeEach {
        Mock New-CheckResultObject { param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage); return @{ Mocked=$true; M_IsAvailable=$IsAvailable; M_CheckSuccess=$CheckSuccess; M_Details=$Details; M_ErrorMessage=$ErrorMessage } } -ModuleName $script:utilsModuleName
        Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName
        # --- Мок Invoke-Sqlcmd ---
        # По умолчанию возвращает строку с валидным XML
        $mockXmlString = '<Root><KeyA>ValueA</KeyA><KeyB>123</KeyB></Root>'
        $mockSqlData = @( [PSCustomObject]@{ XmlColumn = $mockXmlString; OtherColumn = 'data' } )
        Mock Invoke-Sqlcmd { param($Query) Write-Verbose "Mock Invoke-Sqlcmd: Query=$Query"; return $using:mockSqlData }
    }

    Context 'Успешное выполнение и парсинг XML' {
        It 'Должен извлечь значения для существующих ключей' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters.sql_query = "SELECT XmlColumn"; $assignment.parameters.xml_column_name = 'XmlColumn'
            $assignment.parameters.keys_to_extract = @('KeyA', 'KeyB')
            $result = & $script:scriptPath @assignment
            Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                ($Details.extracted_data -is [hashtable]) -and
                $Details.extracted_data.KeyA -eq 'ValueA' -and
                $Details.extracted_data.KeyB -eq '123'
            }
             Should -Invoke Test-SuccessCriteria -Times 0 # Критериев нет
        }

        It 'Должен вернуть null для несуществующих ключей' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters.sql_query = "SELECT XmlColumn"; $assignment.parameters.xml_column_name = 'XmlColumn'
             $assignment.parameters.keys_to_extract = @('KeyA', 'NonExistentKey')
             $result = & $script:scriptPath @assignment
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                  $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                  $Details.extracted_data.KeyA -eq 'ValueA' -and
                  $Details.extracted_data.ContainsKey('NonExistentKey') -and $Details.extracted_data.NonExistentKey -eq $null
             }
        }
    } # Конец Context 'Успешное выполнение'

    Context 'Проверка Критериев Успеха' {
        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=true (mock=true)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters.sql_query = "SELECT XmlColumn"; $assignment.parameters.xml_column_name = 'XmlColumn'; $assignment.parameters.keys_to_extract = @('KeyA', 'KeyB')
             $assignment.success_criteria = @{ extracted_data = @{ KeyA = 'ValueA'; KeyB = @{'>'=100} } }
             Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName -Scope It
             $result = & $script:scriptPath @assignment
             Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CriteriaObject.extracted_data -ne $null }
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $true }
        }
        It 'Должен вызвать Test-SuccessCriteria и вернуть CheckSuccess=false (mock=false)' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters.sql_query = "SELECT XmlColumn"; $assignment.parameters.xml_column_name = 'XmlColumn'; $assignment.parameters.keys_to_extract = @('KeyB')
            $assignment.success_criteria = @{ extracted_data = @{ KeyB = @{'<'=100} } } # Критерий KeyB < 100 (не пройдет, т.к. он 123)
            $failReasonMock = "KeyB (123) не меньше 100"
            Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It
            $result = & $script:scriptPath @assignment
            Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $false -and $ErrorMessage -eq $using:failReasonMock }
        }
    } # Конец Context 'Проверка Критериев'

    Context 'Ошибки SQL или Парсинга' {
        It 'Должен вернуть IsAvailable=false, если Invoke-Sqlcmd выдает ошибку' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters.sql_query = "ERROR"; $assignment.parameters.xml_column_name = 'C'; $assignment.parameters.keys_to_extract = @('K')
            Mock Invoke-Sqlcmd { throw "SQL Error (Mock)" } -Scope It
            $result = & $script:scriptPath @assignment
            $result.Mocked | Should -BeNullOr $false
            $result.IsAvailable | Should -BeFalse; $result.CheckSuccess | Should -BeNull; $result.ErrorMessage | Should -Match 'Критическая ошибка'; $result.ErrorMessage | Should -Match 'SQL Error'
            Should -Invoke Test-SuccessCriteria -Times 0
        }
        It 'Должен вернуть IsAvailable=false, если столбец XML не найден' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters.sql_query = "SELECT OtherColumn"; $assignment.parameters.xml_column_name = 'WrongColumnName'; $assignment.parameters.keys_to_extract = @('K')
            # Мок Invoke-Sqlcmd возвращает OtherColumn='data'
            $result = & $script:scriptPath @assignment
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $IsAvailable -eq $false -and $ErrorMessage -match 'не найден' }
            Should -Invoke Test-SuccessCriteria -Times 0
        }
        It 'Должен вернуть IsAvailable=false, если XML невалиден' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters.sql_query = "SELECT BadXml"; $assignment.parameters.xml_column_name = 'BadXml'; $assignment.parameters.keys_to_extract = @('K')
            Mock Invoke-Sqlcmd { return @([PSCustomObject]@{ BadXml = '<Root><KeyA>ValueA</Root' }) } -Scope It # Незакрытый тег
            $result = & $script:scriptPath @assignment
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $IsAvailable -eq $false -and $ErrorMessage -match 'Ошибка парсинга' }
            Should -Invoke Test-SuccessCriteria -Times 0
        }
         It 'Должен вернуть IsAvailable=true, если SQL не вернул строк' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters.sql_query = "SELECT XmlCol WHERE 1=0"; $assignment.parameters.xml_column_name = 'XmlCol'; $assignment.parameters.keys_to_extract = @('K')
             Mock Invoke-Sqlcmd { return $null } -Scope It # Имитируем пустой результат
             $result = & $script:scriptPath @assignment
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $IsAvailable -eq $true -and $CheckSuccess -eq $true -and $Details.message -match 'не вернул строк' }
             Should -Invoke Test-SuccessCriteria -Times 0
         }
    } # Конец Context 'Ошибки SQL или Парсинга'

} # Конец Describe