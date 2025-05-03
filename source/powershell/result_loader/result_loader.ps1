# powershell/result_loader/result_loader.ps1
# ��������� ����������� �������-������� v3.18 (����������� -f ����� ������������)
# ���������� ������ ParameterBindingException ����� ������ ��������� -f �� ��������� ������������.
<#
.SYNOPSIS
    ������������ ����� *.zrpu �� �������-�������
    � ���������� ������ ������� � API Status Monitor (v3.18).
.DESCRIPTION
    ������-��������� �����������. ����������� �� ������, �������
    ������ ��� � ����� � ������������ �� �������-������� (`check_folder`),
    ��� � � API ������� ����������� (`api_base_url`).

    ������� ������:
    1. ������ ��������� ������������ �� 'config.json'.
    2. � ����������� ����� � ���������� (`scan_interval_seconds`):
       a. ��������� `check_folder` �� ������� ������ `*_OfflineChecks.json.status*.zrpu`.
       b. ��� ������� ���������� �����:
          i.   ������ � ������ JSON.
          ii.  ��������� ������� ��������� (������� `results`, `agent_script_version`, `assignment_config_version`).
          iii. ���� ���� ������� � �������� ����������:
               - ��������� ���� Bulk-������� (���� ������������ JSON).
               - ���������� ���� POST-������ �� `/api/v1/checks/bulk`, ��������� ������� `Invoke-ApiRequestWithRetry`.
          iv.  ����������� ����� �� Bulk API (`status`, `processed`, `failed`, `errors`).
          v.   ���������� �������� ������ ��������� ����� (`success`, `partial_error`, `error_api`, `error_local`).
          vi.  ���������� ������� `FILE_PROCESSED` � API `/api/v1/events` � �������� ���������.
          vii. ���������� ������������ ���� � �������� `Processed` ��� `Error`.
       c. ���� ������ ���, ����.
    3. ���� `scan_interval_seconds` � ��������� ����.
    4. �������� ��� ��������.
.PARAMETER ConfigFile
    [string] ���� � ����� ������������ ���������� (JSON).
    �� ���������: "$PSScriptRoot\config.json".
# ... (��������� ��������� ��� ���������������) ...
.EXAMPLE
    # ������ � �������� �� ���������
    .\result_loader.ps1
.NOTES
    ������: 3.18
    ����: 2025-05-02
    ��������� v3.18:
        - ���������� ������ ParameterBindingException ����� ������ ��������� -f �� ��������� ������������ � Invoke-ApiRequestWithRetry.
    # ... (���������� ������� ���������) ...
    �����������: PowerShell 5.1+, ������� ������ � API, ����� ������� � ����� check_folder.
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\config.json",
    # --- ��������� ��� ��������������� ������� ---
    [string]$apiBaseUrl = $null,
    [string]$apiKey = $null,
    [string]$checkFolder = $null,
    [string]$logFile = $null,
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
    [string]$LogLevel = $null,
    [int]$ScanIntervalSeconds = $null,
    [int]$ApiTimeoutSeconds = $null,
    [int]$MaxApiRetries = $null,
    [int]$RetryDelaySeconds = $null
)

# --- ���������� ���������� � ��������� ---
$ScriptVersion = "3.18" # ��������� ������
$script:Config = $null
$script:EffectiveLogLevel = "Info"
$script:logFilePath = $null
$script:ComputerName = $env:COMPUTERNAME
$DefaultLogLevel = "Info"; $DefaultScanInterval = 30; $DefaultApiTimeout = 30; $DefaultMaxRetries = 3; $DefaultRetryDelay = 5;
$ValidLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error");
$script:EffectiveApiKey = $null

# --- ������� ---

#region �������

