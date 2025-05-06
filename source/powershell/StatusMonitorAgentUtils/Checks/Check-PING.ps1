# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-PING.ps1
# --- Версия 2.3.2 --- Удален Get-OrElse, добавлен Path в Test-SuccessCriteria, улучшено логирование
<#
.SYNOPSIS
    Скрипт проверки доступности узла с помощью .NET Ping. (v2.3.2)
.DESCRIPTION
    Использует System.Net.NetworkInformation.Ping.
    Формирует $Details с результатами (RTT, потери и т.д.).
    Вызывает Test-SuccessCriteria для определения CheckSuccess.
.PARAMETER TargetIP
    [string] Обязательный. IP-адрес или имя хоста.
.PARAMETER Parameters
    [hashtable] Опциональный. Параметры: timeout_ms, count, buffer_size, ttl.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха для полей в $Details
                (напр., @{ rtt_ms = @{'<='=100}; packet_loss_percent = @{'=='=0} }).
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
.NOTES
    Версия: 2.3.2
    Зависит от New-CheckResultObject, Test-SuccessCriteria из модуля StatusMonitorAgentUtils.
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

# --- Инициализация ---
$isAvailable = $false          # Флаг доступности по результатам PING
$checkSuccess = $null         # Результат проверки критериев (изначально null)
$errorMessage = $null         # Сообщение об ошибке
$finalResultFromPing = $null  # Итоговый объект, который вернет эта функция
# $details будет заполнен результатами пинга
$details = @{
    target_ip = $TargetIP # IP или имя, которое пингуем
    packets_sent = 0
    packets_received = 0
    packet_loss_percent = 100 # По умолчанию 100% потерь
    rtt_ms = $null            # Среднее время ответа
    ip_address = $null        # Фактический IP-адрес, ответивший на пинг
    status_string = '[Error]' # Общий статус пинга
}

Write-Host "[$NodeName] Check-PING (v2.3.2 - .NET): Инициализация для $TargetIP" -ForegroundColor Magenta # Используем Write-Host для ручных тестов

