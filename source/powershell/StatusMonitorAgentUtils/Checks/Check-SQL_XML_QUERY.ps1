<#
.SYNOPSIS
    ��������� SQL-������, ��������� XML �� ���������� �������
    � ������ �������� �� ������.
.DESCRIPTION
    ������������ � MS SQL Server, ��������� SQL-������, ������� XML
    � ��������� ������� ������ ������ ����������, ������ XML � ���������
    ��������� �������� ��������� �� ��������� ������ ������.
.PARAMETER TargetIP
    [string] ��� ��� IP-����� SQL Server instance (��������, "SERVER\SQLEXPRESS").
.PARAMETER Parameters
    [hashtable] ������������. �������� ���������:
    - sql_database (string):   ��� ���� ������. �����������.
    - sql_query (string):      SQL-������. ������ ���������� ������� � XML. �����������.
    - xml_column_name (string): ��� ������� � XML. �����������.
    - keys_to_extract (string[]): ������ ���� XML-��������� (������) ��� ����������. �����������.
    - sql_username (string):   ��� ������������ SQL Server (�����������).
    - sql_password (string):   ������ ������������ SQL Server (�����������, �����������).
    - query_timeout_sec (int): ������� ������� � �������� (�����������, �� �����. 30).
.PARAMETER SuccessCriteria
    [hashtable] ��������������. �������� ������ (���� �� �����������).
.PARAMETER NodeName
    [string] ��������������. ��� ���� ��� �����������.
.OUTPUTS
    Hashtable - ������������������� ������ ���������� ��������
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
                Details �������� ���-������� 'extracted_data'.
.NOTES
    ������: 1.1 (�������� �������� SuccessCriteria, �� ��� ���������� ������).
    ������� �� ������� New-CheckResultObject � ������ SqlServer.
    ������� ���� ������� � SQL Server.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP, # ������������ ��� ServerInstance

    [Parameter(Mandatory=$true)]
    [hashtable]$Parameters,

    [Parameter(Mandatory=$false)] # <<<< �������� ��������
    [hashtable]$SuccessCriteria = $null,

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
        Write-Error "Check-SQL_XML_QUERY: ����������� ������: �� ������� ��������� New-CheckResultObject! $($_.Exception.Message)"
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}

# --- ������������� ���������� ---
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{
        extracted_data = @{} # ��� ����������� ������
        query_executed = $null
        xml_source_column = $null
        rows_returned = 0
    }
    ErrorMessage = $null
}

Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: ������ ���������� SQL XML ������� �� $TargetIP"

