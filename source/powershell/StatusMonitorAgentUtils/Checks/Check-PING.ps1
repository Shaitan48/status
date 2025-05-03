<#
.SYNOPSIS
    ������ �������� ����������� ���� � ������� Test-Connection (PING).
.DESCRIPTION
    ���������� Test-Connection ��� �������� ICMP-�������� � �������� ����.
    ���������� ������������������� ������ ����������.
.PARAMETER TargetIP
    [string] ������������. IP-����� ��� ��� ����� ��� �����.
.PARAMETER Parameters
    [hashtable] ������������. ��������� ��� Test-Connection:
    - timeout_ms (int): ������� �������� ������ � ������������� (�� �����. 1000).
    - count (int): ���������� ������������ �������� (�� �����. 1).
    - buffer_size (int): ������ ������ ICMP (�� �����. 32).
.PARAMETER SuccessCriteria
    [hashtable] ������������. �������� ������:
    - max_rtt_ms (int): ����������� ���������� ����� ������ (RTT) � ��.
.PARAMETER NodeName
    [string] ������������. ��� ���� ��� �����������.
.OUTPUTS
    Hashtable - ������������������� ������ ����������
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP,
    [Parameter(Mandatory=$false)]
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory=$false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory=$false)]
    [string]$NodeName = "Unknown Node"
)

# ����������� New-CheckResultObject, ���� �� ��� �� �������� (�� ������ ������� ������� �������)
if (-not (Get-Command New-CheckResultObject -ErrorAction SilentlyContinue)) {
    try {
        # �������� ����� psm1 � ������������ �����
        $UtilsModulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils.psm1"
        if (Test-Path $UtilsModulePath) {
            Write-Verbose "Check-PING: �������� New-CheckResultObject �� $UtilsModulePath"
            . $UtilsModulePath # ���������� dot-sourcing ��� �������� �������
        } else { throw "�� ������� ����� StatusMonitorAgentUtils.psm1" }
    } catch {
        Write-Error "Check-PING: �� ������� ��������� ������� New-CheckResultObject! $($_.Exception.Message)"
        # ������� ��������, ����� ������ �� ���� ���������
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}


$TimeoutMs = $Parameters.timeout_ms | Get-OrElse 1000
$PingCount = $Parameters.count | Get-OrElse 1
$BufferSize = $Parameters.buffer_size | Get-OrElse 32
$TtlValue = 128
if ($TimeoutMs -lt 500) { $TtlValue = 64 }
if ($TimeoutMs -gt 2000) { $TtlValue = 255 }

Write-Verbose "[$NodeName] Check-PING: ������ �������� ��� $TargetIP (Count: $PingCount, Timeout: $TimeoutMs, Buffer: $BufferSize, TTL: $TtlValue)"

$isAvailable = $false
$checkSuccess = $null
$details = $null
$errorMessage = $null

try {
    # � PowerShell Core (v6+) Test-Connection �� ����� BufferSize � TTL.
    # � PowerShell 5.1 ��� ����. ������ �������� ������.
    $invokeParams = @{
        ComputerName = $TargetIP
        Count        = $PingCount
        ErrorAction  = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $invokeParams.TimeToLive = $TtlValue
        $invokeParams.BufferSize = $BufferSize
        # ������� � Test-Connection �� ����� �������, ����� �� ������������ ��� ������ ���� �������
        # if($TimeoutMs) { $invokeParams.TimeoutSeconds = [math]::Ceiling($TimeoutMs / 1000) }
    } else {
         # � PowerShell Core ����� ������������ -PingTimeout ��� ������ ��������
         if($TimeoutMs) { $invokeParams.PingTimeout = [math]::Ceiling($TimeoutMs / 1000) }
    }

    $pingResult = Test-Connection @invokeParams

    $isAvailable = $true
    $firstResponse = $pingResult | Select-Object -First 1
    # ��������� ������ ������ PS ��� ��������� RTT � IP
    $rtt = $null
    $actualIp = $null
    if ($firstResponse.PSObject.Properties.Name -contains 'ResponseTime') {
        $rtt = $firstResponse.ResponseTime # PS 5.1
    } elseif ($firstResponse.PSObject.Properties.Name -contains 'Latency') {
        $rtt = $firstResponse.Latency # PS Core
    }
    if ($firstResponse.PSObject.Properties.Name -contains 'IPV4Address') {
        $actualIp = $firstResponse.IPV4Address.IPAddressToString # PS 5.1
    } elseif ($firstResponse.PSObject.Properties.Name -contains 'Address') {
         $actualIp = $firstResponse.Address # PS Core
    }

    Write-Verbose "[$NodeName] Check-PING: ���� �������. RTT: $($rtt)ms, ���������� IP: $actualIp"

    $details = @{
        response_time_ms = $rtt
        ip_address = $actualIp
        target_ip = $TargetIP
        ping_count = $PingCount
    }

    # ��������� �������� ������
    $maxRtt = $null
    if ($SuccessCriteria -ne $null -and $SuccessCriteria.ContainsKey('max_rtt_ms')) {
        if ([int]::TryParse($SuccessCriteria.max_rtt_ms, [ref]$maxRtt)) {
            Write-Verbose "[$NodeName] Check-PING: ����������� �������� max_rtt_ms = $maxRtt"
            if ($rtt -ne $null -and $rtt -gt $maxRtt) { # �������� �������� $rtt -ne $null
                $checkSuccess = $false
                $errorMessage = "����� ������ (RTT) {0}ms ��������� ����������� ���������� ({1}ms)." -f $rtt, $maxRtt
                $details.success_criteria_failed = $errorMessage
                Write-Verbose "[$NodeName] Check-PING: $errorMessage"
            } else {
                $checkSuccess = $true
                Write-Verbose "[$NodeName] Check-PING: RTT $($rtt)ms ������������� �������� (<= $maxRtt ms)."
            }
        } else {
            $checkSuccess = $false
            $errorMessage = "������������ �������� 'max_rtt_ms' � SuccessCriteria: '$($SuccessCriteria.max_rtt_ms)'."
            $details.success_criteria_error = $errorMessage
            Write-Warning "[$NodeName] Check-PING: $errorMessage"
        }
    } else {
        $checkSuccess = $true
        Write-Verbose "[$NodeName] Check-PING: �������� ������ �� ������, CheckSuccess=True."
    }

} catch {
    # --- ��������: ���������� �������� -f ---
    $isAvailable = $false
    $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "������ PING ��� {0}: {1}" -f $TargetIP, $exceptionMessage
    $details = @{ error = $errorMessage; target_ip = $TargetIP; ErrorRecord = $_.ToString() }
    Write-Warning "[$NodeName] Check-PING: $errorMessage"
}

# ��������� � ���������� ������������������� ���������
$finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                     -CheckSuccess $checkSuccess `
                                     -Details $details `
                                     -ErrorMessage $errorMessage

Write-Verbose "[$NodeName] Check-PING: ������������ ���������: $($finalResult | ConvertTo-Json -Depth 3 -Compress)"
return $finalResult
