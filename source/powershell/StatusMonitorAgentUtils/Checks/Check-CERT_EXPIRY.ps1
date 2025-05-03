<#
.SYNOPSIS
    Скрипт проверки сроков действия локально установленных сертификатов.
.DESCRIPTION
    Использует Get-ChildItem для поиска сертификатов в стандартных хранилищах
    (LocalMachine\My, LocalMachine\WebHosting, CurrentUser\My).
    Позволяет фильтровать сертификаты по различным критериям
    (Subject, Issuer, Thumbprint, EKU).
    Проверяет оставшийся срок действия найденных сертификатов.
    Возвращает стандартизированный объект результата.
.PARAMETER TargetIP
    [string] IP или имя хоста для проверки (передается диспетчером).
    Используется диспетчером для удаленного вызова этого скрипта.
.PARAMETER Parameters
    [hashtable] Обязательный. Параметры фильтрации сертификатов:
    - subject_like (string):   Фильтр по имени субъекта (wildcards *?). Необязательный.
    - issuer_like (string):    Фильтр по имени издателя (wildcards *?). Необязательный.
    - thumbprint (string):     Точный отпечаток сертификата. Если указан, другие
                               фильтры (Subject, Issuer) игнорируются. Необязательный.
    - require_private_key (bool): Требовать наличие закрытого ключа? (По умолчанию $false). Необязательный.
    - eku_oid (string[]):      Массив OID'ов Extended Key Usage, ОДИН ИЗ которых
                               должен присутствовать. Например: @('1.3.6.1.5.5.7.3.1').
                               Если не указан, EKU не проверяется. Необязательный.
    - min_days_warning (int): Пороговое значение в днях для статуса "Warning"
                              (если срок истекает скоро). По умолчанию 30.
.PARAMETER SuccessCriteria
    [hashtable] Обязательный. Критерии успеха:
    - min_days_left (int): Минимальное количество дней, которое ДОЛЖНО оставаться
                           до истечения КАЖДОГО найденного сертификата.
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата.
.NOTES
    Версия: 1.1 (Убран поиск по store_location/store_name, ищет в стандартных местах)
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

# --- Начало логики проверки ---
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{ certificates = [System.Collections.Generic.List[object]]::new(); stores_checked = @() } # Добавили stores_checked
    ErrorMessage = $null
}
$overallCheckSuccess = $true
$errorMessages = [System.Collections.Generic.List[string]]::new()

Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Начало проверки сертификатов на $TargetIP (выполняется локально на $env:COMPUTERNAME)"

try {
    # 1. Валидация и извлечение параметров ФИЛЬТРАЦИИ (параметры хранилищ убраны)
    $SubjectLike = $Parameters.subject_like
    $IssuerLike = $Parameters.issuer_like
    $Thumbprint = $Parameters.thumbprint
    $RequirePrivateKey = [bool]($Parameters.require_private_key | Get-OrElse $false)
    $EkuOids = $Parameters.eku_oid

    # Проверка обязательного критерия успеха
    $minDaysLeftCriterion = $null
    if ($SuccessCriteria -ne $null -and $SuccessCriteria.ContainsKey('min_days_left')) {
        if (-not ([int]::TryParse($SuccessCriteria.min_days_left, [ref]$minDaysLeftCriterion)) -or $minDaysLeftCriterion -lt 0) {
            throw "Некорректное значение min_days_left в SuccessCriteria: '$($SuccessCriteria.min_days_left)'. Ожидается неотрицательное целое число."
        }
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Критерий успеха min_days_left = $minDaysLeftCriterion"
    } else {
        throw "Отсутствует обязательный параметр 'min_days_left' в SuccessCriteria."
    }

    # Порог для Warning статуса
    $minDaysWarning = 30
    if ($Parameters.ContainsKey('min_days_warning')) {
        # ... (валидация min_days_warning без изменений) ...
        if (-not ([int]::TryParse($Parameters.min_days_warning, [ref]$minDaysWarning)) -or $minDaysWarning -lt 0) { Write-Warning "..."; $minDaysWarning = 30 } else { Write-Verbose ... }
    }

    # 2. Определяем список хранилищ для поиска
    $storesToSearch = @(
        @{ Path = "Cert:\LocalMachine\My"; Location = "LocalMachine"; Name = "My" },
        @{ Path = "Cert:\LocalMachine\WebHosting"; Location = "LocalMachine"; Name = "WebHosting" },
        @{ Path = "Cert:\CurrentUser\My"; Location = "CurrentUser"; Name = "My" }
        # Добавьте другие при необходимости, например:
        # @{ Path = "Cert:\LocalMachine\Remote Desktop"; Location = "LocalMachine"; Name = "Remote Desktop" }
    )

    # Список для хранения всех найденных сертификатов из всех хранилищ
    $allFoundCertificates = [System.Collections.Generic.List[object]]::new()
    $storeAccessErrors = [System.Collections.Generic.List[string]]::new()

    # 3. Ищем сертификаты в каждом хранилище
    foreach ($storeInfo in $storesToSearch) {
        $certStorePath = $storeInfo.Path
        $resultData.Details.stores_checked.Add($certStorePath) # Логируем, какие хранилища проверяли
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Поиск в хранилище: $certStorePath"
        try {
            # Используем -ErrorAction SilentlyContinue, чтобы не прерывать цикл при ошибке доступа к одному хранилищу
            $certsInStore = Get-ChildItem -Path $certStorePath -ErrorAction SilentlyContinue
            if ($certsInStore) {
                Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Найдено в '$($certStorePath)': $($certsInStore.Count) серт."
                $allFoundCertificates.AddRange($certsInStore)
            } else {
                 Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Хранилище '$($certStorePath)' пусто или не найдено."
            }
            # Проверяем, была ли ошибка доступа
            if ($Error.Count -gt 0 -and $Error[0].FullyQualifiedErrorId -match 'GetCertificateStore') {
                 $storeAccessErrors.Add("Ошибка доступа к хранилищу '$($certStorePath)': $($Error[0].Exception.Message)")
                 $Error.Clear() # Очищаем ошибку, чтобы не влияла на следующие итерации
            }

        } catch { # Ловим Stop ошибку, если вдруг она возникнет (хотя не должна с SilentlyContinue)
             $storeAccessErrors.Add("Критическая ошибка доступа к хранилищу '$($certStorePath)': $($_.Exception.Message)")
        }
    }

    # Если были ошибки доступа хотя бы к одному хранилищу, но другие доступны - IsAvailable = true, но добавим в ErrorMessage
    if ($storeAccessErrors.Count -gt 0) {
        $resultData.IsAvailable = $true # Мы смогли выполнить часть работы
        $errorMessagePrefix = "Ошибки доступа к некоторым хранилищам: $($storeAccessErrors -join '; ')"
        # Добавим к общему ErrorMessage в конце, если будут и другие ошибки
    } else {
         # Если ошибок доступа не было, и хотя бы одно хранилище было доступно (т.е. не было критической ошибки)
         $resultData.IsAvailable = $true
    }

    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Всего найдено сертификатов до фильтрации: $($allFoundCertificates.Count)"

    # 4. Фильтруем ОБЩИЙ список найденных сертификатов
    $filteredCertificates = $allFoundCertificates # Начинаем со всех
    $filterApplied = $false

    # Приоритет у отпечатка
    if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) {
        $filterApplied = $true
        $Thumbprint = $Thumbprint.Trim().ToUpper()
        $filteredCertificates = $filteredCertificates | Where-Object { $_.Thumbprint -eq $Thumbprint }
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Фильтр по Thumbprint: $Thumbprint"
    } else {
        # Фильтруем по Subject
        if (-not [string]::IsNullOrWhiteSpace($SubjectLike)) {
            $filterApplied = $true
            $filteredCertificates = $filteredCertificates | Where-Object { $_.Subject -like $SubjectLike }
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Фильтр по Subject like: $SubjectLike"
        }
        # Фильтруем по Issuer
        if (-not [string]::IsNullOrWhiteSpace($IssuerLike)) {
            $filterApplied = $true
            $filteredCertificates = $filteredCertificates | Where-Object { $_.Issuer -like $IssuerLike }
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Фильтр по Issuer like: $IssuerLike"
        }
    }

    # Фильтр по наличию закрытого ключа
    if ($RequirePrivateKey) {
        $filterApplied = $true
        $filteredCertificates = $filteredCertificates | Where-Object { $_.HasPrivateKey }
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Фильтр: Требуется закрытый ключ."
    }

    # Фильтр по EKU
    if ($EkuOids -is [array] -and $EkuOids.Count -gt 0) {
        $filterApplied = $true
        $filteredCertificates = $filteredCertificates | Where-Object {
            $cert = $_
            $certEkus = ($cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Enhanced Key Usage' } | Select-Object -First 1).EnhancedKeyUsages
            if ($certEkus) { ($EkuOids | Where-Object { $certEkus.Oid -contains $_ }).Count -gt 0 } else { $false }
        }
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Фильтр по EKU OIDs: $($EkuOids -join ', ')"
    }

    # Предупреждаем, если фильтры не применялись
    if (-not $filterApplied) {
         Write-Warning "[$NodeName] Check-CERT_EXPIRY: Не заданы критерии фильтрации (Subject, Issuer, Thumbprint, EKU). Проверяются ВСЕ найденные сертификаты."
    }

    # --- ИЗМЕНЕНО: Используем .Count для Generic List ---
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Сертификатов после фильтрации: $($filteredCertificates.Count)"

    # 5. Обрабатываем каждый отфильтрованный сертификат
    if ($filteredCertificates.Count -eq 0) {
        # --- ИЗМЕНЕНО: Условие - если фильтры были, но ничего не найдено ---
        if ($filterApplied) {
            $resultData.CheckSuccess = $true # Не найдено по фильтру - считаем успехом
            $resultData.Details.message = "Сертификаты, соответствующие фильтрам, не найдены."
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: $($resultData.Details.message)"
        } else {
             # Если фильтров не было, и список пуст - значит хранилища пустые или недоступны
             $resultData.CheckSuccess = $true # Все еще считаем успехом
             $resultData.Details.message = "Сертификаты в проверяемых хранилищах не найдены."
             Write-Verbose "[$NodeName] Check-CERT_EXPIRY: $($resultData.Details.message)"
        }
    } else {
        $currentTime = Get-Date

        foreach ($cert in $filteredCertificates) {
            # ... (код расчета $daysLeft и $certInfo без изменений) ...
            $timeRemaining = New-TimeSpan -Start $currentTime -End $cert.NotAfter; $daysLeft = [math]::Floor($timeRemaining.TotalDays)
            $certInfo = @{ thumbprint = $cert.Thumbprint; subject = $cert.Subject; issuer = $cert.Issuer; not_before = $cert.NotBefore.ToUniversalTime().ToString("o"); not_after = $cert.NotAfter.ToUniversalTime().ToString("o"); days_left = $daysLeft; has_private_key = $cert.HasPrivateKey; status = "OK"; status_details = ""; store_path = $cert.PSParentPath } # Добавили store_path

            # Проверяем статус срока действия
            if ($currentTime -gt $cert.NotAfter) {
                $certInfo.status = "Expired"
                $certInfo.status_details = "Срок действия истек {0:dd.MM.yyyy HH:mm}" -f $cert.NotAfter.ToLocalTime()
                $errorMessages.Add(("[{0}] {1}: {2}" -f $cert.Thumbprint.Substring(0,8), $cert.Subject, $certInfo.status_details))
                $overallCheckSuccess = $false
            } elseif ($daysLeft -lt 0) {
                $certInfo.status = "Error"
                $certInfo.status_details = "Ошибка расчета оставшегося срока (daysLeft < 0)."
                $errorMessages.Add(("[{0}] {1}: {2}" -f $cert.Thumbprint.Substring(0,8), $cert.Subject, $certInfo.status_details))
                $overallCheckSuccess = $false
            } elseif ($daysLeft -le $minDaysLeftCriterion) {
                $certInfo.status = "Expiring (Fail)"
                $certInfo.status_details = "Осталось дней: $daysLeft (Требуется > $minDaysLeftCriterion)"
                $errorMessages.Add(("[{0}] {1}: {2}" -f $cert.Thumbprint.Substring(0,8), $cert.Subject, $certInfo.status_details))
                $overallCheckSuccess = $false
            } elseif ($daysLeft -le $minDaysWarning) {
                 $certInfo.status = "Expiring (Warn)"
                 $certInfo.status_details = "Осталось дней: $daysLeft (Предупреждение <= $minDaysWarning)" # Исправлен знак < на <=
                 Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Сертификат {0} скоро истекает ({1} дней)." -f $cert.Thumbprint, $daysLeft
            }

            $resultData.Details.certificates.Add($certInfo)
        }

        # Устанавливаем итоговый CheckSuccess
        $resultData.CheckSuccess = $overallCheckSuccess
        # Добавляем ошибки доступа к хранилищам, если они были
        if ($storeAccessErrors.Count -gt 0) {
             $errorMessages.Insert(0, ($storeAccessErrors -join '; ')) # Добавляем в начало
        }
        if ($errorMessages.Count -gt 0) {
            $resultData.ErrorMessage = $errorMessages -join '; '
            if ($resultData.ErrorMessage.Length -gt 1000) { $resultData.ErrorMessage = $resultData.ErrorMessage.Substring(0, 1000) + "..." }
        }
    }

} catch {
    # Ловим критические ошибки (например, некорректные параметры)
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "Ошибка проверки сертификатов: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    Write-Error "[$NodeName] Check-CERT_EXPIRY: Критическая ошибка: $errorMessage"
}

# Формируем и возвращаем стандартизированный результат
if (-not (Get-Command New-CheckResultObject -ErrorAction SilentlyContinue)) {
    Write-Error "[$NodeName] Check-CERT_EXPIRY: Не найдена функция New-CheckResultObject!"
    return $resultData
}
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Возвращаемый результат: $($finalResult | ConvertTo-Json -Depth 4 -Compress)"
return $finalResult