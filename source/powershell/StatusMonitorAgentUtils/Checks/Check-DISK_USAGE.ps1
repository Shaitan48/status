<#
.SYNOPSIS
    ������ �������� ������������� ��������� ������������.
.DESCRIPTION
    �������� ���������� � ���������� ������ (�����, ��������� �����)
    � ������� Get-Volume. ��������� ����������� ����� � ���������
    ������������ ��������� ������ (����������� % ���������� �����).
    ���������� ������������������� ������ ����������.
.PARAMETER TargetIP
    [string] IP ��� ��� ����� ��� �������� (���������� �����������).
    ������������ ���� ��������, �.�. Get-Volume �� ���������� -ComputerName
    �������� ��� ��������� ������ ����� Invoke-Command. ��������� ���
    ������, ��������� ������ �������� ��� ��������.
.PARAMETER Parameters
    [hashtable] ������������. ��������� ��������:
    - drives ([string[]]): ������ ���� ������ ��� �������� (��������, @('C', 'D')).
                           ������� �� �����. ���� �� ������ ��� ����,
                           ����������� ��� ��������� ����� ���� 'Fixed'.
.PARAMETER SuccessCriteria
    [hashtable] ������������. �������� ������. ����� - ������� ����� ������
               (��� ���������, ��������, 'C') ��� ����������� ���� '_default_'.
               �������� - ���-������� � ����������.
    �������������� ��������:
    - min_percent_free (int): ���������� ���������� ������� ���������� �����.
    ������: @{
                C = @{ min_percent_free = 10 } # ��� ����� C ������� 10%
                D = @{ min_percent_free = 15 } # ��� ����� D ������� 15%
                _default_ = @{ min_percent_free = 5 } # ��� ��������� ������ ������� 5%
            }
.PARAMETER NodeName
    [string] ������������. ��� ���� ��� ����������� (���������� �����������).
.OUTPUTS
    Hashtable - ������������������� ������ ����������
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
                Details �������� ������ 'disks', ��� ������ ������� - ���-�������
                � ����������� � ���������� �����.
.NOTES
    ������: 1.1 (���������� ������ � Add() � ToUpper())
    ������� �� ������� New-CheckResultObject, ������� ������ ����
    �������� � ��������� ���������� (��������� �� StatusMonitorAgentUtils.psm1).
#>
param(
    # ������� IP ��� ��� �����. �� ������������ �������� � Get-Volume,
    # �� ����������� ��� ������������� � �����������.
    [Parameter(Mandatory=$true)]
    [string]$TargetIP,

    # ���������, ����������� ��� �������� ������ (��������, ������ ����).
    [Parameter(Mandatory=$false)]
    [hashtable]$Parameters = @{},

    # �������� ��� ����������� ���������� �������� (��������, ���. % ���������� �����).
    [Parameter(Mandatory=$false)]
    [hashtable]$SuccessCriteria = $null,

    # ��� ���� ��� ����� �������������� �����������.
    [Parameter(Mandatory=$false)]
    [string]$NodeName = "Unknown Node"
)

# --- ������ ������ �������� ---

# ������������� ���-������� ��� ����������.
# IsAvailable = $false �� ��������� (���� �������� �� ��������� �������).
# Details.disks ���������������� ��� Generic List ��� ����������� ���������� ���������.
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{ disks = [System.Collections.Generic.List[object]]::new() }
    ErrorMessage = $null
}
# ���� ������ ������ �� ���� ��������� ��� ���� ����������� ������.
$overallCheckSuccess = $true
# ������ ��� ����� ��������� �� ������� (�������� ��� �������������� ���������).
$errorMessages = [System.Collections.Generic.List[string]]::new()

Write-Verbose "[$NodeName] Check-DISK_USAGE: ������ �������� ������."

