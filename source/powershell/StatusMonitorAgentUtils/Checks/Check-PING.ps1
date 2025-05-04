# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-PING.ps1
# --- Версия 2.3.0 --- Использование .NET Ping
# Изменения:
# - Полностью заменен вызов Test-Connection на использование System.Net.NetworkInformation.Ping.
# - Логика адаптирована под результаты .NET Ping (Status, RoundtripTime).
# - Убрана зависимость от версии PowerShell для логики пинга.

<#
.SYNOPSIS
    Скрипт проверки доступности узла с помощью .NET Ping. (v2.3.0)
.DESCRIPTION
    Использует класс System.Net.NetworkInformation.Ping для отправки ICMP эхо-запросов.
    Этот метод более надежен и предсказуем, чем Test-Connection, особенно в PS 5.1.
    Анализирует результат PingReply для определения доступности ($IsAvailable) и RTT.
    Формирует стандартизированный $Details с результатом.
    Для определения итогового CheckSuccess использует универсальную функцию Test-SuccessCriteria.
.PARAMETER TargetIP
    [string] Обязательный. IP-адрес или имя хоста для пинга.
.PARAMETER Parameters
    [hashtable] Опциональный. Параметры для пинга:
    - timeout_ms (int): Таймаут ожидания ответа в миллисекундах (default: 1000).
    - count (int): Количество отправляемых запросов (default: 1). Скрипт отправит столько запросов
                   и вычислит среднее RTT и потери.
    - buffer_size (int): Размер буфера ICMP в байтах (default: 32).
    - ttl (int): Time To Live (default: 128).
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха для сравнения с полями в $Details.
                Пример: @{ rtt_ms = @{ '<=' = 100 }; packet_loss_percent = @{ '<=' = 0 } }
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
                Поле Details (hashtable) содержит (при получении хотя бы одного ответа):
                - target_ip (string): Пингуемый адрес/имя.
                - ip_address (string): IP-адрес, фактически ответивший (первый успешный).
                - rtt_ms (int): Среднее время ответа по успешным пингам в мс (или RTT первого, если count=1).
                - packets_sent (int): Отправлено пакетов.
                - packets_received (int): Получено пакетов (успешных ответов).
                - packet_loss_percent (int): Процент потерь.
                - status_string (string): Статус первого ответа (Success, TimedOut, etc.).
                А также (при полной неудаче):
                - error (string): Сообщение об ошибке.
                - ErrorRecord (string): Полный текст исключения.
.NOTES
    Версия: 2.3.0 (Переход на System.Net.NetworkInformation.Ping).
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria.
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
$isAvailable = $false; $checkSuccess = $null; $errorMessage = $null; $finalResult = $null
$details = @{ target_ip = $TargetIP } # Базовые детали

# --- Параметры пинга ---
$TimeoutMs = 1000; if ($Parameters.ContainsKey('timeout_ms') -and $Parameters.timeout_ms -ne $null -and [int]::TryParse($Parameters.timeout_ms, [ref]$null) -and $Parameters.timeout_ms -gt 0) { $TimeoutMs = [int]$Parameters.timeout_ms }
$PingCount = 1; if ($Parameters.ContainsKey('count') -and $Parameters.count -ne $null -and [int]::TryParse($Parameters.count, [ref]$null) -and $Parameters.count -gt 0) { $PingCount = [int]$Parameters.count }
$BufferSize = 32; if ($Parameters.ContainsKey('buffer_size') -and $Parameters.buffer_size -ne $null -and [int]::TryParse($Parameters.buffer_size, [ref]$null) -and $Parameters.buffer_size -gt 0) { $BufferSize = [int]$Parameters.buffer_size }
$TtlValue = 128; if ($Parameters.ContainsKey('ttl') -and $Parameters.ttl -ne $null -and [int]::TryParse($Parameters.ttl, [ref]$null) -and $Parameters.ttl -gt 0) { $TtlValue = [int]$Parameters.ttl }

$details.packets_sent = $PingCount # Сохраняем количество запрошенных пингов

Write-Host "[$NodeName] Check-PING (v2.3.0 - .NET): Инициализация для $TargetIP (Count: $PingCount, Timeout: $TimeoutMs ms)" -ForegroundColor Magenta