<#
.SYNOPSIS ����� ��������� � ��� �/��� �������.
#>
function Write-Log{
    param ( [Parameter(Mandatory=$true)][string]$Message, [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)][string]$Level = "Info" )
    # ... (��� ������� Write-Log ��� ���������) ...
    if (-not $script:logFilePath) { Write-Host "[$Level] $Message"; return }
    $logLevels=@{"Debug"=4;"Verbose"=3;"Info"=2;"Warn"=1;"Error"=0}; $currentLevelValue=$logLevels[$script:EffectiveLogLevel]; if($null -eq $currentLevelValue){ $currentLevelValue = $logLevels["Info"] }; $messageLevelValue=$logLevels[$Level]; if($null -eq $messageLevelValue){ $messageLevelValue = $logLevels["Info"] };
    if ($messageLevelValue -le $currentLevelValue) { $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage = "[$timestamp] [$Level] [$($script:ComputerName)] - $Message"; $consoleColor = switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}; Write-Host $logMessage -ForegroundColor $consoleColor; if ($script:logFilePath) { try { $logDir = Split-Path $script:logFilePath -Parent; if ($logDir -and (-not(Test-Path $logDir -PathType Container))) { Write-Host "[INFO] �������� ����� �����: '$logDir'"; New-Item -Path $logDir -ItemType Directory -Force -EA Stop | Out-Null }; Add-Content -Path $script:logFilePath -Value $logMessage -Encoding UTF8 -Force -EA Stop } catch { Write-Host ("[Error] �� ������� �������� � ��� '{0}': {1}" -f $script:logFilePath, $_.Exception.Message) -ForegroundColor Red } } }

}

<#
.SYNOPSIS ���������� �������� �� ���������, ���� �������� ������.
#>
filter Get-OrElse_Internal{ param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }

<#
.SYNOPSIS ��������� HTTP-������ � API � ������� ��������� �������.
#>
function Invoke-ApiRequestWithRetry {
    param(
        [Parameter(Mandatory=$true)] [string]$Uri,
        [Parameter(Mandatory=$true)] [string]$Method,
        [Parameter(Mandatory=$false)]$Body = $null,
        [Parameter(Mandatory=$true)] [hashtable]$Headers, # ������� X-API-Key
        [Parameter(Mandatory=$true)] [string]$Description
    )

    $retryCount = 0
    $response = $null
    $currentMaxRetries = $script:EffectiveMaxApiRetries | Get-OrElse_Internal $DefaultMaxRetries
    $currentTimeoutSec = $script:EffectiveApiTimeoutSeconds | Get-OrElse_Internal $DefaultApiTimeout
    $currentRetryDelay = $script:EffectiveRetryDelaySeconds | Get-OrElse_Internal $DefaultRetryDelay

    $invokeParams = @{ Uri = $Uri; Method = $Method; Headers = $Headers; TimeoutSec = $currentTimeoutSec; ErrorAction = 'Stop' }
    if ($Body -ne $null -and $Method -notin @('GET', 'DELETE')) {
        if ($Body -is [array] -and $Body.Count -gt 0 -and $Body[0] -is [byte]) { $invokeParams.Body = $Body }
        elseif ($Body -is [string]) { $invokeParams.Body = [System.Text.Encoding]::UTF8.GetBytes($Body) }
        else { $invokeParams.Body = $Body }
        if (-not $invokeParams.Headers.ContainsKey('Content-Type')) { $invokeParams.Headers.'Content-Type' = 'application/json; charset=utf-8' }
    }

    while ($retryCount -lt $currentMaxRetries -and $response -eq $null) {
        try {
            Write-Log ("���������� ������� ({0}): {1} {2}" -f $Description, $Method, $Uri) -Level Verbose
            if ($invokeParams.Body) {
                 if ($invokeParams.Body -is [array] -and $invokeParams.Body[0] -is [byte]) { Write-Log "���� (�����): $($invokeParams.Body.Count) bytes" -Level Debug }
                 else { Write-Log "����: $($invokeParams.Body | Out-String -Width 500)..." -Level Debug }
            }

            $response = Invoke-RestMethod @invokeParams

            if ($null -eq $response -and $? -and ($Error.Count -eq 0)) {
                 Write-Log ("API ������ �������� ����� ��� ���� (��������, 204 No Content) ��� ({0})." -f $Description) -Level Verbose
                 return $true
            }
            Write-Log ("�������� ����� API ({0})." -f $Description) -Level Verbose
            return $response

        } catch {
            $retryCount++
            $statusCode = $null; if ($_.Exception.Response) { try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {} }; $errorMessage = $_.Exception.Message;
            $errorResponseBody = "[�� ������� ��������� ���� ������]"; if ($_.Exception.Response) { try { $errorStream = $_.Exception.Response.GetResponseStream(); $reader = New-Object System.IO.StreamReader($errorStream); $errorResponseBody = $reader.ReadToEnd(); $reader.Close(); $errorStream.Dispose() } catch { } };
            # <<<< ����������: ���������� ��������� ������������ >>>>
            Write-Log "������ API ($Description) (������� $retryCount/$currentMaxRetries). ���: $($statusCode | Get-OrElse_Internal 'N/A'). Error: $($errorMessage.Replace('{','{{').Replace('}','}}')). �����: $($errorResponseBody.Replace('{','{{').Replace('}','}}'))" "Error"

            if ($statusCode -eq 401 -or $statusCode -eq 403) { Write-Log ("����������� ������ ��������������/����������� ({0}). ��������� API ���� � ��� ���� ('loader'). ���������� ������." -f $Description) -Level Error; exit 1 };
            if ($retryCount -ge $currentMaxRetries) {
                 # <<<< ����������: ���������� ��������� ������������ >>>>
                 Write-Log "��������� ���-�� ������� ($currentMaxRetries) ��� ($Description)." -Level Error;
                 return $null
            };
            Write-Log ("����� $currentRetryDelay ��� ����� ��������� ��������...") "Warn"; Start-Sleep -Seconds $currentRetryDelay
        }
    } # ����� while
    return $null
}

