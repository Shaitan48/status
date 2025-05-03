# powershell/StatusMonitorAgentUtils/StatusMonitorAgentUtils.psm1
# ������ �������� ��������� �������� � ����� ��������������� �������
# ��� ������� ����������� Status Monitor.
# ������ � ������������� �������� �������� � Invoke-RemoteCheck (����� -f).

#region ��������������� �������

#region ������� New-CheckResultObject
<#
.SYNOPSIS
    ������� ������������������� ������ ���������� ��������.
# ... (��������� ������������ New-CheckResultObject ��� ���������) ...
#>
function New-CheckResultObject {
    param(
        [Parameter(Mandatory=$true)]
        [bool]$IsAvailable,
        [Parameter(Mandatory=$false)]
        [nullable[bool]]$CheckSuccess = $null,
        [Parameter(Mandatory=$false)]
        [hashtable]$Details = $null,
        [Parameter(Mandatory=$false)]
        [string]$ErrorMessage = $null
    )
    # ... (��� ������� New-CheckResultObject ��� ���������) ...
    # ������� ������� ���������
    $result = @{
        IsAvailable    = $IsAvailable
        CheckSuccess   = $null # �������������� null
        # --- ���������: ����� ��������� ������ ISO 8601 (UTC) ---
        Timestamp      = (Get-Date).ToUniversalTime().ToString("o")
        Details        = $Details
        ErrorMessage   = $ErrorMessage
    }
    if ($IsAvailable) { $result.CheckSuccess = $CheckSuccess }
    if (-not $IsAvailable -and -not $result.ErrorMessage) { $result.ErrorMessage = "..."}
    if ($IsAvailable -and ($result.CheckSuccess -ne $null) -and (-not $result.CheckSuccess) -and (-not $result.ErrorMessage) ) { $result.ErrorMessage = "..."}

    return $result
}
#endregion

#region ������� Invoke-RemoteCheck
<#
.SYNOPSIS
    ��������� ������ �������� �� ��������� ����.
# ... (��������� ������������ Invoke-RemoteCheck ��� ���������) ...
#>
function Invoke-RemoteCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$TargetIP,

        [Parameter(Mandatory=$true)]
        [string]$CheckScriptPath,

        [Parameter(Mandatory=$true)]
        [hashtable]$checkParams,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential = $null
    )

    Write-Verbose "����� Invoke-RemoteCheck ��� $TargetIP, ������: $CheckScriptPath"

    try {
        # --- ������ ���������� ���������� ������ ---
        if (-not (Test-Path $CheckScriptPath -PathType Leaf)) {
            throw "��������� ������ �������� '$CheckScriptPath' �� ������ ��� ���������� ����������."
        }
        $ScriptContent = Get-Content -Path $CheckScriptPath -Raw -Encoding UTF8
        $RemoteScriptBlock = [ScriptBlock]::Create($ScriptContent)
        $invokeParams = @{ ComputerName = $TargetIP; ScriptBlock  = $RemoteScriptBlock; ErrorAction  = 'Stop'; ArgumentList = @($checkParams) }
        if ($Credential) { $invokeParams.Credential = $Credential }

        Write-Verbose "������� Invoke-Command �� $TargetIP..."
        $remoteResultRaw = Invoke-Command @invokeParams
        $remoteResult = $null
        if ($remoteResultRaw) { $remoteResult = $remoteResultRaw | Select-Object -Last 1 }

        if ($remoteResult -is [hashtable] -and $remoteResult.ContainsKey('IsAvailable')) {
            Write-Verbose "Invoke-Command �� $TargetIP ������� ������ ������������������� ���������."
            if (-not $remoteResult.ContainsKey('Details') -or $remoteResult.Details -eq $null) { $remoteResult.Details = @{} }
            elseif ($remoteResult.Details -isnot [hashtable]) { $remoteResult.Details = @{ OriginalDetails = $remoteResult.Details } }
            $remoteResult.Details.execution_target = $TargetIP
            $remoteResult.Details.execution_mode = 'remote'
            return $remoteResult
        } else {
             Write-Warning ("��������� ������ �� {0} �� ������ ��������� ���-�������. ���������: {1}" -f $TargetIP, ($remoteResultRaw | Out-String -Width 200))
             return New-CheckResultObject -IsAvailable $false -ErrorMessage "��������� ������ �� $TargetIP ������ ������������ ���������." -Details @{ RemoteOutput = ($remoteResultRaw | Out-String -Width 200) }
        }
        # --- ����� ���������� ���������� ������ ---

    } catch {
        # ����� ������ Invoke-Command
        # --- ��������: ���������� �������� -f ---
        $exceptionMessage = $_.Exception.Message
        Write-Warning ("������ Invoke-Command ��� ���������� '{0}' �� {1}: {2}" -f $CheckScriptPath, $TargetIP, $exceptionMessage)
        $errorMessage = "������ ���������� ���������� �� {0}: {1}" -f $TargetIP, $exceptionMessage

        $errorDetails = @{ ErrorRecord = $_.ToString(); ErrorCategory = $_.CategoryInfo.Category.ToString(); ErrorReason = $_.CategoryInfo.Reason; ErrorTarget = $_.TargetObject }

        if ($_.CategoryInfo.Category -in ('ResourceUnavailable', 'AuthenticationError', 'SecurityError', 'OpenError', 'ConnectionError')) {
             # --- ��������: ���������� �������� -f ---
             $errorMessage = "������ �����������/������� � {0}: {1}" -f $TargetIP, $exceptionMessage
        }
        # --- ����� ��������� � CATCH ---

        return New-CheckResultObject -IsAvailable $false -ErrorMessage $errorMessage -Details $errorDetails
    }
}
#endregion

