<#
.SYNOPSIS
    ��������� ������ ��������� ��������� ������.
.DESCRIPTION
    ���������� � ������ �������� ��� �� ��������� ����, ��������� Get-Service ��� ���������
    �������� �������. ���������� ������ � ��������� � SuccessCriteria.
    ���������� ������������������� ������ ���������� ��������.
.PARAMETER TargetIP
    [string] IP ��� ��� ����� ��� �������� (������������ ��������).
    ������������ ����������� ��� �������������� ���������� ������.
.PARAMETER Parameters
    [hashtable] ������������. ������ ��������� ���� 'service_name'.
    ������: @{ service_name = "Spooler" }
.PARAMETER SuccessCriteria
    [hashtable] ��������������. ����� ��������� ���� 'status'.
    ������: @{ status = "Running" } (��������� ������, �� ��������� 'Running').
            @{ status = "Stopped" } (��������� ������ 'Stopped').
.PARAMETER NodeName
    [string] ��������������. ��� ���� ��� �����������.
.OUTPUTS
    Hashtable - ������������������� ������ ���������� ��������
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP, # ������� ������������ ������ ����������� ��� Invoke-Command

    [Parameter(Mandatory=$true)]
    [hashtable]$Parameters,

    [Parameter(Mandatory=$false)]
    [hashtable]$SuccessCriteria = $null,

    [Parameter(Mandatory=$false)]
    [string]$NodeName = "Unknown Node" # ��� �����
)

# ����������, ��� ������� New-CheckResultObject ��������
# (������ ��� � .psm1, �� ��� ����������� ������������ ����� ������������ ��������)
if (-not (Get-Command New-CheckResultObject -ErrorAction SilentlyContinue)) {
    try {
        $commonFunctionsPath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils.psm1" # ���� � ��������� ������
        if(Test-Path $commonFunctionsPath) {
            Write-Verbose "Check-SERVICE_STATUS: �������� ������� �� $commonFunctionsPath"
             # ���������� dot-sourcing ��� �������� ������� � ������� ������� ���������
            . $commonFunctionsPath
        } else { throw "�� ������ ���� ������ ������: $commonFunctionsPath" }
    } catch {
        Write-Error "Check-SERVICE_STATUS: ����������� ������: �� ������� ��������� New-CheckResultObject! $($_.Exception.Message)"
        # ������� ��������, ����� ������ �� ���� ���������
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}

# --- ������������� ���������� ---
$resultData = @{ # ����������� ��������� ��� ��������
    IsAvailable = $false
    CheckSuccess = $null
    Details = $null
    ErrorMessage = $null
}

Write-Verbose "[$NodeName] Check-SERVICE_STATUS: ������ �������� ��� $TargetIP"

try {
    # 1. ��������� ������������ ����������
    $serviceName = $Parameters.service_name
    if (-not $serviceName -or $serviceName -isnot [string] -or $serviceName.Trim() -eq '') {
        throw "�������� 'service_name' ����������� ��� ���� � Parameters."
    }
    $serviceName = $serviceName.Trim()
    Write-Verbose "[$NodeName] Check-SERVICE_STATUS: ����������� ������ '$serviceName'"

    # 2. ����������� ���� (�������� ��� ��������) - ��� Get-Service
    # � ������ StatusMonitor ����� ��������� �������� ���, ������� ComputerName ������ �� �����.
    # Get-Service ������ ����������� �������� � ��������� ������.
    # TargetIP ������������ ��� ����������� � ����������� ��� ������ ���������.
    $ComputerNameParam = $null
    # if ($TargetIP -ne $env:COMPUTERNAME -and $TargetIP -ne 'localhost' -and $TargetIP -ne '127.0.0.1') {
    #     $ComputerNameParam = $TargetIP
    #     Write-Verbose "[$NodeName] Check-SERVICE_STATUS: ���� ���������: $ComputerNameParam"
    # } else {
         Write-Verbose "[$NodeName] Check-SERVICE_STATUS: ���� ���������."
    # }

    # 3. ���������� Get-Service
    $service = $null
    $getServiceParams = @{ Name = $serviceName; ErrorAction = 'Stop' } # Stop, ����� ������� ������, ���� ������ ���
    # if ($ComputerNameParam) { $getServiceParams.ComputerName = $ComputerNameParam } # �� ��������� ComputerName

    try { # ���������� try/catch ��� Get-Service
        $service = Get-Service @getServiceParams
        # --- ������� �������� ������ ---
        $resultData.IsAvailable = $true # ������ ��������� ��������
        $currentStatus = $service.Status.ToString()
        Write-Verbose "[$NodeName] Check-SERVICE_STATUS: ������ '$serviceName' �������. ������: $currentStatus"

        # ��������� Details
        $resultData.Details = @{
            service_name = $serviceName
            status = $currentStatus
            display_name = $service.DisplayName
            start_type = $service.StartType.ToString()
            can_stop = $service.CanStop
            # ����� �������� ������ �������� ������ ��� �������������
        }

        # 4. �������� SuccessCriteria (CheckSuccess)
        $requiredStatus = 'Running' # �������� �� ���������
        $criteriaSource = 'Default'
        $checkSuccessResult = $true # �� ��������� �������, ���� �������� � ��� ��������� ��� �������� ������
        $failReason = $null

        if ($SuccessCriteria -ne $null -and $SuccessCriteria.ContainsKey('status') -and -not [string]::IsNullOrWhiteSpace($SuccessCriteria.status)) {
            # --- >>> ������ ��������� �������� <<< ---
            $requiredStatus = $SuccessCriteria.status.ToString().Trim() # �������� � ������ � ������� �������
            $criteriaSource = 'Explicit'
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: ����������� ����� ��������: status = '$requiredStatus'"

            # ���������� ������� ������ � ��������� (��� ����� ��������)
            if ($currentStatus -ne $requiredStatus) {
                $checkSuccessResult = $false # �������� �� �������
                $failReason = "������� ������ ������ '$currentStatus' �� ������������� ���������� '$requiredStatus'."
                Write-Verbose "[$NodeName] Check-SERVICE_STATUS: $failReason"
            } else {
                $checkSuccessResult = $true # �������� �������
                Write-Verbose "[$NodeName] Check-SERVICE_STATUS: ������ '$currentStatus' ������������� �������� '$requiredStatus'."
            }
             # --- >>> ����� ��������� �������� <<< ---
        } else {
            # �������� �� ������ ����, ���������� ����������� ������ (Running = OK)
            Write-Verbose "[$NodeName] Check-SERVICE_STATUS: ����� �������� 'status' �� �����. ������� ��������, ���� ������ '$requiredStatus' (�� ���������)."
            if ($currentStatus -ne $requiredStatus) {
                 # ������ �� ������������� ���������� Running, �� �.�. �������� �� ����� ����,
                 # ������� ��� ������� ����� *��������*, �� �� ��������.
                 # CheckSuccess ������ �������� ������������ ���������.
                 # ���� ��������� ���, CheckSuccess ������ ���� TRUE ��� IsAvailable = TRUE.
                 # ���� �������� ����, �� �� ������� -> CheckSuccess = FALSE.
                 # $checkSuccessResult = $false # �����������, �.�. �������� �� ����
                 $checkSuccessResult = $true # ���������, �.�. �������� �� ����
                 # $failReason = "������ ������ '$currentStatus', �������� '$requiredStatus' (�� ���������)." # ��� ��������� �� ����� � ErrorMessage, �.�. CheckSuccess=true
                 # Write-Verbose "[$NodeName] Check-SERVICE_STATUS: $failReason" # ���� Verbose ���� ������
            } else {
                $checkSuccessResult = $true
            }
        }
        # ������������� $resultData.CheckSuccess � $resultData.ErrorMessage
        $resultData.CheckSuccess = $checkSuccessResult
        # ErrorMessage ��������� ������ ���� CheckSuccess = false ��� IsAvailable = false
        if ($checkSuccessResult -eq $false) {
             $resultData.ErrorMessage = $failReason
        }

    } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
        # --- ������: ������ �� ������� ---
        $resultData.IsAvailable = $false # �� ������ ��������� ��������, �.�. ������ ���
        $resultData.CheckSuccess = $null
        $resultData.ErrorMessage = "������ '$serviceName' �� ������� �� '$($env:COMPUTERNAME)'."
        $resultData.Details = @{ error = $resultData.ErrorMessage; service_name = $serviceName }
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: $($resultData.ErrorMessage)"
    } catch {
        # --- ������: ������ ������ Get-Service (RPC ���������� � �.�., ���� �� ������ ��������) ---
        $resultData.IsAvailable = $false # �� ������ ��������� ��������
        $resultData.CheckSuccess = $null
        $errorMessage = "������ ��������� ������� ������ '$serviceName' �� '$($env:COMPUTERNAME)': $($_.Exception.Message)"
        # �������� ������� ������� ���������
        if ($errorMessage.Length -gt 500) { $errorMessage = $errorMessage.Substring(0, 500) + "..." }
        $resultData.ErrorMessage = $errorMessage
        $resultData.Details = @{ error = $errorMessage; service_name = $serviceName; ErrorRecord = $_.ToString() }
        Write-Warning "[$NodeName] Check-SERVICE_STATUS: ������ Get-Service: $($_.Exception.Message)"
    }

} catch {
    # --- ������: ����� ������ ������� Check-SERVICE_STATUS (��������, ��������� ����������) ---
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $errorMessage = "���������� ������ ������� Check-SERVICE_STATUS: $($_.Exception.Message)"
    if ($errorMessage.Length -gt 500) { $errorMessage = $errorMessage.Substring(0, 500) + "..." }
    $resultData.ErrorMessage = $errorMessage
    $resultData.Details = @{ error = $errorMessage; ErrorRecord = $_.ToString() }
    Write-Error "[$NodeName] Check-SERVICE_STATUS: ����������� ������ �������: $($_.Exception.Message)"
}

# �������� New-CheckResultObject ��� �������������� � ���������� Timestamp
# �������� ������������ ��������
$finalResult = New-CheckResultObject -IsAvailable $resultData.IsAvailable `
                                     -CheckSuccess $resultData.CheckSuccess `
                                     -Details $resultData.Details `
                                     -ErrorMessage $resultData.ErrorMessage

Write-Verbose "[$NodeName] Check-SERVICE_STATUS: ���������� ��������. IsAvailable=$($finalResult.IsAvailable), CheckSuccess=$($finalResult.CheckSuccess)"
return $finalResult