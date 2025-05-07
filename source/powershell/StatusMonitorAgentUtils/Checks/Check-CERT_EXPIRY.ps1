# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-CERT_EXPIRY.ps1
# --- Версия 2.1.0 --- Рефакторинг для читаемости, PS 5.1, улучшена обработка параметров и ошибок
<#
.SYNOPSIS
    Скрипт проверки сроков действия локально установленных сертификатов. (v2.1.0)
.DESCRIPTION
    Использует Get-ChildItem для поиска сертификатов в указанных или стандартных хранилищах.
    Позволяет фильтровать сертификаты по различным атрибутам (отпечаток, субъект, издатель, EKU, наличие приватного ключа).
    Рассчитывает количество дней до истечения и формирует статус для каждого сертификата.
    Формирует $Details с массивом 'certificates', содержащим подробную информацию.
    Вызывает Test-SuccessCriteria для определения CheckSuccess на основе собранных данных.
.PARAMETER TargetIP 
    [string] Опциональный. IP/Имя хоста (для логирования и контекста). Проверка сертификатов всегда выполняется локально.
.PARAMETER Parameters 
    [hashtable] Опциональный. Параметры для настройки поиска и фильтрации:
                - store_location ([string]): Расположение хранилища (например, 'LocalMachine', 'CurrentUser'). По умолчанию 'LocalMachine'.
                - store_name ([string]): Имя хранилища (например, 'My', 'WebHosting', 'Remote Desktop'). По умолчанию 'My'.
                                         Если store_location и store_name не указаны, используются стандартные хранилища.
                - subject_like ([string]): Фильтр по имени субъекта (CN). Wildcard '*' поддерживается.
                - issuer_like ([string]): Фильтр по имени издателя. Wildcard '*' поддерживается.
                - thumbprint ([string]): Точный отпечаток сертификата для поиска (приоритетный фильтр).
                - require_private_key ([bool]): Искать только сертификаты с приватным ключом. По умолчанию $false.
                - eku_oid ([string[]]): Массив OID'ов расширенного использования ключа.
                - min_days_warning ([int]): Дней до истечения для статуса 'ExpiringSoon'. По умолчанию 30.
.PARAMETER SuccessCriteria 
    [hashtable] Опциональный. Критерии успеха, применяемые к объекту $details.
                Часто используется для проверки массива 'certificates':
                @{ certificates = @{ _condition_='all'; _criteria_=@{days_left=@{'>'=14}; status=@{'!='='Expired'}} } }
.PARAMETER NodeName 
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS Hashtable - Стандартизированный результат.
.NOTES
    Версия: 2.1.0
    Зависит от New-CheckResultObject, Test-SuccessCriteria из модуля StatusMonitorAgentUtils.
#>
param(
    [Parameter(Mandatory = $false)] # Сделан не обязательным
    [string]$TargetIP,
    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node (CERT_EXPIRY)"
)

# --- Инициализация ---
$isAvailable = $false 
$checkSuccess = $null
$errorMessage = $null
$finalResult = $null
$details = @{
    certificates = [System.Collections.Generic.List[object]]::new()
    stores_checked = [System.Collections.Generic.List[string]]::new()
    filter_applied = $false
    parameters_used = @{ # Для отладки и информации в Details
        store_location = $null # Будут установлены из $Parameters или значения по умолчанию
        store_name = $null
        subject_like = $null
        issuer_like = $null
        thumbprint = $null
        require_private_key = $false # Значение по умолчанию
        eku_oid = $null
        min_days_warning = 30  # Значение по умолчанию
    }
    store_access_errors = [System.Collections.Generic.List[string]]::new()
}

$logTargetDisplay = if (-not [string]::IsNullOrWhiteSpace($TargetIP)) { $TargetIP } else { $env:COMPUTERNAME + " (локально)" }
Write-Verbose "[$NodeName] Check-CERT_EXPIRY (v2.1.0): Начало проверки сертификатов. Цель (контекст): $logTargetDisplay"

# --- Основной Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY >>>

    # --- 1. Обработка входных параметров ($Parameters) ---
    # Сохраняем используемые параметры в $details для информации
    if ($Parameters.ContainsKey('store_location')) { $details.parameters_used.store_location = $Parameters.store_location }
    if ($Parameters.ContainsKey('store_name')) { $details.parameters_used.store_name = $Parameters.store_name }
    if ($Parameters.ContainsKey('subject_like')) { $details.parameters_used.subject_like = $Parameters.subject_like }
    if ($Parameters.ContainsKey('issuer_like')) { $details.parameters_used.issuer_like = $Parameters.issuer_like }
    if ($Parameters.ContainsKey('thumbprint')) { $details.parameters_used.thumbprint = $Parameters.thumbprint }

    if ($Parameters.ContainsKey('require_private_key')) {
        try { $details.parameters_used.require_private_key = [bool]$Parameters.require_private_key }
        catch { Write-Warning "[$NodeName] Некорректное значение для 'require_private_key': '$($Parameters.require_private_key)'. Используется $($details.parameters_used.require_private_key)." }
    }
    if ($Parameters.ContainsKey('eku_oid') -and $Parameters.eku_oid -is [array]) {
        $details.parameters_used.eku_oid = @($Parameters.eku_oid | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
        if ($details.parameters_used.eku_oid.Count -eq 0) { $details.parameters_used.eku_oid = $null } # Если массив пуст после фильтрации
    }
    if ($Parameters.ContainsKey('min_days_warning')) {
        $parsedWarnDays = 0
        if ([int]::TryParse($Parameters.min_days_warning.ToString(), [ref]$parsedWarnDays) -and $parsedWarnDays -ge 0) {
            $details.parameters_used.min_days_warning = $parsedWarnDays
        } else {
            Write-Warning "[$NodeName] Некорректное значение min_days_warning: '$($Parameters.min_days_warning)'. Используется $($details.parameters_used.min_days_warning)."
        }
    }
    # Извлекаем значения для использования в скрипте
    $pStoreLoc = $details.parameters_used.store_location
    $pStoreName = $details.parameters_used.store_name
    $pSubjectLike = $details.parameters_used.subject_like
    $pIssuerLike = $details.parameters_used.issuer_like
    $pThumbprint = $details.parameters_used.thumbprint
    $pRequirePK = $details.parameters_used.require_private_key
    $pEkuOids = $details.parameters_used.eku_oid
    $pMinDaysWarn = $details.parameters_used.min_days_warning
    
    # --- 2. Определение хранилищ для поиска и сам поиск ---
    $storesToSearchConfig = [System.Collections.Generic.List[object]]::new()
    $useSpecificStoreParam = (-not [string]::IsNullOrWhiteSpace($pStoreLoc)) -and (-not [string]::IsNullOrWhiteSpace($pStoreName))

    if ($useSpecificStoreParam) {
        $storesToSearchConfig.Add(@{ Path = "Cert:\$pStoreLoc\$pStoreName"; Location = $pStoreLoc; Name = $pStoreName })
        Write-Verbose "[$NodeName] Поиск будет произведен в указанном хранилище: Cert:\$pStoreLoc\$pStoreName"
    } else {
        Write-Verbose "[$NodeName] Поиск будет произведен в стандартных хранилищах."
        $storesToSearchConfig.Add(@{ Path = "Cert:\LocalMachine\My"; Location = "LocalMachine"; Name = "My" })
        $storesToSearchConfig.Add(@{ Path = "Cert:\LocalMachine\WebHosting"; Location = "LocalMachine"; Name = "WebHosting" })
        $storesToSearchConfig.Add(@{ Path = "Cert:\CurrentUser\My"; Location = "CurrentUser"; Name = "My" })
        # $storesToSearchConfig.Add(@{ Path = "Cert:\LocalMachine\Remote Desktop"; Location = "LocalMachine"; Name = "Remote Desktop" })
    }

    $allFoundCertificatesList = [System.Collections.Generic.List[PSObject]]::new() # Типизированный список

    foreach ($storeInfo in $storesToSearchConfig) {
        $currentStorePath = $storeInfo.Path
        $details.stores_checked.Add($currentStorePath)
        Write-Verbose "[$NodeName] Проверка хранилища: $currentStorePath"
        try {
            if (-not (Test-Path -Path $currentStorePath -PathType Container -ErrorAction SilentlyContinue)) {
                $storeErrorMsg = "Хранилище '$currentStorePath' не найдено или недоступно."
                Write-Warning "[$NodeName] $storeErrorMsg"
                $details.store_access_errors.Add($storeErrorMsg)
                continue # Переходим к следующему хранилищу
            }
            
            $certsInCurrentStore = Get-ChildItem -Path $currentStorePath -ErrorAction SilentlyContinue
            if ($Error.Count -gt 0) { # Ошибки при Get-ChildItem
                ($Error | ForEach-Object { 
                    $errMsg = "Ошибка доступа к '$currentStorePath': $($_.Exception.Message.Trim())"
                    Write-Warning "[$NodeName] $errMsg"; $details.store_access_errors.Add($errMsg)
                })
                $Error.Clear()
            }
            if ($null -ne $certsInCurrentStore) {
                # Get-ChildItem может вернуть один объект или массив, приводим к массиву
                $certsInCurrentStoreArray = @($certsInCurrentStore)
                $allFoundCertificatesList.AddRange($certsInCurrentStoreArray)
                Write-Verbose "[$NodeName] В '$currentStorePath' найдено сертификатов: $($certsInCurrentStoreArray.Count)"
            }
        } catch { # Критическая ошибка, не связанная с Get-ChildItem (например, Test-Path)
            $criticalErrorMsg = "Непредвиденная ошибка при работе с хранилищем '$currentStorePath': $($_.Exception.Message.Trim())"
            Write-Warning "[$NodeName] $criticalErrorMsg"
            $details.store_access_errors.Add($criticalErrorMsg)
        }
    }

    if ($details.stores_checked.Count -eq 0) { # Не было задано ни одного хранилища, или все указанные не существуют
        $isAvailable = $false
        $errorMessage = "Не указаны или не найдены хранилища для проверки сертификатов."
        throw $errorMessage 
    }
    # Если хотя бы одно хранилище было проверено (даже с ошибкой доступа, но путь был валиден), считаем проверку доступной
    $isAvailable = $true 
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: IsAvailable=$isAvailable. Всего найдено сертификатов до фильтрации: $($allFoundCertificatesList.Count)."

    # --- 3. Фильтрация сертификатов ---
    $filteredCerts = $allFoundCertificatesList # Начинаем с полного списка
    
    if (-not [string]::IsNullOrWhiteSpace($pThumbprint)) {
        $details.filter_applied = $true
        $normalizedThumbprint = $pThumbprint.Trim().ToUpper() # Отпечатки обычно в верхнем регистре и без пробелов
        $filteredCerts = $filteredCerts | Where-Object { $_.Thumbprint -eq $normalizedThumbprint }
        Write-Verbose "[$NodeName] После фильтра по отпечатку ('$normalizedThumbprint'): $($filteredCerts.Count) серт."
    } else {
        # Фильтры по Subject и Issuer применяются, только если Thumbprint не указан
        if (-not [string]::IsNullOrWhiteSpace($pSubjectLike)) {
            $details.filter_applied = $true
            $filteredCerts = $filteredCerts | Where-Object { $_.Subject -like $pSubjectLike }
            Write-Verbose "[$NodeName] После фильтра по Subject ('$pSubjectLike'): $($filteredCerts.Count) серт."
        }
        if (-not [string]::IsNullOrWhiteSpace($pIssuerLike)) {
            $details.filter_applied = $true
            $filteredCerts = $filteredCerts | Where-Object { $_.Issuer -like $pIssuerLike }
            Write-Verbose "[$NodeName] После фильтра по Issuer ('$pIssuerLike'): $($filteredCerts.Count) серт."
        }
    }

    if ($pRequirePK) {
        $details.filter_applied = $true
        $filteredCerts = $filteredCerts | Where-Object { $_.HasPrivateKey }
        Write-Verbose "[$NodeName] После фильтра 'require_private_key=$true': $($filteredCerts.Count) серт."
    }

    if ($pEkuOids -is [array] -and $pEkuOids.Count -gt 0) {
        $details.filter_applied = $true
        $filteredCerts = $filteredCerts | Where-Object {
            $certToTestEku = $_
            $ekuExtension = $certToTestEku.Extensions | Where-Object { $_.Oid -and $_.Oid.FriendlyName -eq 'Enhanced Key Usage' }
            if ($ekuExtension -and $ekuExtension.EnhancedKeyUsages) {
                # Проверяем, содержит ли сертификат ХОТЯ БЫ ОДИН из указанных EKU OID
                foreach ($requiredOid in $pEkuOids) {
                    if ($ekuExtension.EnhancedKeyUsages.Oid -contains $requiredOid) {
                        return $true # Нашли совпадение
                    }
                }
            }
            return $false # Совпадений не найдено или нет EKU
        }
        Write-Verbose "[$NodeName] После фильтра по EKU OIDs ('$($pEkuOids -join ',')'): $($filteredCerts.Count) серт."
    }

    if (-not $details.filter_applied -and $allFoundCertificatesList.Count -gt 0) {
        Write-Verbose "[$NodeName] Фильтры не применялись. Обрабатываются все $($allFoundCertificatesList.Count) найденных сертификатов."
    } elseif ($details.filter_applied -and $filteredCerts.Count -eq 0 -and $allFoundCertificatesList.Count -gt 0) {
         Write-Verbose "[$NodeName] После применения фильтров не осталось сертификатов (было: $($allFoundCertificatesList.Count))."
    }

    # --- 4. Формирование $details.certificates из отфильтрованного списка ---
    $currentTimeUtc = (Get-Date).ToUniversalTime() # Получаем один раз для консистентности
    if ($filteredCerts.Count -eq 0) {
        $message = "Сертификаты"
        if ($details.filter_applied) { $message += ", соответствующие заданным фильтрам," }
        $message += " не найдены"
        if ($allFoundCertificatesList.Count -gt 0 -and $details.filter_applied) {
            $message += " (всего до фильтрации было $($allFoundCertificatesList.Count) в проверенных хранилищах)."
        } elseif ($allFoundCertificatesList.Count -eq 0) {
            $message += " (в проверенных хранилищах сертификатов не обнаружено)."
        }
        $details.message = $message
    } else {
        foreach ($certToProcess in $filteredCerts) {
            $daysLeftValue = -9999 # Значение по умолчанию при ошибке
            try { 
                # NotAfter это DateTime, Start тоже DateTime
                $timeSpanToExpire = New-TimeSpan -Start $currentTimeUtc -End $certToProcess.NotAfter.ToUniversalTime()
                $daysLeftValue = [math]::Floor($timeSpanToExpire.TotalDays) 
            } catch { 
                Write-Warning "[$NodeName] Не удалось рассчитать days_left для сертификата $($certToProcess.Thumbprint): $($_.Exception.Message)"
            }

            $certCurrentStatus = "OK"
            $certCurrentStatusDetails = ""

            if ($currentTimeUtc -gt $certToProcess.NotAfter.ToUniversalTime()) {
                $certCurrentStatus = "Expired"
                $certCurrentStatusDetails = "Сертификат истек $($certToProcess.NotAfter.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')) ($daysLeftValue дней назад)."
            } elseif ($daysLeftValue -le $pMinDaysWarn) { 
                $certCurrentStatus = "ExpiringSoon"
                $certCurrentStatusDetails = "Сертификат истекает через $daysLeftValue дней (порог предупреждения: $pMinDaysWarn дней или менее)."
            }
            
            $certInfoObject = @{ 
                thumbprint        = $certToProcess.Thumbprint
                subject           = $certToProcess.Subject
                issuer            = $certToProcess.Issuer
                not_before_utc    = $certToProcess.NotBefore.ToUniversalTime().ToString("o")
                not_after_utc     = $certToProcess.NotAfter.ToUniversalTime().ToString("o")
                days_left         = $daysLeftValue
                has_private_key   = $certToProcess.HasPrivateKey
                status            = $certCurrentStatus
                status_details    = $certCurrentStatusDetails
                store_path        = $certToProcess.PSParentPath 
            }
            $details.certificates.Add([PSCustomObject]$certInfoObject) 
        }
        $details.certificates = $details.certificates | Sort-Object days_left # Сортируем по оставшимся дням
    }
    # Копируем использованные параметры в детали, чтобы они были видны
    $details.parameters_used = $details.parameters_used 

    # --- 5. Проверка критериев успеха ---
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Вызов Test-SuccessCriteria..."
            $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
            
            $checkSuccess = $criteriaProcessingResult.Passed
            $failReasonFromCriteria = $criteriaProcessingResult.FailReason

            if ($checkSuccess -ne $true) {
                if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) {
                    $errorMessage = $failReasonFromCriteria
                } else {
                    $errorMessage = "Критерии успеха для сертификатов не пройдены (CheckSuccess: $($checkSuccess | ForEach-Object {if ($_ -eq $null) {'[null]'} else {$_}}))."
                }
                Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria НЕ пройдены или ошибка оценки. ErrorMessage: $errorMessage"
            } else {
                $errorMessage = $null 
                Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria пройдены."
            }
        } else {
            # Критерии не заданы. По умолчанию считаем успешным, если isAvailable.
            # Однако, если были ошибки доступа к хранилищам, это может быть неполный успех.
            $checkSuccess = $true 
            $errorMessage = $null
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria не заданы, CheckSuccess установлен в true (т.к. IsAvailable=true)."
        }
        
        # Добавляем информацию об ошибках доступа к хранилищам в ErrorMessage, если проверка в остальном успешна
        if ($details.store_access_errors.Count -gt 0 -and $checkSuccess -eq $true) {
            $accessErrorString = "При проверке сертификатов были ошибки доступа к некоторым хранилищам: $($details.store_access_errors -join '; ')"
            $errorMessage = if ([string]::IsNullOrEmpty($errorMessage)) { $accessErrorString } else { "$errorMessage; $accessErrorString" }
            # Можно решить, должен ли $checkSuccess стать $null или $false в этом случае.
            # Например, если полный доступ ко всем хранилищам критичен:
            # $checkSuccess = $false 
            Write-Warning "[$NodeName] $accessErrorString. CheckSuccess остается $checkSuccess."
        }

    } else { 
        $checkSuccess = $null 
        if ([string]::IsNullOrEmpty($errorMessage)) { 
            $errorMessage = "Ошибка проверки сертификатов (IsAvailable=false), критерии не проверялись."
        }
    }

    # --- 6. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch { # <<< ОСНОВНОЙ CATCH для критических ошибок скрипта >>>
    $isAvailable = $false 
    $checkSuccess = $null   
    
    $critErrorMessageFromCatch = "Критическая ошибка в Check-CERT_EXPIRY: $($_.Exception.Message)"
    Write-Error "[$NodeName] Check-CERT_EXPIRY: $critErrorMessageFromCatch ScriptStackTrace: $($_.ScriptStackTrace)"
    
    # Заполняем детали информацией об ошибке
    if ($null -eq $details) { $details = @{ certificates = [System.Collections.Generic.List[object]]::new() } } # Гарантируем, что $details - хэш
    $details.error = $critErrorMessageFromCatch
    $details.ErrorRecord = $_.ToString()
    if ($Parameters -and $Parameters.Count -gt 0) { $details.parameters_used_on_error = $Parameters }
    
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $critErrorMessageFromCatch
} # <<< КОНЕЦ ОСНОВНОГО CATCH >>>

# --- Отладка перед возвратом ---
Write-Host "DEBUG (Check-CERT_EXPIRY): --- Начало отладки finalResult.Details ---" -ForegroundColor Green
# ... (ваш отладочный блок) ...
if ($finalResult -and $finalResult.Details) {
    Write-Host "DEBUG (Check-CERT_EXPIRY): Тип finalResult.Details: $($finalResult.Details.GetType().FullName)" -ForegroundColor Green
    if ($finalResult.Details -is [hashtable]) {
        Write-Host "DEBUG (Check-CERT_EXPIRY): Ключи в finalResult.Details: $($finalResult.Details.Keys -join ', ')" -ForegroundColor Green
        if ($finalResult.Details.ContainsKey('certificates')) {
             Write-Host "DEBUG (Check-CERT_EXPIRY): Количество сертификатов в Details: $($finalResult.Details.certificates.Count)" -ForegroundColor Green
        }
        if ($finalResult.Details.ContainsKey('parameters_used')) {
             Write-Host "DEBUG (Check-CERT_EXPIRY): Параметры использованные: $($finalResult.Details.parameters_used | ConvertTo-Json -Compress -Depth 2)" -ForegroundColor Green
        }
    }
} elseif ($finalResult) { Write-Host "DEBUG (Check-CERT_EXPIRY): finalResult.Details является $null или отсутствует." -ForegroundColor Yellow }
else { Write-Host "DEBUG (Check-CERT_EXPIRY): finalResult сам по себе $null." -ForegroundColor Red }
Write-Host "DEBUG (Check-CERT_EXPIRY): --- Конец отладки finalResult.Details ---" -ForegroundColor Green

# --- Возврат результата ---
$isAvailableStrForLog = if ($finalResult) { $finalResult.IsAvailable } else { '[finalResult is null]' }
$checkSuccessStrForLog = if ($finalResult) { if ($null -eq $finalResult.CheckSuccess) {'[null]'} else {$finalResult.CheckSuccess} } else { '[finalResult is null]' }
Write-Verbose "[$NodeName] Check-CERT_EXPIRY (v2.1.0): Завершение. IsAvailable=$isAvailableStrForLog, CheckSuccess=$checkSuccessStrForLog"

return $finalResult