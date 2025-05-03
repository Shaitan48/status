<#
.SYNOPSIS
    Скрипт проверки доступности узла с помощью Test-Connection (PING).
.DESCRIPTION
    Использует Test-Connection для отправки ICMP-запросов к целевому узлу.
    Возвращает стандартизированный объект результата.
.PARAMETER TargetIP
    [string] Обязательный. IP-адрес или имя хоста для пинга.
.PARAMETER Parameters
    [hashtable] Опциональный. Параметры для Test-Connection:
    - timeout_ms (int): Таймаут ожидания ответа в миллисекундах (по умолч. 1000).
    - count (int): Количество отправляемых запросов (по умолч. 1).
    - buffer_size (int): Размер буфера ICMP (по умолч. 32).
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха:
    - max_rtt_ms (int): Максимально допустимое время ответа (RTT) в мс.
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetIP,
    [Parameter(Mandatory=$false)]
    [hashtable]$Parameters = @{},
    [Parameter(Mandatory=$false)]
    [hashtable]$SuccessCriteria = $null,
    [Parameter(Mandatory=$false)]
    [string]$NodeName = "Unknown Node"
)

# Импортируем New-CheckResultObject, если он еще не доступен (на случай прямого запуска скрипта)
if (-not (Get-Command New-CheckResultObject -ErrorAction SilentlyContinue)) {
    try {
        # Пытаемся найти psm1 в родительской папке
        $UtilsModulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\StatusMonitorAgentUtils.psm1"
        if (Test-Path $UtilsModulePath) {
            Write-Verbose "Check-PING: Загрузка New-CheckResultObject из $UtilsModulePath"
            . $UtilsModulePath # Используем dot-sourcing для загрузки функций
        } else { throw "Не удалось найти StatusMonitorAgentUtils.psm1" }
    } catch {
        Write-Error "Check-PING: Не удалось загрузить функцию New-CheckResultObject! $($_.Exception.Message)"
        # Создаем заглушку, чтобы скрипт не упал полностью
        function New-CheckResultObject { param($IsAvailable, $CheckSuccess=$null, $Details=$null, $ErrorMessage=$null) return @{IsAvailable=$IsAvailable; CheckSuccess=$CheckSuccess; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=$Details; ErrorMessage=$ErrorMessage} }
    }
}


$TimeoutMs = $Parameters.timeout_ms | Get-OrElse 1000
$PingCount = $Parameters.count | Get-OrElse 1
$BufferSize = $Parameters.buffer_size | Get-OrElse 32
$TtlValue = 128
if ($TimeoutMs -lt 500) { $TtlValue = 64 }
if ($TimeoutMs -gt 2000) { $TtlValue = 255 }

Write-Verbose "[$NodeName] Check-PING: Начало проверки для $TargetIP (Count: $PingCount, Timeout: $TimeoutMs, Buffer: $BufferSize, TTL: $TtlValue)"

$isAvailable = $false
$checkSuccess = $null
$details = $null
$errorMessage = $null

try {
    # В PowerShell Core (v6+) Test-Connection не имеет BufferSize и TTL.
    # В PowerShell 5.1 они есть. Делаем проверку версии.
    $invokeParams = @{
        ComputerName = $TargetIP
        Count        = $PingCount
        ErrorAction  = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $invokeParams.TimeToLive = $TtlValue
        $invokeParams.BufferSize = $BufferSize
        # Таймаут в Test-Connection не очень надежен, лучше не использовать или делать свою обертку
        # if($TimeoutMs) { $invokeParams.TimeoutSeconds = [math]::Ceiling($TimeoutMs / 1000) }
    } else {
         # В PowerShell Core можно использовать -PingTimeout для общего таймаута
         if($TimeoutMs) { $invokeParams.PingTimeout = [math]::Ceiling($TimeoutMs / 1000) }
    }

    $pingResult = Test-Connection @invokeParams

    $isAvailable = $true
    $firstResponse = $pingResult | Select-Object -First 1
    # Обработка разных версий PS для получения RTT и IP
    $rtt = $null
    $actualIp = $null
    if ($firstResponse.PSObject.Properties.Name -contains 'ResponseTime') {
        $rtt = $firstResponse.ResponseTime # PS 5.1
    } elseif ($firstResponse.PSObject.Properties.Name -contains 'Latency') {
        $rtt = $firstResponse.Latency # PS Core
    }
    if ($firstResponse.PSObject.Properties.Name -contains 'IPV4Address') {
        $actualIp = $firstResponse.IPV4Address.IPAddressToString # PS 5.1
    } elseif ($firstResponse.PSObject.Properties.Name -contains 'Address') {
         $actualIp = $firstResponse.Address # PS Core
    }

    Write-Verbose "[$NodeName] Check-PING: Пинг успешен. RTT: $($rtt)ms, Ответивший IP: $actualIp"

    $details = @{
        response_time_ms = $rtt
        ip_address = $actualIp
        target_ip = $TargetIP
        ping_count = $PingCount
    }

    # Проверяем критерии успеха
    $maxRtt = $null
    if ($SuccessCriteria -ne $null -and $SuccessCriteria.ContainsKey('max_rtt_ms')) {
        if ([int]::TryParse($SuccessCriteria.max_rtt_ms, [ref]$maxRtt)) {
            Write-Verbose "[$NodeName] Check-PING: Применяется критерий max_rtt_ms = $maxRtt"
            if ($rtt -ne $null -and $rtt -gt $maxRtt) { # Добавили проверку $rtt -ne $null
                $checkSuccess = $false
                $errorMessage = "Время ответа (RTT) {0}ms превышает максимально допустимое ({1}ms)." -f $rtt, $maxRtt
                $details.success_criteria_failed = $errorMessage
                Write-Verbose "[$NodeName] Check-PING: $errorMessage"
            } else {
                $checkSuccess = $true
                Write-Verbose "[$NodeName] Check-PING: RTT $($rtt)ms соответствует критерию (<= $maxRtt ms)."
            }
        } else {
            $checkSuccess = $false
            $errorMessage = "Некорректное значение 'max_rtt_ms' в SuccessCriteria: '$($SuccessCriteria.max_rtt_ms)'."
            $details.success_criteria_error = $errorMessage
            Write-Warning "[$NodeName] Check-PING: $errorMessage"
        }
    } else {
        $checkSuccess = $true
        Write-Verbose "[$NodeName] Check-PING: Критерии успеха не заданы, CheckSuccess=True."
    }

} catch {
    # --- ИЗМЕНЕНО: Используем оператор -f ---
    $isAvailable = $false
    $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "Ошибка PING для {0}: {1}" -f $TargetIP, $exceptionMessage
    $details = @{ error = $errorMessage; target_ip = $TargetIP; ErrorRecord = $_.ToString() }
    Write-Warning "[$NodeName] Check-PING: $errorMessage"
}

# Формируем и возвращаем стандартизированный результат
$finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                     -CheckSuccess $checkSuccess `
                                     -Details $details `
                                     -ErrorMessage $errorMessage

Write-Verbose "[$NodeName] Check-PING: Возвращаемый результат: $($finalResult | ConvertTo-Json -Depth 3 -Compress)"
return $finalResult
