# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-PING.ps1
# --- Версия 2.3.1 --- Интеграция Test-SuccessCriteria
<#
.SYNOPSIS
    Скрипт проверки доступности узла с помощью .NET Ping. (v2.3.1)
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
    Версия: 2.3.1 (Интеграция Test-SuccessCriteria).
    Зависит от New-CheckResultObject, Test-SuccessCriteria.
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
$finalResult = $null          # Итоговый возвращаемый объект
# $details будет заполнен результатами пинга
$details = @{ target_ip = $TargetIP; packets_sent = 0; packets_received = 0; packet_loss_percent = 100; rtt_ms = $null; ip_address = $null; status_string = '[Error]' }

Write-Host "[$NodeName] Check-PING (v2.3.1 - .NET): Инициализация для $TargetIP" -ForegroundColor Magenta

# --- Основной Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY БЛОКА >>>

    # --- 1. Получение параметров пинга ---
    $TimeoutMs = 1000; if ($Parameters.ContainsKey('timeout_ms') -and $Parameters.timeout_ms -ne $null -and [int]::TryParse($Parameters.timeout_ms, [ref]$null) -and $Parameters.timeout_ms -gt 0) { $TimeoutMs = [int]$Parameters.timeout_ms }
    $PingCount = 1; if ($Parameters.ContainsKey('count') -and $Parameters.count -ne $null -and [int]::TryParse($Parameters.count, [ref]$null) -and $Parameters.count -gt 0) { $PingCount = [int]$Parameters.count }
    $BufferSize = 32; if ($Parameters.ContainsKey('buffer_size') -and $Parameters.buffer_size -ne $null -and [int]::TryParse($Parameters.buffer_size, [ref]$null) -and $Parameters.buffer_size -gt 0) { $BufferSize = [int]$Parameters.buffer_size }
    $TtlValue = 128; if ($Parameters.ContainsKey('ttl') -and $Parameters.ttl -ne $null -and [int]::TryParse($Parameters.ttl, [ref]$null) -and $Parameters.ttl -gt 0) { $TtlValue = [int]$Parameters.ttl }
    $details.packets_sent = $PingCount # Сразу записываем в детали

    # --- 2. Выполнение пинга ---
    $pingSender = New-Object System.Net.NetworkInformation.Ping
    $pingOptions = New-Object System.Net.NetworkInformation.PingOptions($TtlValue, $true) # TTL, DontFragment
    $sendBuffer = [byte[]]::new($BufferSize)
    $resultsList = [System.Collections.Generic.List[System.Net.NetworkInformation.PingReply]]::new()
    $successCount = 0; $totalRtt = 0; $firstSuccessReply = $null

    Write-Verbose "[$NodeName] Check-PING: Отправка $PingCount ICMP запросов (Timeout: $TimeoutMs ms)..."
    for ($i = 1; $i -le $PingCount; $i++) {
        $reply = $null
        try {
            $reply = $pingSender.Send($TargetIP, $TimeoutMs, $sendBuffer, $pingOptions)
            $resultsList.Add($reply)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $successCount++; $totalRtt += $reply.RoundtripTime
                if ($null -eq $firstSuccessReply) { $firstSuccessReply = $reply }
            }
            Write-Verbose "[$NodeName] Check-PING: Попытка $i - Статус: $($reply.Status), RTT: $($reply.RoundtripTime)ms"
        } catch [System.Net.NetworkInformation.PingException] {
            # КРИТИЧЕСКАЯ ошибка - пинг невозможен
            $errorMessage = "Ошибка PingException для '$TargetIP': $($_.Exception.Message)"
            Write-Warning "[$NodeName] Check-PING: $errorMessage"
            $details.error = $errorMessage; $details.ErrorRecord = $_.ToString()
            # IsAvailable остается false (значение по умолчанию)
            throw $errorMessage # Прерываем выполнение, чтобы попасть в основной catch
        } catch {
             # Другая ошибка при отправке - логируем, но продолжаем (возможно, следующие пройдут)
             $otherError = "Ошибка при отправке пинга ($i/$PingCount) для '$TargetIP': $($_.Exception.Message)"
             Write-Warning "[$NodeName] Check-PING: $otherError"
             if (-not $details.ContainsKey('ping_errors')) { $details.ping_errors = [System.Collections.Generic.List[string]]::new() }
             $details.ping_errors.Add($otherError)
        }
        if ($PingCount -gt 1 -and $i -lt $PingCount) { Start-Sleep -Milliseconds 100 }
    } # Конец for

    # --- 3. Анализ результатов пинга и заполнение $details ---
    $details.packets_received = $successCount
    $details.packet_loss_percent = if ($PingCount -gt 0) { [math]::Round((($PingCount - $successCount) / $PingCount) * 100) } else { 0 }

    if ($successCount -gt 0) {
        $isAvailable = $true # Пинг УСПЕШЕН (хотя бы один ответ)
        $errorMessage = $null # Сбрасываем ошибку, если она была от неудачных попыток
        $details.status_string = 'Success'
        $details.rtt_ms = if ($successCount -gt 0) { [int][math]::Round($totalRtt / $successCount) } else { $null }
        $details.ip_address = $firstSuccessReply.Address.ToString()
        Write-Verbose "[$NodeName] Check-PING: Пинг успешен. IsAvailable=True. Усп: $successCount/$PingCount. RTT: $($details.rtt_ms)ms."
    } else {
        # IsAvailable остается false
        $statusText = if ($resultsList.Count -gt 0) { $resultsList[0].Status.ToString() } else { "[Нет ответа]" }
        $errorMessage = "Ошибка PING для '$TargetIP': Нет успешных ответов ($successCount/$PingCount). Статус первого: $statusText"
        $details.status_string = $statusText
        $details.error = $errorMessage # Добавляем ошибку в детали
        Write-Warning "[$NodeName] Check-PING: $errorMessage"
    }

    # --- 4. Проверка критериев успеха (вызов универсальной функции) ---
    $failReason = $null
    if ($isAvailable -eq $true) { # Проверяем критерии только если пинг прошел
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.PSObject.Properties.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-PING: Вызов Test-SuccessCriteria..."
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed # $true, $false или $null
            $failReason = $criteriaResult.FailReason

            if ($checkSuccess -ne $true) { # Если $false или $null (ошибка критерия)
                $errorMessage = $failReason | Get-OrElse "Критерии успеха не пройдены."
                Write-Verbose "[$NodeName] Check-PING: SuccessCriteria НЕ пройдены/ошибка: $errorMessage"
            } else {
                Write-Verbose "[$NodeName] Check-PING: SuccessCriteria пройдены."
                # Убедимся, что errorMessage пуст, если критерии пройдены
                # (на случай, если были ошибки отдельных пингов, но общий результат прошел критерии)
                $errorMessage = $null
            }
        } else {
            # Критерии не заданы - успех, если пинг прошел
            $checkSuccess = $true
            $errorMessage = $null
            Write-Verbose "[$NodeName] Check-PING: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        # Пинг не прошел ($isAvailable = $false) -> CheckSuccess остается $null
        $checkSuccess = $null
        # $errorMessage уже установлен выше при анализе результатов пинга
        if ([string]::IsNullOrEmpty($errorMessage)) {
             $errorMessage = "Ошибка PING (IsAvailable=false)." # На всякий случай
        }
    }

    # --- 5. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

# <<< Закрываем основной try >>>
} catch {
    # --- Обработка КРИТИЧЕСКИХ ошибок (например, PingException при throw) ---
    $isAvailable = $false; $checkSuccess = $null
    $critErrorMessage = "Критическая ошибка Check-PING для '$TargetIP': $($_.Exception.Message)"
    # Добавляем детали ошибки, сохраняя уже собранные детали, если они есть
    if ($null -eq $details) { $details = @{} } # На случай, если $details не инициализировались
    $details.error = $critErrorMessage; $details.ErrorRecord = $_.ToString()
    $finalResult = @{ IsAvailable=$isAvailable; CheckSuccess=$checkSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$details; ErrorMessage=$critErrorMessage }
    Write-Error "[$NodeName] Check-PING: Критическая ошибка: $critErrorMessage"
} # <<< Закрываем основной catch >>>

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Host "[$NodeName] Check-PING (v2.3.1): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr" -ForegroundColor Magenta
return $finalResult