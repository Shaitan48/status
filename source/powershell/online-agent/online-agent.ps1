# powershell\online-agent\online-agent.ps1
# ������ � ���������� ������ ����������, ������� ����������,
# ���������� ���������������, ������������� � ������������� ��������.
<#
.SYNOPSIS
    ������-����� ��� ������� ����������� Status Monitor v5.5.
.DESCRIPTION
    ���� ����� ������������ ��� ������ �� �������, ������� ������ �������
    ������ � API ������� �����������. �� ��������� ��������� ��������:
    1. ������ ��������� ������������ �� ����� 'config.json'.
    2. ����������� ����������� ������ StatusMonitorAgentUtils.
    3. ������������ (��� � api_poll_interval_seconds) ���������� � API
       ������� (/api/v1/assignments) ��� ��������� ������ �������� �������
       �����������, ��������������� ��� ��� object_id.
    4. ������ ������ ������� � ������ � �������������� ��������� �� ����������
       �������� ����������, ��������� � �������� ��� � ������� �� ���������.
    5. ��� ���������� ������ �������� �������� ������� Invoke-StatusMonitorCheck
       �� ���������������� ������.
    6. �������� ������������������� ��������� �� Invoke-StatusMonitorCheck.
    7. ����������� ��������� � ������, ��������� API /checks (v1).
    8. ���������� ���������� ��������� ������ �������� �� ������ �����
       POST-������ � API /api/v1/checks, ��������� API-���� ��� ��������������.
    9. ����� ��� ����� ������ � ��������� ����.
.NOTES
    ������: 5.5
    ����: 2024-05-20
    ��������� v5.5:
        - ���������� ������ CommandNotFoundException ��-�� �������� "..." � ConvertTo-Json ��� ��������� �������.
    ��������� v5.4:
        - ���������� ������ ParameterBindingException ��� ������ Write-Verbose � ������� Debug. �������� �� Write-Debug.
    ��������� v5.3:
        - ���������� ������ �������� ������ � ����� catch ������� Send-CheckResultToApi.
    ��������� v5.2:
        - ���������� ������ CommandNotFoundException ��-�� �������� "...".
        - ����������� ���������� ��������� ����������� API ����� � �����.
        - ������� ������� ������ ���� �� ��������� ��� ����������.
        - ��������� ��������� �����������.
        - �������� ��������������.
        - ������� Get-ActiveAssignments �������� � ����������.
    ��������� v5.1:
        - ��������� ��� ����� ������ ���������� Invoke-StatusMonitorCheck.
        - ������������� ����� IsAvailable � CheckSuccess �� ���������� ��������.
        - ������������ detail_type � detail_data ��� API �� ������ ����������.
        - ������������� IsAvailable ��� ����������� ����������� ���� ��� ��������.
    �����������: PowerShell 5.1+, ������ StatusMonitorAgentUtils, ������ � API.
#>
param(
    # ���� � ����� ������������ ������.
    [string]$ConfigFile = "$PSScriptRoot\config.json"
)

# --- �������� ������������ ������ ������ ---
# ������������� ������� ����� ��������� ������ �� ����� �������
$ErrorActionPreference = "Stop"
try {
    # ���������� ���� � ��������� ������ ������������ �������� �������
    $ModuleManifestPath = Join-Path -Path $PSScriptRoot `
                                    -ChildPath "..\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1"
    Write-Host "[INFO] �������� ������ '$ModuleManifestPath'..."
    # ������������� ����������� ������
    Import-Module $ModuleManifestPath -Force -ErrorAction Stop
    Write-Host "[INFO] ������ Utils ��������."
} catch {
    # ����������� ������ - ����� �� ����� �������� ��� ������
    Write-Host "[CRITICAL] ����������� ������ �������� ������ '$ModuleManifestPath': $($_.Exception.Message)" -ForegroundColor Red
    # ��������� ������ ������� � ����� ������
    exit 1
} finally {
    # ���������� ����������� ��������� ��������� ������
    $ErrorActionPreference = "Continue"
}
# --- ����� �������� ������ ---

# --- ���������� ���������� � ��������� ---

# ������ �������� ������� ������
$ScriptVersion = "5.5" # �������� ������

# ���-������� ��� �������� �������� ������� (���� - assignment_id, �������� - ������ �������)
$script:ActiveAssignments = @{}
# ���-������� ��� �������� ������� ���������� ���������� ������� ������� (���� - assignment_id, �������� - ������ ISO 8601 UTC)
$script:LastExecutedTimes = @{}
# ������ ��� �������� ������������ �� ����� config.json
$script:Config = $null
# API ���� ��� �������������� �� �������
$script:ApiKey = $null
# ��� �������� ���������� ��� ������������� � ����� � �����������
$script:ComputerName = $env:COMPUTERNAME

# --- �������� �� ��������� ��� ���������� ������������ ---
# ��� ����� ���������� API �� ������� �����/���������� ������� (�������)
$DefaultApiPollIntervalSeconds = 60
# �������� ���������� �������� �� ��������� (���� �� ������ � �������, �������)
$DefaultCheckIntervalSeconds = 120
# ������� ����������� �� ���������
$DefaultLogLevel = "Info"
# ���� � ���-����� �� ��������� (� ����� �� ��������)
$DefaultLogFile = "$PSScriptRoot\online_agent.log"
# ������� �������� ������ �� API (�������)
$ApiTimeoutSeconds = 30
# ������������ ���������� ������� ������� � API ��� ������
$MaxApiRetries = 3
# �������� ����� ���������� ��������� ������� � API (�������)
$RetryDelaySeconds = 5
# ���������� ������ �����������
$ValidLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error")
# ����������� ������� ����������� (����� ���������� ����� ������ �������)
$script:EffectiveLogLevel = $DefaultLogLevel

# --- ������� ---

#region �������

<#
.SYNOPSIS
    ���������� ��������� � ���-���� �/��� ������� � �������.
# ... (������������ Write-Log ��� ���������) ...
#>
function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
        [string]$Level = "Info"
    )
    # ... (��� ������� Write-Log ��� ���������) ...
    $logFilePath = $script:Config.logFile | Get-OrElse $DefaultLogFile; $logLevels = @{ "Debug" = 4; "Verbose" = 3; "Info" = 2; "Warn" = 1; "Error" = 0 }; $currentLevelValue = $logLevels[$script:EffectiveLogLevel]; if ($null -eq $currentLevelValue) { $currentLevelValue = $logLevels["Info"] }; $messageLevelValue = $logLevels[$Level]; if ($null -eq $messageLevelValue) { $messageLevelValue = $logLevels["Info"] }; if ($messageLevelValue -le $currentLevelValue) { $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage = "[$timestamp] [$Level] [$script:ComputerName] - $Message"; $consoleColor = switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}; Write-Host $logMessage -ForegroundColor $consoleColor; try { $logDir = Split-Path $logFilePath -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { Write-Host "[INFO] �������� ����� �����: '$logDir'"; New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }; $logMessage | Out-File -FilePath $logFilePath -Append -Encoding UTF8 -ErrorAction Stop } catch { Write-Host "[Error] �� ������� �������� � ��� '$($logFilePath)': $($_.Exception.Message)" -ForegroundColor Red } }
}

<#
.SYNOPSIS
    ���������� �������� �� ���������, ���� ������� �������� �����.
# ... (������������ Get-OrElse ��� ���������) ...
#>
filter Get-OrElse {
    param([object]$DefaultValue)
    if ($_) { $_ } else { $DefaultValue }
}

<#
.SYNOPSIS
    ���������� ��������� ����� �������� � API /checks.
# ... (������������ Send-CheckResultToApi ��� ���������) ...
#>
function Send-CheckResultToApi {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$CheckResult,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Assignment
    )

    $assignmentId = $Assignment.assignment_id
    Write-Log "�������� ���������� ��� ������� ID $assignmentId..." "Verbose"

    # --- ��������� ���� ������� ��� API /checks ---
    $isAvailableApi = [bool]$CheckResult.IsAvailable
    $checkTimestampApi = $CheckResult.Timestamp
    $detailTypeApi = $null
    $detailDataApi = $null

    if ($CheckResult.Details -ne $null -and $CheckResult.Details -is [hashtable]) {
        $detailTypeApi = $Assignment.method_name
        $detailDataApi = $CheckResult.Details
        if ($CheckResult.ContainsKey('CheckSuccess')) {
            $detailDataApi.check_success = $CheckResult.CheckSuccess
        }
        if (-not [string]::IsNullOrEmpty($CheckResult.ErrorMessage)) {
             $detailDataApi.error_message_from_check = $CheckResult.ErrorMessage
        }
    }
    elseif (-not [string]::IsNullOrEmpty($CheckResult.ErrorMessage)) {
        $detailTypeApi = "ERROR"
        $detailDataApi = @{ message = $CheckResult.ErrorMessage }
    }

    $body = @{
        assignment_id        = $assignmentId
        is_available         = $isAvailableApi
        check_timestamp      = $checkTimestampApi
        executor_object_id   = $script:Config.object_id
        executor_host        = $script:ComputerName
        resolution_method    = $Assignment.method_name
        detail_type          = $detailTypeApi
        detail_data          = $detailDataApi
        agent_script_version = $ScriptVersion
    }
    # --- ����� ������������ ���� ������� ---

    # ����������� ���� � JSON ������
    try {
        $jsonBody = $body | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
    } catch {
         # ���������� -f ��� �������������� ������
         Write-Log ("����������� ������ ConvertTo-Json ��� ID {0}: {1}" -f $assignmentId, $_.Exception.Message) "Error"
         Write-Log "���������� ������: $($body | Out-String)" "Error"
         return $false
    }

    # ��������� � URL
    $headers = @{
        'Content-Type' = 'application/json; charset=utf-8'
        'X-API-Key'    = $script:ApiKey
    }
    $apiUrl = "$($script:Config.apiBaseUrl.TrimEnd('/'))/v1/checks"
    Write-Log "URL ��������: $apiUrl" "Debug"
    Write-Log "���� JSON: $jsonBody" "Debug"

    # --- �������� ������� � ������� ��������� ������� (retry) ---
    $retryCount = 0; $success = $false
    while ($retryCount -lt $MaxApiRetries -and (-not $success)) {
        try {
            $response = Invoke-RestMethod -Uri $apiUrl `
                                          -Method Post `
                                          -Body ([System.Text.Encoding]::UTF8.GetBytes($jsonBody)) `
                                          -Headers $headers `
                                          -TimeoutSec $ApiTimeoutSeconds `
                                          -ErrorAction Stop

            Write-Log ("��������� ID {0} ���������. ����� API: {1}" -f `
                        $assignmentId, ($response | ConvertTo-Json -Depth 2 -Compress -WarningAction SilentlyContinue)) "Info"
            $success = $true

        } catch {
            $retryCount++; $statusCode = $null; if ($_.Exception.Response) { try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {} }; $errorMessage = $_.Exception.Message;
            $errorResponseBody = "[�� ������� ��������� ���� ������]"; if ($_.Exception.Response) { try { $errorStream = $_.Exception.Response.GetResponseStream(); $reader = New-Object System.IO.StreamReader($errorStream); $errorResponseBody = $reader.ReadToEnd(); $reader.Close(); $errorStream.Dispose() } catch {} };
            Write-Log ("������ �������� ID {0} (������� {1}/{2}). ���: {3}. Error: {4}. �����: {5}" -f $assignmentId, $retryCount, $MaxApiRetries, ($statusCode | Get-OrElse 'N/A'), $errorMessage, $errorResponseBody) "Error"
            if ($statusCode -eq 401 -or $statusCode -eq 403) { Write-Log "����������� ������: �������� API ���� ��� ����� (���: $statusCode). ���������� ������." "Error"; exit 1 }
            if ($retryCount -ge $MaxApiRetries) { Write-Log "��������� ���-�� ������� ($MaxApiRetries) ��� ID $assignmentId." "Error"; break }
            Write-Log "����� $RetryDelaySeconds ���..." "Warn"; Start-Sleep -Seconds $RetryDelaySeconds
        }
    } # ����� while retry
    return $success
}

<#
.SYNOPSIS
    ����������� �������� ������� � API �������.
# ... (������������ Get-ActiveAssignments ��� ���������) ...
#>
function Get-ActiveAssignments {
    Write-Log "������ �������� ������� � API..." "Info"
    $apiUrl = "$($script:Config.apiBaseUrl.TrimEnd('/'))/v1/assignments?object_id=$($script:Config.object_id)"
    Write-Log "URL: $apiUrl" "Verbose"

    # ����������� ����� API �����
    $apiKeyPartial = "[�� �����]"
    if ($script:ApiKey) {
        $len = $script:ApiKey.Length; $prefix = $script:ApiKey.Substring(0, [math]::Min(4, $len)); $suffix = if ($len -gt 8) { $script:ApiKey.Substring($len - 4, 4) } else { "" }; $apiKeyPartial = "$prefix....$suffix"
    }
    Write-Log "���. API ���� (��������): $apiKeyPartial" "Debug"

    $headers = @{ 'X-API-Key' = $script:ApiKey }
    $newAssignments = $null; $retryCount = 0
    while ($retryCount -lt $MaxApiRetries -and $newAssignments -eq $null) {
        try {
            $newAssignments = Invoke-RestMethod -Uri $apiUrl `
                                                -Method Get `
                                                -Headers $headers `
                                                -TimeoutSec $ApiTimeoutSeconds `
                                                -ErrorAction Stop
            if ($newAssignments -isnot [array]) { throw ("API ����� �� �������� ��������: $($newAssignments | Out-String)") }
            Write-Log "�������� $($newAssignments.Count) �������� �������." "Info"
            return $newAssignments
        } catch {
            $retryCount++; $statusCode = $null; if ($_.Exception.Response) { try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {} }; $errorMessage = $_.Exception.Message;
            Write-Log ("������ API ��� ��������� ������� (������� {0}/{1}). ���: {2}. Error: {3}" -f $retryCount, $MaxApiRetries, ($statusCode | Get-OrElse 'N/A'), $errorMessage) "Error"
            if ($statusCode -eq 401 -or $statusCode -eq 403) { Write-Log "����������� ������: �������� API ���� ��� ����� (���: $statusCode). ���������� ������." "Error"; exit 1 }
            if ($retryCount -ge $MaxApiRetries) { Write-Log "��������� ���-�� ������� ($MaxApiRetries) ��������� �������." "Error"; return $null }
            Write-Log "����� $RetryDelaySeconds ���..." "Warn"; Start-Sleep -Seconds $RetryDelaySeconds
        }
    } # ����� while retry
    return $null
}

#endregion �������

# --- �������� ��� ������ ---

# 1. ������ ������������ �� �����
Write-Host "������ ������������ ��: $ConfigFile"
if (-not (Test-Path $ConfigFile -PathType Leaf)) { Write-Error ...; exit 1 }
try { $script:Config = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Error ...; exit 1 }
$requiredCfg=@("object_id","apiBaseUrl","api_key","logFile","LogLevel","api_poll_interval_seconds","default_check_interval_seconds"); $missingCfg=$requiredCfg|?{-not $script:Config.PSObject.Properties.Name.Contains($_) -or !$script:Config.$_}; if($missingCfg){ Write-Error ...; exit 1 }
$script:EffectiveLogLevel = $script:Config.LogLevel | Get-OrElse $DefaultLogLevel
if ($script:EffectiveLogLevel -notin $ValidLogLevels) { Write-Host ...; $script:EffectiveLogLevel = $DefaultLogLevel }
$script:ApiKey = $script:Config.api_key

# 2. ������������� � ����������� ������ ������
Write-Log "������-����� v$ScriptVersion �������." "Info"
Write-Log "������������: ObjectID=$($script:Config.object_id), API URL=$($script:Config.apiBaseUrl)" "Info"
Write-Log ("�������� ������ API: {0} ���, ����������� �������� ��������: {1} ���." -f `
    $script:Config.api_poll_interval_seconds, $script:Config.default_check_interval_seconds) "Verbose"
Write-Log "����������� � '$($script:Config.logFile)' � ������� '$($script:EffectiveLogLevel)'" "Info"

# 3. �������� ���� ������ ������
$lastApiPollTime = [DateTime]::MinValue
$apiPollInterval = [TimeSpan]::FromSeconds($script:Config.api_poll_interval_seconds)
$DefaultCheckInterval = [TimeSpan]::FromSeconds($script:Config.default_check_interval_seconds)

Write-Log "������ ��������� ����� ��������� �������..." "Info"
while ($true) {
    $loopStartTime = Get-Date
    Write-Log "������ �������� �����." "Verbose"

    # 3.1 ������/���������� ������ �������� ������� � API
    if (($loopStartTime - $lastApiPollTime) -ge $apiPollInterval) {
        Write-Log "����� �������� ������ ������� � API." "Info"; $fetchedAssignments = Get-ActiveAssignments
        if ($fetchedAssignments -ne $null) {
            Write-Log "��������� ���������� �������..." "Info"; $newAssignmentMap = @{}; $fetchedIds = [System.Collections.Generic.List[int]]::new()
            foreach ($assignment in $fetchedAssignments) { if ($assignment.assignment_id -ne $null) { $id = $assignment.assignment_id; $newAssignmentMap[$id] = $assignment; $fetchedIds.Add($id) } else { Write-Log "..." "Warn" } }
            $currentIds = $script:ActiveAssignments.Keys | ForEach-Object { [int]$_ }; $removedIds = $currentIds | Where-Object { $fetchedIds -notcontains $_ }
            if ($removedIds) { foreach ($removedId in $removedIds) { Write-Log "... $removedId" "Info"; $script:ActiveAssignments.Remove($removedId); $script:LastExecutedTimes.Remove($removedId) } }
            $addedCount = 0; $updatedCount = 0
            foreach ($assignmentId in $fetchedIds) {
                if (-not $script:ActiveAssignments.ContainsKey($assignmentId)) {
                    # ���������� ������ �������
                    Write-Log "��������� ����� ������� ID $assignmentId" "Info"
                    $script:ActiveAssignments[$assignmentId] = $newAssignmentMap[$assignmentId]
                    $script:LastExecutedTimes[$assignmentId] = (Get-Date).AddDays(-1).ToUniversalTime().ToString("o")
                    $addedCount++
                } else {
                    # ��������, ���������� �� ������������ �������
                    # --- ����������: ������ �������� "..." ---
                    $oldJson = $script:ActiveAssignments[$assignmentId] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue
                    $newJson = $newAssignmentMap[$assignmentId] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue
                    # --- ����� ����������� ---
                    if ($oldJson -ne $newJson) {
                         Write-Log "��������� ������� ID $assignmentId" "Verbose"
                         $script:ActiveAssignments[$assignmentId] = $newAssignmentMap[$assignmentId]
                         # ���������� �� LastExecutedTimes ��� ����������?
                         # ���� �� �����, ����� �� ������� ���������� ����� ����� ����������.
                         $updatedCount++
                    }
                }
            } # ����� foreach ($assignmentId in $fetchedIds)
            Write-Log ("������������� ������� ���������. ���������:{0}. ���������:{1}. �������:{2}." -f $addedCount, $updatedCount, $removedIds.Count) "Info"
            $lastApiPollTime = $loopStartTime
        } else { Write-Log "�� ������� �������� ������� �� API..." "Error" }
    } else { Write-Log "����� API ��� �� ���������..." "Verbose" }

    # 3.2 ���������� ��������������� ��������
    # ... (��� ���������� ��������, ������ Invoke-StatusMonitorCheck � Send-CheckResultToApi ��� ���������) ...
    $currentTime = Get-Date
    if ($script:ActiveAssignments.Count -gt 0) {
        Write-Log "�������� ��������������� ������� ($($script:ActiveAssignments.Count) �������)..." "Verbose"
        $assignmentIdsToCheck = $script:ActiveAssignments.Keys | ForEach-Object { $_ }
        foreach ($id in $assignmentIdsToCheck) {
            if (-not $script:ActiveAssignments.ContainsKey($id)) { continue }
            $assignment = $script:ActiveAssignments[$id]; $checkIntervalSeconds = $assignment.check_interval_seconds | Get-OrElse $script:Config.default_check_interval_seconds; if ($checkIntervalSeconds -le 0) { $checkIntervalSeconds = $script:Config.default_check_interval_seconds }; $checkInterval = [TimeSpan]::FromSeconds($checkIntervalSeconds); $lastRunString = $script:LastExecutedTimes[$id]; $lastRunTime = [DateTime]::MinValue; if ($lastRunString) { try { $lastRunTime = [DateTime]::ParseExact($lastRunString,"o",$null).ToLocalTime() } catch { Write-Log "... ID ${id}: '$lastRunString'" "Error"; $lastRunTime = [DateTime]::MinValue } }; $nextRunTime = $lastRunTime + $checkInterval
            Write-Debug ("������� ID {0}: ��������={1} ���, ����.={2}, ����.={3}" -f $id, $checkInterval.TotalSeconds, $lastRunTime.ToString('s'), $nextRunTime.ToString('s'))
            if ($currentTime -ge $nextRunTime) {
                Write-Log ("���������� ������� ID {0} ({1} ��� {2})." -f $id, $assignment.method_name, $assignment.node_name) "Info"; $checkResult = $null
                try { $checkResult = Invoke-StatusMonitorCheck -Assignment $assignment -Verbose:$VerbosePreference -Debug:$DebugPreference; Write-Log ("��������� �������� ID {0}: IsAvailable={1}, CheckSuccess={2}, Error='{3}'" -f $id, $checkResult.IsAvailable, $checkResult.CheckSuccess, $checkResult.ErrorMessage) "Verbose"; Write-Log ("������ ���������� ID {0}: {1}" -f $id, ($checkResult.Details | ConvertTo-Json -Depth 3 -Compress -WarningAction SilentlyContinue)) "Debug"; $sendSuccess = Send-CheckResultToApi -CheckResult $checkResult -Assignment $assignment; if ($sendSuccess) { $script:LastExecutedTimes[$id] = $currentTime.ToUniversalTime().ToString("o"); Write-Log "����� ���������� ���������� ID $id ���������." "Verbose" } else { Write-Log "��������� ��� ID $id �� ��� ������� ��������� � API." "Error" } } catch { Write-Log "����������� ������ ��� ���������� ������� ID ${id}: $($_.Exception.Message)" "Error" }
            }
        }
    } else { Write-Log "��� �������� ������� ��� ����������." "Verbose" }

    # 3.3 ����� ����� ��������� ���������
    Start-Sleep -Seconds 1

} # --- ����� while ($true) ---

Write-Log "������-����� ��������� ������ (����������� ����� �� ��������� �����)." "Error"
exit 1