#endregion

# --- �������� �������-��������� ---

<#
.SYNOPSIS
    ��������� �������� ����������� �������� �������.
.DESCRIPTION
    �������-���������. ���������� ����� �������� �� �������,
    ������� ��������������� ������ � ����� 'Checks', ��������������
    ��������� � ��������� ������ �������� �� ������ ������.
    ���������� ������������������� ��������� ��������.
.PARAMETER Assignment
    [PSCustomObject] ������������. ������ �������.
.OUTPUTS
    Hashtable - ������������������� ������ ���������� ��������.
#>
function Invoke-StatusMonitorCheck {
    [CmdletBinding(SupportsShouldProcess=$false)]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Assignment
    )

    # �������� ������� ���������� �������
    if (-not $Assignment -or -not $Assignment.PSObject.Properties.Name.Contains('assignment_id') -or -not $Assignment.PSObject.Properties.Name.Contains('method_name')) {
        Write-Warning "Invoke-StatusMonitorCheck: ������� ������������ ������ �������."
        # ��������� ��������� ������ ������� (�.�. New-CheckResultObject ����� ���� ��� �� �������� ��� ���� ������ ��������)
        return @{ IsAvailable = $false; CheckSuccess = $null; Timestamp = (Get-Date).ToUniversalTime().ToString("o"); ErrorMessage = "������������ ������ ������� ������� � Invoke-StatusMonitorCheck."; Details = $null }
    }

    # ��������� �������� ������ �� �������
    $assignmentId = $Assignment.assignment_id
    $methodName = $Assignment.method_name
    $targetIP = $null
    if ($Assignment.PSObject.Properties.Name.Contains('ip_address')) {
        $targetIP = $Assignment.ip_address
    }
    $nodeName = $Assignment.node_name | Get-OrElse "���� ID $($Assignment.node_id | Get-OrElse $assignmentId)"
    $parameters = $Assignment.parameters | Get-OrElse @{}
    $successCriteria = $Assignment.success_criteria | Get-OrElse $null

    Write-Verbose "[$($assignmentId)] ������ ���������� Invoke-StatusMonitorCheck ��� ������ '$methodName' �� '$nodeName' (TargetIP: $($targetIP | Get-OrElse 'Local'))"

    # ���������� ���� � ������� ��������
    $result = $null # �������������� ���������� ��� ����������
    try {
        # �������� ���� � �������� ������, ����� ����� ����� Checks
        # $MyInvocation.MyCommand.ModuleName ����� ���� �������� $PSScriptRoot ������ ������
        $ModulePath = (Get-Module -Name $MyInvocation.MyCommand.ModuleName).Path
        $ModuleDir = Split-Path -Path $ModulePath -Parent
        $ChecksFolder = Join-Path -Path $ModuleDir -ChildPath "Checks"
        $CheckScriptFile = "Check-$($methodName).ps1"
        $CheckScriptPath = Join-Path -Path $ChecksFolder -ChildPath $CheckScriptFile

        # ��������� ������������� �������
        if (-not (Test-Path $CheckScriptPath -PathType Leaf)) {
            $errorMessage = "������ �������� '$CheckScriptFile' �� ������ � '$ChecksFolder'."
            Write-Warning "[$($assignmentId)] $errorMessage"
            # ���������� New-CheckResultObject, �����������, ��� �� ��� �������� �� ���� �����
            return New-CheckResultObject -IsAvailable $false -ErrorMessage $errorMessage -Details @{ CheckedScriptPath = $CheckScriptPath }
        }

        # �������������� ��������� ��� �������� � ������ ��������
        $checkParams = @{
            TargetIP        = $targetIP # �������� IP �� �������
            Parameters      = $parameters
            SuccessCriteria = $successCriteria
            NodeName        = $nodeName
        }

        # === ���������: ������ ��������� �������� ===
        Write-Verbose "[$($assignmentId)] ������ ���������� �������: $CheckScriptPath"
        # ���������� ���� try/catch ��� ������ ������ ������ ������� Check-*.ps1
        try {
             # ��������� ������ ����� �������� ������ '&', ��������� ��������� ����� splatting (@)
             $result = & $CheckScriptPath @checkParams
        } catch {
             # ������ ��������� ������ ������� Check-*.ps1
             throw # ������������� ������, ����� �� ������ ������� catch
        }
        # === ����� ��������� ===

        # ���������, ��� ������ ������ ��������� ���������
        if ($result -isnot [hashtable] -or -not $result.ContainsKey('IsAvailable')) {
            Write-Warning "[$($assignmentId)] ������ �������� '$CheckScriptFile' ������ ����������� ���������: $($result | Out-String -Width 200)"
            $result = New-CheckResultObject -IsAvailable $false `
                                            -ErrorMessage "������ �������� '$CheckScriptFile' ������ ������������ ���������." `
                                            -Details @{ ScriptOutput = ($result | Out-String -Width 200) }
        }
        # ��������� ���������� � ���������� (������ ��������� ��� ������)
        if ($result -is [hashtable]) {
            if (-not $result.ContainsKey('Details') -or $result.Details -eq $null) { $result.Details = @{} }
            elseif ($result.Details -isnot [hashtable]) { $result.Details = @{ OriginalDetails = $result.Details } }
            # ���������, ��� ����������� �� ������ ������ ($env:COMPUTERNAME)
            $result.Details.execution_target = $env:COMPUTERNAME
            $result.Details.execution_mode = 'local_agent' # ����� ������
            $result.Details.check_target_ip = $targetIP # ��������� �������� ���� ��������
        }

    } catch {
        # ����� ������:
        # - �� ������ ������ $MyInvocation.MyCommand.ModuleName
        # - ������, ������������� �� ����������� try/catch (������ ������� Check-*.ps1)
        # - ������ ������ ����������
        $errorMessage = "������ ���������� �������� '$methodName' ��� '$nodeName': $($_.Exception.Message)"
        Write-Warning "[$($assignmentId)] $errorMessage"
        # ���������� ������ ������������, ��� ��� ������ ����� ���� �� New-CheckResultObject
        $result = @{
            IsAvailable    = $false
            CheckSuccess   = $null
            Timestamp      = (Get-Date).ToUniversalTime().ToString("o")
            ErrorMessage   = $errorMessage
            Details        = @{ ErrorRecord = $_.ToString() }
        }
    }

    # ���������� ������������������� ���������
    Write-Verbose "[$($assignmentId)] ��������� �������� ������. IsAvailable: $($result.IsAvailable), CheckSuccess: $($result.CheckSuccess)"
    return $result
}
# --- ����� �������� ������� ---

# ��������������� ������� New-CheckResultObject, Invoke-RemoteCheck (����� ���� ��������, �� ��� �� ������������ �������), Get-OrElse
# ... (��� ���� ������� ��� ���������) ...


# --- ��������������� ������� Get-OrElse ---
filter Get-OrElse { param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }

# --- ������� ������� ---
Export-ModuleMember -Function Invoke-StatusMonitorCheck, New-CheckResultObject # ������ Invoke-RemoteCheck �� �������� �� ���������
