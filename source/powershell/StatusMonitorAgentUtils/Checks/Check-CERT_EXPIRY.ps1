<#
.SYNOPSIS
    ������ �������� ������ �������� �������� ������������� ������������.
.DESCRIPTION
    ���������� Get-ChildItem ��� ������ ������������ � ����������� ����������
    (LocalMachine\My, LocalMachine\WebHosting, CurrentUser\My).
    ��������� ����������� ����������� �� ��������� ���������
    (Subject, Issuer, Thumbprint, EKU).
    ��������� ���������� ���� �������� ��������� ������������.
    ���������� ������������������� ������ ����������.
.PARAMETER TargetIP
    [string] IP ��� ��� ����� ��� �������� (���������� �����������).
    ������������ ����������� ��� ���������� ������ ����� �������.
.PARAMETER Parameters
    [hashtable] ������������. ��������� ���������� ������������:
    - subject_like (string):   ������ �� ����� �������� (wildcards *?). ��������������.
    - issuer_like (string):    ������ �� ����� �������� (wildcards *?). ��������������.
    - thumbprint (string):     ������ ��������� �����������. ���� ������, ������
                               ������� (Subject, Issuer) ������������. ��������������.
    - require_private_key (bool): ��������� ������� ��������� �����? (�� ��������� $false). ��������������.
    - eku_oid (string[]):      ������ OID'�� Extended Key Usage, ���� �� �������
                               ������ ��������������. ��������: @('1.3.6.1.5.5.7.3.1').
                               ���� �� ������, EKU �� �����������. ��������������.
    - min_days_warning (int): ��������� �������� � ���� ��� ������� "Warning"
                              (���� ���� �������� �����). �� ��������� 30.
.PARAMETER SuccessCriteria
    [hashtable] ������������. �������� ������:
    - min_days_left (int): ����������� ���������� ����, ������� ������ ����������
                           �� ��������� ������� ���������� �����������.
.PARAMETER NodeName
    [string] ������������. ��� ���� ��� �����������.
.OUTPUTS
    Hashtable - ������������������� ������ ����������.
.NOTES
    ������: 1.1 (����� ����� �� store_location/store_name, ���� � ����������� ������)
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP,

    [Parameter(Mandatory=$true)]
    [hashtable]$Parameters,

    [Parameter(Mandatory=$true)]
    [hashtable]$SuccessCriteria,

    [Parameter(Mandatory=$false)]
    [string]$NodeName = "Unknown Node"
)

# --- ������ ������ �������� ---
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{ certificates = [System.Collections.Generic.List[object]]::new(); stores_checked = @() } # �������� stores_checked
    ErrorMessage = $null
}
$overallCheckSuccess = $true
$errorMessages = [System.Collections.Generic.List[string]]::new()

Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ������ �������� ������������ �� $TargetIP (����������� �������� �� $env:COMPUTERNAME)"

