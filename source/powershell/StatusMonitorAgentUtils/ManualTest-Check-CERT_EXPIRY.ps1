# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-CERT_EXPIRY.ps1
# --- Версия 2.1.5 --- Используем обычный массив PowerShell для $allFoundCertificatesList

<#
.SYNOPSIS
    Скрипт проверки сроков действия локально установленных сертификатов Windows. (v2.1.5)
.DESCRIPTION
    Этот скрипт выполняет поиск сертификатов в указанных или стандартных хранилищах
    локальной машины или текущего пользователя. Он позволяет фильтровать найденные
    сертификаты по различным атрибутам, таким как отпечаток (thumbprint), имя субъекта (subject),
    имя издателя (issuer), расширенное использование ключа (EKU OID) и наличие приватного ключа.

    Для каждого отфильтрованного сертификата скрипт рассчитывает:
    - Количество дней, оставшихся до истечения срока действия.
    - Текущий статус ('OK', 'Expired' - истек, 'ExpiringSoon' - скоро истекает).

    Результаты собираются в структурированный объект $Details, который включает:
    - Массив 'certificates' с подробной информацией о каждом подходящем сертификате.
    - Список проверенных хранилищ ('stores_checked').
    - Список ошибок доступа к хранилищам ('store_access_errors').
    - Использованные параметры фильтрации ('parameters_used').
    - Сообщение, если сертификаты по фильтрам не найдены ('message').

    Скрипт определяет общую доступность проверки (IsAvailable):
    - $true, если удалось хотя бы попытаться прочитать сконфигурированные хранилища.
    - $false, если произошла критическая ошибка, не позволяющая начать проверку.

    Если проверка доступна (IsAvailable=$true) и переданы критерии успеха ($SuccessCriteria),
    вызывается функция Test-SuccessCriteria для определения поля CheckSuccess.
    - CheckSuccess=$true: Критерии выполнены.
    - CheckSuccess=$false: Критерии не выполнены.
    - CheckSuccess=$null: Критерии не заданы, ИЛИ произошла ошибка при их оценке, ИЛИ
                         были ошибки доступа к некоторым хранилищам, что делает результат
                         неоднозначным (даже если формально критерии для найденных сертификатов прошли).

    Итоговый ErrorMessage формируется на основе ошибок выполнения или провала критериев.
.PARAMETER TargetIP
    [string] Опциональный. IP-адрес или имя хоста. В текущей реализации скрипт всегда
             проверяет сертификаты на ЛОКАЛЬНОЙ машине. Этот параметр используется
             преимущественно для логирования и контекста в системе мониторинга,
             чтобы связать результат с конкретным узлом, даже если проверка локальная.
