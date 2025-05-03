<#
.SYNOPSIS
    Скрипт проверки использования дискового пространства.
.DESCRIPTION
    Получает информацию о логических дисках (объем, свободное место)
    с помощью Get-Volume. Позволяет фильтровать диски и проверять
    соответствие критериям успеха (минимальный % свободного места).
    Возвращает стандартизированный объект результата.
.PARAMETER TargetIP
    [string] IP или имя хоста для проверки (передается диспетчером).
    Игнорируется этим скриптом, т.к. Get-Volume не использует -ComputerName
    напрямую при удаленном вызове через Invoke-Command. Диспетчер сам
    решает, выполнять скрипт локально или удаленно.
.PARAMETER Parameters
    [hashtable] Опциональный. Параметры проверки:
    - drives ([string[]]): Массив букв дисков для проверки (например, @('C', 'D')).
                           Регистр не важен. Если не указан или пуст,
                           проверяются все локальные диски типа 'Fixed'.
.PARAMETER SuccessCriteria
    [hashtable] Опциональный. Критерии успеха. Ключи - БОЛЬШИЕ буквы дисков
               (без двоеточия, например, 'C') или специальный ключ '_default_'.
               Значения - хэш-таблицы с критериями.
    Поддерживаемые критерии:
    - min_percent_free (int): Минимально допустимый процент свободного места.
    Пример: @{
                C = @{ min_percent_free = 10 } # Для диска C минимум 10%
                D = @{ min_percent_free = 15 } # Для диска D минимум 15%
                _default_ = @{ min_percent_free = 5 } # Для остальных дисков минимум 5%
            }
.PARAMETER NodeName
    [string] Опциональный. Имя узла для логирования (передается диспетчером).
.OUTPUTS
    Hashtable - Стандартизированный объект результата
                (IsAvailable, CheckSuccess, Timestamp, Details, ErrorMessage).
                Details содержит массив 'disks', где каждый элемент - хэш-таблица
                с информацией о конкретном диске.
.NOTES
    Версия: 1.1 (Исправлена ошибка с Add() и ToUpper())
    Зависит от функции New-CheckResultObject, которая должна быть
    доступна в окружении выполнения (загружена из StatusMonitorAgentUtils.psm1).
#>
param(
    # Целевой IP или имя хоста. Не используется напрямую в Get-Volume,
    # но принимается для совместимости с диспетчером.
    [Parameter(Mandatory=$true)]
    [string]$TargetIP,

    # Параметры, специфичные для проверки дисков (например, список букв).
    [Parameter(Mandatory=$false)]
    [hashtable]$Parameters = @{},

    # Критерии для определения успешности проверки (например, мин. % свободного места).
    [Parameter(Mandatory=$false)]
    [hashtable]$SuccessCriteria = $null,

    # Имя узла для более информативного логирования.
    [Parameter(Mandatory=$false)]
    [string]$NodeName = "Unknown Node"
)

# --- Начало логики проверки ---

# Инициализация хэш-таблицы для результата.
# IsAvailable = $false по умолчанию (пока проверка не выполнена успешно).
# Details.disks инициализируется как Generic List для возможности добавления элементов.
$resultData = @{
    IsAvailable = $false
    CheckSuccess = $null
    Details = @{ disks = [System.Collections.Generic.List[object]]::new() }
    ErrorMessage = $null
}
# Флаг общего успеха по всем критериям для всех проверенных дисков.
$overallCheckSuccess = $true
# Список для сбора сообщений об ошибках (особенно при несоответствии критериям).
$errorMessages = [System.Collections.Generic.List[string]]::new()

Write-Verbose "[$NodeName] Check-DISK_USAGE: Начало проверки дисков."

