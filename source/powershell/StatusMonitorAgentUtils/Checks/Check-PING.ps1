# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-PING.ps1
# --- Версия 2.3.3 --- Добавлены комментарии для контекста pipeline-шага.
# (Предполагается, что вызывается из Invoke-StatusMonitorCheck, где $Assignment - это объект ШАГА pipeline)
<#
.SYNOPSIS
    Скрипт для выполнения шага 'PING' в рамках pipeline-задания. (v2.3.3)
.DESCRIPTION
    Использует System.Net.NetworkInformation.Ping для проверки доступности узла.
    Параметры для пинга (адрес, количество, таймаут и т.д.) берутся из $Parameters (переданного объекта шага).
    Критерии успеха (RTT, потери) также берутся из $SuccessCriteria объекта шага.
    Формирует $Details с результатами пинга.
    Вызывает Test-SuccessCriteria для определения CheckSuccess на основе собранных данных и критериев шага.
.PARAMETER TargetIP
    [string] Обязательный. IP-адрес или имя хоста для пинга.
             В контексте вызова из Invoke-StatusMonitorCheck, это значение берется из
             $Assignment.ip_address или $Assignment.target шага pipeline.
.PARAMETER Parameters
    [hashtable] Опциональный. Параметры, специфичные для шага PING:
                - timeout_ms (int): Таймаут для каждого ICMP-запроса (мс). По умолчанию 1000.
                - count (int): Количество ICMP-запросов. По умолчанию 1.
                - buffer_size (int): Размер буфера ICMP (байт). По умолчанию 32.
                - ttl (int): Time-To-Live для пакетов. По умолчанию 128.
                - target (string): Альтернативное имя для $TargetIP, если нужно пинговать не основной IP узла.
                                   Если 'target' указан в $Parameters, он имеет приоритет над $TargetIP.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха для оценки результатов этого шага PING.
                Применяются к полям в $Details (например, @{ rtt_ms = @{'<='=100}; packet_loss_percent = @{'=='=0} }).
.PARAMETER NodeName
    [string] Опциональный. Имя узла (или контекстное имя для этого шага), используется для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки (шага), созданный New-CheckResultObject.
.NOTES
    Версия: 2.3.3
    - Добавлены комментарии для ясности работы в качестве исполнителя шага pipeline.
    - Логика извлечения 'target' из $Parameters добавлена.
    Зависит от New-CheckResultObject, Test-SuccessCriteria из модуля StatusMonitorAgentUtils.
#>
param(
    [Parameter(Mandatory = $false)] # Сделан необязательным, т.к. может быть в Parameters.target
    [string]$TargetIP,
    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node (PING Step)" # Обновлено для ясности
)

# --- Инициализация ---
$isAvailable = $false
$checkSuccess = $null
$errorMessage = $null
$finalResultFromPing = $null
$details = @{
    target_to_ping = $null # IP или имя, которое реально пингуется
    packets_sent = 0
    packets_received = 0
    packet_loss_percent = 100
    rtt_ms = $null
    ip_address_replied = $null # Фактический IP-адрес, ответивший на пинг
    status_string = '[Error Init]'
}

# --- 1. Определение цели для пинга ---
# Приоритет у параметра 'target' внутри $Parameters, затем у $TargetIP (переданного как основной IP узла/шага)
$actualTargetToPing = $TargetIP # По умолчанию
if ($Parameters.ContainsKey('target') -and -not [string]::IsNullOrWhiteSpace($Parameters.target)) {
    $actualTargetToPing = $Parameters.target
    Write-Verbose "[$NodeName] Check-PING: Используется цель из Parameters.target: '$actualTargetToPing'"
} elseif ([string]::IsNullOrWhiteSpace($actualTargetToPing)) {
    # Если ни $TargetIP, ни Parameters.target не заданы - это ошибка конфигурации шага
    $errorMessage = "Цель для PING не указана (ни в TargetIP, ни в Parameters.target)."
    Write-Warning "[$NodeName] Check-PING: $errorMessage"
    # Используем New-CheckResultObject для возврата стандартизированной ошибки
    return New-CheckResultObject -IsAvailable $false -CheckSuccess $null -Details $details -ErrorMessage $errorMessage
}
$details.target_to_ping = $actualTargetToPing # Сохраняем фактическую цель в детали