try {
    # 1. ��������� � ���������� ���������� ���������� (��������� �������� ������)
    $SubjectLike = $Parameters.subject_like
    $IssuerLike = $Parameters.issuer_like
    $Thumbprint = $Parameters.thumbprint
    $RequirePrivateKey = [bool]($Parameters.require_private_key | Get-OrElse $false)
    $EkuOids = $Parameters.eku_oid

    # �������� ������������� �������� ������
    $minDaysLeftCriterion = $null
    if ($SuccessCriteria -ne $null -and $SuccessCriteria.ContainsKey('min_days_left')) {
        if (-not ([int]::TryParse($SuccessCriteria.min_days_left, [ref]$minDaysLeftCriterion)) -or $minDaysLeftCriterion -lt 0) {
            throw "������������ �������� min_days_left � SuccessCriteria: '$($SuccessCriteria.min_days_left)'. ��������� ��������������� ����� �����."
        }
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: �������� ������ min_days_left = $minDaysLeftCriterion"
    } else {
        throw "����������� ������������ �������� 'min_days_left' � SuccessCriteria."
    }

    # ����� ��� Warning �������
    $minDaysWarning = 30
    if ($Parameters.ContainsKey('min_days_warning')) {
        # ... (��������� min_days_warning ��� ���������) ...
        if (-not ([int]::TryParse($Parameters.min_days_warning, [ref]$minDaysWarning)) -or $minDaysWarning -lt 0) { Write-Warning "..."; $minDaysWarning = 30 } else { Write-Verbose ... }
    }

    # 2. ���������� ������ �������� ��� ������
    $storesToSearch = @(
        @{ Path = "Cert:\LocalMachine\My"; Location = "LocalMachine"; Name = "My" },
        @{ Path = "Cert:\LocalMachine\WebHosting"; Location = "LocalMachine"; Name = "WebHosting" },
        @{ Path = "Cert:\CurrentUser\My"; Location = "CurrentUser"; Name = "My" }
        # �������� ������ ��� �������������, ��������:
        # @{ Path = "Cert:\LocalMachine\Remote Desktop"; Location = "LocalMachine"; Name = "Remote Desktop" }
    )

    # ������ ��� �������� ���� ��������� ������������ �� ���� ��������
    $allFoundCertificates = [System.Collections.Generic.List[object]]::new()
    $storeAccessErrors = [System.Collections.Generic.List[string]]::new()

    # 3. ���� ����������� � ������ ���������
    foreach ($storeInfo in $storesToSearch) {
        $certStorePath = $storeInfo.Path
        $resultData.Details.stores_checked.Add($certStorePath) # ��������, ����� ��������� ���������
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ����� � ���������: $certStorePath"
        try {
            # ���������� -ErrorAction SilentlyContinue, ����� �� ��������� ���� ��� ������ ������� � ������ ���������
            $certsInStore = Get-ChildItem -Path $certStorePath -ErrorAction SilentlyContinue
            if ($certsInStore) {
                Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ������� � '$($certStorePath)': $($certsInStore.Count) ����."
                $allFoundCertificates.AddRange($certsInStore)
            } else {
                 Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ��������� '$($certStorePath)' ����� ��� �� �������."
            }
            # ���������, ���� �� ������ �������
            if ($Error.Count -gt 0 -and $Error[0].FullyQualifiedErrorId -match 'GetCertificateStore') {
                 $storeAccessErrors.Add("������ ������� � ��������� '$($certStorePath)': $($Error[0].Exception.Message)")
                 $Error.Clear() # ������� ������, ����� �� ������ �� ��������� ��������
            }

        } catch { # ����� Stop ������, ���� ����� ��� ��������� (���� �� ������ � SilentlyContinue)
             $storeAccessErrors.Add("����������� ������ ������� � ��������� '$($certStorePath)': $($_.Exception.Message)")
        }
    }

    # ���� ���� ������ ������� ���� �� � ������ ���������, �� ������ �������� - IsAvailable = true, �� ������� � ErrorMessage
    if ($storeAccessErrors.Count -gt 0) {
        $resultData.IsAvailable = $true # �� ������ ��������� ����� ������
        $errorMessagePrefix = "������ ������� � ��������� ����������: $($storeAccessErrors -join '; ')"
        # ������� � ������ ErrorMessage � �����, ���� ����� � ������ ������
    } else {
         # ���� ������ ������� �� ����, � ���� �� ���� ��������� ���� �������� (�.�. �� ���� ����������� ������)
         $resultData.IsAvailable = $true
    }

    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ����� ������� ������������ �� ����������: $($allFoundCertificates.Count)"

    # 4. ��������� ����� ������ ��������� ������������
    $filteredCertificates = $allFoundCertificates # �������� �� ����
    $filterApplied = $false

    # ��������� � ���������
    if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) {
        $filterApplied = $true
        $Thumbprint = $Thumbprint.Trim().ToUpper()
        $filteredCertificates = $filteredCertificates | Where-Object { $_.Thumbprint -eq $Thumbprint }
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ������ �� Thumbprint: $Thumbprint"
    } else {
        # ��������� �� Subject
        if (-not [string]::IsNullOrWhiteSpace($SubjectLike)) {
            $filterApplied = $true
            $filteredCertificates = $filteredCertificates | Where-Object { $_.Subject -like $SubjectLike }
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ������ �� Subject like: $SubjectLike"
        }
        # ��������� �� Issuer
        if (-not [string]::IsNullOrWhiteSpace($IssuerLike)) {
            $filterApplied = $true
            $filteredCertificates = $filteredCertificates | Where-Object { $_.Issuer -like $IssuerLike }
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ������ �� Issuer like: $IssuerLike"
        }
    }

    # ������ �� ������� ��������� �����
    if ($RequirePrivateKey) {
        $filterApplied = $true
        $filteredCertificates = $filteredCertificates | Where-Object { $_.HasPrivateKey }
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ������: ��������� �������� ����."
    }

    # ������ �� EKU
    if ($EkuOids -is [array] -and $EkuOids.Count -gt 0) {
        $filterApplied = $true
        $filteredCertificates = $filteredCertificates | Where-Object {
            $cert = $_
            $certEkus = ($cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Enhanced Key Usage' } | Select-Object -First 1).EnhancedKeyUsages
            if ($certEkus) { ($EkuOids | Where-Object { $certEkus.Oid -contains $_ }).Count -gt 0 } else { $false }
        }
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ������ �� EKU OIDs: $($EkuOids -join ', ')"
    }

    # �������������, ���� ������� �� �����������
    if (-not $filterApplied) {
         Write-Warning "[$NodeName] Check-CERT_EXPIRY: �� ������ �������� ���������� (Subject, Issuer, Thumbprint, EKU). ����������� ��� ��������� �����������."
    }

    # --- ��������: ���������� .Count ��� Generic List ---
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ������������ ����� ����������: $($filteredCertificates.Count)"

    # 5. ������������ ������ ��������������� ����������
    if ($filteredCertificates.Count -eq 0) {
        # --- ��������: ������� - ���� ������� ����, �� ������ �� ������� ---
        if ($filterApplied) {
            $resultData.CheckSuccess = $true # �� ������� �� ������� - ������� �������
            $resultData.Details.message = "�����������, ��������������� ��������, �� �������."
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: $($resultData.Details.message)"
        } else {
             # ���� �������� �� ����, � ������ ���� - ������ ��������� ������ ��� ����������
             $resultData.CheckSuccess = $true # ��� ��� ������� �������
             $resultData.Details.message = "����������� � ����������� ���������� �� �������."
             Write-Verbose "[$NodeName] Check-CERT_EXPIRY: $($resultData.Details.message)"
        }
    } else {
        $currentTime = Get-Date

        foreach ($cert in $filteredCertificates) {
            # ... (��� ������� $daysLeft � $certInfo ��� ���������) ...
            $timeRemaining = New-TimeSpan -Start $currentTime -End $cert.NotAfter; $daysLeft = [math]::Floor($timeRemaining.TotalDays)
            $certInfo = @{ thumbprint = $cert.Thumbprint; subject = $cert.Subject; issuer = $cert.Issuer; not_before = $cert.NotBefore.ToUniversalTime().ToString("o"); not_after = $cert.NotAfter.ToUniversalTime().ToString("o"); days_left = $daysLeft; has_private_key = $cert.HasPrivateKey; status = "OK"; status_details = ""; store_path = $cert.PSParentPath } # �������� store_path

            # ��������� ������ ����� ��������
            if ($currentTime -gt $cert.NotAfter) {
                $certInfo.status = "Expired"
                $certInfo.status_details = "���� �������� ����� {0:dd.MM.yyyy HH:mm}" -f $cert.NotAfter.ToLocalTime()
                $errorMessages.Add(("[{0}] {1}: {2}" -f $cert.Thumbprint.Substring(0,8), $cert.Subject, $certInfo.status_details))
                $overallCheckSuccess = $false
            } elseif ($daysLeft -lt 0) {
                $certInfo.status = "Error"
                $certInfo.status_details = "������ ������� ����������� ����� (daysLeft < 0)."
                $errorMessages.Add(("[{0}] {1}: {2}" -f $cert.Thumbprint.Substring(0,8), $cert.Subject, $certInfo.status_details))
                $overallCheckSuccess = $false
            } elseif ($daysLeft -le $minDaysLeftCriterion) {
                $certInfo.status = "Expiring (Fail)"
                $certInfo.status_details = "�������� ����: $daysLeft (��������� > $minDaysLeftCriterion)"
                $errorMessages.Add(("[{0}] {1}: {2}" -f $cert.Thumbprint.Substring(0,8), $cert.Subject, $certInfo.status_details))
                $overallCheckSuccess = $false
            } elseif ($daysLeft -le $minDaysWarning) {
                 $certInfo.status = "Expiring (Warn)"
                 $certInfo.status_details = "�������� ����: $daysLeft (�������������� <= $minDaysWarning)" # ��������� ���� < �� <=
                 Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ���������� {0} ����� �������� ({1} ����)." -f $cert.Thumbprint, $daysLeft
            }

            $resultData.Details.certificates.Add($certInfo)
        }

        # ������������� �������� CheckSuccess
        $resultData.CheckSuccess = $overallCheckSuccess
        # ��������� ������ ������� � ����������, ���� ��� ����
        if ($storeAccessErrors.Count -gt 0) {
             $errorMessages.Insert(0, ($storeAccessErrors -join '; ')) # ��������� � ������
        }
        if ($errorMessages.Count -gt 0) {
            $resultData.ErrorMessage = $errorMessages -join '; '
            if ($resultData.ErrorMessage.Length -gt 1000) { $resultData.ErrorMessage = $resultData.ErrorMessage.Substring(0, 1000) + "..." }
        }
    }

} catch {
    # ����� ����������� ������ (��������, ������������ ���������)
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "������ �������� ������������: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    Write-Error "[$NodeName] Check-CERT_EXPIRY: ����������� ������: $errorMessage"
}

# ��������� � ���������� ������������������� ���������
if (-not (Get-Command New-CheckResultObject -ErrorAction SilentlyContinue)) {
    Write-Error "[$NodeName] Check-CERT_EXPIRY: �� ������� ������� New-CheckResultObject!"
    return $resultData
}
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-CERT_EXPIRY: ������������ ���������: $($finalResult | ConvertTo-Json -Depth 4 -Compress)"
return $finalResult