# �������� ���� try/catch ��� ������ ����������� ������ (��������, ������������� Get-Volume).
try {

    # 1. �������� ���������� � ����� � ������� Get-Volume.
    # Get-Volume ���������� ���������� � �������� ����� �������.
    # ���������� -ErrorAction Stop, ����� �������� ���������� � ������� � catch ��� ������ ����������.
    Write-Verbose "[$NodeName] Check-DISK_USAGE: ����� Get-Volume..."
    $volumes = Get-Volume -ErrorAction Stop

    # ���� Get-Volume ���������� ��� ������, �������, ��� �������� ����� ���������.
    $resultData.IsAvailable = $true
    Write-Verbose "[$NodeName] Check-DISK_USAGE: �������� �����: $($volumes.Count)"

    # 2. ��������� ����, ������� ����� ���������.

    # ������ ��� �������� ������� ���� ������ (� ������� ��������).
    $targetDriveLetters = @()
    # ���������, ������� �� �������� 'drives' � �������� �� �� �������� ��������.
    if ($Parameters.ContainsKey('drives') -and $Parameters.drives -is [array] -and $Parameters.drives.Count -gt 0) {
        # ���� ��, �������� ������ ����� � �������� �������� � ������� �������.
        $targetDriveLetters = $Parameters.drives | ForEach-Object { $_.Trim().ToUpper() }
        Write-Verbose "[$NodeName] Check-DISK_USAGE: ���������� �� ��������� ������: $($targetDriveLetters -join ', ')"
    } else {
        # ���� �������� 'drives' �� �����, ����� ��������� ��� ���������� �����.
        Write-Verbose "[$NodeName] Check-DISK_USAGE: �������� 'drives' �� ������, ��������� ��� ����� ���� 'Fixed'."
    }

    # ��������� ���������� ����:
    $filteredVolumes = $volumes | Where-Object {
        # ��������� ������ ����� ���� 'Fixed' (��������� ������� �����).
        $isFixed = $_.DriveType -eq 'Fixed'
        # ��������� ������ �����, � ������� ���� ����������� �����.
        $currentDriveLetterChar = $_.DriveLetter
        $hasLetter = $null -ne $currentDriveLetterChar -and (-not [string]::IsNullOrWhiteSpace($currentDriveLetterChar))

        # ����������� ����� (������� �������� [char]) � ������ ��� ���������� ��������.
        $currentDriveLetterString = $currentDriveLetterChar.ToString()

        # ���������, ������ �� ����� ����� � ������� ������ (���� ������ �����).
        # ���� $targetDriveLetters ���� (�.�. �������� 'drives' �� ��� �����), �� ��� ������� ������ true.
        $isInTargetList = $targetDriveLetters.Count -eq 0 -or $targetDriveLetters -contains $currentDriveLetterString.ToUpper()

        # �������� �������: ���� ������ ���� Fixed, ����� ����� � ��������������� ������ (���� �� �����).
        $isFixed -and $hasLetter -and $isInTargetList
    }
    Write-Verbose "[$NodeName] Check-DISK_USAGE: ����� ����� ����������: $($filteredVolumes.Count)"

    # ���� ����� ���������� �� �������� ������ ��� ��������.
    if ($filteredVolumes.Count -eq 0) {
         # ������� ��������� �������� (��� ������ - ��� �������).
         $resultData.CheckSuccess = $true
         # ��������� �������������� ��������� � Details.
         $resultData.Details.message = "��� ������ ���� 'Fixed'"
         if ($targetDriveLetters.Count -gt 0) {
             $resultData.Details.message += " ��������������� ��������� ������ ($($targetDriveLetters -join ', '))"
         }
         $resultData.Details.message += "."
         Write-Verbose "[$NodeName] Check-DISK_USAGE: $($resultData.Details.message)"
    } else {
        # 3. ������������ ������ ��������������� ���.
        foreach ($vol in $filteredVolumes) {

            # �������� ����� �����, ����������� � ������ � ������� �������.
            $driveLetter = $vol.DriveLetter.ToString().ToUpper()

            # ������� ���-������� ��� �������� ���������� �� ���� �����.
            $diskInfo = @{
                drive_letter = $driveLetter
                label        = $vol.FileSystemLabel # ����� ����
                filesystem   = $vol.FileSystem     # �������� ������� (NTFS, FAT32 � �.�.)
                size_bytes   = $vol.Size           # ����� ������ � ������
                free_bytes   = $vol.SizeRemaining  # �������� � ������
                used_bytes   = $vol.Size - $vol.SizeRemaining # ������ � ������
                # ���� ��� ������������ �������� (GB, %) - �������������� null.
                size_gb      = $null
                free_gb      = $null
                used_gb      = $null
                percent_free = $null
                percent_used = $null
                # ���� ��� ����������� �������� ���������.
                criteria_applied = $null # ����� �������� ��� �������� ([hashtable] ��� $null).
                criteria_passed  = $null # ��������� �������� �������� ([bool] ��� $null).
                criteria_failed_reason = $null # ������� ������� �������� ([string] ��� $null).
            }

            # ������������ �������� � �� � ���������.
            # ���������, ��� ������ ����� > 0, ����� �������� ������� �� ����.
            if ($diskInfo.size_bytes -gt 0) {
                $diskInfo.size_gb = [math]::Round($diskInfo.size_bytes / 1GB, 2)
                $diskInfo.free_gb = [math]::Round($diskInfo.free_bytes / 1GB, 2)
                $diskInfo.used_gb = [math]::Round($diskInfo.used_bytes / 1GB, 2)
                $diskInfo.percent_free = [math]::Round(($diskInfo.free_bytes / $diskInfo.size_bytes) * 100, 1)
                $diskInfo.percent_used = [math]::Round(($diskInfo.used_bytes / $diskInfo.size_bytes) * 100, 1)
            } else {
                # ���� ������ 0 (��������, ������ ���������), ������������� ������� ��������.
                $diskInfo.size_gb = 0
                $diskInfo.free_gb = 0
                $diskInfo.used_gb = 0
                $diskInfo.percent_free = 0
                $diskInfo.percent_used = 100
            }

            # 4. ��������� �������� ������ ��� ����� �����.
            $criterion = $null
            # ���� �������� ������ ��������.
            if ($SuccessCriteria -ne $null) {
                # ���� �������� ��� ���������� ����� ����� (� ������� ��������).
                if ($SuccessCriteria.ContainsKey($driveLetter)) {
                    $criterion = $SuccessCriteria[$driveLetter]
                    Write-Verbose "[$NodeName] Check-DISK_USAGE: ������ �������� ��� ����� $driveLetter"
                }
                # ���� ����������� ���, ���� �������� �� ��������� '_default_'.
                elseif ($SuccessCriteria.ContainsKey('_default_')) {
                    $criterion = $SuccessCriteria['_default_']
                    Write-Verbose "[$NodeName] Check-DISK_USAGE: ������������ �������� _default_ ��� ����� $driveLetter"
                }
            }

            # ��������� ��������, ���� �� ������, �������� ���-�������� � �������� ���� 'min_percent_free'.
            if ($criterion -is [hashtable] -and $criterion.ContainsKey('min_percent_free')) {
                # ����������, ����� �������� ���������.
                $diskInfo.criteria_applied = $criterion

                $minPercentFree = $null
                # �������� ������������� �������� �������� � ����� �����.
                if ([int]::TryParse($criterion.min_percent_free, [ref]$minPercentFree)) {
                     Write-Verbose "[$NodeName] Check-DISK_USAGE: ���� $driveLetter - �������� �������� min_percent_free = $minPercentFree %"
                     # ���������, ���� ������� ���������� ����� ��������� � �� ������ ����������.
                     if ($diskInfo.percent_free -ne $null -and $diskInfo.percent_free -lt $minPercentFree) {
                         # �������� �� �������.
                         $diskInfo.criteria_passed = $false
                         $failReason = "�������� {0}% < ��������� {1}%" -f $diskInfo.percent_free, $minPercentFree
                         $diskInfo.criteria_failed_reason = $failReason
                         # ��������� ��������� �� ������ � ����� ������.
                         $errorMessages.Add(("���� {0}: {1}" -f $driveLetter, $failReason)) | Out-Null
                         # ������������� ����� ���� ������ � $false.
                         $overallCheckSuccess = $false
                         Write-Verbose "[$NodeName] Check-DISK_USAGE: ���� $driveLetter - ������� �� ��������: $failReason"
                     } else {
                          # �������� �������.
                          $diskInfo.criteria_passed = $true
                          Write-Verbose "[$NodeName] Check-DISK_USAGE: ���� $driveLetter - ����� �� ��������."
                     }
                } else {
                     # ������������ �������� � �������� (�� �����).
                     $diskInfo.criteria_passed = $false # ������� ��������.
                     $failReason = "������������ �������� min_percent_free ('$($criterion.min_percent_free)')"
                     $diskInfo.criteria_failed_reason = $failReason
                     # ��������� ��������� �� ������ � ����� ������.
                     $errorMessages.Add(("���� {0}: {1}" -f $driveLetter, $failReason)) | Out-Null
                     $overallCheckSuccess = $false
                     Write-Warning "[$NodeName] Check-DISK_USAGE: ���� $driveLetter - $failReason"
                }
            } else {
                 # �������� ��� ����� ����� �� ������ ��� �� �������� min_percent_free.
                 $diskInfo.criteria_passed = $null # ���� ���������, ��� �������� �� ����������.
                 Write-Verbose "[$NodeName] Check-DISK_USAGE: ���� $driveLetter - �������� min_percent_free �� ������/�� ��������."
            }

            # ��������� ��������� ���������� � ����� � �������� ������ � Details.
            $resultData.Details.disks.Add($diskInfo)

        } # ����� ����� foreach ($vol in $filteredVolumes)
    } # ����� else (���� ���� ����� ��� ��������)

    # ������������� �������� ��������� CheckSuccess.
    $resultData.CheckSuccess = $overallCheckSuccess
    # ���� ���� �� ���� �������� �� ��� �������, ��������� ����� ��������� �� ������.
    if (-not $overallCheckSuccess) {
        $resultData.ErrorMessage = $errorMessages -join '; '
    }

} catch {
    # ����� ����������� ������ (��������, Get-Volume �� ��������).
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    # ��������� ��������� �� ������.
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "������ ��������� ���������� � ������: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    # ����������, ��� Details ���������� � ��������� ���������� �� ������.
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    # ������� ������ � ����� ������.
    Write-Error "[$NodeName] Check-DISK_USAGE: ����������� ������: $errorMessage"
}

# ��������� ��������� ������ ���������� � ������� ����� �������.
# �������� ��� ��������� ������ @resultData (splatting).
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-DISK_USAGE: ������������ ���������: $($finalResult | ConvertTo-Json -Depth 4 -Compress)"

# ���������� ���������.
return $finalResult