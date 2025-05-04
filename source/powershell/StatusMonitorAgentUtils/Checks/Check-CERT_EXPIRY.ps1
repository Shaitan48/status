# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-CERT_EXPIRY.ps1
# --- Версия 2.0.2 ---
# Изменения:
# - Исправлены синтаксические ошибки (закрывающие скобки, оператор ?.)
# - Добавлены комментарии и улучшено форматирование.
# - Логика проверки SuccessCriteria вынесена в универсальную функцию Test-SuccessCriteria.
# - Стандартизирован формат $Details.
# - Убран прямой расчет CheckSuccess на основе min_days_left.
# - Добавлен вызов Test-SuccessCriteria.

<#
.SYNOPSIS
    Скрипт проверки сроков действия локально установленных сертификатов. (v2.0.2)
.DESCRIPTION
    Использует Get-ChildItem для поиска сертификатов в стандартных хранилищах.
    Позволяет фильтровать сертификаты по различным критериям.
    Формирует стандартизированный объект $Details со списком найденных сертификатов
    и их статусами (OK, Expired, Expiring (Warn)).
    Для определения итогового CheckSuccess использует универсальную функцию
    Test-SuccessCriteria, сравнивающую $Details с переданным $SuccessCriteria.
    Ожидаемый формат SuccessCriteria для проверки срока:
    @{ certificates = @{ _condition_ = 'all'; days_left = @{ '>' = <кол-во дней> } } }
.PARAMETER TargetIP
    [string] Обязательный. IP или имя хоста. Используется для логирования,
             скрипт выполняется локально.
.PARAMETER Parameters
    [hashtable] Параметры фильтрации сертификатов:
    - subject_like (string): Фильтр по имени субъекта (с wildcard *?).
    - issuer_like (string): Фильтр по имени издателя (с wildcard *?).
    - thumbprint (string): Точный отпечаток (игнорирует subject/issuer).
    - require_private_key (bool): Искать только с закрытым ключом (default: $false).
    - eku_oid (string[]): Массив OID'ов EKU (хотя бы один должен совпасть).
    - min_days_warning (int): Порог дней для статуса "Warning" в Details (default: 30).
                              Не влияет на итоговый CheckSuccess.
.PARAMETER SuccessCriteria
    [hashtable] Критерии успеха. Для проверки срока действия ожидается структура,
                работающая с массивом 'certificates' в $Details. Например:
                @{ certificates = @{ _condition_ = 'all'; days_left = @{ '>' = 14 } } }
                (где '>' - оператор сравнения, 14 - пороговое значение).
                Обработка этого формата выполняется функцией Test-SuccessCriteria.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
                Поле Details (hashtable) содержит:
                - certificates (List<object>): Массив данных о найденных и отфильтрованных сертификатах.
                - stores_checked (string[]): Список проверенных хранилищ.
                - message (string): Опциональное сообщение (напр., если сертификаты не найдены).
                - access_errors (string[]): Опционально, список ошибок доступа к хранилищам.
                - error (string): Опциональное сообщение об ошибке выполнения скрипта.
                - ErrorRecord (string): Опционально, полный текст исключения.
.NOTES
    Версия: 2.0.2
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria из StatusMonitorAgentUtils.psm1.
    Требует прав доступа к хранилищам сертификатов.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIP,

    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},

    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,

    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node"
)

# --- Инициализация переменных для результата ---
$isAvailable = $false          # Смогли ли мы вообще выполнить проверку?
$checkSuccess = $null         # Прошли ли критерии? (null до проверки)
$errorMessage = $null         # Сообщение для ErrorMessage в итоговом объекте
$finalResult = $null          # Итоговый объект, возвращаемый скриптом
$details = @{                 # Стандартная структура Details
    certificates   = [System.Collections.Generic.List[object]]::new() # Список найденных серт-ов
    stores_checked = @()        # Какие хранилища проверяли
    # Дополнительные поля будут добавлены по ходу дела (message, access_errors, error)
}

