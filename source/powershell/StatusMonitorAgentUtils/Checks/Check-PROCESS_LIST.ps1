<#
.SYNOPSIS
    �������� ������ ���������� ���������.
.DESCRIPTION
    ���������� Get-Process ��� ��������� ���������� � ��������� ��������.
    ������������ ���������� �� �����, ����������, ����� N �������,
    � ����� ������������ ��������� ����� ������������ � ���� � �����.
.PARAMETER TargetIP
    [string] IP ��� ��� ����� (������������, ������������ ��� �����������).
.PARAMETER Parameters
    [hashtable] ��������������. ��������� ��� Get-Process � ��������������:
    - process_names ([string[]]): ������ ���� ��������� ��� ���������� (wildcards *?).
    - include_username ([bool]): �������� �� ��� ������������ ($false).
    - include_path ([bool]):     �������� �� ���� � ����� ($false).
    - sort_by ([string]):        ���� ��� ���������� ('Name', 'Id', 'CPU', 'Memory'/'WS', 'StartTime'). �� �����. 'Name'.
    - sort_descending ([bool]):  ����������� �� ��������? ($false).
    - top_n ([int]):             �������� ������ ��� N ���������.
.PARAMETER SuccessCriteria
    [hashtable] ��������������. �������� ������ (���� �� �����������).
.PARAMETER NodeName
    [string] ��������������. ��� ���� ��� �����������.
.OUTPUTS
    Hashtable - ������������������� ������ ���������� ��������
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
                Details �������� ������ 'processes'.
.NOTES
    ������: 1.2 (�������� �������� SuccessCriteria, �� ��� ���������� ������).
    ������� �� ������� New-CheckResultObject.
    ��������� Username/Path ����� ��������� ���������� ����.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP,

    [Parameter(Mandatory=$false)]
    [hashtable]$Parameters = @{},

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
        Write-Error "Check-PROCESS_LIST: ����������� ������: �� ������� ��������� New-CheckResultObject! $($_.Exception.Message)"
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}

# --- ������������� ���������� ---
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{ processes = [System.Collections.Generic.List[object]]::new() }
    ErrorMessage = $null
}

Write-Verbose "[$NodeName] Check-PROCESS_LIST: ������ ��������� ������ ��������� � $TargetIP (��������)"

try {
    # 1. ��������� ��� Get-Process
    $getProcessParams = @{}
    $filteringByName = $false
    if ($Parameters.ContainsKey('process_names') -and $Parameters.process_names -is [array] -and $Parameters.process_names.Count -gt 0) {
        $getProcessParams.Name = $Parameters.process_names
        $getProcessParams.ErrorAction = 'SilentlyContinue' # �� ������, ���� ������� �� ������
        $filteringByName = $true
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: ������ �� ������: $($Parameters.process_names -join ', ')"
    } else {
        $getProcessParams.ErrorAction = 'Stop' # ������ ��� ����� �������
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: ��������� ���� ���������."
    }

    $includeUsername = [bool]($Parameters.include_username | Get-OrElse $false)
    $includePath = [bool]($Parameters.include_path | Get-OrElse $false)
    if($includeUsername) { Write-Verbose "[$NodeName] Check-PROCESS_LIST: ������� Username." }
    if($includePath) { Write-Verbose "[$NodeName] Check-PROCESS_LIST: ������� Path." }

    # 2. ���������� Get-Process
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: ����� Get-Process..."
    $processesRaw = Get-Process @getProcessParams
    $resultData.IsAvailable = $true # ���� Get-Process �� ����, ������ �������� ��������
    $processCount = if($processesRaw) { @($processesRaw).Count } else { 0 } # ������� ����������
    Write-Verbose "[$NodeName] Check-PROCESS_LIST: Get-Process ��������. ������� ���������: $processCount"

    # ��������� ������, ����� �����������, �� ������ �� �����
    if ($filteringByName -and $processCount -eq 0) {
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: �������� � ������� '$($Parameters.process_names -join ', ')' �� �������."
        $resultData.CheckSuccess = $true # ������� �������, �.�. ������ ����������, ������ ��������� ����
        $resultData.Details.message = "�������� � ���������� ������� �� �������."
    }
    # ���������, ���� �������� �������
    elseif ($processCount -gt 0) {
        # 3. ������������ ������ �����������
        $processedList = foreach ($proc in $processesRaw) {
            $procInfo = @{
                id = $proc.Id
                name = $proc.ProcessName
                cpu_seconds = $null
                memory_ws_mb = $null
                username = $null
                path = $null
                start_time = $null
            }
            try { $procInfo.cpu_seconds = [math]::Round($proc.CPU, 2) } catch {}
            try { $procInfo.memory_ws_mb = [math]::Round($proc.WS / 1MB, 1) } catch {}
            try { $procInfo.start_time = $proc.StartTime.ToUniversalTime().ToString("o") } catch {}

            if ($includeUsername) {
                try {
                    $ownerInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($proc.Id)" | Select-Object -ExpandProperty Owner -ErrorAction SilentlyContinue
                    $procInfo.username = if ($ownerInfo -and $ownerInfo.User) { if ($ownerInfo.Domain) { "$($ownerInfo.Domain)\$($ownerInfo.User)" } else { $ownerInfo.User } } else { '[N/A]' }
                } catch { $procInfo.username = '[Access Error]' }
            }
            if ($includePath) {
                try {
                    $procPath = $proc.Path
                    if (-not $procPath -and $proc.MainModule) { $procPath = $proc.MainModule.FileName }
                    $procInfo.path = $procPath
                } catch { $procInfo.path = '[Access Error]' }
            }
            [PSCustomObject]$procInfo
        } # ����� foreach

        # 4. ����������
        $sortByInput = $Parameters.sort_by | Get-OrElse 'Name'
        $sortDesc = [bool]($Parameters.sort_descending | Get-OrElse $false)
        $validSortFields = @('id', 'name', 'cpu_seconds', 'memory_ws_mb', 'start_time')
        $sortByActual = switch ($sortByInput.ToLower()) {
            {$_ -in @('memory', 'mem', 'ws')} { 'memory_ws_mb' }
            {$_ -in @('processor', 'proc', 'cpu')} { 'cpu_seconds' }
            default { if($sortByInput -in $validSortFields) {$sortByInput} else {'name'} }
        }
        if($sortByActual -notin $validSortFields) {$sortByActual = 'name'}
        $sortDirectionText = if ($sortDesc) { 'Desc' } else { 'Asc' }
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: ���������� �� '$sortByActual' ($sortDirectionText)"
        try { $processedList = $processedList | Sort-Object -Property $sortByActual -Descending:$sortDesc }
        catch { Write-Warning "[$NodeName] Check-PROCESS_LIST: ������ ���������� �� '$sortByActual'. ������������ ���������� �� Name." ; try { $processedList = $processedList | Sort-Object -Property 'name' } catch {} }

        # 5. Top N
        $topN = $null; if ($Parameters.ContainsKey('top_n') -and $Parameters.top_n -is [int]) { $topN = $Parameters.top_n }
        if ($topN -gt 0) {
            Write-Verbose "[$NodeName] Check-PROCESS_LIST: ����� ��� $topN ���������."
            $processedList = $processedList | Select-Object -First $topN
        }

        # 6. ������ ���������� � Details
        $resultData.Details.processes.AddRange($processedList)
        Write-Verbose "[$NodeName] Check-PROCESS_LIST: ��������� � ���������: $($resultData.Details.processes.Count) ���������."

        # 7. ��������� CheckSuccess (���� ��� ���������)
        $resultData.CheckSuccess = $true # �������, ���� ������ �������� ������
    }
    # ��������� ������, ����� �������� �� ������� � �� ����������� �� �����
    elseif (-not $filteringByName -and $processCount -eq 0) {
         Write-Verbose "[$NodeName] Check-PROCESS_LIST: Get-Process �� ������ ��������� (��� ������� �� �����)."
         $resultData.CheckSuccess = $true # ������� �������, �.�. ������� �����������
         $resultData.Details.message = "������ ��������� ����."
    }


} catch {
    # �������� ������ Get-Process (���� ErrorAction=Stop) ��� ������
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "������ ��������� ������ ���������: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    Write-Error "[$NodeName] Check-PROCESS_LIST: ����������� ������: $errorMessage"
}

# --- ��������� ��������� ���������� ---
# ���� ���� ������ IsAvailable = false, �� CheckSuccess ������ ���� null
if ($resultData.IsAvailable -eq $false) {
    $resultData.CheckSuccess = $null
}
# ���� IsAvailable = true, �� CheckSuccess ��� �� ���������� (�� ���� ������� ���������), ������ true
elseif ($resultData.CheckSuccess -eq $null) {
     $resultData.CheckSuccess = $true
}

# ��������� SuccessCriteria (���� ��� ����������)
if ($resultData.IsAvailable -and $resultData.CheckSuccess -and $SuccessCriteria -ne $null) {
     Write-Verbose "[$NodeName] Check-PROCESS_LIST: SuccessCriteria ��������, �� �� ��������� ���� �� �����������."
     # ����� ����� ����� �������� ������, ��������:
     # if ($SuccessCriteria.ContainsKey('required_process') -and -not $resultData.Details.processes.name.Contains($SuccessCriteria.required_process)) {
     #     $resultData.CheckSuccess = $false
     #     $resultData.ErrorMessage = "������������ ������� '$($SuccessCriteria.required_process)' �� ������."
     # }
}

# ����� New-CheckResultObject ��� ��������� ��������������
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-PROCESS_LIST: ����������. IsAvailable=$($finalResult.IsAvailable), CheckSuccess=$($finalResult.CheckSuccess)"
return $finalResult