try {
    # 1. ��������� � ���������� ����������
    $SqlServerInstance = $TargetIP
    $DatabaseName = $Parameters.sql_database
    $SqlQuery = $Parameters.sql_query
    $XmlColumnName = $Parameters.xml_column_name
    $KeysToExtract = $Parameters.keys_to_extract
    $SqlUsername = $Parameters.sql_username
    $SqlPassword = $Parameters.sql_password
    $QueryTimeoutSec = $Parameters.query_timeout_sec | Get-OrElse 30

    # ������ � Details ��� ������������/�������
    $resultData.Details.query_executed = $SqlQuery
    $resultData.Details.xml_source_column = $XmlColumnName

    # �������� ������������ ����������
    if (-not $DatabaseName) { throw "����������� ������������ �������� 'sql_database'." }
    if (-not $SqlQuery) { throw "����������� ������������ �������� 'sql_query'." }
    if (-not $XmlColumnName) { throw "����������� ������������ �������� 'xml_column_name'." }
    if (-not ($KeysToExtract -is [array]) -or $KeysToExtract.Count -eq 0) {
        throw "�������� 'keys_to_extract' ������ ���� �������� �������� �����."
    }
    if ($SqlUsername -and (-not $SqlPassword)) { throw "�������� 'sql_password' ���������� ��� �������� 'sql_username'." }
    if (-not ([int]::TryParse($QueryTimeoutSec, [ref]$null)) -or $QueryTimeoutSec -le 0) {
         Write-Warning "[$NodeName] ������������ �������� query_timeout_sec ('$($Parameters.query_timeout_sec)'). ������������ 30 ���."; $QueryTimeoutSec = 30
    }

    # 2. ������������ ���������� ��� Invoke-Sqlcmd
    $invokeSqlParams = @{ ServerInstance = $SqlServerInstance; Database = $DatabaseName; Query = $SqlQuery; QueryTimeout = $QueryTimeoutSec; ErrorAction = 'Stop' }
    if ($SqlUsername) {
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: ������������ SQL �������������� ��� '$SqlUsername'."
        $securePassword = ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force
        $invokeSqlParams.Credential = New-Object System.Management.Automation.PSCredential($SqlUsername, $securePassword)
    } else { Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: ������������ Windows ��������������." }

    # 3. �������� ������ SqlServer
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -ListAvailable -Name SqlServer)) { throw "������ 'SqlServer' �� ������. ���������� ���." }
        try { Import-Module SqlServer -ErrorAction Stop } catch { throw "�� ������� ��������� ������ 'SqlServer'. ������: $($_.Exception.Message)" }
    }

    # 4. ���������� SQL-�������
    Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: ���������� ������� � '$SqlServerInstance/$DatabaseName'..."
    $queryResult = Invoke-Sqlcmd @invokeSqlParams
    $resultData.IsAvailable = $true # ���� ��� ������, ������ ������

    # 5. ��������� ����������
    $xmlString = $null
    if ($queryResult -ne $null) {
        if ($queryResult -isnot [array]) { $queryResult = @($queryResult) }
        $resultData.Details.rows_returned = $queryResult.Count

        if ($queryResult.Count -gt 0) {
            $firstRow = $queryResult[0]
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: ������ ������ �����: $($queryResult.Count). ��������� ������ ������."
            if ($firstRow.PSObject.Properties.Name -contains $XmlColumnName) {
                $xmlValue = $firstRow.$XmlColumnName
                if ($xmlValue -ne $null -and $xmlValue -ne [System.DBNull]::Value) {
                    $xmlString = $xmlValue.ToString()
                    Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: ������� XML �� ������� '$XmlColumnName'."
                } else { $resultData.ErrorMessage = "������� '$XmlColumnName' � ������ ������ ���� (NULL)."; $resultData.CheckSuccess = $false }
            } else { $resultData.ErrorMessage = "������� '$XmlColumnName' �� ������ � ���������� �������."; $resultData.CheckSuccess = $false }
        } else { $resultData.Details.message = "������ �� ������ �����."; $resultData.CheckSuccess = $true }
    } else { $resultData.Details.message = "������ �� ������ ������ (��������, non-query?)."; $resultData.CheckSuccess = $true }

    # 6. ������� XML � ���������� ������
    if ($xmlString -and $resultData.CheckSuccess -ne $false) { # ������ ������ ���� ���� XML � �� ���� ������ �����
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: ������� XML..."
        try {
            [xml]$xmlDoc = $xmlString
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: XML ������� ���������."
            if ($null -eq $xmlDoc.DocumentElement) { throw "�������� ������� � XML �� ������." }

            $extractedData = @{}
            foreach ($key in $KeysToExtract) {
                $value = $null
                # ���� ������� � ����� ������ ����� �������� ���������
                $xmlElement = $xmlDoc.DocumentElement.SelectSingleNode("./*[local-name()='$key']") # ������������ � namespace
                if ($xmlElement -ne $null) {
                    $value = $xmlElement.InnerText # �������� ��������� ����������
                }
                $extractedData[$key] = $value # ��������� �������� (��� null)
                Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: ���� '$key', ��������: '$value'"
            }
            $resultData.Details.extracted_data = $extractedData
            $resultData.CheckSuccess = $true # ���� ����� ����, ������� �������

        } catch {
            # ������ �������� XML
            $errorMessage = "������ �������� XML �� ������� '$XmlColumnName': $($_.Exception.Message)"
            if ($errorMessage.Length -gt 500) { $errorMessage = $errorMessage.Substring(0, 500) + "..." }
            $resultData.ErrorMessage = $errorMessage
            $resultData.Details.error = $errorMessage
            $resultData.Details.xml_content_sample = $xmlString.Substring(0, [math]::Min($xmlString.Length, 200)) + "..."
            $resultData.CheckSuccess = $false # ������� �� ������
        }
    }

    # 7. ��������� SuccessCriteria (���� �� �����������)
    if ($resultData.IsAvailable -and $resultData.CheckSuccess -and $SuccessCriteria -ne $null) {
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: SuccessCriteria ��������, �� �� ��������� ���� �� �����������."
        # ����� ����� ���������� �������� �� $resultData.Details.extracted_data � $SuccessCriteria
        # if ($resultData.Details.extracted_data.VersionStat -ne $SuccessCriteria.expected_version) {
        #     $resultData.CheckSuccess = $false
        #     $resultData.ErrorMessage = "�������� VersionStat �� ��������� � ���������."
        # }
    }


} catch {
    # ��������� ������ Invoke-Sqlcmd ��� ������
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "������ ���������� SQL XML �������: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    Write-Error "[$NodeName] Check-SQL_XML_QUERY: ����������� ������: $errorMessage"
}

# ��������� ��������� CheckSuccess, ���� ������ ������� ��� null
if ($resultData.IsAvailable -eq $false) { $resultData.CheckSuccess = $null }
elseif ($resultData.CheckSuccess -eq $null) { $resultData.CheckSuccess = $true } # ���� IsAvailable=true � �� ���� ������ -> �����

# ����� New-CheckResultObject
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: ����������. IsAvailable=$($finalResult.IsAvailable), CheckSuccess=$($finalResult.CheckSuccess)"
return $finalResult