.PARAMETER Parameters
    [hashtable] Опциональный. Хэш-таблица с параметрами для настройки поиска и фильтрации сертификатов:
                - store_location ([string]): Расположение хранилища сертификатов.
                                             Допустимые значения: 'LocalMachine', 'CurrentUser'.
                                             По умолчанию, если не указано вместе с store_name,
                                             проверяются стандартные расположения.
                - store_name ([string]): Имя хранилища сертификатов (например, 'My', 'WebHosting', 'CA', 'Root').
                                         По умолчанию, если не указано вместе с store_location,
                                         проверяются стандартные хранилища ('My', 'WebHosting').
                                         Если store_location и store_name указаны, поиск ведется только в этом хранилище.
                - subject_like ([string]): Фильтр по имени субъекта сертификата (поле Subject).
                                           Поддерживаются wildcard символы PowerShell (например, '*example.com').
                                           Применяется, если 'thumbprint' не указан.
                - issuer_like ([string]): Фильтр по имени издателя сертификата (поле Issuer).
                                          Поддерживаются wildcard. Применяется, если 'thumbprint' не указан.
                - thumbprint ([string]): Точный отпечаток (thumbprint) сертификата для поиска.
                                         Если указан, другие фильтры (subject_like, issuer_like) игнорируются для поиска,
                                         но могут быть использованы в $SuccessCriteria._where_.
                - require_private_key ([bool]): Флаг, указывающий, что нужно искать только сертификаты,
                                                имеющие связанный приватный ключ. По умолчанию $false.
                - eku_oid ([string[]]): Массив строк, содержащих OID (Object Identifier) для расширенного
                                       использования ключа (EKU). Сертификат будет выбран, если он содержит
                                       хотя бы один из указанных OID в своем EKU.
                                       Пример EKU OID для SSL Server Authentication: '1.3.6.1.5.5.7.3.1'.
                - min_days_warning ([int]): Порог в днях для определения статуса 'ExpiringSoon'.
                                            Если до истечения сертификата осталось дней меньше или равно этому значению,
                                            сертификат получит статус 'ExpiringSoon'. По умолчанию 30 дней.
                                            Это значение не влияет на CheckSuccess напрямую, только на статус в деталях.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Хэш-таблица с критериями для определения успешности проверки (CheckSuccess).
                Критерии применяются к объекту $Details, который формируется этим скриптом.
                Чаще всего используется для проверки массива '$Details.certificates'.
                Пример: Проверить, что все найденные SSL-сертификаты действительны еще как минимум 14 дней:
                @{
                    certificates = @{
                        _condition_ = 'all' # Применить ко всем элементам массива
                        _where_ = @{ # Опциональный фильтр для элементов массива
                            # Например, status = @{'!=' = 'Expired'}
                        }
                        _criteria_ = @{ # Критерии для проверки каждого (отфильтрованного) элемента
                            days_left = @{ '>=' = 14 }
                        }
                    }
                }
.PARAMETER NodeName
    [string] Опциональный. Имя узла, для которого выполняется проверка (для логирования).
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки, созданный функцией New-CheckResultObject.
.NOTES
    Версия: 2.1.5
    Изменения:
    - $allFoundCertificatesList теперь обычный массив PowerShell (@()), чтобы избежать проблем с типизацией Generic List.
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria из модуля StatusMonitorAgentUtils.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetIP,
    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node (CERT_EXPIRY)"
)

# --- Инициализация переменных результата и деталей ---
$isAvailable = $false
$checkSuccess = $null
$errorMessage = $null
$finalResult = $null

$details = @{
    certificates        = [System.Collections.Generic.List[object]]::new() # Для финальных деталей PSCustomObject
    stores_checked      = [System.Collections.Generic.List[string]]::new()
    filter_applied      = $false
    parameters_used     = @{
        store_location      = $null
        store_name          = $null
        subject_like        = $null
        issuer_like         = $null
        thumbprint          = $null
        require_private_key = $false
        eku_oid             = $null
        min_days_warning    = 30
    }
    store_access_errors = [System.Collections.Generic.List[string]]::new()
}

$logTargetDisplay = if (-not [string]::IsNullOrWhiteSpace($TargetIP)) { $TargetIP } else { "$($env:COMPUTERNAME) (локально)" }
Write-Verbose "[$NodeName] Check-CERT_EXPIRY (v2.1.5): Начало проверки. Цель (контекст): $logTargetDisplay"

# --- Основной блок Try/Catch ---
try {
    # --- 1. Обработка и валидация входных параметров ($Parameters) ---
    if ($Parameters.ContainsKey('store_location')) { $details.parameters_used.store_location = $Parameters.store_location }
    if ($Parameters.ContainsKey('store_name')) { $details.parameters_used.store_name = $Parameters.store_name }
    if ($Parameters.ContainsKey('subject_like')) { $details.parameters_used.subject_like = $Parameters.subject_like }
    if ($Parameters.ContainsKey('issuer_like')) { $details.parameters_used.issuer_like = $Parameters.issuer_like }
    if ($Parameters.ContainsKey('thumbprint')) { $details.parameters_used.thumbprint = $Parameters.thumbprint }
    if ($Parameters.ContainsKey('require_private_key')) {
        try { $details.parameters_used.require_private_key = [bool]$Parameters.require_private_key }
        catch { Write-Warning "[$NodeName] Некорректное значение для 'require_private_key': '$($Parameters.require_private_key)'. Используется значение по умолчанию ($($details.parameters_used.require_private_key))." }
    }
    if ($Parameters.ContainsKey('eku_oid') -and $Parameters.eku_oid -is [array]) {
        $details.parameters_used.eku_oid = @($Parameters.eku_oid | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($details.parameters_used.eku_oid.Count -eq 0) { $details.parameters_used.eku_oid = $null }
    }
    if ($Parameters.ContainsKey('min_days_warning')) {
        $parsedWarnDays = 0
        if ([int]::TryParse($Parameters.min_days_warning.ToString(), [ref]$parsedWarnDays) -and $parsedWarnDays -ge 0) {
            $details.parameters_used.min_days_warning = $parsedWarnDays
        } else {
            Write-Warning "[$NodeName] Некорректное значение для 'min_days_warning': '$($Parameters.min_days_warning)'. Используется значение по умолчанию ($($details.parameters_used.min_days_warning))."
        }
    }
    $pStoreLoc    = $details.parameters_used.store_location
    $pStoreName   = $details.parameters_used.store_name
    $pSubjectLike = $details.parameters_used.subject_like
    $pIssuerLike  = $details.parameters_used.issuer_like
    $pThumbprint  = $details.parameters_used.thumbprint
    $pRequirePK   = $details.parameters_used.require_private_key
    $pEkuOids     = $details.parameters_used.eku_oid
    $pMinDaysWarn = $details.parameters_used.min_days_warning
    
    # --- 2. Определение хранилищ для поиска и сам поиск сертификатов ---
    $storesToSearchConfig = [System.Collections.Generic.List[object]]::new()
    $useSpecificStoreParam = (-not [string]::IsNullOrWhiteSpace($pStoreLoc)) -and (-not [string]::IsNullOrWhiteSpace($pStoreName))

    if ($useSpecificStoreParam) {
        $storesToSearchConfig.Add(@{ Path = "Cert:\$pStoreLoc\$pStoreName"; Location = $pStoreLoc; Name = $pStoreName })
        Write-Verbose "[$NodeName] Поиск будет произведен только в указанном хранилище: Cert:\$pStoreLoc\$pStoreName"
    } else {
        Write-Verbose "[$NodeName] Поиск будет произведен в стандартных хранилищах (LocalMachine\My, LocalMachine\WebHosting, CurrentUser\My)."
        $storesToSearchConfig.Add(@{ Path = "Cert:\LocalMachine\My"; Location = "LocalMachine"; Name = "My" })
        $storesToSearchConfig.Add(@{ Path = "Cert:\LocalMachine\WebHosting"; Location = "LocalMachine"; Name = "WebHosting" })
        $storesToSearchConfig.Add(@{ Path = "Cert:\CurrentUser\My"; Location = "CurrentUser"; Name = "My" })
    }

    # --- ИСПОЛЬЗУЕМ ОБЫЧНЫЙ МАССИВ POWERSHELL ---
    $allFoundCertificatesList = @()

    foreach ($storeInfo in $storesToSearchConfig) {
        $currentStorePath = $storeInfo.Path
        $details.stores_checked.Add($currentStorePath)
        Write-Verbose "[$NodeName] Проверка хранилища: '$currentStorePath'"
        $currentStoreErrorMessage = $null 
        $storeExistsAndAccessible = $false
        
        $Error.Clear() # Очищаем перед каждой операцией с хранилищем
        try {
            try {
                $storeExistsAndAccessible = Test-Path -Path $currentStorePath -PathType Container -ErrorAction Stop
            } catch {
                $currentStoreErrorMessage = "Ошибка Test-Path для '$currentStorePath': $($_.Exception.Message.Trim())"
                Write-Warning "[$NodeName] $currentStoreErrorMessage"
            }

            if ($storeExistsAndAccessible) {
                $Error.Clear() 
                $certsInCurrentStore = Get-ChildItem -Path $currentStorePath -ErrorAction SilentlyContinue
                
                if ($Error.Count -gt 0) {
                    $gciErrorMessages = ($Error | ForEach-Object { $_.Exception.Message.Trim() }) -join "; "
                    $currentStoreErrorMessage = "Ошибка(и) Get-ChildItem для '$currentStorePath': $gciErrorMessages"
                    Write-Warning "[$NodeName] $currentStoreErrorMessage"
                    $Error.Clear() 
                } elseif ($null -ne $certsInCurrentStore) {
                    # Добавляем в обычный массив PowerShell
                    $allFoundCertificatesList += @($certsInCurrentStore)
                    Write-Verbose "[$NodeName] В '$currentStorePath' найдено сертификатов: $(@($certsInCurrentStore).Count)"
                } else { 
                    Write-Verbose "[$NodeName] В '$currentStorePath' сертификаты не найдены (но хранилище доступно)."
                }
            } elseif (-not $currentStoreErrorMessage) { 
                $currentStoreErrorMessage = "Хранилище '$currentStorePath' не найдено (Test-Path вернул false)."
                Write-Warning "[$NodeName] $currentStoreErrorMessage"
            }
        } catch { 
            $currentStoreErrorMessage = "Непредвиденная ошибка при доступе к '$currentStorePath': $($_.Exception.Message.Trim())"
            Write-Warning "[$NodeName] $currentStoreErrorMessage"
        }
        
        if ($currentStoreErrorMessage) {
            $details.store_access_errors.Add($currentStoreErrorMessage)
        }
    }

    if ($details.stores_checked.Count -eq 0) {
        $isAvailable = $false
        $errorMessage = "Не сконфигурированы хранилища для проверки."
        throw $errorMessage
    }
    $isAvailable = $true 
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: IsAvailable=$isAvailable. Всего найдено сертификатов (до фильтрации): $($allFoundCertificatesList.Count)."

    # --- 3. Фильтрация найденных сертификатов ---
    $filteredCerts = $allFoundCertificatesList # $allFoundCertificatesList теперь обычный массив
    
    if (-not [string]::IsNullOrWhiteSpace($pThumbprint)) {
        $details.filter_applied = $true
        $normalizedThumbprint = $pThumbprint.Trim().ToUpper()
        $filteredCerts = $filteredCerts | Where-Object { $_.Thumbprint -eq $normalizedThumbprint }
        Write-Verbose "[$NodeName] Применен фильтр по отпечатку ('$normalizedThumbprint'). Найдено: $($filteredCerts.Count) серт."
    } else {
        # Фильтры по Subject и Issuer применяются, только если Thumbprint не указан
        if (-not [string]::IsNullOrWhiteSpace($pSubjectLike)) {
            $details.filter_applied = $true
            $filteredCerts = $filteredCerts | Where-Object { $_.Subject -like $pSubjectLike }
            Write-Verbose "[$NodeName] Применен фильтр по Subject ('$pSubjectLike'). Найдено: $($filteredCerts.Count) серт."
        }
        if (-not [string]::IsNullOrWhiteSpace($pIssuerLike)) {
            $details.filter_applied = $true
            $filteredCerts = $filteredCerts | Where-Object { $_.Issuer -like $pIssuerLike }
            Write-Verbose "[$NodeName] Применен фильтр по Issuer ('$pIssuerLike'). Найдено: $($filteredCerts.Count) серт."
        }
    }

    if ($pRequirePK) {
        $details.filter_applied = $true
        $filteredCerts = $filteredCerts | Where-Object { $_.HasPrivateKey }
        Write-Verbose "[$NodeName] Применен фильтр 'require_private_key=$true'. Найдено: $($filteredCerts.Count) серт."
    }

    if ($pEkuOids -is [array] -and $pEkuOids.Count -gt 0) {
        $details.filter_applied = $true
        $filteredCerts = $filteredCerts | Where-Object {
            $certToTestEku = $_
            $ekuExtension = $certToTestEku.Extensions | Where-Object { $_.Oid -and $_.Oid.FriendlyName -eq 'Enhanced Key Usage' }
            if ($ekuExtension -and $ekuExtension.EnhancedKeyUsages) {
                foreach ($requiredOid in $pEkuOids) {
                    if ($ekuExtension.EnhancedKeyUsages.Oid -contains $requiredOid) {
                        return $true 
                    }
                }
            }
            return $false 
        }
        Write-Verbose "[$NodeName] Применен фильтр по EKU OIDs ('$($pEkuOids -join ',')'). Найдено: $($filteredCerts.Count) серт."
    }

    if (-not $details.filter_applied -and $allFoundCertificatesList.Count -gt 0) {
        Write-Verbose "[$NodeName] Фильтры не применялись. Обрабатываются все $($allFoundCertificatesList.Count) найденных сертификатов."
    } elseif ($details.filter_applied -and $filteredCerts.Count -eq 0 -and $allFoundCertificatesList.Count -gt 0) {
         Write-Verbose "[$NodeName] После применения фильтров не осталось сертификатов (было найдено до фильтрации: $($allFoundCertificatesList.Count))."
    }

    # --- 4. Формирование массива $details.certificates из отфильтрованного списка ---
    $currentTimeUtc = (Get-Date).ToUniversalTime()
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
        Write-Verbose "[$NodeName] $message"
    } else {
        foreach ($certToProcess in $filteredCerts) {
            $daysLeftValue = -9999 
            try { 
                $timeSpanToExpire = New-TimeSpan -Start $currentTimeUtc -End $certToProcess.NotAfter.ToUniversalTime()
                $daysLeftValue = [math]::Floor($timeSpanToExpire.TotalDays) 
            } catch { 
                Write-Warning "[$NodeName] Не удалось рассчитать days_left для сертификата '$($certToProcess.Thumbprint)': $($_.Exception.Message)"
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
        $details.certificates = $details.certificates | Sort-Object days_left 
        Write-Verbose "[$NodeName] Сформирован список из $($details.certificates.Count) отфильтрованных сертификатов."
    }
    $details.parameters_used = $details.parameters_used

    # --- 5. Проверка критериев успеха ($SuccessCriteria) ---
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Вызов Test-SuccessCriteria для оценки результатов..."
            $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
            
            $checkSuccess = $criteriaProcessingResult.Passed
            $failReasonFromCriteria = $criteriaProcessingResult.FailReason

            if ($checkSuccess -ne $true) {
                if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) {
                    $errorMessage = $failReasonFromCriteria
                } else {
                    $errorMessage = "Критерии успеха для проверки сертификатов не пройдены (CheckSuccess: $($checkSuccess | ForEach-Object {if ($_ -eq $null) {'[null]'} else {$_}}))."
                }
                Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria НЕ пройдены или была ошибка их оценки. ErrorMessage: $errorMessage"
            } else {
                $errorMessage = $null 
                Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria успешно пройдены."
            }
        } else {
            if ($details.store_access_errors.Count -eq 0) {
                $checkSuccess = $true
            } else {
                if ($details.certificates.Count -gt 0) {
                    $checkSuccess = $true 
                } else {
                    $checkSuccess = $false 
                    $errorMessage = "Сертификаты не найдены, возможно, из-за ошибок доступа к некоторым хранилищам (критерии не заданы)."
                }
            }
            if ($checkSuccess -eq $true -and $errorMessage -eq $null -and $details.certificates.Count -eq 0 -and (-not $details.filter_applied)) {
                 # $errorMessage = "Сертификаты не найдены (фильтры не применялись, ошибок доступа не было)." # Информационное сообщение
            }
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria не заданы. CheckSuccess установлен в '$checkSuccess' (на основе ошибок доступа и наличия сертификатов)."
        }
        
        if ($details.store_access_errors.Count -gt 0) {
            $accessErrorString = "При проверке сертификатов были ошибки доступа к некоторым хранилищам: $($details.store_access_errors -join '; ')"
            $errorMessage = if ([string]::IsNullOrEmpty($errorMessage)) { $accessErrorString } else { "$errorMessage; $accessErrorString" }
            Write-Warning "[$NodeName] $accessErrorString."
            if ($checkSuccess -eq $true) {
                 $checkSuccess = $null 
                 Write-Warning "[$NodeName] CheckSuccess изменен на `$null из-за ошибок доступа к хранилищам, несмотря на прохождение критериев (или их отсутствие)."
            }
        }
    } else { 
        $checkSuccess = $null 
        if ([string]::IsNullOrEmpty($errorMessage)) { 
            $errorMessage = "Ошибка выполнения проверки сертификатов (IsAvailable=false), критерии не проверялись."
        }
    }

    # --- 6. Формирование итогового объекта результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch { # Перехват любых других непредвиденных исключений в скрипте
    $isAvailable = $false 
    $checkSuccess = $null   
    
    $critErrorMessageFromCatch = "Критическая непредвиденная ошибка в Check-CERT_EXPIRY: $($_.Exception.Message)"
    Write-Error "[$NodeName] Check-CERT_EXPIRY: $critErrorMessageFromCatch ScriptStackTrace: $($_.ScriptStackTrace)"
    
    if ($null -eq $details) { $details = @{ certificates = [System.Collections.Generic.List[object]]::new() } } # Гарантируем, что $details - это Hashtable
    $details.error = $critErrorMessageFromCatch
    $details.ErrorRecord = $_.ToString()
    if ($Parameters -and $Parameters.Count -gt 0) { $details.parameters_used_on_error = $Parameters }
    
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $critErrorMessageFromCatch
} # Конец основного Try/Catch

# --- Блок отладки перед возвратом результата ---
if ($MyInvocation.BoundParameters.Debug -or ($DebugPreference -ne 'SilentlyContinue' -and $DebugPreference -ne 'Ignore')) {
    Write-Host "DEBUG (Check-CERT_EXPIRY): --- Начало отладки итогового объекта finalResult.Details ---" -ForegroundColor Green
    if ($finalResult -and $finalResult.Details) {
        Write-Host "DEBUG (Check-CERT_EXPIRY): Тип finalResult.Details: $($finalResult.Details.GetType().FullName)" -ForegroundColor Green
        if ($finalResult.Details -is [hashtable]) {
            Write-Host "DEBUG (Check-CERT_EXPIRY): Ключи в finalResult.Details: $($finalResult.Details.Keys -join ', ')" -ForegroundColor Green
            if ($finalResult.Details.ContainsKey('certificates')) {
                Write-Host "DEBUG (Check-CERT_EXPIRY): Количество сертификатов в Details: $($finalResult.Details.certificates.Count)" -ForegroundColor Green
            }
            if ($finalResult.Details.ContainsKey('parameters_used')) {
                Write-Host "DEBUG (Check-CERT_EXPIRY): Параметры, использованные для проверки: $($finalResult.Details.parameters_used | ConvertTo-Json -Compress -Depth 2)" -ForegroundColor Green
            }
            if ($finalResult.Details.ContainsKey('store_access_errors') -and $finalResult.Details.store_access_errors.Count -gt 0) {
                Write-Host "DEBUG (Check-CERT_EXPIRY): Ошибки доступа к хранилищам:" -ForegroundColor Yellow
                $finalResult.Details.store_access_errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
            }
        }
    } elseif ($finalResult) {
        Write-Host "DEBUG (Check-CERT_EXPIRY): Объект finalResult существует, но finalResult.Details является `$null или отсутствует." -ForegroundColor Yellow
    } else {
        Write-Host "DEBUG (Check-CERT_EXPIRY): Итоговый объект finalResult сам по себе является `$null (вероятно, ошибка до его формирования)." -ForegroundColor Red
    }
    Write-Host "DEBUG (Check-CERT_EXPIRY): --- Конец отладки итогового объекта finalResult.Details ---" -ForegroundColor Green
}

# --- Возврат стандартизированного результата ---
$isAvailableStrForLog = if ($finalResult) { $finalResult.IsAvailable } else { '[finalResult is null]' }
$checkSuccessStrForLog = if ($finalResult) { if ($null -eq $finalResult.CheckSuccess) {'[null]'} else {$finalResult.CheckSuccess} } else { '[finalResult is null]' }
Write-Verbose "[$NodeName] Check-CERT_EXPIRY (v2.1.5): Завершение. IsAvailable=$isAvailableStrForLog, CheckSuccess=$checkSuccessStrForLog"

return $finalResult