# --- Основной Try/Catch ---
try { # <<< НАЧАЛО ОСНОВНОГО TRY БЛОКА >>>
    # Создаем объект Ping и опции
    $pingSender = New-Object System.Net.NetworkInformation.Ping
    $pingOptions = New-Object System.Net.NetworkInformation.PingOptions
    $pingOptions.DontFragment = $true # Устанавливаем флаг Don't Fragment
    $pingOptions.Ttl = $TtlValue

    # Создаем буфер нужного размера
    $sendBuffer = [byte[]]::new($BufferSize)
    # Заполняем буфер (не обязательно, но можно для имитации стандартного пинга)
    # For ($i = 0; $i -lt $BufferSize; $i++) { $sendBuffer[$i] = $i % 256 }

    # Массив для хранения результатов каждого пинга
    $resultsList = [System.Collections.Generic.List[System.Net.NetworkInformation.PingReply]]::new()
    $successCount = 0
    $totalRtt = 0
    $firstReplyStatus = $null # Статус самого первого ответа
    $firstSuccessReply = $null # Первый успешный ответ

    Write-Verbose "[$NodeName] Check-PING: Отправка $PingCount ICMP запросов..."
    # Отправляем запросы в цикле
    for ($i = 1; $i -le $PingCount; $i++) {
        $reply = $null
        try {
            # Отправляем синхронный пинг
            $reply = $pingSender.Send($TargetIP, $TimeoutMs, $sendBuffer, $pingOptions)
            $resultsList.Add($reply) # Добавляем результат в список

            # Сохраняем статус первого ответа
            if ($i -eq 1) { $firstReplyStatus = $reply.Status }

            # Если ответ успешный
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $successCount++
                $totalRtt += $reply.RoundtripTime
                # Сохраняем первый успешный ответ
                if ($null -eq $firstSuccessReply) { $firstSuccessReply = $reply }
            }
             Write-Verbose "[$NodeName] Check-PING: Попытка $i - Статус: $($reply.Status), RTT: $($reply.RoundtripTime)ms"
        } catch [System.Net.NetworkInformation.PingException] {
             # Ошибка на уровне отправки (например, не удалось разрешить имя хоста)
             $errorMessage = "Ошибка PingException для '$TargetIP': $($_.Exception.Message)"
             Write-Warning "[$NodeName] Check-PING: $errorMessage"
             # Записываем ошибку в details и прерываем цикл, т.к. пинг невозможен
             $details.error = $errorMessage
             $details.ErrorRecord = $_.ToString()
             $isAvailable = $false # Явно указываем, что проверка не удалась
             break # Выходим из цикла for
        } catch {
             # Другая непредвиденная ошибка при отправке
             $errorMessage = "Неожиданная ошибка при отправке пинга ($i/$PingCount) для '$TargetIP': $($_.Exception.Message)"
             Write-Warning "[$NodeName] Check-PING: $errorMessage"
             # Продолжаем цикл (возможно, следующие попытки пройдут) или прерываем?
             # Пока продолжим, но запишем ошибку в details
             if (-not $details.ContainsKey('ping_errors')) { $details.ping_errors = [System.Collections.Generic.List[string]]::new() }
             $details.ping_errors.Add($errorMessage)
        }
        # Небольшая пауза между пингами, если их несколько
        if ($PingCount -gt 1 -and $i -lt $PingCount) { Start-Sleep -Milliseconds 100 }
    } # Конец цикла for

    # --- Анализ результатов цикла ---
    # Проверяем, не было ли критической ошибки PingException
    if ($details.ContainsKey('error')) {
         # Ошибка уже установлена, IsAvailable = false
         $isAvailable = $false
    } else {
        # Ошибки PingException не было, анализируем результаты
        $details.packets_received = $successCount
        $details.packet_loss_percent = if ($PingCount -gt 0) { [math]::Round((($PingCount - $successCount) / $PingCount) * 100) } else { 0 }

        # Считаем проверку успешной (IsAvailable), если ХОТЯ БЫ ОДИН ответ был Success
        if ($successCount -gt 0) {
            $isAvailable = $true
            $errorMessage = $null # Сбрасываем сообщение об ошибке, т.к. пинг прошел
            $details.status_string = 'Success' # Общий статус - успех
            # Рассчитываем среднее RTT по успешным ответам
            $details.rtt_ms = if ($successCount -gt 0) { [int][math]::Round($totalRtt / $successCount) } else { $null }
            # Берем IP из первого успешного ответа
            $details.ip_address = $firstSuccessReply.Address.ToString()
             Write-Verbose "[$NodeName] Check-PING: Пинг успешен (IsAvailable=True). Успешных: $successCount/$PingCount. Средний RTT: $($details.rtt_ms)ms. IP: $($details.ip_address)."
        } else {
            # Ни одного успешного ответа
            $isAvailable = $false
            # Формируем сообщение об ошибке на основе статуса первого ответа
            $statusText = if ($firstReplyStatus -ne $null) { $firstReplyStatus.ToString() } else { "[Нет ответа]" }
            $errorMessage = "Ошибка PING для '$TargetIP': Нет успешных ответов ($successCount/$PingCount). Статус первого: $statusText"
            $details.error = $errorMessage
            $details.status_string = $statusText
            Write-Warning "[$NodeName] Check-PING: $errorMessage"
        }
    }

    # --- Вызов проверки критериев ---
    $failReason = $null
    if ($isAvailable -eq $true) { # Явное сравнение
        # Проверяем, что SuccessCriteria существует и содержит ключи
        if (($SuccessCriteria -ne $null) -and ($SuccessCriteria.PSObject.Properties.Name.Count -gt 0)) {
            Write-Verbose "[$NodeName] Check-PING: Вызов Test-SuccessCriteria..."
            try { # Перехватываем ошибку, если функция не найдена или не работает
                # <<< РАСКОММЕНТИРОВАНО >>>
                $criteriaResult = StatusMonitorAgentUtils\Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
                $checkSuccess = $criteriaResult.Passed
                $failReason = $criteriaResult.FailReason
                Write-Verbose "[$NodeName] Check-PING: Test-SuccessCriteria вернул Passed=$checkSuccess, Reason='$failReason'"
                if ($checkSuccess -eq $null) { $errorMessage = "Ошибка обработки SuccessCriteria: $failReason"; $details.error_criteria = $errorMessage; Write-Warning "[$NodeName] $errorMessage" }
                elseif ($checkSuccess -eq $false) { $errorMessage = $failReason; Write-Verbose "[$NodeName] Check-PING: SuccessCriteria НЕ пройдены: $failReason" }
                else { $errorMessage = $null; Write-Verbose "[$NodeName] Check-PING: SuccessCriteria пройдены." }
                # <<< КОНЕЦ РАСКОММЕНТИРОВАННОГО БЛОКА >>>
            } catch {
                # <<< ИЗМЕНЕНО: Выводим ТОЛЬКО Exception.Message >>>
                $exceptionMessageOnly = "Нет сообщения"
                if ($_.Exception) { $exceptionMessageOnly = $_.Exception.Message }
                $errorMessage = "Критическая ошибка при вызове Test-SuccessCriteria: $exceptionMessageOnly"
                # Обрежем, если ОЧЕНЬ длинное
                if ($errorMessage.Length -gt 1000) { $errorMessage = $errorMessage.Substring(0, 1000) + "..." }
                $checkSuccess = $null # Считаем проверку критериев неуспешной/невозможной
                # Добавляем ТОЛЬКО сообщение об ошибке в детали
                if ($details -isnot [hashtable]) { $details = @{} } # Убедимся, что details это hashtable
                $details.error_criteria = $errorMessage
                Write-Warning "[$NodeName] $errorMessage" # Выводим ошибку
            }
        } else { $checkSuccess = $true; $errorMessage = $null; Write-Verbose "[$NodeName] Check-PING: SuccessCriteria не заданы, CheckSuccess=true."}
    } else { $checkSuccess = $null; if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = "Ошибка PING (IsAvailable=false)." } }

    # --- Формирование результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

} catch {
    # --- Критическая ошибка ---
    Write-Host "[$NodeName] Check-PING: Перехвачена критическая ошибка!" -ForegroundColor Red
    $isAvailable = $false; $checkSuccess = $null
    $critErrorMessage = "Критическая ошибка PING для '$TargetIP': Ошибка в основном блоке try - $($_.Exception.Message)"
    $detailsError = @{ error = $critErrorMessage; ErrorRecord = $_.ToString(); target_ip = $TargetIP; packets_sent = $PingCount }
    $finalResult = @{ IsAvailable=$isAvailable; CheckSuccess=$checkSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$detailsError; ErrorMessage=$critErrorMessage }
    Write-Error "[$NodeName] Check-PING: Критическая ошибка (упрощенный catch): $critErrorMessage"
}

# --- Возврат ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Host "[$NodeName] Check-PING (v2.3.0 - .NET): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr" -ForegroundColor Magenta
return $finalResult