#endregion �������

# --- �������� ������ ---

# 1. ������ � ��������� ������������
Write-Host "������ ���������� ����������� PowerShell v$ScriptVersion"
Write-Log "������ ������������..." "Info"
# ... (��� ������ ������� ��� ���������) ...
if (Test-Path $ConfigFile -PathType Leaf) {
    try { $script:Config = Get-Content $ConfigFile -Raw -Enc UTF8 | ConvertFrom-Json -EA Stop }
    catch { Write-Log ("������ ������/�������� JSON �� '{0}': {1}. ������������ ��������� �� ���������/��������� ������." -f $ConfigFile, $_.Exception.Message) "Error" }
} else { Write-Log ("���� ������������ '{0}' �� ������. ������������ ��������� �� ���������/��������� ������." -f $ConfigFile) "Warn" }
$EffectiveApiBaseUrl = $apiBaseUrl | Get-OrElse_Internal $script:Config.api_base_url
$script:EffectiveApiKey = $apiKey | Get-OrElse_Internal $script:Config.api_key
$EffectiveCheckFolder = $checkFolder | Get-OrElse_Internal $script:Config.check_folder
$EffectiveLogFile = $logFile | Get-OrElse_Internal ($script:Config.log_file | Get-OrElse_Internal "$PSScriptRoot\result_loader.log")
$EffectiveLogLevel = $LogLevel | Get-OrElse_Internal ($script:Config.log_level | Get-OrElse_Internal $DefaultLogLevel)
$EffectiveScanIntervalSeconds = $ScanIntervalSeconds | Get-OrElse_Internal ($script:Config.scan_interval_seconds | Get-OrElse_Internal $DefaultScanInterval)
$EffectiveApiTimeoutSeconds = $ApiTimeoutSeconds | Get-OrElse_Internal ($script:Config.api_timeout_sec | Get-OrElse_Internal $DefaultApiTimeout)
$EffectiveMaxApiRetries = $MaxApiRetries | Get-OrElse_Internal ($script:Config.max_api_retries | Get-OrElse_Internal $DefaultMaxRetries)
$EffectiveRetryDelaySeconds = $RetryDelaySeconds | Get-OrElse_Internal ($script:Config.retry_delay_sec | Get-OrElse_Internal $DefaultRetryDelay)
$script:logFilePath = $EffectiveLogFile
$script:EffectiveLogLevel = $EffectiveLogLevel
if (-not $ValidLogLevels.Contains($script:EffectiveLogLevel)) { Write-Log ("������������ LogLevel '{0}'. ������������ '{1}'." -f $script:EffectiveLogLevel, $DefaultLogLevel) "Warn"; $script:EffectiveLogLevel = $DefaultLogLevel }
if (-not $EffectiveApiBaseUrl) { Write-Log "����������� ������: �� ����� 'api_base_url'." "Error"; exit 1 }; if (-not $script:EffectiveApiKey) { Write-Log "����������� ������: �� ����� 'api_key'." "Error"; exit 1 }; if (-not $EffectiveCheckFolder) { Write-Log "����������� ������: �� ����� 'check_folder'." "Error"; exit 1 }
if ($EffectiveScanIntervalSeconds -lt 5) { Write-Log "ScanIntervalSeconds < 5. ����������� 5 ���." "Warn"; $EffectiveScanIntervalSeconds = 5 }
if ($EffectiveApiTimeoutSeconds -le 0) { $EffectiveApiTimeoutSeconds = $DefaultApiTimeout }; if ($EffectiveMaxApiRetries -lt 0) { $EffectiveMaxApiRetries = $DefaultMaxRetries }; if ($EffectiveRetryDelaySeconds -lt 0) { $EffectiveRetryDelaySeconds = $DefaultRetryDelay }
$script:EffectiveScanIntervalSeconds = $EffectiveScanIntervalSeconds; $script:EffectiveApiTimeoutSeconds = $EffectiveApiTimeoutSeconds; $script:EffectiveMaxApiRetries = $EffectiveMaxApiRetries; $script:EffectiveRetryDelaySeconds = $EffectiveRetryDelaySeconds