Write-Host "[$NodeName] Check-PING (v2.3.3 - .NET): Инициализация для '$($actualTargetToPing)'" -ForegroundColor Magenta

# --- Основной Try/Catch для всей логики скрипта ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY БЛОКА >>>

    # --- 2. Получение параметров пинга из $Parameters (объекта шага) ---
    $TimeoutMs = 1000
    if ($Parameters.ContainsKey('timeout_ms') -and $Parameters.timeout_ms -ne $null) {
        $parsedVal = 0
        if ([int]::TryParse($Parameters.timeout_ms, [ref]$parsedVal) -and $parsedVal -gt 0) { $TimeoutMs = $parsedVal }
        else { Write-Warning "[$NodeName] Check-PING: Некорректное значение timeout_ms ('$($Parameters.timeout_ms)'). Используется $TimeoutMs мс." }
    }

    $PingCount = 1
    if ($Parameters.ContainsKey('count') -and $Parameters.count -ne $null) {
        $parsedVal = 0
        if ([int]::TryParse($Parameters.count, [ref]$parsedVal) -and $parsedVal -gt 0) { $PingCount = $parsedVal }
        else { Write-Warning "[$NodeName] Check-PING: Некорректное значение count ('$($Parameters.count)'). Используется $PingCount." }
    }
    $details.packets_sent = $PingCount

    $BufferSize = 32
    if ($Parameters.ContainsKey('buffer_size') -and $Parameters.buffer_size -ne $null) {
        $parsedVal = 0
        if ([int]::TryParse($Parameters.buffer_size, [ref]$parsedVal) -and $parsedVal -gt 0) { $BufferSize = $parsedVal }
        else { Write-Warning "[$NodeName] Check-PING: Некорректное значение buffer_size ('$($Parameters.buffer_size)'). Используется $BufferSize." }
    }

    $TtlValue = 128
    if ($Parameters.ContainsKey('ttl') -and $Parameters.ttl -ne $null) {
        $parsedVal = 0
        if ([int]::TryParse($Parameters.ttl, [ref]$parsedVal) -and $parsedVal -gt 0) { $TtlValue = $parsedVal }
        else { Write-Warning "[$NodeName] Check-PING: Некорректное значение ttl ('$($Parameters.ttl)'). Используется $TtlValue." }
    }
    
    Write-Verbose "[$NodeName] Check-PING: Параметры шага: Count=$PingCount, Timeout=$TimeoutMs, Buffer=$BufferSize, TTL=$TtlValue для '$($actualTargetToPing)'"

    # --- 3. Выполнение пинга ---
    $pingSender = New-Object System.Net.NetworkInformation.Ping
    $pingOptions = New-Object System.Net.NetworkInformation.PingOptions($TtlValue, $true) # TTL, DontFragment
    $sendBuffer = [byte[]]::new($BufferSize)
    
    $resultsList = [System.Collections.Generic.List[System.Net.NetworkInformation.PingReply]]::new()
    $successfulRepliesCount = 0
    $totalRoundtripTime = 0
    $firstSuccessfulReply = $null

    Write-Verbose "[$NodeName] Check-PING: Отправка $PingCount ICMP запросов к '$actualTargetToPing' (Таймаут: $TimeoutMs мс)..."
    for ($i = 1; $i -le $PingCount; $i++) {
        $currentReply = $null
        try {
            $currentReply = $pingSender.Send($actualTargetToPing, $TimeoutMs, $sendBuffer, $pingOptions)
            $resultsList.Add($currentReply)

            if ($currentReply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $successfulRepliesCount++
                $totalRoundtripTime += $currentReply.RoundtripTime
                if ($null -eq $firstSuccessfulReply) { $firstSuccessfulReply = $currentReply }
            }
            Write-Verbose "[$NodeName] Check-PING: Попытка $i/$PingCount к '$actualTargetToPing' - Статус: $($currentReply.Status), RTT: $(if($currentReply.Status -eq 'Success') {$currentReply.RoundtripTime} else {'N/A'})ms, Адрес: $($currentReply.Address)"
        
        } catch [System.Net.NetworkInformation.PingException] {
            $errorMessage = "Критическая ошибка PingException для '$actualTargetToPing': $($_.Exception.Message)"
            Write-Warning "[$NodeName] Check-PING: $errorMessage"
            $details.status_string = 'PingException' # Обновляем статус в деталях
            $details.error = $errorMessage
            $details.ErrorRecord = $_.ToString()
            throw $errorMessage # Прерываем, чтобы попасть в основной catch
        } catch {
             $otherSinglePingError = "Ошибка при отправке пинга ($i/$PingCount) для '$actualTargetToPing': $($_.Exception.Message)"
             Write-Warning "[$NodeName] Check-PING: $otherSinglePingError"
             if (-not $details.ContainsKey('individual_ping_errors')) { $details.individual_ping_errors = [System.Collections.Generic.List[string]]::new() }
             $details.individual_ping_errors.Add($otherSinglePingError)
        }
        if ($PingCount -gt 1 -and $i -lt $PingCount) { Start-Sleep -Milliseconds 100 }
    }

    # --- 4. Анализ результатов и заполнение $details ---
    $details.packets_received = $successfulRepliesCount
    if ($PingCount -gt 0) {
        $details.packet_loss_percent = [math]::Round((($PingCount - $successfulRepliesCount) / $PingCount) * 100.0)
    } else { $details.packet_loss_percent = 0 }

    if ($successfulRepliesCount -gt 0) {
        $isAvailable = $true # Шаг PING успешен, если получен хотя бы один ответ "Success"
        $errorMessage = $null # Сбрасываем, если были ошибки отдельных пингов, но в целом успешно
        $details.status_string = 'Success'
        $details.rtt_ms = [int][math]::Round($totalRoundtripTime / $successfulRepliesCount)
        if ($null -ne $firstSuccessfulReply) { $details.ip_address_replied = $firstSuccessfulReply.Address.ToString() }
        Write-Verbose "[$NodeName] Check-PING: Пинг для '$actualTargetToPing' в целом успешен. IsAvailable=True. Ответов: $successfulRepliesCount/$PingCount. RTT: $($details.rtt_ms)ms."
    } else {
        # $isAvailable остается $false (инициализировано)
        $firstReplyStatusText = if ($resultsList.Count -gt 0) { $resultsList[0].Status.ToString() } else { "[Нет ответов после $PingCount попыток]" }
        $errorMessage = "Ошибка PING для '$actualTargetToPing': Нет успешных ответов ($successfulRepliesCount/$PingCount). Статус первой попытки (если была): $firstReplyStatusText"
        $details.status_string = $firstReplyStatusText
        $details.error = $errorMessage
        Write-Warning "[$NodeName] Check-PING: $errorMessage"
    }

    # --- 5. Проверка критериев успеха ($SuccessCriteria из объекта шага) ---
    if ($isAvailable -eq $true) { # Критерии проверяем, только если пинг был доступен
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-PING для '$actualTargetToPing': Вызов Test-SuccessCriteria..."
            $criteriaProcessingResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria -Path '$details'
            $checkSuccess = $criteriaProcessingResult.Passed
            $failReasonFromCriteria = $criteriaProcessingResult.FailReason
            if ($checkSuccess -ne $true) {
                $errorMessage = if (-not [string]::IsNullOrEmpty($failReasonFromCriteria)) { $failReasonFromCriteria }
                                else { "Критерии успеха для PING шага не пройдены (CheckSuccess: $($checkSuccess | ForEach-Object {if($_ -eq $null){'[null]'}else{$_}}))." }
                Write-Verbose "[$NodeName] Check-PING для '$actualTargetToPing': SuccessCriteria НЕ пройдены. Error: $errorMessage"
            } else {
                 $errorMessage = $null # Критерии пройдены, сбрасываем возможные предыдущие ошибки (не PingException)
                 Write-Verbose "[$NodeName] Check-PING для '$actualTargetToPing': SuccessCriteria пройдены."
            }
        } else { # Критерии не заданы
            $checkSuccess = $true # Если пинг прошел (IsAvailable=true) и критериев нет, считаем CheckSuccess=true
            $errorMessage = $null
            Write-Verbose "[$NodeName] Check-PING для '$actualTargetToPing': SuccessCriteria не заданы, CheckSuccess=true (т.к. IsAvailable=true)."
        }
    } else { # Пинг не прошел ($isAvailable = $false)
        $checkSuccess = $null # Критерии не оценивались
        if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = "Ошибка PING шага (IsAvailable=false), критерии не проверялись." }
    }

    # --- 6. Формирование итогового результата шага ---
    $finalResultFromPing = New-CheckResultObject -IsAvailable $isAvailable `
                                                 -CheckSuccess $checkSuccess `
                                                 -Details $details `
                                                 -ErrorMessage $errorMessage
} catch {
    # Обработка КРИТИЧЕСКИХ ошибок (например, PingException, выброшенная ранее, или другие)
    $isAvailable = $false; $checkSuccess = $null
    if ([string]::IsNullOrEmpty($errorMessage)) { # Если errorMessage еще не установлен
        $errorMessage = "Критическая ошибка в Check-PING для '$($actualTargetToPing_final = if($actualTargetToPing){$actualTargetToPing}else{$TargetIP})': $($_.Exception.Message)"
    }
    Write-Error "[$NodeName] Check-PING: $errorMessage ScriptStackTrace: $($_.ScriptStackTrace)"
    if ($null -eq $details) { $details = @{} }; if(-not $details.target_to_ping){ $details.target_to_ping = $actualTargetToPing_final }
    $details.error = $errorMessage; $details.ErrorRecord = $_.ToString()
    if ($details.status_string -eq '[Error Init]' -or [string]::IsNullOrEmpty($details.status_string)) { $details.status_string = 'CriticalError' }
    $finalResultFromPing = New-CheckResultObject -IsAvailable $isAvailable -CheckSuccess $checkSuccess -Details $details -ErrorMessage $errorMessage
}

# --- Отладка и возврат ---
# ... (Блок отладки можно оставить как есть) ...
Write-Host "DEBUG (Check-PING): --- Начало отладки finalResult.Details в Check-PING ---" -ForegroundColor Green
if ($finalResultFromPing -and $finalResultFromPing.Details) {
    Write-Host "DEBUG (Check-PING): Тип finalResult.Details: $($finalResultFromPing.Details.GetType().FullName)" -ForegroundColor Green
    if ($finalResultFromPing.Details -is [hashtable]) { Write-Host "DEBUG (Check-PING): Ключи: $($finalResultFromPing.Details.Keys -join ', ')" -FG Green }
    Write-Host "DEBUG (Check-PING): Содержимое (JSON): $($finalResultFromPing.Details | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue)" -ForegroundColor DarkGreen
} elseif ($finalResultFromPing) { Write-Host "DEBUG (Check-PING): finalResult.Details `$null." -FG Yellow }
else { Write-Host "DEBUG (Check-PING): finalResult `$null." -FG Red }
Write-Host "DEBUG (Check-PING): --- Конец отладки ---" -ForegroundColor Green

$isAvailableStrForLog = if ($finalResultFromPing) { $finalResultFromPing.IsAvailable } else { '[null]' }
$checkSuccessStrForLog = if ($finalResultFromPing) { if ($null -eq $finalResultFromPing.CheckSuccess) {'[null]'} else {$finalResultFromPing.CheckSuccess} } else { '[null]' }
Write-Host "[$NodeName] Check-PING (v2.3.3): Завершение для '$($details.target_to_ping)'. IsAvailable=$isAvailableStrForLog, CheckSuccess=$checkSuccessStrForLog" -ForegroundColor Magenta

return $finalResultFromPing