Write-Verbose "[$NodeName] Check-CERT_EXPIRY (v2.0.2): Начало проверки сертификатов на $TargetIP (локально на $env:COMPUTERNAME)"

# --- Основной блок Try/Catch для перехвата критических ошибок ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY БЛОКА >>>

    # --- 1. Валидация и извлечение параметров фильтрации из $Parameters ---
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Обработка параметров фильтрации..."
    $SubjectLike = $Parameters.subject_like # Может быть $null
    $IssuerLike = $Parameters.issuer_like   # Может быть $null
    $Thumbprint = $Parameters.thumbprint   # Может быть $null
    $EkuOids = $Parameters.eku_oid       # Может быть $null или массив строк

    # Получаем флаг require_private_key с обработкой ошибок
    $RequirePrivateKey = $false # Значение по умолчанию
    if ($Parameters.ContainsKey('require_private_key')) {
        try {
            $RequirePrivateKey = [bool]$Parameters.require_private_key # Пытаемся преобразовать к булеву значению
        } catch {
            Write-Warning "[$NodeName] Check-CERT_EXPIRY: Некорректное значение 'require_private_key' ('$($Parameters.require_private_key)'), используется значение по умолчанию `$false."
        }
    }
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: RequirePrivateKey = $RequirePrivateKey"

    # Получаем порог дней для статуса "Warning" в $Details
    $minDaysWarning = 30 # Значение по умолчанию
    if ($Parameters.ContainsKey('min_days_warning') -and $Parameters.min_days_warning -ne $null) {
        $parsedWarningDays = 0
        if ([int]::TryParse($Parameters.min_days_warning, [ref]$parsedWarningDays) -and $parsedWarningDays -ge 0) {
            $minDaysWarning = $parsedWarningDays # Используем значение из параметра
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Используется min_days_warning: $minDaysWarning дней."
        } else {
            Write-Warning "[$NodeName] Check-CERT_EXPIRY: Некорректное или отрицательное значение 'min_days_warning' ('$($Parameters.min_days_warning)'), используется значение по умолчанию $minDaysWarning дней."
        }
    } else {
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: min_days_warning не задан, используется значение по умолчанию: $minDaysWarning дней."
    }

    # --- 2. Поиск сертификатов в стандартных хранилищах ---
    $storesToSearch = @(
        @{ Path = "Cert:\LocalMachine\My"; Location = "LocalMachine"; Name = "My" }
        @{ Path = "Cert:\LocalMachine\WebHosting"; Location = "LocalMachine"; Name = "WebHosting" }
        @{ Path = "Cert:\CurrentUser\My"; Location = "CurrentUser"; Name = "My" }
    )
    $allFoundCertificates = [System.Collections.Generic.List[object]]::new() # Общий список найденных
    $storeAccessErrors = [System.Collections.Generic.List[string]]::new()    # Список ошибок доступа

    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Поиск сертификатов в хранилищах: $($storesToSearch.Path -join ', ')"
    # Цикл по хранилищам
    foreach ($storeInfo in $storesToSearch) {
        $certStorePath = $storeInfo.Path
        $details.stores_checked.Add($certStorePath) # Запоминаем, что пытались проверить
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Проверка хранилища: $certStorePath"
        # Внутренний try/catch для доступа к КОНКРЕТНОМУ хранилищу
        try {
            # Получаем сертификаты, подавляя ошибку "не найдено"
            $certsInStore = Get-ChildItem -Path $certStorePath -ErrorAction SilentlyContinue
            if ($certsInStore) {
                $allFoundCertificates.AddRange($certsInStore) # Добавляем найденные в общий список
                Write-Verbose "[$NodeName] Check-CERT_EXPIRY: В '$($certStorePath)' найдено: $($certsInStore.Count) серт."
            } else {
                 Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Хранилище '$($certStorePath)' пусто или не найдено."
            }
            # Проверяем, была ли ошибка доступа (например, отказано в доступе к LocalMachine)
            if ($Error.Count -gt 0 -and $Error[0].FullyQualifiedErrorId -match 'StoreCouldNotBeOpened|GetCertificateStore') {
                 $errMsg = "Ошибка доступа к хранилищу '$($certStorePath)': $($Error[0].Exception.Message)"
                 $storeAccessErrors.Add($errMsg)
                 Write-Warning "[$NodeName] Check-CERT_EXPIRY: $errMsg"
                 $Error.Clear() # Очищаем ошибку, чтобы не влиять на следующие итерации
            }
        } catch { # Ловим другие непредвиденные ошибки при доступе к хранилищу
             $errMsg = "Критическая ошибка доступа к хранилищу '$($certStorePath)': $($_.Exception.Message)"
             $storeAccessErrors.Add($errMsg)
             Write-Warning "[$NodeName] Check-CERT_EXPIRY: $errMsg"
        } # <<< Закрывает внутренний catch >>>
    } # <<< Закрывает foreach ($storeInfo in $storesToSearch) >>>

    # Устанавливаем IsAvailable = $true, если удалось проверить ХОТЯ БЫ одно хранилище
    if ($details.stores_checked.Count -gt 0) {
        $isAvailable = $true
        # Если были ошибки доступа, добавляем их в Details
        if ($storeAccessErrors.Count -gt 0) {
            $details.access_errors = $storeAccessErrors
        }
    } else {
        # Если не удалось проверить НИ ОДНО хранилище, проверка не удалась
        $isAvailable = $false
        $errorMessage = "Не удалось получить доступ ни к одному из проверяемых хранилищ сертификатов."
        # Выбрасываем исключение, т.к. дальнейшая работа бессмысленна
        throw $errorMessage
    }
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: IsAvailable=$isAvailable. Всего найдено сертификатов до фильтрации: $($allFoundCertificates.Count)."

    # --- 3. Фильтрация найденных сертификатов по заданным параметрам ---
    $filteredCertificates = $allFoundCertificates # Начинаем со всех найденных
    $filterApplied = $false # Флаг, что хотя бы один фильтр применен

    # Приоритет у фильтра по отпечатку
    if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) {
        $filterApplied = $true
        $Thumbprint = $Thumbprint.Trim().ToUpper() # Нормализуем отпечаток
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Применяем фильтр по Thumbprint: '$Thumbprint'"
        $filteredCertificates = $filteredCertificates | Where-Object { $_.Thumbprint -eq $Thumbprint }
    } else {
        # Если отпечаток не задан, применяем фильтры по Subject и Issuer
        if (-not [string]::IsNullOrWhiteSpace($SubjectLike)) {
            $filterApplied = $true
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Применяем фильтр по Subject like: '$SubjectLike'"
            $filteredCertificates = $filteredCertificates | Where-Object { $_.Subject -like $SubjectLike }
        }
        if (-not [string]::IsNullOrWhiteSpace($IssuerLike)) {
            $filterApplied = $true
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Применяем фильтр по Issuer like: '$IssuerLike'"
            $filteredCertificates = $filteredCertificates | Where-Object { $_.Issuer -like $IssuerLike }
        }
    }

    # Фильтр по наличию закрытого ключа
    if ($RequirePrivateKey) {
        $filterApplied = $true
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Применяем фильтр 'require_private_key = $true'"
        $filteredCertificates = $filteredCertificates | Where-Object { $_.HasPrivateKey }
    }

    # Фильтр по EKU (Extended Key Usage)
    if ($EkuOids -is [array] -and $EkuOids.Count -gt 0) {
        $filterApplied = $true
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Применяем фильтр по EKU OIDs: $($EkuOids -join ', ')"
        # Отбираем сертификаты, у которых в EKU есть ХОТЯ БЫ ОДИН из указанных OID
        $filteredCertificates = $filteredCertificates | Where-Object {
            $cert = $_
            # Получаем расширение EKU
            $ekuExtension = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Enhanced Key Usage' } | Select-Object -First 1
            # Получаем список OID'ов из этого расширения
            $certEkus = $ekuExtension.EnhancedKeyUsages
            if ($certEkus) {
                # Проверяем пересечение массивов OID'ов
                ($EkuOids | Where-Object { $certEkus.Oid -contains $_ }).Count -gt 0
            } else { $false } # Нет EKU - не соответствует фильтру
        }
    }

    # Выводим предупреждение, если фильтры не применялись
    if (-not $filterApplied) {
         Write-Warning "[$NodeName] Check-CERT_EXPIRY: Критерии фильтрации не заданы. Будут обработаны ВСЕ сертификаты из проверенных хранилищ."
    }
    Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Количество сертификатов после фильтрации: $($filteredCertificates.Count)."

    # --- 4. Формирование массива сертификатов для поля $Details ---
    $currentTime = Get-Date # Фиксируем текущее время для консистентного расчета дней

    if ($filteredCertificates.Count -eq 0) {
        # Если после фильтрации сертификатов не осталось
        $details.message = "Сертификаты" + ($filterApplied ? ", соответствующие фильтрам," : "") + " не найдены."
        Write-Verbose "[$NodeName] Check-CERT_EXPIRY: $($details.message)"
    } else {
        # Обрабатываем каждый отфильтрованный сертификат
        foreach ($cert in $filteredCertificates) {
            # Рассчитываем оставшееся время и дни
            $timeRemaining = New-TimeSpan -Start $currentTime -End $cert.NotAfter
            $daysLeft = [math]::Floor($timeRemaining.TotalDays) # Целое количество дней (вниз)

            # Формируем объект с информацией о сертификате для $Details
            $certInfo = [ordered]@{
                thumbprint      = $cert.Thumbprint
                subject         = $cert.Subject
                issuer          = $cert.Issuer
                not_before      = $cert.NotBefore.ToUniversalTime().ToString("o") # ISO 8601 UTC
                not_after       = $cert.NotAfter.ToUniversalTime().ToString("o")  # ISO 8601 UTC
                days_left       = $daysLeft         # Это поле будет проверяться Test-SuccessCriteria
                has_private_key = $cert.HasPrivateKey
                status          = "OK"              # Статус для отображения
                status_details  = ""                # Пояснение к статусу
                store_path      = $cert.PSParentPath # Путь к хранилищу
            }

            # --- Определяем статус для отображения (OK/Expired/Warn/Error) ---
            # Этот статус не влияет на CheckSuccess, он только для информации в $Details
            if ($currentTime -gt $cert.NotAfter) {
                $certInfo.status = "Expired"
                $certInfo.status_details = "Истек {0:dd.MM.yyyy HH:mm}" -f $cert.NotAfter.ToLocalTime()
            } elseif ($daysLeft -lt 0) {
                # Эта ситуация маловероятна, если $currentTime > $cert.NotAfter обработан
                $certInfo.status = "Error"
                $certInfo.status_details = "Ошибка расчета оставшегося срока (daysLeft < 0)."
            } elseif ($daysLeft -le $minDaysWarning) {
                 # Если дней осталось <= порога предупреждения
                 $certInfo.status = "Expiring (Warn)"
                 $certInfo.status_details = "Истекает через {0} дней (Предупреждение: <= {1})" -f $daysLeft, $minDaysWarning
                 Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Сертификат $($cert.Thumbprint.Substring(0,8))... истекает скоро ($daysLeft дней)."
            }
            # Иначе статус остается "OK"

            # Добавляем информацию о сертификате в $Details.certificates
            $details.certificates.Add($certInfo)

        } # Конец foreach ($cert in $filteredCertificates)
    } # Конец else (если сертификаты найдены)

    # --- 5. Вызов универсальной функции проверки критериев ---
    # Инициализируем переменные для результата проверки критериев
    $checkSuccess = $null
    $failReason = $null

    # Проверяем критерии ТОЛЬКО если сама проверка была доступна ($isAvailable = true)
    if ($isAvailable) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            # Если критерии переданы и они не пустые
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: Вызов Test-SuccessCriteria для проверки критериев..."
            # Вызываем универсальную функцию, передавая ей наши Details и SuccessCriteria
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed # Получаем результат: $true, $false или $null
            $failReason = $criteriaResult.FailReason # Получаем причину провала или ошибки

            if ($checkSuccess -eq $null) {
                # Ошибка при обработке самих критериев
                $errorMessage = "Ошибка при обработке SuccessCriteria: $failReason"
                Write-Warning "[$NodeName] $errorMessage"
            } elseif ($checkSuccess -eq $false) {
                # Критерии не пройдены
                $errorMessage = $failReason # Используем причину как сообщение об ошибке
                Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria НЕ пройдены: $failReason"
            } else {
                # Критерии пройдены ($checkSuccess = $true)
                $errorMessage = $null # Нет сообщения об ошибке
                Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria пройдены."
            }
        } else {
            # Критерии НЕ ЗАДАНЫ
            # Если проверка была доступна, но критериев нет, считаем CheckSuccess = true
            $checkSuccess = $true
            $errorMessage = $null # Ошибки, связанной с критериями, нет
            Write-Verbose "[$NodeName] Check-CERT_EXPIRY: SuccessCriteria не заданы, CheckSuccess установлен в true (т.к. IsAvailable=true)."
        }
    } else {
        # Если IsAvailable = $false, то CheckSuccess должен быть $null
        $checkSuccess = $null
        # $errorMessage уже должен быть установлен ранее (например, ошибка доступа к хранилищам
        # или исключение, выброшенное при невозможности проверить ни одно хранилище)
        if ([string]::IsNullOrEmpty($errorMessage)) {
            # Эта ветка не должна выполняться, если логика выше верна,
            # но добавлена для подстраховки.
            $errorMessage = "Не удалось выполнить проверку сертификатов (IsAvailable=false)."
        }
    }

    # --- 6. Формирование итогового результата ---
    # Используем New-CheckResultObject для создания стандартного объекта
    # $errorMessage будет содержать либо причину провала критерия, либо ошибку выполнения проверки
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