# --- Основной Try/Catch для всей логики скрипта ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY БЛОКА >>>

    # --- 1. Получение параметров пинга (без Get-OrElse) ---
    $TimeoutMs = 1000 # Значение по умолчанию
    if ($Parameters.ContainsKey('timeout_ms') -and $Parameters.timeout_ms -ne $null) {
        $parsedVal = 0
        if ([int]::TryParse($Parameters.timeout_ms, [ref]$parsedVal) -and $parsedVal -gt 0) { $TimeoutMs = $parsedVal }
        else { Write-Warning "[$NodeName] Check-PING: Некорректное значение timeout_ms ('$($Parameters.timeout_ms)'). Используется $TimeoutMs мс." }
    }

    $PingCount = 1 # Значение по умолчанию
    if ($Parameters.ContainsKey('count') -and $Parameters.count -ne $null) {
        $parsedVal = 0
        if ([int]::TryParse($Parameters.count, [ref]$parsedVal) -and $parsedVal -gt 0) { $PingCount = $parsedVal }
        else { Write-Warning "[$NodeName] Check-PING: Некорректное значение count ('$($Parameters.count)'). Используется $PingCount." }
    }
    $details.packets_sent = $PingCount # Сразу записываем в детали

    $BufferSize = 32 # Значение по умолчанию
    if ($Parameters.ContainsKey('buffer_size') -and $Parameters.buffer_size -ne $null) {
        $parsedVal = 0
        if ([int]::TryParse($Parameters.buffer_size, [ref]$parsedVal) -and $parsedVal -gt 0) { $BufferSize = $parsedVal }
        else { Write-Warning "[$NodeName] Check-PING: Некорректное значение buffer_size ('$($Parameters.buffer_size)'). Используется $BufferSize." }
    }

    $TtlValue = 128 # Значение по умолчанию
    if ($Parameters.ContainsKey('ttl') -and $Parameters.ttl -ne $null) {
        $parsedVal = 0
        if ([int]::TryParse($Parameters.ttl, [ref]$parsedVal) -and $parsedVal -gt 0) { $TtlValue = $parsedVal }
        else { Write-Warning "[$NodeName] Check-PING: Некорректное значение ttl ('$($Parameters.ttl)'). Используется $TtlValue." }
    }
    
    Write-Verbose "[$NodeName] Check-PING: Параметры: Count=$PingCount, Timeout=$TimeoutMs, Buffer=$BufferSize, TTL=$TtlValue"

    # --- 2. Выполнение пинга ---
    $pingSender = New-Object System.Net.NetworkInformation.Ping
    $pingOptions = New-Object System.Net.NetworkInformation.PingOptions($TtlValue, $true) # TTL, DontFragment
    $sendBuffer = [byte[]]::new($BufferSize) # Создаем буфер нужного размера
    
    $resultsList = [System.Collections.Generic.List[System.Net.NetworkInformation.PingReply]]::new()
    $successfulRepliesCount = 0
    $totalRoundtripTime = 0
    $firstSuccessfulReply = $null

    Write-Verbose "[$NodeName] Check-PING: Отправка $PingCount ICMP запросов к '$TargetIP' (Таймаут на каждый: $TimeoutMs мс)..."
    for ($i = 1; $i -le $PingCount; $i++) {
        $currentReply = $null
        try {
            $currentReply = $pingSender.Send($TargetIP, $TimeoutMs, $sendBuffer, $pingOptions)
            $resultsList.Add($currentReply) # Сохраняем все ответы для возможного анализа

            if ($currentReply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $successfulRepliesCount++
                $totalRoundtripTime += $currentReply.RoundtripTime
                if ($null -eq $firstSuccessfulReply) { $firstSuccessfulReply = $currentReply }
            }
            Write-Verbose "[$NodeName] Check-PING: Попытка $i/$PingCount - Статус: $($currentReply.Status), RTT: $(if($currentReply.Status -eq 'Success') {$currentReply.RoundtripTime} else {'N/A'})ms, Адрес: $($currentReply.Address)"
        
        } catch [System.Net.NetworkInformation.PingException] {
            # КРИТИЧЕСКАЯ ошибка - пинг невозможен (например, хост не найден DNS, нет маршрута)
            $errorMessage = "Критическая ошибка PingException для '$TargetIP': $($_.Exception.Message)"
            Write-Warning "[$NodeName] Check-PING: $errorMessage"
            # Заполняем детали ошибки
            $details.status_string = 'PingException'
            $details.error = $errorMessage
            $details.ErrorRecord = $_.ToString()
            # IsAvailable остается $false (установлено при инициализации)
            throw $errorMessage # Прерываем выполнение, чтобы попасть в основной catch и вернуть ошибку
        } catch {
             # Другая, менее критичная ошибка при отправке одного из пингов
             $otherSinglePingError = "Ошибка при отправке пинга ($i/$PingCount) для '$TargetIP': $($_.Exception.Message)"
             Write-Warning "[$NodeName] Check-PING: $otherSinglePingError"
             if (-not $details.ContainsKey('individual_ping_errors')) { $details.individual_ping_errors = [System.Collections.Generic.List[string]]::new() }
             $details.individual_ping_errors.Add($otherSinglePingError)
             # Не прерываем цикл, следующие пинги могут пройти
        }
        # Пауза между пингами, если их несколько
        if ($PingCount -gt 1 -and $i -lt $PingCount) { Start-Sleep -Milliseconds 100 } # Небольшая пауза
    } # Конец for

    # --- 3. Анализ результатов всех пингов и заполнение $details ---
    $details.packets_received = $successfulRepliesCount
    if ($PingCount -gt 0) {
        $details.packet_loss_percent = [math]::Round((($PingCount - $successfulRepliesCount) / $PingCount) * 100.0)
    } else { # На случай, если $PingCount был 0 (хотя валидация выше должна это предотвратить)
        $details.packet_loss_percent = 0 
    }

    if ($successfulRepliesCount -gt 0) {
        $isAvailable = $true # Пинг считается УСПЕШНЫМ, если получен хотя бы один ответ "Success"
        $errorMessage = $null # Сбрасываем общий errorMessage, если он был от неудачных предыдущих попыток
        
        $details.status_string = 'Success' # Общий статус
        $details.rtt_ms = [int][math]::Round($totalRoundtripTime / $successfulRepliesCount) # Среднее RTT
        if ($null -ne $firstSuccessfulReply) {
            $details.ip_address = $firstSuccessfulReply.Address.ToString() # IP ответившего хоста
        }
        Write-Verbose "[$NodeName] Check-PING: Пинг в целом успешен. IsAvailable=True. Успешных ответов: $successfulRepliesCount/$PingCount. Среднее RTT: $($details.rtt_ms)ms."
    } else {
        # IsAvailable остается $false (установлено при инициализации)
        $firstReplyStatusText = if ($resultsList.Count -gt 0) { $resultsList[0].Status.ToString() } else { "[Нет ответов после $PingCount попыток]" }
        $errorMessage = "Ошибка PING для '$TargetIP': Нет успешных ответов ($successfulRepliesCount/$PingCount). Статус первой попытки (если была): $firstReplyStatusText"
        $details.status_string = $firstReplyStatusText # Статус первой неудачной попытки или общее сообщение
        $details.error = $errorMessage # Добавляем основную причину неудачи в детали
        Write-Warning "[$NodeName] Check-PING: $errorMessage"
    }

    # --- 4. Проверка критериев успеха (вызов универсальной функции Test-SuccessCriteria) ---
    # Критерии проверяются только если пинг был доступен (IsAvailable = $true)
    if ($isAvailable -eq $true) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) { # Проверяем, что SuccessCriteria не пустой хэш
            Write-Verbose "[$NodeName] Check-PING: Вызов Test-SuccessCriteria..."
            # Передаем полный объект $details и $SuccessCriteria в Test-SuccessCriteria
            # Также передаем путь '$details' для корректного формирования сообщений об ошибках в Test-SuccessCriteria
            $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
            
            $checkSuccess = $criteriaProcessingResult.Passed # Результат: $true, $false, или $null (при ошибке в критерии)
            $failReasonFromCriteria = $criteriaProcessingResult.FailReason

            if ($checkSuccess -ne $true) { # Если критерий не пройден ($false) или была ошибка оценки ($null)
                # Формируем ErrorMessage на основе причины от Test-SuccessCriteria
                if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) {
                    $errorMessage = $failReasonFromCriteria
                } else {
                    # Fallback, если FailReason пуст, но CheckSuccess не true
                    $errorMessage = "Критерии успеха для пинга не пройдены (CheckSuccess: $($checkSuccess | ForEach-Object {if ($_ -eq $null) {'[null]'} else {$_}}))."
                }
                Write-Verbose "[$NodeName] Check-PING: SuccessCriteria НЕ пройдены или ошибка оценки. ErrorMessage: $errorMessage"
            } else {
                # Критерии пройдены
                Write-Verbose "[$NodeName] Check-PING: SuccessCriteria пройдены."
                # Убедимся, что ErrorMessage пуст, если критерии пройдены
                # (на случай, если были ошибки отдельных пингов, но общий результат прошел критерии)
                $errorMessage = $null
            }
        } else {
            # Критерии не заданы - считаем проверку успешной, если пинг прошел (IsAvailable = $true)
            $checkSuccess = $true
            $errorMessage = $null # Нет ошибок, связанных с критериями
            Write-Verbose "[$NodeName] Check-PING: SuccessCriteria не заданы, CheckSuccess установлен в true, т.к. IsAvailable=true."
        }
    } else {
        # Пинг не прошел ($isAvailable = $false) -> CheckSuccess должен остаться $null (неприменимо)
        $checkSuccess = $null
        # $errorMessage уже был установлен выше при анализе результатов пинга
        if ([string]::IsNullOrEmpty($errorMessage)) {
             $errorMessage = "Ошибка PING (IsAvailable=false), критерии не проверялись." # Запасной вариант
        }
    }

    # --- 5. Формирование итогового результата с помощью New-CheckResultObject ---
    $finalResultFromPing = New-CheckResultObject -IsAvailable $isAvailable `
                                                 -CheckSuccess $checkSuccess `
                                                 -Details $details `
                                                 -ErrorMessage $errorMessage

# <<< Закрываем основной try >>>
} catch {
    # --- Обработка КРИТИЧЕСКИХ ошибок (например, PingException, выброшенная из цикла пингов, или другая непредвиденная ошибка) ---
    $isAvailable = $false # Гарантированно false при критической ошибке
    $checkSuccess = $null   # Критерии не могли быть оценены
    
    # Формируем сообщение об ошибке, если оно еще не установлено
    # $errorMessage может быть уже установлен, если исключение было поймано и переброшено из цикла for
    if ([string]::IsNullOrEmpty($errorMessage)) {
        $errorMessage = "Критическая непредвиденная ошибка в Check-PING для '$TargetIP': $($_.Exception.Message)"
    }
    
    Write-Error "[$NodeName] Check-PING: $errorMessage ScriptStackTrace: $($_.ScriptStackTrace)" # Логируем полную ошибку

    # Обновляем $details информацией об ошибке
    # $details мог быть частично заполнен до ошибки, или остаться инициализированным
    if ($null -eq $details) { $details = @{ target_ip = $TargetIP } } # На случай, если $details вообще не создался
    $details.error = $errorMessage       # Основное сообщение
    $details.ErrorRecord = $_.ToString() # Полная информация об ошибке PowerShell
    $details.status_string = if ($details.status_string -eq '[Error]' -or [string]::IsNullOrEmpty($details.status_string)) { 'CriticalError' } else { $details.status_string } # Обновляем статус, если он не был специфичен
    
    # Создаем финальный результат с ошибкой
    # Используем уже установленные $isAvailable, $checkSuccess, $errorMessage
    $finalResultFromPing = New-CheckResultObject -IsAvailable $isAvailable `
                                                 -CheckSuccess $checkSuccess `
                                                 -Details $details `
                                                 -ErrorMessage $errorMessage
} # <<< Закрываем основной catch >>>


# --- Отладка перед возвратом ---
Write-Host "DEBUG (Check-PING): --- Начало отладки finalResult.Details в Check-PING ---" -ForegroundColor Green
if ($finalResultFromPing -and $finalResultFromPing.Details) {
    Write-Host "DEBUG (Check-PING): Тип finalResult.Details: $($finalResultFromPing.Details.GetType().FullName)" -ForegroundColor Green
    if ($finalResultFromPing.Details -is [hashtable]) {
        Write-Host "DEBUG (Check-PING): Ключи в finalResult.Details (Hashtable): $($finalResultFromPing.Details.Keys -join ', ')" -ForegroundColor Green
    }
    Write-Host "DEBUG (Check-PING): Полное содержимое finalResult.Details (ConvertTo-Json -Depth 5):" -ForegroundColor Green
    Write-Host ($finalResultFromPing.Details | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue) -ForegroundColor DarkGreen
} elseif ($finalResultFromPing) {
    Write-Host "DEBUG (Check-PING): finalResult.Details является $null или отсутствует." -ForegroundColor Yellow
} else {
    Write-Host "DEBUG (Check-PING): finalResult сам по себе $null (ошибка до его формирования)." -ForegroundColor Red
}
Write-Host "DEBUG (Check-PING): --- Конец отладки finalResult.Details в Check-PING ---" -ForegroundColor Green

# --- Возврат результата ---
$isAvailableStr = if ($finalResultFromPing) { $finalResultFromPing.IsAvailable } else { '[finalResultFromPing is null]' }
$checkSuccessStrForLog = if ($finalResultFromPing) { if ($null -eq $finalResultFromPing.CheckSuccess) {'[null]'} else {$finalResultFromPing.CheckSuccess} } else { '[finalResultFromPing is null]' }
Write-Host "[$NodeName] Check-PING (v2.3.2): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStrForLog" -ForegroundColor Magenta

return $finalResultFromPing