# Основной блок try/catch для отлова критических ошибок (например, недоступность Get-Volume).
try {

    # 1. Получаем информацию о томах с помощью Get-Volume.
    # Get-Volume возвращает информацию о дисковых томах системы.
    # Используем -ErrorAction Stop, чтобы прервать выполнение и перейти в catch при ошибке командлета.
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Вызов Get-Volume..."
    $volumes = Get-Volume -ErrorAction Stop

    # Если Get-Volume выполнился без ошибок, считаем, что проверка стала доступной.
    $resultData.IsAvailable = $true
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Получено томов: $($volumes.Count)"

    # 2. Фильтруем тома, которые нужно проверить.

    # Массив для хранения целевых букв дисков (в верхнем регистре).
    $targetDriveLetters = @()
    # Проверяем, передан ли параметр 'drives' и является ли он непустым массивом.
    if ($Parameters.ContainsKey('drives') -and $Parameters.drives -is [array] -and $Parameters.drives.Count -gt 0) {
        # Если да, приводим каждую букву к верхнему регистру и убираем пробелы.
        $targetDriveLetters = $Parameters.drives | ForEach-Object { $_.Trim().ToUpper() }
        Write-Verbose "[$NodeName] Check-DISK_USAGE: Фильтрация по указанным дискам: $($targetDriveLetters -join ', ')"
    } else {
        # Если параметр 'drives' не задан, будем проверять все подходящие диски.
        Write-Verbose "[$NodeName] Check-DISK_USAGE: Параметр 'drives' не указан, проверяем все диски типа 'Fixed'."
    }

    # Фильтруем полученные тома:
    $filteredVolumes = $volumes | Where-Object {
        # Оставляем только диски типа 'Fixed' (локальные жесткие диски).
        $isFixed = $_.DriveType -eq 'Fixed'
        # Оставляем только диски, у которых есть назначенная буква.
        $currentDriveLetterChar = $_.DriveLetter
        $hasLetter = $null -ne $currentDriveLetterChar -and (-not [string]::IsNullOrWhiteSpace($currentDriveLetterChar))

        # Преобразуем букву (которая является [char]) в строку для дальнейших операций.
        $currentDriveLetterString = $currentDriveLetterChar.ToString()

        # Проверяем, входит ли буква диска в целевой список (если список задан).
        # Если $targetDriveLetters пуст (т.е. параметр 'drives' не был задан), то это условие всегда true.
        $isInTargetList = $targetDriveLetters.Count -eq 0 -or $targetDriveLetters -contains $currentDriveLetterString.ToUpper()

        # Итоговое условие: диск должен быть Fixed, иметь букву и соответствовать списку (если он задан).
        $isFixed -and $hasLetter -and $isInTargetList
    }
    Write-Verbose "[$NodeName] Check-DISK_USAGE: Томов после фильтрации: $($filteredVolumes.Count)"

    # Если после фильтрации не осталось дисков для проверки.
    if ($filteredVolumes.Count -eq 0) {
         # Считаем результат успешным (нет дисков - нет проблем).
         $resultData.CheckSuccess = $true
         # Добавляем информационное сообщение в Details.
         $resultData.Details.message = "Нет дисков типа 'Fixed'"
         if ($targetDriveLetters.Count -gt 0) {
             $resultData.Details.message += " соответствующих указанным буквам ($($targetDriveLetters -join ', '))"
         }
         $resultData.Details.message += "."
         Write-Verbose "[$NodeName] Check-DISK_USAGE: $($resultData.Details.message)"
    } else {
        # 3. Обрабатываем каждый отфильтрованный том.
        foreach ($vol in $filteredVolumes) {

            # Получаем букву диска, преобразуем в строку и верхний регистр.
            $driveLetter = $vol.DriveLetter.ToString().ToUpper()

            # Создаем хэш-таблицу для хранения информации об этом диске.
            $diskInfo = @{
                drive_letter = $driveLetter
                label        = $vol.FileSystemLabel # Метка тома
                filesystem   = $vol.FileSystem     # Файловая система (NTFS, FAT32 и т.д.)
                size_bytes   = $vol.Size           # Общий размер в байтах
                free_bytes   = $vol.SizeRemaining  # Свободно в байтах
                used_bytes   = $vol.Size - $vol.SizeRemaining # Занято в байтах
                # Поля для рассчитанных значений (GB, %) - инициализируем null.
                size_gb      = $null
                free_gb      = $null
                used_gb      = $null
                percent_free = $null
                percent_used = $null
                # Поля для результатов проверки критериев.
                criteria_applied = $null # Какой критерий был применен ([hashtable] или $null).
                criteria_passed  = $null # Результат проверки критерия ([bool] или $null).
                criteria_failed_reason = $null # Причина провала критерия ([string] или $null).
            }

            # Рассчитываем значения в ГБ и процентах.
            # Проверяем, что размер диска > 0, чтобы избежать деления на ноль.
            if ($diskInfo.size_bytes -gt 0) {
                $diskInfo.size_gb = [math]::Round($diskInfo.size_bytes / 1GB, 2)
                $diskInfo.free_gb = [math]::Round($diskInfo.free_bytes / 1GB, 2)
                $diskInfo.used_gb = [math]::Round($diskInfo.used_bytes / 1GB, 2)
                $diskInfo.percent_free = [math]::Round(($diskInfo.free_bytes / $diskInfo.size_bytes) * 100, 1)
                $diskInfo.percent_used = [math]::Round(($diskInfo.used_bytes / $diskInfo.size_bytes) * 100, 1)
            } else {
                # Если размер 0 (например, пустой картридер), устанавливаем нулевые значения.
                $diskInfo.size_gb = 0
                $diskInfo.free_gb = 0
                $diskInfo.used_gb = 0
                $diskInfo.percent_free = 0
                $diskInfo.percent_used = 100
            }

            # 4. Проверяем критерии успеха для этого диска.
            $criterion = $null
            # Если критерии вообще переданы.
            if ($SuccessCriteria -ne $null) {
                # Ищем критерий для конкретной буквы диска (в верхнем регистре).
                if ($SuccessCriteria.ContainsKey($driveLetter)) {
                    $criterion = $SuccessCriteria[$driveLetter]
                    Write-Verbose "[$NodeName] Check-DISK_USAGE: Найден критерий для диска $driveLetter"
                }
                # Если конкретного нет, ищем критерий по умолчанию '_default_'.
                elseif ($SuccessCriteria.ContainsKey('_default_')) {
                    $criterion = $SuccessCriteria['_default_']
                    Write-Verbose "[$NodeName] Check-DISK_USAGE: Используется критерий _default_ для диска $driveLetter"
                }
            }

            # Применяем критерий, если он найден, является хэш-таблицей и содержит ключ 'min_percent_free'.
            if ($criterion -is [hashtable] -and $criterion.ContainsKey('min_percent_free')) {
                # Запоминаем, какой критерий применили.
                $diskInfo.criteria_applied = $criterion

                $minPercentFree = $null
                # Пытаемся преобразовать значение критерия в целое число.
                if ([int]::TryParse($criterion.min_percent_free, [ref]$minPercentFree)) {
                     Write-Verbose "[$NodeName] Check-DISK_USAGE: Диск $driveLetter - Проверка критерия min_percent_free = $minPercentFree %"
                     # Проверяем, если процент свободного места рассчитан и он меньше требуемого.
                     if ($diskInfo.percent_free -ne $null -and $diskInfo.percent_free -lt $minPercentFree) {
                         # Критерий НЕ пройден.
                         $diskInfo.criteria_passed = $false
                         $failReason = "Свободно {0}% < Требуется {1}%" -f $diskInfo.percent_free, $minPercentFree
                         $diskInfo.criteria_failed_reason = $failReason
                         # Добавляем сообщение об ошибке в общий список.
                         $errorMessages.Add(("Диск {0}: {1}" -f $driveLetter, $failReason)) | Out-Null
                         # Устанавливаем общий флаг успеха в $false.
                         $overallCheckSuccess = $false
                         Write-Verbose "[$NodeName] Check-DISK_USAGE: Диск $driveLetter - НЕУДАЧА по критерию: $failReason"
                     } else {
                          # Критерий пройден.
                          $diskInfo.criteria_passed = $true
                          Write-Verbose "[$NodeName] Check-DISK_USAGE: Диск $driveLetter - УСПЕХ по критерию."
                     }
                } else {
                     # Некорректное значение в критерии (не число).
                     $diskInfo.criteria_passed = $false # Считаем неудачей.
                     $failReason = "Некорректное значение min_percent_free ('$($criterion.min_percent_free)')"
                     $diskInfo.criteria_failed_reason = $failReason
                     # Добавляем сообщение об ошибке в общий список.
                     $errorMessages.Add(("Диск {0}: {1}" -f $driveLetter, $failReason)) | Out-Null
                     $overallCheckSuccess = $false
                     Write-Warning "[$NodeName] Check-DISK_USAGE: Диск $driveLetter - $failReason"
                }
            } else {
                 # Критерий для этого диска не найден или не содержит min_percent_free.
                 $diskInfo.criteria_passed = $null # Явно указываем, что критерий не применялся.
                 Write-Verbose "[$NodeName] Check-DISK_USAGE: Диск $driveLetter - Критерий min_percent_free не найден/не применен."
            }

            # Добавляем собранную информацию о диске в итоговый список в Details.
            $resultData.Details.disks.Add($diskInfo)

        } # Конец цикла foreach ($vol in $filteredVolumes)
    } # Конец else (если были диски для проверки)

    # Устанавливаем итоговый результат CheckSuccess.
    $resultData.CheckSuccess = $overallCheckSuccess
    # Если хотя бы один критерий не был пройден, формируем общее сообщение об ошибке.
    if (-not $overallCheckSuccess) {
        $resultData.ErrorMessage = $errorMessages -join '; '
    }

} catch {
    # Ловим критическую ошибку (например, Get-Volume не сработал).
    $resultData.IsAvailable = $false
    $resultData.CheckSuccess = $null
    # Формируем сообщение об ошибке.
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $errorMessage = "Ошибка получения информации о дисках: {0}" -f $exceptionMessage
    $resultData.ErrorMessage = $errorMessage
    # Убеждаемся, что Details существует и добавляем информацию об ошибке.
    if ($null -eq $resultData.Details) { $resultData.Details = @{} }
    $resultData.Details.error = $errorMessage
    $resultData.Details.ErrorRecord = $_.ToString()
    # Выводим ошибку в поток ошибок.
    Write-Error "[$NodeName] Check-DISK_USAGE: Критическая ошибка: $errorMessage"
}

# Формируем финальный объект результата с помощью общей функции.
# Передаем все собранные данные @resultData (splatting).
$finalResult = New-CheckResultObject @resultData
Write-Verbose "[$NodeName] Check-DISK_USAGE: Возвращаемый результат: $($finalResult | ConvertTo-Json -Depth 4 -Compress)"

# Возвращаем результат.
return $finalResult