# <<< ИСПРАВЛЕНО: Закрывающая скобка для ОСНОВНОГО try блока >>>
} catch {
    # --- Обработка КРИТИЧЕСКИХ ошибок скрипта ---
    # Сюда попадаем, если произошла ошибка, не обработанная выше
    # (например, ошибка в параметрах, исключение при throw из-за недоступности хранилищ)
    $isAvailable = $false
    $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message
    # Обрезаем слишком длинные сообщения
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $critErrorMessage = "Критическая ошибка при проверке сертификатов: {0}" -f $exceptionMessage

    # Формируем Details с информацией об ошибке
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString() }
    # Добавляем хранилища, которые успели проверить, если они есть
    if ($details.stores_checked.Count -gt 0) { $detailsError.stores_checked = $details.stores_checked }

    # Создаем финальный результат ВРУЧНУЮ, т.к. New-CheckResultObject может быть недоступен
    $finalResult = @{
        IsAvailable  = $isAvailable
        CheckSuccess = $checkSuccess
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        Details      = $detailsError
        ErrorMessage = $critErrorMessage
    }
    Write-Error "[$NodeName] Check-CERT_EXPIRY: Критическая ошибка: $critErrorMessage"
} # <<< Закрывает ОСНОВНОЙ catch блок >>>

# --- Возврат результата ---
# <<< ИСПРАВЛЕНО: Заменяем ?. на стандартный доступ, проверяя $finalResult >>>
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[finalResult is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[finalResult is null]' }
Write-Verbose "[$NodeName] Check-CERT_EXPIRY (v2.0.2): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult