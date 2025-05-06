# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-CERT_EXPIRY.ps1
# --- Версия 2.0.3 --- Исправлена логика установки ErrorMessage при ошибке критерия
<#
.SYNOPSIS
    Скрипт проверки сроков действия локально установленных сертификатов. (v2.0.3)
.DESCRIPTION
    Использует Get-ChildItem для поиска сертификатов. Позволяет фильтровать.
    Формирует $Details со списком 'certificates'.
    Вызывает Test-SuccessCriteria для определения CheckSuccess.
.PARAMETER TargetIP [string] Обязательный. IP/Имя хоста (для логирования).
.PARAMETER Parameters [hashtable] Опциональный. Параметры фильтра: subject_like,
             issuer_like, thumbprint, require_private_key, eku_oid, min_days_warning.
.PARAMETER SuccessCriteria [hashtable] Опциональный. Критерии для массива 'certificates'
             в $Details (напр., @{ certificates=@{_condition_='all';_criteria_=@{days_left=@{'>'=14}}} }).
.PARAMETER NodeName [string] Опциональный. Имя узла для логирования.
.OUTPUTS Hashtable - Стандартизированный результат.
.NOTES
    Версия: 2.0.3 (Исправлен ErrorMessage при ошибке критерия).
    Зависит от New-CheckResultObject, Test-SuccessCriteria.
#>
param(
    [Parameter(Mandatory = $true)][string]$TargetIP,
    [Parameter(Mandatory = $false)][hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)][hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)][string]$NodeName = "Unknown Node"
)

# --- Инициализация ---
$isAvailable = $false; $checkSuccess = $null; $errorMessage = $null; $finalResult = $null
$details = @{ certificates = [System.Collections.Generic.List[object]]::new(); stores_checked = @() }

Write-Verbose "[$NodeName] Check-CERT_EXPIRY (v2.0.3): Начало проверки сертификатов на $TargetIP (локально)"

# --- Основной Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>

    # --- 1. Параметры фильтрации ---
    $SubjectLike = $Parameters.subject_like; $IssuerLike = $Parameters.issuer_like; $Thumbprint = $Parameters.thumbprint; $EkuOids = $Parameters.eku_oid
    $RequirePrivateKey = $false; if ($Parameters.ContainsKey('require_private_key')) { try { $RequirePrivateKey = [bool]$Parameters.require_private_key } catch { Write-Warning "..." } }
    $minDaysWarning = 30; if ($Parameters.ContainsKey('min_days_warning')) { $parsed=0; if([int]::TryParse($Parameters.min_days_warning,[ref]$parsed) -and $parsed -ge 0){$minDaysWarning=$parsed}else{Write-Warning "..."} }

    # --- 2. Поиск сертификатов ---
    $storesToSearch = @( @{ Path = "Cert:\LocalMachine\My"; Loc = "LocalMachine"; Name = "My" }, @{ Path = "Cert:\LocalMachine\WebHosting"; Loc = "LocalMachine"; Name = "WebHosting" }, @{ Path = "Cert:\CurrentUser\My"; Loc = "CurrentUser"; Name = "My" })
    $allFoundCertificates = [System.Collections.Generic.List[object]]::new(); $storeAccessErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($storeInfo in $storesToSearch) {
        $certStorePath = $storeInfo.Path; $details.stores_checked.Add($certStorePath)
        try {
            $certsInStore = Get-ChildItem -Path $certStorePath -EA SilentlyContinue
            if ($certsInStore) { $allFoundCertificates.AddRange($certsInStore); Write-Verbose "... В '$certStorePath' найдено: $($certsInStore.Count)" }
            if ($Error.Count -gt 0 -and $Error[0].FullyQualifiedErrorId -match 'StoreCouldNotBeOpened') { $errMsg="Ошибка доступа к '$certStorePath': $($Error[0].Exception.Message)"; $storeAccessErrors.Add($errMsg); Write-Warning "... $errMsg"; $Error.Clear() }
        } catch { $errMsg="Критическая ошибка доступа к '$certStorePath': $($_.Exception.Message)"; $storeAccessErrors.Add($errMsg); Write-Warning "... $errMsg" }
    }
    if ($details.stores_checked.Count -gt 0) { $isAvailable = $true; if ($storeAccessErrors.Count -gt 0) { $details.access_errors = $storeAccessErrors } }
    else { $isAvailable = $false; $errorMessage = "Не удалось получить доступ ни к одному хранилищу."; throw $errorMessage }
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: IsAvailable=$isAvailable. Найдено до фильтрации: $($allFoundCertificates.Count)."

    # --- 3. Фильтрация сертификатов ---
    $filteredCertificates = $allFoundCertificates; $filterApplied = $false
    if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) { $filterApplied=$true; $t = $Thumbprint.Trim().ToUpper(); $filteredCertificates = $filteredCertificates |? { $_.Thumbprint -eq $t } }
    else { if (-not [string]::IsNullOrWhiteSpace($SubjectLike)) { $filterApplied=$true; $filteredCertificates = $filteredCertificates |? { $_.Subject -like $SubjectLike } }
           if (-not [string]::IsNullOrWhiteSpace($IssuerLike)) { $filterApplied=$true; $filteredCertificates = $filteredCertificates |? { $_.Issuer -like $IssuerLike } } }
    if ($RequirePrivateKey) { $filterApplied=$true; $filteredCertificates = $filteredCertificates |? { $_.HasPrivateKey } }
    if ($EkuOids -is [array] -and $EkuOids.Count -gt 0) { $filterApplied=$true; $filteredCertificates = $filteredCertificates |? { $eku = $_.Extensions |? {$_.Oid.FriendlyName -eq 'Enhanced Key Usage'}; $ekus = $eku.EnhancedKeyUsages; ($EkuOids |? {$ekus.Oid -contains $_}).Count -gt 0 } }
    if (-not $filterApplied) { Write-Warning "[$NodeName] Check-CERT_EXPIRY: Фильтры не заданы, обрабатываются все сертификаты." }
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Сертификатов после фильтрации: $($filteredCertificates.Count)."

    # --- 4. Формирование $details.certificates ---
    $currentTime = Get-Date
    if ($filteredCertificates.Count -eq 0) { $details.message = "Сертификаты" + ($filterApplied ? ", соотв. фильтрам," : "") + " не найдены." }
    else {
        foreach ($cert in $filteredCertificates) {
            $daysLeft = [math]::Floor((New-TimeSpan -Start $currentTime -End $cert.NotAfter).TotalDays)
            $certInfo = [ordered]@{ thumbprint=$cert.Thumbprint; subject=$cert.Subject; issuer=$cert.Issuer; not_before=$cert.NotBefore.ToUniversalTime().ToString("o"); not_after=$cert.NotAfter.ToUniversalTime().ToString("o"); days_left=$daysLeft; has_private_key=$cert.HasPrivateKey; status="OK"; status_details=""; store_path=$cert.PSParentPath }
            if ($currentTime -gt $cert.NotAfter) { $certInfo.status="Expired"; $certInfo.status_details="Истек $($cert.NotAfter.ToLocalTime())" }
            elseif ($daysLeft -le $minDaysWarning) { $certInfo.status="Expiring (Warn)"; $certInfo.status_details="Истекает через $daysLeft дней (<= $minDaysWarning)" }
            $details.certificates.Add($certInfo)
        }
    }

    # --- 5. Проверка критериев успеха ---
    $failReason = $null
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.PSObject.Properties.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Вызов Test-SuccessCriteria..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason
            # <<< ИСПРАВЛЕНО: Устанавливаем errorMessage ТОЛЬКО если критерий не пройден/ошибка >>>
            if ($checkSuccess -ne $true) {
                $errorMessage = $failReason | Get-OrElse "Критерии успеха для сертификатов не пройдены."
                Write-Verbose "[$NodeName] ... SuccessCriteria НЕ пройдены/ошибка: $errorMessage"
            } else {
                # Критерии пройдены, errorMessage должен быть null (если не было ошибки доступа к хранилищу)
                if ($null -eq $details.access_errors) { $errorMessage = $null }
                else { $errorMessage = "Были ошибки доступа к некоторым хранилищам, но критерии пройдены для найденных сертификатов." } # Или не сбрасываем? Зависит от требований. Пока оставим null. $errorMessage = $null
                Write-Verbose "[$NodeName] ... SuccessCriteria пройдены."
            }
            # <<< КОНЕЦ ИСПРАВЛЕНИЯ >>>
        } else {
            $checkSuccess = $true; # По умолчанию успех, если нет критериев
            # Оставляем $errorMessage, если были ошибки доступа к хранилищам
            if ($details.access_errors) { $errorMessage = "Критерии не заданы, но были ошибки доступа к хранилищам."} else { $errorMessage = $null }
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        $checkSuccess = $null
        if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = "Ошибка проверки сертификатов (IsAvailable=false)." }
    }

    # --- 6. Формирование результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch { # <<< ОСНОВНОЙ CATCH >>>
    $isAvailable = $false; $checkSuccess = $null
    $critErrorMessage = "Критическая ошибка Check-CERT_EXPIRY: $($_.Exception.Message)"
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString() }
    if($details.stores_checked.Count -gt 0) { $detailsError.stores_checked = $details.stores_checked } # Сохраняем, что успели проверить
    $finalResult = @{ IsAvailable=$isAvailable; CheckSuccess=$checkSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$detailsError; ErrorMessage=$critErrorMessage }
    Write-Error "[$NodeName] Check-CERT_EXPIRY: Критическая ошибка: $critErrorMessage"
} # <<< КОНЕЦ ОСНОВНОГО CATCH >>>

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-CERT_EXPIRY (v2.0.3): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult