# Check-SQL_QUERY_EXECUTE.Tests.ps1
# Тесты для Check-SQL_QUERY_EXECUTE.ps1 v2.0.1 с моками Invoke-Sqlcmd

# Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.0' }

# Локальная New-CheckResultObject
function New-CheckResultObject { [CmdletBinding()] param([bool]$IsAvailable,[nullable[bool]]$CheckSuccess=$null,[hashtable]$Details=$null,[string]$ErrorMessage=$null); $r=[ordered]@{IsAvailable=$IsAvailable;CheckSuccess=$CheckSuccess;Timestamp=(Get-Date).ToUniversalTime().ToString("o");Details=$Details;ErrorMessage=$ErrorMessage}; if($r.IsAvailable){if($r.CheckSuccess-eq$null){$r.CheckSuccess=$true}}else{$r.CheckSuccess=$null}; if([string]::IsNullOrEmpty($r.ErrorMessage)){if(-not $r.IsAvailable){$r.ErrorMessage="Ошибка выполнения проверки (IsAvailable=false)."}}; return $r }

Describe 'Check-SQL_QUERY_EXECUTE.ps1 (v2.0.1)' {

    $script:scriptPath = $null
    $script:utilsModuleName = 'StatusMonitorAgentUtils'

    BeforeAll {
        $script:scriptPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\Checks\Check-SQL_QUERY_EXECUTE.ps1') -EA Stop
        try { Import-Module (Join-Path $PSScriptRoot '..\StatusMonitorAgentUtils.psd1') -Force -EA Stop } catch { throw "..." }
        # Мок Get-Command, чтобы скрипт думал, что модуль SqlServer есть
        Mock Get-Command { param($Name) if($Name -eq 'Invoke-Sqlcmd'){ return $true } else { Get-Command @PSBoundParameters } }
    }

    # Базовое задание
    $baseAssignment = @{ method_name = 'SQL_QUERY_EXECUTE'; node_name = 'TestNode-SQL'; ip_address = 'TestSQLServer'; parameters = @{sql_database='TestDB'}; success_criteria = $null }

    # Общие моки
    BeforeEach {
        Mock New-CheckResultObject { param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage); return @{ Mocked=$true; M_IsAvailable=$IsAvailable; M_CheckSuccess=$CheckSuccess; M_Details=$Details; M_ErrorMessage=$ErrorMessage } } -ModuleName $script:utilsModuleName
        Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName
        # --- Мок Invoke-Sqlcmd ---
        # По умолчанию возвращает одну строку
        $mockSqlData = @( [PSCustomObject]@{ ID = 1; Name = 'Row1'; Value = 100 } )
        Mock Invoke-Sqlcmd { param($Query) Write-Verbose "Mock Invoke-Sqlcmd: Query=$Query"; return $using:mockSqlData }
    }

    Context 'Обработка разных return_format' {
        It 'first_row: Должен вернуть первую строку как хэш-таблицу' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters.sql_query = "SELECT *"; $assignment.parameters.return_format = 'first_row'
            $result = & $script:scriptPath @assignment
            Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                ($Details.return_format_used -eq 'first_row') -and
                ($Details.query_result -is [hashtable]) -and $Details.query_result.ID -eq 1 -and $Details.query_result.Name -eq 'Row1' -and
                ($Details.rows_returned -eq 1)
            }
        }
        It 'all_rows: Должен вернуть массив хэш-таблиц' {
            $assignment = $script:baseAssignment.PSObject.Copy()
            $assignment.parameters.sql_query = "SELECT *"; $assignment.parameters.return_format = 'all_rows'
            # Мок вернет тот же массив из 1 элемента
            $result = & $script:scriptPath @assignment
            Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                 $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                 ($Details.return_format_used -eq 'all_rows') -and
                 ($Details.query_result -is [System.Collections.Generic.List[object]]) -and $Details.query_result.Count -eq 1 -and
                 ($Details.query_result[0] -is [hashtable]) -and $Details.query_result[0].Value -eq 100 -and
                 ($Details.rows_returned -eq 1)
            }
        }
         It 'row_count: Должен вернуть количество строк' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters.sql_query = "SELECT ID"; $assignment.parameters.return_format = 'row_count'
             # Мок вернет 1 строку
             $result = & $script:scriptPath @assignment
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                  $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                  ($Details.return_format_used -eq 'row_count') -and ($Details.row_count -eq 1)
             }
         }
          It 'scalar: Должен вернуть значение первого столбца первой строки' {
              $assignment = $script:baseAssignment.PSObject.Copy()
              $assignment.parameters.sql_query = "SELECT Value"; $assignment.parameters.return_format = 'scalar'
              # Мок вернет объект с Value=100
              $result = & $script:scriptPath @assignment
              Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                   $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                   ($Details.return_format_used -eq 'scalar') -and ($Details.scalar_value -eq 100)
              }
          }
          It 'non_query: Должен вернуть non_query_success = true' {
              $assignment = $script:baseAssignment.PSObject.Copy()
              $assignment.parameters.sql_query = "UPDATE T"; $assignment.parameters.return_format = 'non_query'
              Mock Invoke-Sqlcmd { return $null } -Scope It # Non-query обычно ничего не возвращает
              $result = & $script:scriptPath @assignment
              Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly
              Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                   $IsAvailable -eq $true -and $CheckSuccess -eq $true -and
                   ($Details.return_format_used -eq 'non_query') -and ($Details.non_query_success -eq $true)
              }
          }
          It 'Должен обработать пустой результат от Invoke-Sqlcmd для first_row' {
               $assignment = $script:baseAssignment.PSObject.Copy()
               $assignment.parameters.sql_query = "SELECT * WHERE 1=0"; $assignment.parameters.return_format = 'first_row'
               Mock Invoke-Sqlcmd { return $null } -Scope It
               $result = & $script:scriptPath @assignment
               Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                    $IsAvailable -eq $true -and $CheckSuccess -eq $true -and # Пустой результат - не ошибка
                    ($Details.return_format_used -eq 'first_row') -and ($Details.query_result -eq $null) -and ($Details.rows_returned -eq 0)
               }
          }
    } # Конец Context 'Обработка return_format'

    Context 'Проверка Критериев Успеха' {
         It 'Должен вызвать Test-SuccessCriteria для row_count и вернуть CheckSuccess=false (mock=false)' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters.sql_query = "SELECT ID"; $assignment.parameters.return_format = 'row_count'
             $assignment.success_criteria = @{ row_count = @{ '==' = 0 } } # Критерий: строк должно быть 0
             $failReasonMock = "Количество строк (1) не равно 0"
             Mock Test-SuccessCriteria { return @{ Passed = $false; FailReason = $using:failReasonMock } } -ModuleName $script:utilsModuleName -Scope It
             # Мок Invoke-Sqlcmd возвращает 1 строку
             $result = & $script:scriptPath @assignment
             Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CriteriaObject.row_count -ne $null }
             Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $false -and $ErrorMessage -eq $using:failReasonMock }
         }
         It 'Должен вызвать Test-SuccessCriteria для scalar и вернуть CheckSuccess=true (mock=true)' {
              $assignment = $script:baseAssignment.PSObject.Copy()
              $assignment.parameters.sql_query = "SELECT Value"; $assignment.parameters.return_format = 'scalar'
              $assignment.success_criteria = @{ scalar_value = @{ '<' = 200 } } # Критерий: значение < 200
              Mock Test-SuccessCriteria { return @{ Passed = $true; FailReason = $null } } -ModuleName $script:utilsModuleName -Scope It
              # Мок Invoke-Sqlcmd возвращает 100
              $result = & $script:scriptPath @assignment
              Should -Invoke Test-SuccessCriteria -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CriteriaObject.scalar_value -ne $null }
              Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter { $CheckSuccess -eq $true }
         }
    } # Конец Context 'Проверка Критериев'

    Context 'Ошибки Invoke-Sqlcmd' {
         BeforeEach { Mock Invoke-Sqlcmd { throw "Ошибка подключения к SQL (Mock)" } }
         It 'Должен вернуть IsAvailable=false и сообщение об ошибке SQL' {
             $assignment = $script:baseAssignment.PSObject.Copy()
             $assignment.parameters.sql_query = "SELECT 1"; $assignment.parameters.return_format = 'scalar'
             $result = & $script:scriptPath @assignment
             $result.Mocked | Should -BeNullOr $false # Реальный результат из catch
             $result.IsAvailable | Should -BeFalse
             $result.CheckSuccess | Should -BeNull
             $result.ErrorMessage | Should -Match 'Критическая ошибка'
             $result.ErrorMessage | Should -Match 'SQL'
             Should -Invoke Test-SuccessCriteria -Times 0 -ModuleName $script:utilsModuleName
         }
          It 'non_query: Должен вернуть IsAvailable=false и non_query_success=false' {
              $assignment = $script:baseAssignment.PSObject.Copy()
              $assignment.parameters.sql_query = "UPDATE T"; $assignment.parameters.return_format = 'non_query'
              $result = & $script:scriptPath @assignment
              Should -Invoke New-CheckResultObject -Times 1 -Exactly -ModuleName $script:utilsModuleName -ParameterFilter {
                   $IsAvailable -eq $false -and $CheckSuccess -eq $null -and
                   ($Details.non_query_success -eq $false) -and
                   $ErrorMessage -match 'Ошибка non-query SQL'
              }
          }
    } # Конец Context 'Ошибки Invoke-Sqlcmd'
} # Конец Describe