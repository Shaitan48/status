<#
.SYNOPSIS
    ��������� SQL-������ � ���������� ���������.
.DESCRIPTION
    ������������ � MS SQL Server, ��������� ��������� SQL-������
    � ���������� ��������� � �������� ������� (������ ������, ��� ������,
    ���������� �����, ��������� �������� ��� ������ ���������� non-query).
    ������������ �������� SuccessCriteria ��� ��������� �����������.
.PARAMETER TargetIP
    [string] ��� ��� IP-����� SQL Server instance. ������������.
.PARAMETER Parameters
    [hashtable] ������������. �������� ��������� ����������� � �������:
    - sql_database (string):   ��� ���� ������. �����������.
    - sql_query (string):      SQL-������ ��� ����������. �����������.
    - return_format (string):  ������ ������������� ����������. ��������������.
                               ��������: 'first_row' (�� �����.), 'all_rows',
                               'row_count', 'scalar', 'non_query'.
    - sql_username (string):   ��� ������������ ��� SQL Server ��������������. ��������������.
    - sql_password (string):   ������ ��� SQL Server ��������������. ��������������.
                               (������������� �� �������������).
    - query_timeout_sec (int): ������� ���������� SQL-������� � ��������. (�� �����. 30).
.PARAMETER SuccessCriteria
    [hashtable] ��������������. �������� ������.
    ��� return_format = 'scalar':
    - expected_value (any): ��������� ������ �������� (������������ ��� ������).
    - value_greater_than (numeric): �������� ��������, ������� ��������� ������ ���������.
    - value_less_than (numeric): �������� ��������, �������� ��������� ������ ���� ������.
    (������ ������� ���� �� ������������ ��������).
.PARAMETER NodeName
    [string] ��������������. ��� ���� ��� �����������.
.OUTPUTS
    Hashtable - ������������������� ������ ���������� ��������
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
                ���������� Details ������� �� 'return_format'.
.NOTES
    ������: 1.1 (��������� ��������� SuccessCriteria ��� scalar)
    ������� �� ������� New-CheckResultObject �� ������������� ������.
    ������� ������� ������ PowerShell 'SqlServer'.
    ������� ���� ������� � SQL Server � ���� ������.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP, # ServerInstance

    [Parameter(Mandatory=$true)]
    [hashtable]$Parameters,

    [Parameter(Mandatory=$false)]
    [hashtable]$SuccessCriteria = $null, # �������� ��������

    [Parameter(Mandatory=$false)]
    [string]$NodeName = "Unknown Node"
)

# --- �������� ��������������� ������� ---
if (-not (Get-Command New-CheckResultObject -ErrorAction SilentlyContinue)) {
    try {
        $commonFunctionsPath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils.psm1"
        if(Test-Path $commonFunctionsPath) { . $commonFunctionsPath }
        else { throw "�� ������ ���� ������ ������: $commonFunctionsPath" }
    } catch {
        Write-Error "Check-SQL_QUERY_EXECUTE: ����������� ������: �� ������� ��������� New-CheckResultObject! $($_.Exception.Message)"
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}

# --- ������������� ���������� ---
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{ # ���-�������������� ���� Details
        server_instance = $TargetIP
        database_name = $null
        query_executed = $null
        return_format_used = 'first_row' # �������� �� ���������
    }
    ErrorMessage = $null
}

Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ������ ���������� SQL �� $TargetIP"