# 2. ���������� ���������
Write-Log "������������� ����������." "Info"
Write-Log ("���������: API='{0}', �����='{1}', ��������={2} ���, ���='{3}', �������='{4}'" -f $EffectiveApiBaseUrl, $EffectiveCheckFolder, $script:EffectiveScanIntervalSeconds, $script:logFilePath, $script:EffectiveLogLevel) "Info"
$apiKeyPart = "[�� �����]"; if($script:EffectiveApiKey){ $l=$script:EffectiveApiKey.Length; $p=$script:EffectiveApiKey.Substring(0,[math]::Min(4,$l)); $s=if($l -gt 8){$script:EffectiveApiKey.Substring($l-4,4)}else{""}; $apiKeyPart="$p....$s" }; Write-Log "API ���� (��������): $apiKeyPart" "Debug"
if (-not (Test-Path $EffectiveCheckFolder -PathType Container)) { Write-Log "����������� ������: ����� ��� ������������ '$($EffectiveCheckFolder)' �� ����������." "Error"; exit 1 };
$processedFolder = Join-Path $EffectiveCheckFolder "Processed"; $errorFolder = Join-Path $EffectiveCheckFolder "Error"; foreach ($folder in @($processedFolder, $errorFolder)) { if (-not (Test-Path $folder -PathType Container)) { Write-Log "�������� �����: $folder" "Info"; try { New-Item -Path $folder -ItemType Directory -Force -EA Stop | Out-Null } catch { Write-Log ("����������� ������: �� ������� ������� ����� '{0}'. ������: {1}" -f $folder, $_.Exception.Message) "Error"; exit 1 } } }


