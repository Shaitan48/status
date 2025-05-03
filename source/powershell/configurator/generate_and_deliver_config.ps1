# powershell\configurator\generate_and_deliver_config.ps1 (������ 3.6 - ������ JSON, ��� .zrpu)
<#
.SYNOPSIS
    ���������� � ���������� ���������������� ����� ��� �������-������� v4.4+.
    ���� �������� ������ JSON (���������� + ������� + ���).
    ��� ����� ����������� ��� .zrpu.
.NOTES
    ������: 3.6
    ����: 2024-05-19 (��� ����������)
    ���������:
        - ��������� ���� JSON ����� �� API /offline_config.
        - ����� ������� .zrpu �� ����� �����.
        - ��������� �������� �� ������� ������������ ����� � ������ API.
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\config.json",
    [string]$ParamLogFile = $null,
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)]
    [string]$ParamLogLevel = $null
)

# --- ��������������� ������� (Sanitize-String, Write-Log, Get-OrElse) ---
filter Get-OrElse { param([object]$DefaultValue); if ($_) { $_ } else { $DefaultValue } }
function Sanitize-String { param([Parameter(Mandatory=$true)][string]$InputString,[string]$ReplacementChar=''); if($null-eq$InputString){return $null};try{return $InputString -replace '\p{C}',$ReplacementChar}catch{Write-Warning "������ ����������� ������: $($_.Exception.Message)";return $InputString} }
function Write-Log { param ([Parameter(Mandatory=$true)][string]$Message, [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", IgnoreCase = $true)][string]$Level = "Info"); if (-not $script:Config -or -not $script:Config.log_file) { Write-Host "[$Level] $Message"; return }; $logLevels = @{ "Debug" = 4; "Verbose" = 3; "Info" = 2; "Warn" = 1; "Error" = 0 }; $currentLevelValue = $logLevels[$script:EffectiveLogLevel]; if ($null -eq $currentLevelValue) { $currentLevelValue = $logLevels["Info"] }; $messageLevelValue = $logLevels[$Level]; if ($null -eq $messageLevelValue) { $messageLevelValue = $logLevels["Info"] }; if ($messageLevelValue -le $currentLevelValue) { $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $logMessage = "[$timestamp] [$Level] - $Message"; Write-Host $logMessage -ForegroundColor $(switch($Level){"Error"{"Red"};"Warn"{"Yellow"};"Info"{"White"};"Verbose"{"Gray"};"Debug"{"DarkGray"};Default{"Gray"}}); try { $logDir = Split-Path $script:Config.log_file -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { Write-Host "[INFO] �������� ����� ��� ����: '$logDir'"; New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }; $logMessage | Out-File -FilePath $script:Config.log_file -Append -Encoding UTF8 -ErrorAction Stop } catch { Write-Host "[Error] ���������� �������� � ��� '$($script:Config.log_file)': $($_.Exception.Message)" -ForegroundColor Red } } }

# --- ������ ������� ---
$ScriptVersion = "3.6"
$script:Config = $null
$script:EffectiveLogLevel = "Info"
$script:ApiKey = $null

# --- ��� 1: ������ � ��������� ������������ ---
Write-Host "�������� ������������ �� �����: $ConfigFile"
if (-not (Test-Path $ConfigFile -PathType Leaf)) { Write-Error "����������� ������: ���� ������������ '$ConfigFile' �� ������."; exit 1 }
try { $script:Config = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Error "����������� ������: ������ ������/�������� JSON '$ConfigFile'. ������: $($_.Exception.Message)"; exit 1 }
# �������� ���� ������������ �����
$requiredConfigFields = @("api_base_url", "api_key", "output_path_base", "delivery_path_base", "log_file", "log_level", "subdivision_ids_to_process", "output_filename_template", "delivery_subdir_template")
$missingFields = $requiredConfigFields | Where-Object { -not $script:Config.PSObject.Properties.Name.Contains($_) }
if ($missingFields) { Write-Error "����������� ������: � '$ConfigFile' ����������� ����: $($missingFields -join ', ')"; exit 1 }
# �������� ���� subdivision_ids_to_process
if ($script:Config.subdivision_ids_to_process -isnot [array]) { Write-Error "����������� ������: 'subdivision_ids_to_process' ������ ���� ��������."; exit 1 }
# ��������������� logFile � logLevel �� ����������, ���� ��������
if ($ParamLogFile) { $script:Config.log_file = $ParamLogFile }
if ($ParamLogLevel) { $script:Config.log_level = $ParamLogLevel }
# ��������� LogLevel
$validLogLevelsMap = @{ "Debug" = 0; "Verbose" = 1; "Info" = 2; "Warn" = 3; "Error" = 4 }
if (-not $validLogLevelsMap.ContainsKey($script:Config.log_level)) { Write-Host "[WARN] ������������ LogLevel '$($script:Config.log_level)'. ������������ 'Info'." -F Yellow; $script:Config.log_level = "Info" }
$script:EffectiveLogLevel = $script:Config.log_level
$script:ApiKey = $script:Config.api_key

# --- ��� 2: ������������� � ����������� ---
$logDir = Split-Path $script:Config.log_file -Parent; if ($logDir -and (-not (Test-Path $logDir -PathType Container))) { Write-Host "[INFO] �������� ����� ����: '$logDir'..."; try { New-Item -Path $logDir -ItemType Directory -Force -EA Stop | Out-Null } catch { Write-Error "�����������: �� ������� ������� ����� ���� '$logDir': $($_.Exception.Message)"; exit 1 } }
Write-Log "������ ������������� (v$ScriptVersion) �������." "Info"
Write-Log "������������ �� '$ConfigFile'" "Verbose"
Write-Log "API URL: $($script:Config.api_base_url)" "Verbose"
$apiKeyPartial = "[�� �����]"; if($script:ApiKey){$len=$script:ApiKey.Length;$p=$script:ApiKey.Substring(0,[math]::Min(4,$len));$s=if($len -gt 8){$script:ApiKey.Substring($len-4,4)}else{""};$apiKeyPartial="$p....$s"}; Write-Log "API Key (��������): $apiKeyPartial" "Debug";
Write-Log "����� ������: $($script:Config.output_path_base)" "Verbose"
Write-Log "����� ��������: $($script:Config.delivery_path_base | Get-OrElse '[�� ������]')" "Verbose"
Write-Log "������ ����� �����: $($script:Config.output_filename_template)" "Verbose" # ������ .zrpu
Write-Log "������ �������� ��������: $($script:Config.delivery_subdir_template)" "Verbose"
Write-Log "������ ID ��� ���������: $($script:Config.subdivision_ids_to_process -join ', ' | Get-OrElse '[���� (��� � ����� ��)]')" "Verbose"

# --- ��� 3: ����������� ������ ObjectId ��� ��������� ---
$objectIdsToProcess = @()
Write-Log "������ 'subdivision_ids_to_process'..." "Info"
if ($script:Config.subdivision_ids_to_process.Count -gt 0) {
    Write-Log "��������� ������ ID � �������. ��������� ���: $($script:Config.subdivision_ids_to_process -join ', ')" "Info"
    $objectIdsToProcess = $script:Config.subdivision_ids_to_process | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    if ($objectIdsToProcess.Count -ne $script:Config.subdivision_ids_to_process.Count) { Write-Log "��������������: ���������� �������� � 'subdivision_ids_to_process' ���������������." "Warn" }
} else {
    Write-Log "������ ID � ������� ���� (`[]`). ����������� ��� ������������� � ����� �� �� API..." "Info"
    $apiUrlSubdivisions = "$($script:Config.api_base_url.TrimEnd('/'))/v1/subdivisions?limit=1000" # ������ ����
    $headers = @{ 'X-API-Key' = $script:ApiKey }
    try {
        Write-Log "������: GET $apiUrlSubdivisions" "Verbose"
        $response = Invoke-RestMethod -Uri $apiUrlSubdivisions -Method Get -Headers $headers -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse 60) -ErrorAction Stop
        if ($response -and $response.items -is [array]) {
            $subdivisions = $response.items
            # ��������� �� ������� transport_system_code � object_id
            $objectIdsToProcess = $subdivisions | Where-Object { $_.transport_system_code -and $_.object_id } | Select-Object -ExpandProperty object_id
            Write-Log "�������� $($subdivisions.Count) �������������. ������� ��� ��������� (� ����� ��): $($objectIdsToProcess.Count)" "Info"
            if ($objectIdsToProcess.Count -eq 0 -and $subdivisions.Count -gt 0) { Write-Log "��������������: �� � ������ ������������� �� API �� ����� transport_system_code." "Warn" }
        } else { Write-Log "����� API /subdivisions �� �������� ��������� ������ 'items'." "Warn" }
    } catch {
        $rawErrorMessage = $_.Exception.Message; $responseBody="[N/A]"; $statusCode=$null; if($_.Exception.Response){try{$statusCode=$_.Exception.Response.StatusCode}catch{}; try{$stream=[System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream());$responseBody=$stream.ReadToEnd();$stream.Close()}catch{$responseBody="[Read Error]"}};
        $cleanErrorMessage = Sanitize-String -InputString $rawErrorMessage; $cleanResponseBody = Sanitize-String -InputString $responseBody; $finalLogMessage = "${cleanErrorMessage} - Code: $($statusCode|Get-OrElse 'N/A') - Resp: ${cleanResponseBody}"
        Write-Log "����������� ������ ��������� ������ ������������� �� API ($apiUrlSubdivisions): $finalLogMessage" "Error"
        Write-Log "��������� ����������� API, API ���� � ����� �������. ���������� ������." "Error"
        exit 1
    }
}

if ($objectIdsToProcess.Count -eq 0) { Write-Log "��� ObjectId ��� ���������. ����������." "Info"; exit 0 }

# --- ��� 4: ���� ��������� ������� ObjectId ---
Write-Log "������ ����� ��������� ��� $($objectIdsToProcess.Count) �������������: $($objectIdsToProcess -join ', ')" "Info"
foreach ($currentObjectId in $objectIdsToProcess) {
    Write-Log "--- ��������� ObjectId: $currentObjectId ---" "Info"
    # 1. ������ ������������
    $apiUrlConfig = "$($script:Config.api_base_url.TrimEnd('/'))/v1/objects/${currentObjectId}/offline_config"
    $apiResponse = $null
    $headersConfig = @{ 'X-API-Key' = $script:ApiKey }
    Write-Log "������ ������������: GET $apiUrlConfig" "Verbose"
    try {
        $apiResponse = Invoke-RestMethod -Uri $apiUrlConfig -Method Get -Headers $headersConfig -TimeoutSec ($script:Config.api_timeout_sec | Get-OrElse 60) -ErrorAction Stop

        # <<< �������� ������ API �� ������� ������������ ����� >>>
        if (-not ($apiResponse -is [PSCustomObject]) -or
            (-not $apiResponse.PSObject.Properties.Name.Contains('assignment_config_version')) -or
            (-not $apiResponse.PSObject.Properties.Name.Contains('transport_system_code')) -or
            (-not $apiResponse.PSObject.Properties.Name.Contains('assignments')) -or
            ($apiResponse.assignments -isnot [array]))
        {
            # ���� ��������� �� ��, �� ���� ���� error �� API
            if($apiResponse -is [PSCustomObject] -and $apiResponse.error -and $apiResponse.message){
                throw "API ������ ������: ��� '$($apiResponse.error)', ��������� '$($apiResponse.message)'"
            } else {
                throw "������������ ��������� ������ API /offline_config ��� ����������� ������������ ���� (assignment_config_version, transport_system_code, assignments) ��� ObjectId ${currentObjectId}."
            }
        }

        # <<< ��������� ������ ����� �������� >>>
        $versionTag = $apiResponse.assignment_config_version
        $transportCode = $apiResponse.transport_system_code
        $assignmentCount = $apiResponse.assignments.Count
        Write-Log "������������ ��������. ������: ${versionTag}. �������: ${assignmentCount}. ��� ��: ${transportCode}." "Info"

    } catch {
        $exceptionMessage = $_.Exception.Message; $responseBody = "[��� ���� ������]"; $statusCode = $null;
        if ($_.Exception.Response) { try {$statusCode = $_.Exception.Response.StatusCode} catch {}; try {$errorStream = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $responseBody = $errorStream.ReadToEnd(); $errorStream.Close()} catch {$responseBody = "[������ ������ ���� ������]"} };
        $logErrorMessage = "������ ��������� ������������ �� API ��� ObjectId ${currentObjectId}: $($exceptionMessage)";
        if ($statusCode -eq 401 -or $statusCode -eq 403) { $logErrorMessage += " (��������� API ���� � ����� ������� 'configurator'!)"; }
        else { $logErrorMessage += " - Code: $($statusCode | Get-OrElse 'N/A') - Resp: $responseBody"; };
        Write-Log $logErrorMessage "Error";
        continue # ���������� ���� ID � ��������� � ����������
    }

    # 2. ������������ ����� ����� (��� .zrpu)
    $outputFileNameBase = $script:Config.output_filename_template -replace "{version_tag}", $versionTag -replace "{transport_code}", $transportCode
    # ������� ������������ ������� �� ����� �����
    $outputFileName = $outputFileNameBase -replace '[\\/:*?"<>|]', '_'
    # �������� ������ ����
    $outputFilePath = Join-Path -Path $script:Config.output_path_base -ChildPath $outputFileName
    $outputDir = Split-Path $outputFilePath -Parent

    # 3. �������� ����� ������, ���� � ���
    if (-not (Test-Path $outputDir -PathType Container)) {
        Write-Log "�������� ����� ������ '$outputDir'" "Verbose"
        try { New-Item -Path $outputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        catch { Write-Log "������ �������� ����� ������ '$outputDir'. ������� ${currentObjectId}. Error: $($_.Exception.Message)" "Error"; continue }
    }

    # 4. ���������� ������� JSON ������ API � ����
    Write-Log "���������� ������ ������������ � ����: $outputFilePath" "Verbose"
    try {
        # ����������� ������ PowerShell � �������� JSON ������
        $jsonToSave = $apiResponse | ConvertTo-Json -Depth 10 -WarningAction SilentlyContinue
        # ���������� WriteAllText ��� ������ ������ � UTF-8 ��� BOM
        $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($outputFilePath, $jsonToSave, $Utf8NoBomEncoding)
        Write-Log "���� ������������ '$outputFileName' �������� � '$outputDir'." "Info"
    } catch {
        Write-Log "������ ���������� ����� '$outputFilePath'. ������� ${currentObjectId}. Error: $($_.Exception.Message)" "Error"
        continue
    }

    # 5. �������� ����� (���� delivery_path_base �����)
    if ($script:Config.delivery_path_base) {
        $deliverySubDir = $script:Config.delivery_subdir_template -replace "{transport_code}", $transportCode
        $deliveryPath = Join-Path -Path $script:Config.delivery_path_base -ChildPath $deliverySubDir
        $deliveryFileName = $outputFileName # ��� ����� ��� ������������ ���������
        $deliveryFilePath = Join-Path -Path $deliveryPath -ChildPath $deliveryFileName
        Write-Log "�������� ���� ��������: $deliveryFilePath" "Info"

        # ������� ����� ��������, ���� �� ���
        if (-not (Test-Path $deliveryPath -PathType Container)) {
            Write-Log "����� �������� '$deliveryPath' �� �������. ��������..." "Warn"
            try { New-Item -Path $deliveryPath -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "����� '$deliveryPath' �������." "Verbose" }
            catch { Write-Log "������ �������� ����� �������� '$deliveryPath'. ������� ��������. Error: $($_.Exception.Message)" "Error"; }
        }

        # �������� ����, ���� ����� �������� ����������
        if (Test-Path $deliveryPath -PathType Container) {
            Write-Log "����������� '$outputFilePath' -> '$deliveryFilePath'" "Verbose"
            try { Copy-Item -Path $outputFilePath -Destination $deliveryFilePath -Force -ErrorAction Stop; Write-Log "���� '$outputFileName' ��������� � '$deliveryPath'." "Info" }
            catch { Write-Log "������ ����������� � '$deliveryFilePath'. Error: $($_.Exception.Message)" "Error"; }
        }
    } else { Write-Log "delivery_path_base �� �����. ������� ��������." "Info" }

    Write-Log "--- ��������� ObjectId: $currentObjectId ��������� ---" "Info"
} # --- ����� ����� foreach ---

Write-Log "������ ������� ������������� ������� ���������." "Info"