try {
    # 1. ��������� � ���������� ����������
    $SqlServerInstance = $TargetIP
    $DatabaseName = $Parameters.sql_database
    $SqlQuery = $Parameters.sql_query
    $ReturnFormat = ($Parameters.return_format | Get-OrElse 'first_row').ToLower()
    $SqlUsername = $Parameters.sql_username
    $SqlPassword = $Parameters.sql_password
    $QueryTimeoutSec = $Parameters.query_timeout_sec | Get-OrElse 30

    # ��������� Details
    $resultData.Details.database_name = $DatabaseName
    $resultData.Details.query_executed = $SqlQuery
    $resultData.Details.return_format_used = $ReturnFormat

    # �������� ������������ ����������
    if (-not $DatabaseName) { throw "����������� ������������ �������� 'sql_database'." }
    if (-not $SqlQuery) { throw "����������� ������������ �������� 'sql_query'." }
    if ($ReturnFormat -notin @('first_row', 'all_rows', 'row_count', 'scalar', 'non_query')) {
        throw "������������ �������� 'return_format': '$ReturnFormat'."
    }
    if ($SqlUsername -and (-not $SqlPassword)) { throw "�������� 'sql_password' ���������� ��� �������� 'sql_username'." }
    if (-not ([int]::TryParse($QueryTimeoutSec, [ref]$null)) -or $QueryTimeoutSec -le 0) {
         Write-Warning "[$NodeName] ������������ �������� query_timeout_sec ('$($Parameters.query_timeout_sec)'). ������������ 30 ���."; $QueryTimeoutSec = 30
    }


    # 2. ������������ ���������� ��� Invoke-Sqlcmd
    $invokeSqlParams = @{
        ServerInstance = $SqlServerInstance
        Database       = $DatabaseName
        Query          = $SqlQuery
        QueryTimeout   = $QueryTimeoutSec
        ErrorAction    = 'Stop' # ����� ��� ��������� ������
    }
    if ($SqlUsername) {
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ������������ SQL Server �������������� ��� '$SqlUsername'."
        $securePassword = ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($SqlUsername, $securePassword)
        $invokeSqlParams.Credential = $credential
    } else {
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ������������ Windows ��������������."
    }

    # 3. �������� � �������� ������ SqlServer
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
         if (-not (Get-Module -ListAvailable -Name SqlServer)) {
              throw "������ PowerShell 'SqlServer' �� ������. ���������� ���: Install-Module SqlServer -Scope CurrentUser -Force"
         }
         try {
             Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: �������� ������ SqlServer..."
             Import-Module SqlServer -ErrorAction Stop
         } catch {
              throw "�� ������� ��������� ������ 'SqlServer'. ������: $($_.Exception.Message)"
         }
    }

    # 4. ���������� SQL-�������
    Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ���������� ������� � '$SqlServerInstance/$DatabaseName'..."
    $queryResultData = Invoke-Sqlcmd @invokeSqlParams

    # ������ �������� ������� (��� ������)
    $resultData.IsAvailable = $true
    $resultData.CheckSuccess = $true # �� ��������� ������� ��������, ���� �� ���� ������ � �������� ������

    # 5. ��������� ���������� � ����������� �� return_format
    Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ��������� ���������� (������: $ReturnFormat)"
    $scalarValueForCriteria = $null # ��� �������� ���������

    switch ($ReturnFormat) {
        'first_row' {
            if ($queryResultData -ne $null) {
                 $firstRow = $queryResultData | Select-Object -First 1
                 $resultHashTable = @{}
                 if ($firstRow) {
                     $firstRow.PSObject.Properties | ForEach-Object { $resultHashTable[$_.Name] = $_.Value }
                 }
                 $resultData.Details.query_result = $resultHashTable
                 $resultData.Details.rows_returned = if ($queryResultData -is [array]) { $queryResultData.Length } elseif($firstRow) { 1 } else { 0 }
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ���������� ������ ������."
            } else {
                 $resultData.Details.query_result = $null; $resultData.Details.rows_returned = 0
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ������ �� ������ �����."
            }
        }
        'all_rows' {
            $allRowsList = [System.Collections.Generic.List[object]]::new()
            if ($queryResultData -ne $null) {
                 foreach($row in $queryResultData) {
                      $rowHashTable = @{}
                      $row.PSObject.Properties | ForEach-Object { $rowHashTable[$_.Name] = $_.Value }
                      $allRowsList.Add($rowHashTable)
                 }
                 $resultData.Details.rows_returned = $allRowsList.Count
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ���������� �����: $($allRowsList.Count)"
            } else {
                $resultData.Details.rows_returned = 0
                Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ������ �� ������ �����."
            }
             $resultData.Details.query_result = $allRowsList # ������ ���-������
        }
        'row_count' {
            if ($queryResultData -ne $null) {
                 $rowCount = if ($queryResultData -is [array]) { $queryResultData.Length } else { 1 }
                 $resultData.Details.row_count = $rowCount
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ���������� �����: $rowCount"
            } else {
                 $resultData.Details.row_count = 0
                 Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ������ �� ������ �����."
            }
        }
        'scalar' {
             if ($queryResultData -ne $null) {
                 $firstRow = $queryResultData | Select-Object -First 1
                 if ($firstRow) {
                     $firstColumnName = ($firstRow.PSObject.Properties | Select-Object -First 1).Name
                     $scalarValue = $firstRow.$firstColumnName
                     $resultData.Details.scalar_value = $scalarValue
                     $scalarValueForCriteria = $scalarValue # ��������� ��� �������� ���������
                     Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ��������� ��������: '$scalarValue'"
                 } else { $resultData.Details.scalar_value = $null; Write-Verbose "[...] ������ �� ������ ����� ��� �������." }
             } else { $resultData.Details.scalar_value = $null; Write-Verbose "[...] ������ �� ������ ����� ��� �������." }
        }
        'non_query' {
            # ������ ������� ����� ErrorAction=Stop, ��� ��������� null ��� non-query
            $resultData.Details.non_query_success = $true
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: Non-query ������ �������� �������."
        }
    }

    # 6. ��������� SuccessCriteria (���� ������ ��� SCALAR)
    if ($resultData.IsAvailable -and $ReturnFormat -eq 'scalar' -and $SuccessCriteria -ne $null) {
        Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ���������� SuccessCriteria ��� ���������� ��������..."
        $checkSuccessResult = $true # ��������� ���������� ��� ���������� �������� ���������
        $failReason = $null

        # �������� �� ������ ����������
        if ($SuccessCriteria.ContainsKey('expected_value')) {
            $expected = $SuccessCriteria.expected_value
            # ���������� ��� ������, ����� �������� ������� � ������
            if ("$scalarValueForCriteria" -ne "$expected") {
                $checkSuccessResult = $false
                $failReason = "�������� '$scalarValueForCriteria' �� ����� ���������� '$expected'."
            }
        }
        # �������� "������ ���"
        if ($checkSuccessResult -and $SuccessCriteria.ContainsKey('value_greater_than')) {
            try {
                $threshold = [double]$SuccessCriteria.value_greater_than
                $currentValue = [double]$scalarValueForCriteria
                if ($currentValue -le $threshold) {
                    $checkSuccessResult = $false
                    $failReason = "�������� $currentValue �� ������ $threshold."
                }
            } catch {
                 $checkSuccessResult = $null # ������ ��������� -> CheckSuccess = null
                 $failReason = "������ ���������: �������� '$scalarValueForCriteria' ��� �������� '$($SuccessCriteria.value_greater_than)' �� �������� ������."
            }
        }
        # �������� "������ ���"
        if ($checkSuccessResult -and $SuccessCriteria.ContainsKey('value_less_than')) {
            try {
                $threshold = [double]$SuccessCriteria.value_less_than
                $currentValue = [double]$scalarValueForCriteria
                if ($currentValue -ge $threshold) {
                    $checkSuccessResult = $false
                    $failReason = "�������� $currentValue �� ������ $threshold."
                }
            } catch {
                 $checkSuccessResult = $null # ������ ��������� -> CheckSuccess = null
                 $failReason = "������ ���������: �������� '$scalarValueForCriteria' ��� �������� '$($SuccessCriteria.value_less_than)' �� �������� ������."
            }
        }
        # ... ����� �������� ������ �������� (contains, not_contains, etc.)

        # ��������� �������� ���������
        if ($failReason -ne $null) {
            $resultData.ErrorMessage = $failReason
            $resultData.CheckSuccess = if ($checkSuccessResult -eq $null) { $null } else { $false }
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: �������� �� �������: $failReason"
        } else {
            $resultData.CheckSuccess = $true # ��� �������� ��������
            Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ��� �������� ��� ������� ��������."
        }
    } elseif ($SuccessCriteria -ne $null) {
         Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: SuccessCriteria ��������, �� ��� ������� '$ReturnFormat' �� ��������� ���� �� �����������."
    }


} catch {
    # �������� ������ Invoke-Sqlcmd ��� ������ (���������, ������)
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "������ ���������� SQL-�������: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    # ��������� ������ ������
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    # �������� ������
    Write-Error "[$NodeName] Check-SQL_QUERY_EXECUTE: ����������� ������: $errorMessage"
}

# ����� New-CheckResultObject ��� ��������� ��������������
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-SQL_QUERY_EXECUTE: ����������. IsAvailable=$($finalResult.IsAvailable), CheckSuccess=$($finalResult.CheckSuccess)"
return $finalResult