# --- 3. �������� ���� ������������ � ��������� ---
Write-Log "������ ����� ������������ ����� '$($EffectiveCheckFolder)'..." "Info"
while ($true) {
    Write-Log "������������ �����..." "Verbose"
    $filesToProcess = @()
    try {
        $resultsFileFilter = "*_OfflineChecks.json.status*.zrpu"
        $filesToProcess = Get-ChildItem -Path $EffectiveCheckFolder -Filter $resultsFileFilter -File -ErrorAction Stop
    } catch {
        # <<<< ����������: ���������� ������������ >>>>
        Write-Log "����������� ������ ������� � ����� '$EffectiveCheckFolder': $($_.Exception.Message). ������� ��������." "Error";
        Start-Sleep -Seconds $script:EffectiveScanIntervalSeconds; continue
    }

    if ($filesToProcess.Count -eq 0) { Write-Log "��� ������ *.zrpu ��� ���������." "Verbose" }
    else {
        Write-Log "������� ������ ��� ���������: $($filesToProcess.Count)." "Info"
        # --- ��������� ������� ����� ---
        foreach ($file in $filesToProcess) {
            $fileStartTime = Get-Date; Write-Log "--- ������ ��������� �����: '$($file.FullName)' ---" "Info"
            $fileProcessingStatus = "unknown"; $fileProcessingMessage = ""; $fileEventDetails = @{}; $apiResponse = $null;

            try {
                # --- ������ � ������� ����� ---
                Write-Log "������ ����� '$($file.Name)'..." "Debug"
                $fileContent = Get-Content -Path $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $fileContentClean = $fileContent.TrimStart([char]0xFEFF)
                $payloadFromFile = $fileContentClean | ConvertFrom-Json -ErrorAction Stop
                Write-Log "���� '$($file.Name)' ������� �������� � ���������." "Debug"

                # --- ��������� ��������� ����� ---
                if ($null -eq $payloadFromFile -or -not $payloadFromFile.PSObject.Properties.Name.Contains('results') -or $payloadFromFile.results -isnot [array] -or -not $payloadFromFile.PSObject.Properties.Name.Contains('agent_script_version') -or -not $payloadFromFile.PSObject.Properties.Name.Contains('assignment_config_version')) {
                     # <<<< ����������: ���������� ������������ � throw >>>>
                    throw "������������ ��������� JSON ����� '$($file.Name)'. ����������� ������������ ����."
                }
                $resultsArray = $payloadFromFile.results
                $fileAgentVersion = $payloadFromFile.agent_script_version | Get-OrElse_Internal "[�� �������]"
                $fileAssignmentVersion = $payloadFromFile.assignment_config_version | Get-OrElse_Internal "[�� �������]"
                $totalRecordsInFile = $resultsArray.Count
                # <<<< ����������: ����������� ������ �� ������ Write-Log >>>>
                $logMsgFileRead = "���� '{0}' �������� �������: {1}. AgentVer: '{2}', ConfigVer: '{3}'" -f $file.Name, $totalRecordsInFile, $fileAgentVersion, $fileAssignmentVersion
                Write-Log $logMsgFileRead "Info"

                if ($totalRecordsInFile -eq 0) {
                    # <<<< ����������: ����������� ������ �� ������ Write-Log >>>>
                    Write-Log ("���� '{0}' �� �������� ������� � ������� 'results'. ���� ����� ��������� � Processed." -f $file.Name) "Warn"
                    $fileProcessingStatus = "success_empty"
                    $fileProcessingMessage = "��������� ����� ��������� (������ ������ results)."
                    $fileEventDetails = @{ total_records_in_file = 0; agent_version_in_file = $fileAgentVersion; assignment_version_in_file = $fileAssignmentVersion }
                } else {
                    # --- �������� Bulk ������� ---
                    $apiUrlBulk = "$EffectiveApiBaseUrl/v1/checks/bulk"
                    $jsonBodyToSend = $null
                    try {
                         $jsonBodyToSend = $payloadFromFile | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
                    } catch {
                        # <<<< ����������: ���������� ������������ � throw >>>>
                        throw "������ ������������ ������ ����� '$($file.Name)' � JSON: $($_.Exception.Message)"
                    }
                    $headersForBulk = @{ 'Content-Type' = 'application/json; charset=utf-8'; 'X-API-Key' = $script:EffectiveApiKey }
                    $bulkApiParams = @{ Uri = $apiUrlBulk; Method = 'Post'; Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBodyToSend); Headers = $headersForBulk; Description = "�������� Bulk �� ����� '$($file.Name)' ($totalRecordsInFile �������)" }
                    Write-Log ("�������� Bulk ������� ��� ����� '$($file.Name)' ({0} �������)..." -f $totalRecordsInFile) -Level Info
                    $apiResponse = Invoke-ApiRequestWithRetry @bulkApiParams

                    # ��������� ������ Bulk API
                    if ($apiResponse -eq $null) {
                        $fileProcessingStatus = "error_api"
                        $fileProcessingMessage = "������ �������� Bulk ������� � API ����� ���� �������."
                        $fileEventDetails.error = "API request failed after retries."; $fileEventDetails.api_response_status = $null
                    } else {
                        $processed = $apiResponse.processed | Get-OrElse_Internal 0; $failed = $apiResponse.failed | Get-OrElse_Internal 0; $apiStatus = $apiResponse.status | Get-OrElse_Internal "unknown"
                        if ($apiStatus -eq "success") { $fileProcessingStatus = "success"; $fileProcessingMessage = "�������� ��������� ����� ������� ��������� API. ����������: $processed." }
                        elseif ($apiStatus -eq "partial_error") { $fileProcessingStatus = "partial_error"; $fileProcessingMessage = "�������� ��������� ����� ��������� API � ��������. �������: $processed, ������: $failed."; $fileEventDetails.api_errors = $apiResponse.errors }
                        else { $fileProcessingStatus = "error_api_response"; $fileProcessingMessage = "API ������ ������ '$apiStatus' ��� �������� ���������. �������: $processed, ������: $failed."; $fileEventDetails.error = "API processing error status: $apiStatus"; $fileEventDetails.api_errors = $apiResponse.errors }
                        $fileEventDetails.api_response_status = $apiStatus; $fileEventDetails.api_processed_count = $processed; $fileEventDetails.api_failed_count = $failed
                        $fileEventDetails.total_records_in_file = $totalRecordsInFile; $fileEventDetails.agent_version_in_file = $fileAgentVersion; $fileEventDetails.assignment_version_in_file = $fileAssignmentVersion
                    }
                    # --- ����� Bulk ������� ---
                } # ����� else ($totalRecordsInFile -eq 0)

            } catch { # ��������� ������ ������/�������� �����
                $errorMessage = "����������� ������ ��������� ����� '$($file.FullName)': $($_.Exception.Message)"
                Write-Log $errorMessage "Error"
                $fileProcessingStatus = "error_local"
                $fileProcessingMessage = "������ ������ ��� �������� JSON �����."
                $fileEventDetails = @{ error = $errorMessage; ErrorRecord = $_.ToString() }
            }

            # --- �������� ������� FILE_PROCESSED ---
            $fileEndTime = Get-Date; $processingTimeMs = ($fileEndTime - $fileStartTime).TotalMilliseconds;
            $fileLogSeverity = "INFO"; if ($fileProcessingStatus -like "error*") { $fileLogSeverity = "ERROR" } elseif ($fileProcessingStatus -eq "partial_error") { $fileLogSeverity = "WARN" }
            $fileEventDetails.processing_time_ms = [math]::Round($processingTimeMs)
            if ($fileProcessingStatus -eq "error_event") { $fileEventDetails.event_sending_error = $true }

            $fileEventBody = @{ event_type = "FILE_PROCESSED"; severity = $fileLogSeverity; message = $fileProcessingMessage; source = "result_loader.ps1 (v$ScriptVersion)"; related_entity = "FILE"; related_entity_id = $file.Name; details = $fileEventDetails }
            $fileEventJsonBody = $fileEventBody | ConvertTo-Json -Compress -Depth 5 -WarningAction SilentlyContinue;
            $apiUrlEvents = "$EffectiveApiBaseUrl/v1/events";
            $headersForEvent = @{ 'Content-Type' = 'application/json; charset=utf-8'; 'X-API-Key' = $script:EffectiveApiKey }
            $eventApiParams = @{ Uri = $apiUrlEvents; Method = 'Post'; Body = [System.Text.Encoding]::UTF8.GetBytes($fileEventJsonBody); Headers = $headersForEvent; Description = "�������� ������� FILE_PROCESSED ��� '$($file.Name)'" }

            Write-Log ("�������� ������� FILE_PROCESSED ��� '$($file.Name)' (������: $fileProcessingStatus)...") "Info"
            $eventResponse = Invoke-ApiRequestWithRetry @eventApiParams

            if ($eventResponse -eq $null) {
                 Write-Log ("�� ������� ��������� ������� FILE_PROCESSED ��� '$($file.Name)'. �������� ������ ��� 'error_event'.") "Error";
                 $fileProcessingStatus = "error_event"
            } else {
                $eventId = if ($eventResponse -is [PSCustomObject] -and $eventResponse.PSObject.Properties.Name.Contains('event_id')) { $eventResponse.event_id } else { '(id ?)' };
                Write-Log ("������� FILE_PROCESSED ��� '$($file.Name)' ����������. Event ID: $eventId") "Info"
            }

            # --- ����������� ����� ---
            $destinationFolder = if ($fileProcessingStatus -like "success*") { $processedFolder } else { $errorFolder };
            $destinationPath = Join-Path $destinationFolder $file.Name;
            # <<<< ����������: ����������� ������ �� ������ Write-Log >>>>
            $moveLogMsg = "����������� '{0}' � '{1}' (�������� ������: {2})." -f $file.Name, $destinationFolder, $fileProcessingStatus
            Write-Log $moveLogMsg "Info";
            try {
                Move-Item -Path $file.FullName -Destination $destinationPath -Force -ErrorAction Stop;
                Write-Log ("���� '$($file.Name)' ������� ���������.") "Info"
            } catch {
                 # <<<< ����������: ����������� ������ �� ������ Write-Log >>>>
                 Write-Log ("����������� ������ ����������� ����� '{0}' � '{1}'. ���� ����� ���� ��������� ��������! ������: {2}" -f $file.Name, $destinationPath, $_.Exception.Message) "Error";
            }

            Write-Log "--- ���������� ��������� �����: '$($file.FullName)' ---" "Info"

        } # ����� foreach ($file in $filesToProcess)
    } # ����� else ($filesToProcess.Count -eq 0)

    # --- ����� ����� ��������� ������������� ---
    Write-Log "����� $script:EffectiveScanIntervalSeconds ��� ����� ��������� �������������..." "Verbose"
    Start-Sleep -Seconds $script:EffectiveScanIntervalSeconds

} # --- ����� while ($true) ---

Write-Log "��������� ����������� �������� ������ ������������� (����� �� ����� while)." "Error"
exit 1