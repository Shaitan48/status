# powershell\offline-agent\offline-agent.ps1
# �������-����� ����������� v3.1.
# ���������� ���������� assignment_id � �����������.
<#
.SYNOPSIS
    �������-����� ������� ����������� Status Monitor v3.1.
.DESCRIPTION
    ������������ ��� ������ � ������������� ����� ��� ������� � API.
    1. ������ ��������� ������������ ������ ('config.json').
    2. ������������ ��������� ������� ����� � ���������
       � ����� 'assignments_file_path'.
    3. ��� ����������� ������ ����� �������:
       - ������ JSON-����������.
       - ��������� ������ 'assignments' � 'assignment_config_version'.
       - ��������� �� ��� ����������.
    4. � ����� ��������� ��� �������� ������� � �������
       Invoke-StatusMonitorCheck �� ������ StatusMonitorAgentUtils.
    5. �������� ������������������� ���������� ���� ��������.
    6. **������� ����� ������ ��� ������� ����������, ���������
       ����������� ��������� � 'assignment_id'.**
    7. ��������� �������� JSON-���� (*.zrpu) � ����� 'output_path',
       ������� ���������� (������ ������ � �������) � ������ 'results'.
    8. ���� *.zrpu ���� ����� ���������� � ����������� �� ������.
.NOTES
    ������: 3.1
    ����: 2024-05-20
    ��������� v3.1:
        - ��������� ������ ���������� 'assignment_id' � �����������. ������
          Add-Member ������ ��������� ����� ������ ����� ������� ���-������.
    ��������� v3.0:
        - ������� �������� ���� 'assignment_id' � ������� �������� � ������� 'results'.
    �����������: PowerShell 5.1+, ������ StatusMonitorAgentUtils, ������� ����� ������������ �������.
#>

param (
    # ���� � ����� ������������ ������.
    [string]$configFile = "$PSScriptRoot\config.json",

    # ��������� ��� ��������������� ���-����� � ������ ����������� �� ��������� ������.
    [string]$paramLogFile = $null,
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
    [string]$paramLogLevel = $null
)

# --- �������� ������ Utils ---
$ErrorActionPreference = "Stop"
try {
    $ModuleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1"
    Write-Host "[INFO] �������� ������ '$ModuleManifestPath'..."
    Import-Module $ModuleManifestPath -Force -ErrorAction Stop
    Write-Host "[INFO] ������ Utils ��������."
} catch {
    Write-Host "[CRITICAL] ����������� ������ �������� ������ '$ModuleManifestPath': $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    $ErrorActionPreference = "Continue"
}
# --- ����� �������� ������ ---

# --- ���������� ���������� ---
# ������ �������� ������� �������-������
$AgentScriptVersion = "agent_script_v3.1" # �������� ������

# ��� ����������
$script:ComputerName = $env:COMPUTERNAME
# ������� ������ ������� (������ �������� PSCustomObject �� ����� ������������)
$script:currentAssignments = $null
# ������� ������ ����� ������������ ������� (������ �� �����)
$script:currentAssignmentVersion = $null
# ���� � ���������� ������������� ����� ������������ �������
$script:lastProcessedConfigFile = $null
# ������ � ������������� ������ ������ (�� config.json)
$script:localConfig = $null
# ���� � ���-����� ������
$script:logFile = $null
# ������������� ������� �����������
$script:LogLevel = "Info"
# ���������� ������ �����������
$ValidLogLevels = @("Debug", "Verbose", "Info", "Warn", "Error")


# --- ������� ---

#region �������

<#
.SYNOPSIS ���������� ��������� � ���.
#>
function Write-Log{
    param( [Parameter(Mandatory=$true)][string]$Message, [ValidateSet("Debug","Verbose","Info","Warn","Error",IgnoreCase=$true)] [string]$Level="Info" ); if (-not $script:localConfig -or -not $script:logFile) { Write-Host "[$Level] $Message"; return }; $logLevels=@{"Debug"=4;"Verbose"=3;"Info"=2;"Warn"=1;"Error"=0}; $effectiveLogLevel = $script:LogLevel; if(-not $logLevels.ContainsKey($effectiveLogLevel)){ $effectiveLogLevel="Info" }; $currentLevelValue = $logLevels[$effectiveLogLevel]; $messageLevelValue = $logLevels[$Level]; if($null -eq $messageLevelValue){ $messageLevelValue=$logLevels["Info"] }; if($messageLevelValue -le $currentLevelValue){ $timestamp=Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage="[$timestamp] [$Level] [$script:ComputerName] - $Message"; $consoleColor = switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}; Write-Host $logMessage -ForegroundColor $consoleColor; if($script:logFile){ try { $logDir = Split-Path $script:logFile -Parent; if($logDir -and (-not(Test-Path $logDir -PathType Container))){ Write-Host "[INFO] �������� ����� �����: '$logDir'."; New-Item -Path $logDir -ItemType Directory -Force -EA Stop | Out-Null }; Add-Content -Path $script:logFile -Value $logMessage -Encoding UTF8 -Force -EA Stop } catch { Write-Host "[CRITICAL] ������ ������ � ��� '$script:logFile': $($_.Exception.Message)" -ForegroundColor Red; try { $fallbackLog = "$PSScriptRoot\offline_agent_fallback.log"; Add-Content -Path $fallbackLog -Value $logMessage -Encoding UTF8 -Force -EA SilentlyContinue; Add-Content -Path $fallbackLog -Value "[CRITICAL] ������ ������ � '$script:logFile': $($_.Exception.Message)" -Encoding UTF8 -Force -EA SilentlyContinue } catch {} } } }
}

<#
.SYNOPSIS ���������� �������� �� ���������, ���� ������� �������� �����.
#>
filter Get-OrElse_Internal{ param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }

#endregion �������

# --- �������� ��� ������ ---

# 1. ������ � ��������� ������������ ������
# ... (��� ������ � ��������� ������� ��� ���������) ...
Write-Host "�������-����� ����������� v$AgentScriptVersion"; Write-Host "������ ������������ ������: $configFile"
if(-not(Test-Path $configFile -PathType Leaf)){ Write-Error "����������� ������: ���� ������������ '$configFile' �� ������."; exit 1 }
try { $script:localConfig = Get-Content -Path $configFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Error "����������� ������: ������ ������/�������� JSON �� '$configFile': $($_.Exception.Message)"; exit 1 }
$requiredLocalConfigFields = @("object_id","output_path","output_name_template","assignments_file_path","logFile","LogLevel","check_interval_seconds"); $missingFields = $requiredLocalConfigFields | Where-Object { -not ($script:localConfig.PSObject.Properties.Name.Contains($_)) -or $null -eq $script:localConfig.$_ -or ($script:localConfig.$_ -is [string] -and [string]::IsNullOrWhiteSpace($script:localConfig.$_))}; if($missingFields){ Write-Error "����������� ������: �����������/����� ������������ ���� � '$configFile': $($missingFields -join ', ')"; exit 1 }
$script:logFile = if($PSBoundParameters.ContainsKey('paramLogFile') -and $paramLogFile){ $paramLogFile } else { $script:localConfig.logFile }; $script:LogLevel = if($PSBoundParameters.ContainsKey('paramLogLevel') -and $paramLogLevel){ $paramLogLevel } else { $script:localConfig.LogLevel }; if(-not $ValidLogLevels.Contains($script:LogLevel)){ Write-Host "[WARN] ������������ LogLevel '$($script:LogLevel)'. ������������ 'Info'." -ForegroundColor Yellow; $script:LogLevel = "Info" }; $checkInterval = 60; if($script:localConfig.check_interval_seconds -and [int]::TryParse($script:localConfig.check_interval_seconds,[ref]$null) -and $script:localConfig.check_interval_seconds -ge 5){ $checkInterval = $script:localConfig.check_interval_seconds } else { Write-Log "������������ �������� check_interval_seconds ('$($script:localConfig.check_interval_seconds)'). ������������ $checkInterval ���." "Warn" }
$objectId = $script:localConfig.object_id; $outputPath = $script:localConfig.output_path; $outputNameTemplate = $script:localConfig.output_name_template; $assignmentsFolderPath = $script:localConfig.assignments_file_path


# 2. ������������� � �������� �����
# ... (��� ������������� � �������� ����� ��� ���������) ...
Write-Log "�������-����� �������. ������: $AgentScriptVersion. ��� �����: $script:ComputerName" "Info"; Write-Log ("���������: ObjectID={0}, ��������={1} ���, ����� �������='{2}', ����� �����������='{3}'" -f $objectId, $checkInterval, $assignmentsFolderPath, $outputPath) "Info"; Write-Log "����������� � '$script:logFile' � ������� '$script:LogLevel'" "Info"; if(-not(Test-Path $outputPath -PathType Container)){ Write-Log "����� ��� ����������� '$outputPath' �� �������. ������� �������..." "Warn"; try { New-Item -Path $outputPath -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "����� '$outputPath' ������� �������." "Info" } catch { Write-Log "����������� ������: �� ������� ������� ����� ��� ����������� '$outputPath': $($_.Exception.Message)" "Error"; exit 1 } }; if(-not(Test-Path $assignmentsFolderPath -PathType Container)){ Write-Log "����������� ������: ����� ��� ������ ������� '$assignmentsFolderPath' �� �������." "Error"; exit 1 }


# --- 3. �������� ���� ������ ������ ---
Write-Log "������ ��������� ����� ������..." "Info"
while ($true) {
    $cycleStartTime = Get-Date
    Write-Log "������ �������� ����� ($($cycleStartTime.ToString('s')))." "Verbose"

    # --- 3.1 ����� � ������ ����� ������������ ������� ---
    # ... (��� ������ � ������ ����� ������� ��� ���������) ...
    $latestConfigFile = $null; $configError = $null; $configData = $null
    try { $configFileNamePattern = "*_${objectId}_*_assignments.json.status.*"; Write-Log "����� ����� ������������ � '$assignmentsFolderPath' �� ������� '$configFileNamePattern'..." "Debug"; $foundFiles = Get-ChildItem -Path $assignmentsFolderPath -Filter $configFileNamePattern -File -ErrorAction SilentlyContinue; if ($Error.Count -gt 0 -and $Error[0].CategoryInfo.Category -eq 'ReadError') { throw ("������ ������� ��� ������ ����� ������������ � '$assignmentsFolderPath': " + $Error[0].Exception.Message); $Error.Clear() }; if ($foundFiles) { $latestConfigFile = $foundFiles | Sort-Object Name -Descending | Select-Object -First 1; Write-Log "������ ��������� ���� ������������: $($latestConfigFile.FullName)" "Verbose" } else { Write-Log "����� ������������ ��� ObjectID $objectId � '$assignmentsFolderPath' �� �������." "Warn" } } catch { $configError = "������ ������ ����� ������������: $($_.Exception.Message)"; Write-Log $configError "Error" }
    if ($latestConfigFile -ne $null -and $configError -eq $null) { if ($latestConfigFile.FullName -ne $script:lastProcessedConfigFile) { Write-Log "��������� �����/����������� ���� ������������: $($latestConfigFile.Name). ������..." "Info"; $tempAssignments = $null; $tempVersionTag = $null; try { $fileContent = Get-Content -Path $latestConfigFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop; $fileContentClean = $fileContent.TrimStart([char]0xFEFF); $configData = $fileContentClean | ConvertFrom-Json -ErrorAction Stop; if ($null -eq $configData -or (-not $configData.PSObject.Properties.Name.Contains('assignments')) -or ($configData.assignments -isnot [array]) -or (-not $configData.PSObject.Properties.Name.Contains('assignment_config_version')) -or (-not $configData.assignment_config_version) ) { throw ("���� '$($latestConfigFile.Name)' ����� ������������ ��������� JSON...") }; $tempVersionTag = $configData.assignment_config_version; $tempAssignments = $configData.assignments; Write-Log ("���� '{0}' ������� ��������..." -f $latestConfigFile.Name, $tempAssignments.Count, $tempVersionTag) "Info"; $script:currentAssignments = $tempAssignments; $script:currentAssignmentVersion = $tempVersionTag; $script:lastProcessedConfigFile = $latestConfigFile.FullName; Write-Log "������ ������� �������� (������: $tempVersionTag)..." "Info" } catch { $errorMsg = "����������� ������ ��������� ����� '$($latestConfigFile.Name)': $($_.Exception.Message)"; Write-Log $errorMsg "Error"; Write-Log ("���������� ������������ ���������� ������ ������� (������: {0})." -f ($script:currentAssignmentVersion | Get-OrElse_Internal '[����������]')) "Warn" } } else { Write-Log "���� ������������ '$($latestConfigFile.Name)' �� ���������." "Verbose" } } elseif ($configError -ne $null) { Write-Log "���������� ������������ ���������� ������ �������..." "Warn" } elseif ($script:lastProcessedConfigFile -ne $null) { Write-Log "����� ������������ �� �������. ���������� ������������ ���������� ������..." "Warn" } else { Write-Log "����� ������������ �� �������..." "Info" }

    # --- 3.2 ���������� �������� ������ ������� ---
    $cycleCheckResultsList = [System.Collections.Generic.List[object]]::new()

    if ($script:currentAssignments -ne $null -and $script:currentAssignments.Count -gt 0) {
        $assignmentsCount = $script:currentAssignments.Count
        Write-Log "������ ���������� $assignmentsCount ������� (������ �������: $($script:currentAssignmentVersion | Get-OrElse_Internal 'N/A'))..." "Info"
        $completedCount = 0

        foreach ($assignmentRaw in $script:currentAssignments) {
            $completedCount++
            $assignment = [PSCustomObject]$assignmentRaw
            Write-Log "���������� $completedCount/$assignmentsCount (ID: $($assignment.assignment_id))..." "Verbose"

            if ($null -eq $assignment -or $null -eq $assignment.assignment_id -or -not $assignment.method_name) {
                Write-Log "��������� ������������ ������� � ������: $($assignment | Out-String)" "Warn"
                # --- ��������: ������� ������ ������ ����� ������� ---
                $errorDetails = @{ assignment_object = ($assignment | Out-String) }
                $errorResultBase = New-CheckResultObject -IsAvailable $false `
                                      -ErrorMessage "������������ ��������� ������� � ����� ������������." `
                                      -Details $errorDetails
                $idPart = @{ assignment_id = ($assignment.assignment_id | Get-OrElse_Internal $null) }
                $errorResultToSave = $idPart + $errorResultBase
                $cycleCheckResultsList.Add($errorResultToSave)
                # --- ����� ��������� ---
                continue
            }

            $checkResult = $null
            try {
                # �������� ��������� ��������
                $checkResult = Invoke-StatusMonitorCheck -Assignment $assignment `
                                                        -Verbose:$VerbosePreference `
                                                        -Debug:$DebugPreference

                Write-Log ("��������� ID {0}: IsAvailable={1}, CheckSuccess={2}, Error='{3}'" -f `
                           $assignment.assignment_id, $checkResult.IsAvailable, $checkResult.CheckSuccess, $checkResult.ErrorMessage) "Verbose"

                # --- ��������: ������� ����� ������ ���������� � ID ����� ������� ---
                $idPart = @{ assignment_id = $assignment.assignment_id }
                $resultToSave = $idPart + $checkResult
                # --- ����� ��������� ---

                # ���������� ����� (���� ������� Debug)
                Write-Debug ("������ �� ���������� � ������ (ID: {0}): {1}" -f `
                             $assignment.assignment_id, ($resultToSave | ConvertTo-Json -Depth 4 -Compress))

                # ��������� ��������� � ������ ��� �����
                $cycleCheckResultsList.Add($resultToSave)

            } catch {
                 # ��������� ����������� ������ ���������� Invoke-StatusMonitorCheck
                 $errorMessage = "����������� ������ ��� ���������� ������� ID $($assignment.assignment_id): $($_.Exception.Message)"
                 Write-Log $errorMessage "Error"
                 # ������� ������ �� ������
                 $errorDetails = @{ ErrorRecord = $_.ToString() }
                 $errorResultBase = New-CheckResultObject -IsAvailable $false `
                                      -ErrorMessage $errorMessage `
                                      -Details $errorDetails
                 # --- ��������: ������� ����� ������ ������ � ID ����� ������� ---
                 $idPart = @{ assignment_id = $assignment.assignment_id }
                 $errorResultToSave = $idPart + $errorResultBase
                 # --- ����� ��������� ---

                 # ���������� ����� ��� ������
                 Write-Debug ("������ ������ �� ���������� � ������ (ID: {0}): {1}" -f `
                              $assignment.assignment_id, ($errorResultToSave | ConvertTo-Json -Depth 4 -Compress))

                 # ��������� ��������� � ������� � ����� ������
                 $cycleCheckResultsList.Add($errorResultToSave)
            }
        } # ����� foreach assignment

        Write-Log "���������� $assignmentsCount ������� ���������. ������� �����������: $($cycleCheckResultsList.Count)." "Info"

    } else {
        Write-Log "��� �������� ������� ��� ���������� � ���� ��������." "Verbose"
    }

    # --- 3.3 ������������ � ���������� ����� ����������� (*.zrpu) ---
    if ($cycleCheckResultsList.Count -gt 0) {
        # ... (��� ������������ $finalPayload � ���������� ����� ��� ���������) ...
        $finalPayload = @{ agent_script_version = $AgentScriptVersion; assignment_config_version = $script:currentAssignmentVersion; results = $cycleCheckResultsList }
        $timestampForFile = Get-Date -Format "ddMMyy_HHmmss"; $outputFileName = $outputNameTemplate -replace "{object_id}", $objectId -replace "{ddMMyy_HHmmss}", $timestampForFile; $outputFileName = $outputFileName -replace '[\\/:*?"<>|]', '_'; $outputFileFullPath = Join-Path $outputPath $outputFileName
        Write-Log "���������� $($cycleCheckResultsList.Count) ����������� � ����: '$outputFileFullPath'" "Info"; Write-Log ("������ ������: {0}, ������ ������� �������: {1}" -f $AgentScriptVersion, ($script:currentAssignmentVersion | Get-OrElse_Internal 'N/A')) "Verbose"
        try { $jsonToSave = $finalPayload | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue; $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllText($outputFileFullPath, $jsonToSave, $Utf8NoBomEncoding); Write-Log "���� ����������� '$outputFileName' ������� ��������." "Info" }
        catch { Write-Log "����������� ������ ���������� ����� ����������� '$outputFileFullPath': $($_.Exception.Message)" "Error" }
    } else {
        Write-Log "��� ����������� ��� ���������� � ���� � ���� ��������." "Verbose"
    }

    # --- 3.4 ����� ����� ��������� ��������� ---
    # ... (��� ������� ����� � Start-Sleep ��� ���������) ...
    $cycleEndTime = Get-Date; $elapsedSeconds = ($cycleEndTime - $cycleStartTime).TotalSeconds; $sleepSeconds = $checkInterval - $elapsedSeconds; if ($sleepSeconds -lt 1) { $sleepSeconds = 1 }
    Write-Log ("�������� ������ {0:N2} ���. ����� {1:N2} ��� �� ���������� �����..." -f $elapsedSeconds, $sleepSeconds) "Verbose"; Start-Sleep -Seconds $sleepSeconds

} # --- ����� while ($true) ---

Write-Log "�������-����� ��������� ������ (����������� ����� �� ��������� �����)." "Error"
exit 1