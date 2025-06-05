# F:\status\source\powershell\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psm1
# --- Модуль утилит для Гибридного Агента Status Monitor ---
# --- Версия 2.1.3 --- (соответствует последней версии Check-SQL_QUERY_EXECUTE)
# - Добавлены комментарии для ясности работы в pipeline-архитектуре.
# - Небольшие улучшения в логировании Invoke-StatusMonitorCheck.
# - Предполагается, что Test-SuccessCriteria ~v2.0.6, Handle-ArrayCriteriaProcessing ~v1.0.3.

#--------------------------------------------------------------------------
# Приватные функции (не экспортируются модулем)
#--------------------------------------------------------------------------

#region Функция Compare-Values (v1.1.2 - Без изменений от предыдущего полного листинга)
# Сравнивает два значения с использованием указанного оператора.
# Используется внутри Test-SuccessCriteria.
function Compare-Values {
    param(
        $Value,
        $Operator,
        $Threshold
    )
    # Подробное логирование для отладки сравнений (включается через $DebugPreference = "Continue")
    Write-Debug "Compare-Values: Value=`"$($Value | Out-String -Width 100 | ForEach-Object {$_.Trim()})`", Operator=`"$Operator`", Threshold=`"$($Threshold | Out-String -Width 100 | ForEach-Object {$_.Trim()})`""
    $result = @{ Passed = $true; Reason = '' } # Инициализация результата по умолчанию
    $opLower = $Operator.ToString().ToLower() # Приводим оператор к нижнему регистру для унификации

    try {
        # Специальный оператор 'exists' для проверки наличия/отсутствия значения
        if ($opLower -eq 'exists') {
            if (($Threshold -eq $true -and $Value -eq $null) -or `
                ($Threshold -eq $false -and $Value -ne $null)) {
                $result.Passed = $false
                $result.Reason = "Проверка существования (exists=$Threshold) не пройдена для значения (Value is `$(if($Value -eq $null){'null'}else{'not null'}))."
            }
            return $result # Возвращаем результат проверки 'exists'
        }

        # Если значение $null, большинство операторов (кроме ==, !=) не могут быть применены корректно
        if ($Value -eq $null -and $opLower -ne '==' -and $opLower -ne '!=') {
             $result.Passed = $false # По умолчанию считаем провалом
             $result.Reason = "Невозможно применить оператор '$Operator' к значению `$null (если только оператор не '==' или '!=' для сравнения с `$null)."
             # Для числовых сравнений с $null результат неопределен (ставим Passed = $null)
             if ($opLower -in @('>', '>=', '<', '<=')) { $result.Passed = $null } 
             return $result
        }

        # Обработка операторов равенства/неравенства
        if ($opLower -eq '==') {
             if (-not ($Value -eq $Threshold)) { # Используем оператор PowerShell -eq
                 $result.Passed = $false; $result.Reason = "'$Value' не равно '$Threshold'"
             }
        }
        elseif ($opLower -eq '!=') {
             if (-not ($Value -ne $Threshold)) { # Используем оператор PowerShell -ne
                 $result.Passed = $false; $result.Reason = "'$Value' равно '$Threshold'"
             }
        }
        # Обработка числовых операторов сравнения
        elseif ($opLower -in @('>', '>=', '<', '<=')) {
            $numValue = 0.0; $numThreshold = 0.0
            $culture = [System.Globalization.CultureInfo]::InvariantCulture # Для корректного парсинга чисел с точкой/запятой
            
            $valueIsNumber = $false
            # Пытаемся преобразовать $Value в число
            if ($Value -is [ValueType] -and $Value -isnot [bool] -and $Value -isnot [datetime]) {
                try { $numValue = [double]$Value; $valueIsNumber = $true } catch {}
            }
            if (-not $valueIsNumber) { # Если прямое приведение не удалось, пробуем Parse
                $valueIsNumber = [double]::TryParse($Value, [System.Globalization.NumberStyles]::Any, $culture, [ref]$numValue)
            }

            $thresholdIsNumber = $false
            # Пытаемся преобразовать $Threshold в число
            if ($Threshold -is [ValueType] -and $Threshold -isnot [bool] -and $Threshold -isnot [datetime]) {
                try { $numThreshold = [double]$Threshold; $thresholdIsNumber = $true } catch {}
            }
            if (-not $thresholdIsNumber) {
                $thresholdIsNumber = [double]::TryParse($Threshold, [System.Globalization.NumberStyles]::Any, $culture, [ref]$numThreshold)
            }

            # Если одно из значений не удалось преобразовать в число, результат сравнения неопределен
            if (-not $valueIsNumber -or -not $thresholdIsNumber) {
                $result.Passed = $null 
                $reasonParts = @()
                if (-not $valueIsNumber) { $reasonParts += "Не удалось преобразовать значение '$Value' в число." }
                if (-not $thresholdIsNumber) { $reasonParts += "Не удалось преобразовать порог '$Threshold' в число." }
                $result.Reason = "Ошибка числового сравнения '$opLower': $($reasonParts -join ' ')"
                return $result
            }
            # Выполняем числовое сравнение
            switch ($opLower) {
                '>'  { if (-not ($numValue -gt $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' ($numValue) не больше (>) '$Threshold' ($numThreshold)" } }
                '>=' { if (-not ($numValue -ge $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' ($numValue) не больше или равно (>=) '$Threshold' ($numThreshold)" } }
                '<'  { if (-not ($numValue -lt $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' ($numValue) не меньше (<) '$Threshold' ($numThreshold)" } }
                '<=' { if (-not ($numValue -le $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' ($numValue) не меньше или равно (<=) '$Threshold' ($numThreshold)" } }
            }
        }
        # Обработка строковых операторов (contains, matches и их отрицания)
        elseif ($opLower -in @('contains', 'not_contains', 'matches', 'not_matches')) {
            $strValue = "$Value"       # Приводим к строке для безопасности
            $strThreshold = "$Threshold" # Приводим к строке
            switch ($opLower) {
                'contains'     { if ($strValue -notlike "*$strThreshold*") { $result.Passed = $false; $result.Reason = "'$strValue' не содержит '$strThreshold'" } }
                'not_contains' { if ($strValue -like "*$strThreshold*")    { $result.Passed = $false; $result.Reason = "'$strValue' содержит '$strThreshold'" } }
                'matches'      { if ($strValue -notmatch $strThreshold)    { $result.Passed = $false; $result.Reason = "'$strValue' не соответствует регулярному выражению '$strThreshold'" } } # $strThreshold - это Regex
                'not_matches'  { if ($strValue -match $strThreshold)       { $result.Passed = $false; $result.Reason = "'$strValue' соответствует регулярному выражению '$strThreshold'" } }
            }
        } else { # Если оператор неизвестен
            $result.Passed = $null # Результат неопределен
            $result.Reason = "Неизвестный оператор сравнения: '$Operator'"
        }
    } catch { # Обработка любых исключений во время сравнения
        $result.Passed = $null # Результат неопределен при ошибке
        $result.Reason = "Исключение при сравнении оператором '$Operator' для '$Value' и '$Threshold': $($_.Exception.Message)"
    }
    Write-Debug "Compare-Values Result: Passed=$($result.Passed), Reason=`"$($result.Reason)`""
    return $result
}
#endregion

#region Вспомогательная функция Test-IsOperatorBlock (v1.0.1 - Без изменений)
# Проверяет, является ли объект критерия операторным блоком (например, @{'>'=10; '<='=20}).
function Test-IsOperatorBlock {
    param (
        [Parameter(Mandatory=$true)] $CriteriaObject 
    )
    # Операторный блок должен быть Hashtable или PSCustomObject
    if (-not ($CriteriaObject -is [hashtable] -or $CriteriaObject -is [System.Management.Automation.PSCustomObject])) {
        return $false
    }
    # Список допустимых операторов
    $validOperators = @('>', '>=', '<', '<=', '==', '!=', 'contains', 'not_contains', 'matches', 'not_matches', 'exists')
    $keysInCriteria = $null
    if ($CriteriaObject -is [hashtable]) {
        $keysInCriteria = $CriteriaObject.Keys
    } elseif ($CriteriaObject -is [System.Management.Automation.PSCustomObject]) {
        $keysInCriteria = @($CriteriaObject.PSObject.Properties.Name)
    } else { return $false } # На всякий случай, хотя первая проверка уже это покрывает

    if ($keysInCriteria.Count -eq 0) { return $false } # Пустой объект - не операторный блок

    # Все ключи в операторном блоке должны быть из списка $validOperators
    foreach ($key in $keysInCriteria) {
        if ($validOperators -notcontains $key.ToString().ToLower()) { return $false }
    }
    return $true # Если все проверки пройдены
}
#endregion

#region Вспомогательная функция Handle-OperatorBlockProcessing (v1.0.1 - Без изменений)
# Обрабатывает операторный блок, применяя все операторы к значению из Details.
function Handle-OperatorBlockProcessing {
    param(
        [Parameter(Mandatory=$true)] 
        $DetailsValue,    # Значение из объекта Details, которое проверяется
        [Parameter(Mandatory=$true)]
        $OperatorBlock,   # Сам операторный блок (например, @{'>'=10; '<='=20})
        [Parameter(Mandatory=$true)]
        [string]$KeyName, # Имя ключа, к которому относится этот блок (для логов/сообщений)
        [Parameter(Mandatory=$true)]
        [string]$BasePath   # Путь к этому ключу в объекте Details (для логов/сообщений)
    )
    Write-Debug "Handle-OperatorBlockProcessing: Path=`"$BasePath.$KeyName`", DetailsValue=`"$($DetailsValue | Out-String -Width 100 | ForEach-Object {$_.Trim()})`""
    # Итерируем по каждому оператору в блоке
    foreach ($operatorEntry in $OperatorBlock.GetEnumerator()) {
        $operator = $operatorEntry.Name
        $threshold = $operatorEntry.Value
        # Выполняем сравнение
        $comparisonResult = Compare-Values -Value $DetailsValue -Operator $operator -Threshold $threshold
        # Если хотя бы одно сравнение не прошло, весь блок считается не пройденным
        if ($comparisonResult.Passed -ne $true) {
            return @{ Passed = $comparisonResult.Passed; Reason = "Оператор '$operator' для ключа '$KeyName' не пройден. $($comparisonResult.Reason)" }
        }
    }
    # Если все сравнения в блоке прошли успешно
    return @{ Passed = $true; Reason = $null }
}
#endregion

#region Вспомогательная функция Handle-ArrayCriteriaProcessing (v1.0.3 - Улучшен FailReason и логика all/any)
# Обрабатывает критерии для массивов (ключи _condition_, _where_, _criteria_, _count_).
function Handle-ArrayCriteriaProcessing {
    param(
        [Parameter(Mandatory=$true)]
        $DetailsArray,    # Массив значений из объекта Details, который проверяется
        [Parameter(Mandatory=$true)]
        [hashtable]$ArrayCriteria, # Объект критерия для массива
        [Parameter(Mandatory=$true)]
        [string]$PathPrefix # Путь к этому массиву в объекте Details
    )
    Write-Debug ("Handle-ArrayCriteriaProcessing: Начало обработки для пути `"{0}`". Условие: `"{1}`". Критерии массива: {2}" -f `
        $PathPrefix, $ArrayCriteria._condition_, ($ArrayCriteria | ConvertTo-Json -Depth 2 -Compress -WarningAction SilentlyContinue))

    $result = @{ Passed = $null; FailReason = $null } # Инициализация результата
    $condition = $ArrayCriteria._condition_
    $whereClause = $ArrayCriteria._where_          # Опциональный фильтр для элементов массива
    $criteriaForItems = $ArrayCriteria._criteria_  # Критерии, применяемые к каждому (отфильтрованному) элементу
    $countCriteria = $ArrayCriteria._count_       # Критерий на количество элементов

    # Валидация ключа _condition_
    if (-not $condition -or $condition.ToString().ToLower() -notin @('all', 'any', 'none', 'count')) {
        $result.Passed = $null
        $result.FailReason = "Отсутствует или неверный ключ '_condition_' в критерии для массива по пути '$PathPrefix'. Допустимые значения: 'all', 'any', 'none', 'count'."
        Write-Debug ("Handle-ArrayCriteriaProcessing: Ошибка валидации _condition_. Result: $($result | ConvertTo-Json -Compress)")
        return $result
    }
    $conditionLower = $condition.ToString().ToLower()

    # Валидация наличия _criteria_ для 'all' и 'any'
    if ($conditionLower -in @('all', 'any') -and ($null -eq $criteriaForItems -or ($criteriaForItems -is [hashtable] -and $criteriaForItems.Count -eq 0))) {
        $result.Passed = $null
        $result.FailReason = "Для _condition_ '$condition' в критерии массива по пути '$PathPrefix' требуется непустой ключ '_criteria_' (Hashtable)."
        Write-Debug ("Handle-ArrayCriteriaProcessing: Ошибка валидации _criteria_ для '$condition'. Result: $($result | ConvertTo-Json -Compress)")
        return $result
    }
    # Валидация наличия и формата _count_ для 'count'
    if ($conditionLower -eq 'count' -and ($null -eq $countCriteria -or -not (Test-IsOperatorBlock -CriteriaObject $countCriteria))) {
        $result.Passed = $null
        $result.FailReason = "Для _condition_ 'count' в критерии массива по пути '$PathPrefix' требуется ключ '_count_', содержащий корректный операторный блок."
        Write-Debug ("Handle-ArrayCriteriaProcessing: Ошибка валидации _count_. Result: $($result | ConvertTo-Json -Compress)")
        return $result
    }

    # Фильтрация массива, если задан _where_
    $filteredArray = $DetailsArray
    if ($null -ne $whereClause) {
        Write-Verbose "[$PathPrefix] Фильтрация массива (исходный размер: $($DetailsArray.Count)) с использованием _where_..."
        $tempFiltered = [System.Collections.Generic.List[object]]::new() 
        $itemIndex = -1
        foreach ($item in $DetailsArray) {
            $itemIndex++
            # Путь для логгирования/отладки фильтрации элемента
            $itemPathForWhere = "$PathPrefix" + "[$itemIndex_where]" 
            # Рекурсивный вызов Test-SuccessCriteria для проверки условия _where_ на элементе
            $filterCheckResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $whereClause -Path $itemPathForWhere
            if ($filterCheckResult.Passed -eq $true) { # Если элемент соответствует фильтру
                $tempFiltered.Add($item)
            } elseif ($filterCheckResult.Passed -eq $null) { # Ошибка при оценке фильтра
                $result.Passed = $null
                $result.FailReason = "Ошибка при фильтрации (проверке _where_) элемента массива [$itemIndex] по пути '$itemPathForWhere': $($filterCheckResult.FailReason)"
                Write-Debug ("Handle-ArrayCriteriaProcessing: Ошибка фильтрации элемента. Result: $($result | ConvertTo-Json -Compress)")
                return $result
            }
        }
        $filteredArray = $tempFiltered.ToArray() # Преобразуем список обратно в массив
        Write-Verbose "[$PathPrefix] Массив отфильтрован. Размер после _where_: $($filteredArray.Count)."
    }

    # Применение основного условия (_condition_) к (отфильтрованному) массиву
    $finalPassedStatus = $null # Итоговый статус прохождения критерия для массива

    switch ($conditionLower) {
        'all' { # Все элементы должны соответствовать _criteria_
            if ($filteredArray.Count -eq 0) { # Если массив пуст (после фильтра или изначально)
                $finalPassedStatus = $true # Условие 'all' на пустом множестве считается выполненным
            } else {
                 $allPassedFlag = $true # Предполагаем, что все пройдут
                 $firstFailReason = $null # Причина первого провала
                 $encounteredNullPassed = $false # Флаг, если оценка элемента дала $null
                 $itemIndexAll = -1
                 foreach ($item in $filteredArray) {
                     $itemIndexAll++
                     $itemPathForCriteriaAll = "$PathPrefix" + $(if ($null -ne $whereClause) { "[filtered:$itemIndexAll]" } else { "[$itemIndexAll]" })
                     $itemProcessingResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteriaForItems -Path $itemPathForCriteriaAll
                     
                     if ($itemProcessingResult.Passed -eq $null) { # Ошибка оценки для элемента
                         $allPassedFlag = $null # Весь 'all' становится $null
                         $encounteredNullPassed = $true
                         $firstFailReason = "Условие 'all': Ошибка оценки для элемента по пути '$itemPathForCriteriaAll'. Причина: $($itemProcessingResult.FailReason)"
                         break # Дальше проверять нет смысла
                     } elseif ($itemProcessingResult.Passed -eq $false) { # Элемент не прошел
                         $allPassedFlag = $false 
                         $firstFailReason = "Условие 'all' не выполнено для элемента по пути '$itemPathForCriteriaAll'. Причина: $($itemProcessingResult.FailReason)"
                         break # Дальше проверять нет смысла
                     }
                 }
                 $finalPassedStatus = $allPassedFlag
                 if ($finalPassedStatus -ne $true) { $result.FailReason = $firstFailReason }
            }
        } 
        'any' { # Хотя бы один элемент должен соответствовать _criteria_
             $anyPassedFlag = $false # Предполагаем, что ни один не пройдет
             $firstErrorReasonForAny = $null # Причина первой ошибки оценки
             $firstSuccessReasonForAny = $null # Для отладки, если нужно
             $foundTrue = $false # Флаг, что найден элемент, прошедший проверку

             if ($filteredArray.Count -gt 0) {
                 $itemIndexAny = -1
                 foreach ($item in $filteredArray) {
                     $itemIndexAny++
                     $itemPathForCriteriaAny = "$PathPrefix" + $(if ($null -ne $whereClause) { "[filtered:$itemIndexAny]" } else { "[$itemIndexAny]" })
                     $itemProcessingResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteriaForItems -Path $itemPathForCriteriaAny
                     
                     if ($itemProcessingResult.Passed -eq $true) { # Элемент прошел
                         $anyPassedFlag = $true
                         $firstSuccessReasonForAny = "Условие 'any' выполнено для элемента: $itemPathForCriteriaAny"
                         $foundTrue = $true
                         break # Нашли один, дальше проверять не нужно
                     } elseif ($itemProcessingResult.Passed -eq $null) { # Ошибка оценки элемента
                         $anyPassedFlag = $null # Весь 'any' становится $null
                         $firstErrorReasonForAny = "Условие 'any': Ошибка оценки для элемента по пути '$itemPathForCriteriaAny'. Причина: $($itemProcessingResult.FailReason)"
                         break # Дальше проверять нет смысла
                     }
                     # Если Passed -eq $false, просто запоминаем причину на случай, если true так и не найдется
                     if (-not $foundTrue) { # Обновляем причину, только если еще не нашли true
                        $result.FailReason = "Условие 'any': Элемент '$itemPathForCriteriaAny' не соответствует. Причина: $($itemProcessingResult.FailReason)"
                     }
                 }
             } # Если $filteredArray.Count -eq 0, то 'any' не может быть true, остается false
             
             if ($anyPassedFlag -eq $true) { # Если хотя бы один элемент прошел
                 $result.FailReason = $null # Успех, причина провала не нужна
             } elseif ($anyPassedFlag -eq $null) { # Если была ошибка оценки и ни один не прошел до этого
                 $result.FailReason = $firstErrorReasonForAny
             } else { # $anyPassedFlag -eq $false (ни один не подошел, и не было ошибок оценки)
                 if ([string]::IsNullOrEmpty($result.FailReason)) { # Если FailReason не был установлен от последнего элемента
                    $result.FailReason = "Условие 'any': ни один элемент в (отфильтрованном) массиве по пути '$PathPrefix' не соответствует указанным _criteria_."
                 }
             }
             $finalPassedStatus = $anyPassedFlag
        } 
        'none' { # Ни один элемент не должен соответствовать _criteria_ (или массив должен быть пуст, если _criteria_ нет)
             $nonePassedFlag = $true # Предполагаем, что условие выполнено
             if ($filteredArray.Count -gt 0) { # Если есть элементы для проверки
                 if ($null -eq $criteriaForItems) { # Если _criteria_ не заданы, а элементы есть - провал
                      $nonePassedFlag = $false
                      $result.FailReason = "Условие 'none' (без _criteria_): в (отфильтрованном) массиве по пути '$PathPrefix' есть элементы ($($filteredArray.Count) шт.), а ожидалось 0."
                 } else { # Если _criteria_ заданы, проверяем каждый элемент
                     $itemIndexNone = -1
                     foreach ($item in $filteredArray) {
                         $itemIndexNone++
                         $itemPathForCriteriaNone = "$PathPrefix" + $(if ($null -ne $whereClause) { "[filtered:$itemIndexNone]" } else { "[$itemIndexNone]" })
                         $itemProcessingResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteriaForItems -Path $itemPathForCriteriaNone
                         if ($itemProcessingResult.Passed -eq $true) { # Если элемент СООТВЕТСТВУЕТ - провал 'none'
                             $nonePassedFlag = $false
                             $result.FailReason = "Условие 'none': элемент по пути '$itemPathForCriteriaNone' СООТВЕТСТВУЕТ _criteria_, а не должен был."
                             break
                         } elseif ($itemProcessingResult.Passed -eq $null) { # Ошибка оценки
                             $nonePassedFlag = $null 
                             $result.FailReason = "Ошибка проверки элемента по пути '$itemPathForCriteriaNone' для условия 'none': $($itemProcessingResult.FailReason)"
                             break
                         }
                     }
                 }
             } # Если $filteredArray.Count -eq 0, то 'none' всегда true
             $finalPassedStatus = $nonePassedFlag
             Write-Debug "[$PathPrefix] Условие 'none': результат = $finalPassedStatus. Причина (если fail/null): $($result.FailReason)"
        } 
        'count' { # Проверка количества элементов
            $actualItemCount = $filteredArray.Count
            Write-Verbose "[$PathPrefix] Проверка количества элементов ($actualItemCount) для условия '_count_..."
            # Используем Handle-OperatorBlockProcessing для проверки количества
            $countCheckResult = Handle-OperatorBlockProcessing -DetailsValue $actualItemCount -OperatorBlock $countCriteria -KeyName "_count_" -BasePath $PathPrefix 
            $finalPassedStatus = $countCheckResult.Passed
            if ($finalPassedStatus -ne $true) {
                $result.FailReason = "Критерий количества ('count') элементов по пути '$PathPrefix' не пройден. $($countCheckResult.Reason)"
            }
            Write-Debug "[$PathPrefix] Условие 'count': результат = $finalPassedStatus. Причина (если fail/null): $($result.FailReason)"
        }
    } 

    $result.Passed = $finalPassedStatus
    Write-Debug ("Handle-ArrayCriteriaProcessing: Завершение обработки для пути `"{0}`". Итоговый Passed: {1}. FailReason: {2}" -f $PathPrefix, $result.Passed, $result.FailReason)
    return $result
}
#endregion

#region Основная функция Test-SuccessCriteria (v2.0.6 - Улучшено определение типа критерия для массивов и FailReason)
# Рекурсивно проверяет соответствие объекта Details заданным Критериям Успеха.
function Test-SuccessCriteria {
    [CmdletBinding()] 
    param(
        [Parameter(Mandatory=$true)] $DetailsObject,    # Объект (или его часть) с результатами проверки
        [Parameter(Mandatory=$true)] $CriteriaObject,   # Объект (или его часть) с критериями успеха
        [string]$Path = '$Details' # Текущий путь в объекте Details (для логгирования и сообщений об ошибках)
    )
    Write-Debug "--- Test-SuccessCriteria [Вход] --- Path: `"$Path`", Details Type: `"$($DetailsObject.GetType().Name)`", Criteria Type: `"$($CriteriaObject.GetType().Name)`""
    # Критерий должен быть Hashtable или PSCustomObject
    if (-not ($CriteriaObject -is [hashtable] -or $CriteriaObject -is [System.Management.Automation.PSCustomObject])) {
        return @{ Passed = $null; FailReason = "Объект критерия по пути '$Path' не является Hashtable или PSCustomObject (получен тип: $($CriteriaObject.GetType().FullName))." }
    }

    # Итерируем по каждому ключу в объекте критерия
    foreach ($criterionEntry in $CriteriaObject.GetEnumerator()) {
        $criterionKey = $criterionEntry.Name     # Имя ключа в критерии
        $criterionValue = $criterionEntry.Value  # Значение/объект критерия для этого ключа
        $currentEvaluationPath = "$Path.$criterionKey" # Полный путь к текущему проверяемому элементу
        Write-Debug "  [Цикл TSC] Path=`"$Path`", Key=`"$criterionKey`", CriteriaValue Type=`"$($criterionValue.GetType().FullName)`""

        # Пропускаем служебные ключи (_condition_, _where_ и т.д.) на верхнем уровне объекта,
        # они обрабатываются в Handle-ArrayCriteriaProcessing.
        # Проверяем, что текущий путь НЕ заканчивается на индекс массива (т.е. мы не внутри обработки элемента массива)
        if ($criterionKey -in @('_condition_', '_where_', '_criteria_', '_count_') -and -not ($Path -match '\[.+\]$')) {
            Write-Debug "    Пропуск служебного ключа массива '$criterionKey' на уровне объекта '$Path'."
            continue
        }

        $detailsValue = $null # Значение из DetailsObject для текущего ключа
        $keyExistsInDetails = $false  # Флаг, существует ли ключ в DetailsObject
        $propertyAccessError = $null  # Ошибка доступа к свойству/ключу

        # Получаем значение из DetailsObject
        if ($null -ne $DetailsObject) {
            if ($DetailsObject -is [hashtable]) { # Если DetailsObject - это Hashtable
                if ($DetailsObject.ContainsKey($criterionKey)) {
                    try { $detailsValue = $DetailsObject[$criterionKey]; $keyExistsInDetails = $true }
                    catch { $propertyAccessError = "Исключение при доступе к ключу '$criterionKey' в Hashtable '$Path': $($_.Exception.Message)" }
                }
            } elseif ($DetailsObject -is [System.Management.Automation.PSCustomObject]) { # Если PSCustomObject
                $propInfo = $DetailsObject.PSObject.Properties[$criterionKey]
                if ($null -ne $propInfo) {
                    try { $detailsValue = $propInfo.Value; $keyExistsInDetails = $true }
                    catch { $propertyAccessError = "Исключение при доступе к свойству '$criterionKey' в PSCustomObject '$Path': $($_.Exception.Message)" }
                }
            } elseif ($DetailsObject -is [array] -and $criterionKey -match '^\d+$' -and [int]::TryParse($criterionKey, [ref]$null)) {
                # Обработка случая, когда DetailsObject - это массив, а criterionKey - это индекс
                # (маловероятно на верхнем уровне, но возможно для вложенных структур)
                try {
                    $idx = [int]$criterionKey
                    if ($idx -ge 0 -and $idx -lt $DetailsObject.Count) {
                        $detailsValue = $DetailsObject[$idx]; $keyExistsInDetails = $true
                    }
                } catch { $propertyAccessError = "Исключение при доступе по индексу '$criterionKey' к массиву '$Path': $($_.Exception.Message)" }
            }
        }

        if ($null -ne $propertyAccessError) { # Если была ошибка доступа к данным
            Write-Debug "  [Ошибка доступа к свойству TSC] Path=`"$Path`", Key=`"$criterionKey`", Error=`"$propertyAccessError`""
            return @{ Passed = $null; FailReason = $propertyAccessError } # Результат неопределен
        }
        Write-Debug "    DetailsValue для '$criterionKey' (существует: $keyExistsInDetails): `"$($detailsValue | Out-String -Width 100 | ForEach-Object {$_.Trim()})`""

        $comparisonResult = $null # Результат сравнения/рекурсивного вызова
        $isCriterionValueComplex = $criterionValue -is [hashtable] -or $criterionValue -is [System.Management.Automation.PSCustomObject]

        if ($isCriterionValueComplex) { # Если значение критерия - это сложный объект (Hashtable/PSCustomObject)
            $isCriterionForArray = $false
            $criterionValueContainsCondition = $false
            # Проверяем, есть ли ключ _condition_ (признак критерия для массива)
            if ($criterionValue -is [hashtable]) {
                $criterionValueContainsCondition = $criterionValue.ContainsKey('_condition_')
            } elseif ($criterionValue -is [System.Management.Automation.PSCustomObject]) {
                $criterionValueContainsCondition = $criterionValue.PSObject.Properties.Name -contains '_condition_'
            }

            if ($criterionValueContainsCondition) { # Если есть _condition_
                 $condVal = $null
                 if ($criterionValue -is [hashtable]) {$condVal = $criterionValue['_condition_']} else {$condVal = $criterionValue._condition_}
                 # Проверяем, валидно ли значение _condition_
                 if ($condVal -and $condVal.ToString().ToLower() -in @('all', 'any', 'none', 'count')) {
                    $isCriterionForArray = $true # Это критерий для массива
                 } else { # Невалидное значение _condition_
                    $comparisonResult = @{ Passed = $null; Reason = "Ключ '_condition_' в критерии для '$currentEvaluationPath' имеет недопустимое значение '$($condVal | Out-String -Width 50)'. Ожидались 'all', 'any', 'none', 'count'." }
                 }
            }
            
            if ($null -eq $comparisonResult) { # Если предыдущая проверка на _condition_ прошла (или его не было)
                if ($isCriterionForArray) { # Обработка критерия для массива
                    Write-Debug "    Тип критерия для '$criterionKey': Массив (_condition_ найден и валиден)"
                    $isDetailsValueACollection = $false
                    if ($null -ne $detailsValue) {
                        if (($detailsValue -is [array]) -or ($detailsValue -is [System.Collections.IList])) {
                            $isDetailsValueACollection = $true
                        }
                    }
                    if (-not $keyExistsInDetails) { # Если ключ для массива отсутствует в Details
                         $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey', для которого ожидался массив данных, отсутствует в '$Path'." }
                    } elseif (-not $isDetailsValueACollection) { # Если значение в Details не является коллекцией
                        $actualType = if ($null -eq $detailsValue) { '$null' } else { $detailsValue.GetType().FullName }
                        $comparisonResult = @{ Passed = $false; Reason = "Для критерия массива по пути '$currentEvaluationPath' ожидался массив или коллекция (System.Array или System.Collections.IList) в данных, но получен '$actualType'." }
                    } else { # Данные являются коллекцией, передаем в Handle-ArrayCriteriaProcessing
                        $detailsArrayForProcessing = @($detailsValue) # Гарантируем, что это массив
                        $comparisonResult = Handle-ArrayCriteriaProcessing -DetailsArray $detailsArrayForProcessing -ArrayCriteria $criterionValue -PathPrefix $currentEvaluationPath
                    }
                } elseif (Test-IsOperatorBlock -CriteriaObject $criterionValue) { # Это операторный блок
                    Write-Debug "    Тип критерия для '$criterionKey': Операторный блок"
                    # Проверяем существование ключа в данных, если это не проверка на exists=false
                    if (-not $keyExistsInDetails) {
                         $isExistsFalseCheck = $false
                         if ($criterionValue -is [hashtable]) { $isExistsFalseCheck = ($criterionValue.ContainsKey('exists') -and $criterionValue['exists'] -eq $false) }
                         else { $isExistsFalseCheck = ($criterionValue.PSObject.Properties.Name -contains 'exists' -and $criterionValue.exists -eq $false) }

                        if (-not $isExistsFalseCheck) { # Если это не проверка на exists=false, а ключа нет - провал
                            $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey' отсутствует в данных ('$Path') для применения операторного блока." }
                        } else { # Это проверка exists=false и ключ отсутствует - будет обработано в Compare-Values
                             $comparisonResult = Handle-OperatorBlockProcessing -DetailsValue $detailsValue -OperatorBlock $criterionValue -KeyName $criterionKey -BasePath $Path
                        }
                    } else { # Ключ существует, применяем операторный блок
                        $comparisonResult = Handle-OperatorBlockProcessing -DetailsValue $detailsValue -OperatorBlock $criterionValue -KeyName $criterionKey -BasePath $Path
                    }
                } else { # $criterionValue - это сложный объект, но не критерий для массива и не операторный блок -> рекурсия
                    Write-Debug "    Тип критерия для '$criterionKey': Вложенный объект (рекурсивный вызов Test-SuccessCriteria)"
                    if (-not $keyExistsInDetails) { # Если ключ для вложенного объекта отсутствует в данных
                        $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey' из вложенного критерия отсутствует в данных по пути '$Path'."}
                    } elseif ($null -eq $detailsValue -and ($criterionValue.PSObject.Properties.Count -gt 0)) { # Данные null, а критерий ожидает объект
                         $comparisonResult = @{ Passed = $false; Reason = "Данные для '$currentEvaluationPath' равны `$null, но вложенный критерий ожидает объект."}
                    } elseif (($detailsValue -is [hashtable] -or $detailsValue -is [System.Management.Automation.PSCustomObject]) -or `
                              ($null -eq $detailsValue -and $criterionValue.PSObject.Properties.Count -eq 0) ) { # Данные - объект (или null, и критерий пуст)
                        # Рекурсивный вызов для вложенного объекта
                        $comparisonResult = Test-SuccessCriteria -DetailsObject $detailsValue -CriteriaObject $criterionValue -Path $currentEvaluationPath
                    } else { # Некорректный формат критерия (ожидался объект, а в данных простое значение)
                        $comparisonResult = @{ Passed = $null; Reason = "Некорректный формат критерия для ключа '$criterionKey' по пути '$Path'. Ожидалось простое значение или операторный блок, но получен сложный объект: '$($criterionValue | ConvertTo-Json -Depth 1 -Compress -WarningAction SilentlyContinue)'." }
                    }
                }
            } 
        } else { # $criterionValue - это простое значение (сравнение на точное равенство '==')
            Write-Debug "    Тип критерия для '$criterionKey': Простое значение (сравнение на точное равенство '==')"
            if (-not $keyExistsInDetails) { # Ключ отсутствует в данных
                $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey' из критерия отсутствует в данных для простого сравнения по пути '$Path'."}
            } else { # Ключ есть, выполняем сравнение
                $comparisonResult = Compare-Values -Value $detailsValue -Operator '==' -Threshold $criterionValue
            }
        }

        # Если результат сравнения/рекурсии не $true (т.е. $false или $null) - возвращаем ошибку
        if ($null -ne $comparisonResult -and $comparisonResult.Passed -ne $true) {
            $finalFailReasonDetail = $comparisonResult.Reason 
            if ([string]::IsNullOrEmpty($finalFailReasonDetail)) { # Запасная причина, если обработчик не вернул
                if ($comparisonResult.Passed -eq $false) { $finalFailReasonDetail = "Условие не выполнено (без дополнительной причины от обработчика)." }
                elseif ($comparisonResult.Passed -eq $null) { $finalFailReasonDetail = "Ошибка оценки условия (без дополнительной причины от обработчика)." }
                else { $finalFailReasonDetail = "Неизвестная причина провала (обработчик не вернул Reason)." }
            }
            $finalFailReason = "Критерий для '$criterionKey' по пути '$Path' не пройден. Причина: $finalFailReasonDetail"
            Write-Debug "  [Провал TSC] Key=`"$criterionKey`", Path=`"$Path`", CriterionValue=`"$($criterionValue | Out-String -Width 100 | ForEach-Object {$_.Trim()})`", ComparisonPassed=`"$($comparisonResult.Passed)`", Reason=`"$finalFailReason`""
            return @{ Passed = $comparisonResult.Passed; FailReason = $finalFailReason }
        }
        Write-Debug "  [Успех TSC для ключа] Key=`"$criterionKey`", Path=`"$Path`""
    } # Конец цикла foreach по критериям

    # Если все критерии на текущем уровне пройдены
    Write-Debug "--- Test-SuccessCriteria [Выход - Успех для всех ключей] --- Path: `"$Path`""
    return @{ Passed = $true; FailReason = $null } 
}
#endregion


#--------------------------------------------------------------------------
# Экспортируемые функции
#--------------------------------------------------------------------------

#region Функция New-CheckResultObject (Экспортируемая, v1.3.2 - Возвращает Hashtable)
# Формирует стандартизированный объект результата проверки.
function New-CheckResultObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [bool]$IsAvailable,          # УДАЛОСЬ ли выполнить саму проверку?
        [Parameter(Mandatory = $false)] [nullable[bool]]$CheckSuccess = $null, # Соответствует ли результат КРИТЕРИЯМ? (null если IsAvailable=false или ошибка критериев)
        [Parameter(Mandatory = $false)] $Details = $null,           # Детали проверки (зависят от метода, обычно Hashtable)
        [Parameter(Mandatory = $false)] [string]$ErrorMessage = $null # Сообщение об ошибке (если IsAvailable=false ИЛИ CheckSuccess=false/null)
    )
    # Обработка Details: приводим к Hashtable, если это PSCustomObject
    $processedDetails = $null
    if ($null -ne $Details) {
        if ($Details -is [hashtable]) { 
            $processedDetails = $Details 
        } elseif ($Details -is [System.Management.Automation.PSCustomObject]) {
            $processedDetails = @{} # Создаем новую Hashtable
            # Копируем свойства из PSCustomObject в Hashtable
            $Details.PSObject.Properties | ForEach-Object { $processedDetails[$_.Name] = $_.Value }
        } else { # Если Details - это простое значение, оборачиваем его
            $processedDetails = @{ Value = $Details }
        }
    }

    # Логика для CheckSuccess: если проверка недоступна, то и результат критериев $null
    $finalCheckSuccess = $CheckSuccess 
    if (-not $IsAvailable) {
        $finalCheckSuccess = $null
    }
    # Если проверка доступна ($IsAvailable=$true), но $CheckSuccess не был передан (т.е. остался $null из объявления параметра),
    # это означает, что либо критерии не применялись, либо их оценка дала $null (ошибка критерия).
    # В случае, если критерии НЕ применялись, скрипт Check-*.ps1 САМ должен установить $CheckSuccess = $true перед вызовом New-CheckResultObject.
    # Поэтому здесь мы НЕ меняем $finalCheckSuccess на $true по умолчанию, если $IsAvailable.

    # Логика для ErrorMessage
    $finalErrorMessage = $ErrorMessage
    if ([string]::IsNullOrEmpty($finalErrorMessage)) { # Если ErrorMessage не был явно задан
        if (-not $IsAvailable) {
            $finalErrorMessage = "Ошибка выполнения проверки (IsAvailable=false)."
        } elseif ($finalCheckSuccess -eq $false) {
            $finalErrorMessage = "Проверка не прошла по критериям (CheckSuccess=false)."
        } elseif ($finalCheckSuccess -eq $null -and $IsAvailable) { # $IsAvailable=true, но $CheckSuccess=$null (ошибка критерия)
             $finalErrorMessage = "Не удалось оценить критерии успеха (CheckSuccess=null), хотя проверка доступности прошла."
        }
    }
    
    # Формируем итоговый объект (Hashtable)
    $result = @{
        IsAvailable  = $IsAvailable
        CheckSuccess = $finalCheckSuccess
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o") # Время выполнения этой функции в UTC ISO 8601
        Details      = $processedDetails 
        ErrorMessage = $finalErrorMessage
    }

    Write-Verbose ("New-CheckResultObject (v1.3.2 - Hashtable): Создан результат: IsAvailable=$($result.IsAvailable), CheckSuccess=$($result.CheckSuccess | ForEach-Object {if($_ -eq $null){'[null]'}else{$_}}), ErrorMessage SET: $(!([string]::IsNullOrEmpty($result.ErrorMessage)))")
    return $result
}
#endregion

#region Функция Invoke-StatusMonitorCheck (Экспортируемая, v1.2.5 - Улучшено логирование и комментарии для pipeline)
# Главная функция-диспетчер. Вызывается Гибридным Агентом.
# В контексте pipeline-архитектуры (v5.x), эта функция вызывается для выполнения ОДНОГО ШАГА pipeline.
# Параметр $Assignment здесь представляет собой объект ОДНОГО ШАГА из массива pipeline.
function Invoke-StatusMonitorCheck {
    [CmdletBinding(SupportsShouldProcess = $false)] # ShouldProcess не используется
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Assignment # В v5.x это объект ОДНОГО ШАГА pipeline
    )

    # Валидация входного объекта шага
    if ($null -eq $Assignment -or `
        -not ($Assignment -is [System.Management.Automation.PSCustomObject]) -or `
        # Для шага pipeline ключевым является 'type', а не 'assignment_id'/'method_name' напрямую от агента.
        # 'method_name' или 'type' может приходить от агента, в зависимости от того, как он формирует $Assignment.
        # Будем более гибкими: ищем 'type' или 'method_name'.
        (-not ($Assignment.PSObject.Properties.Name -contains 'type') -and -not ($Assignment.PSObject.Properties.Name -contains 'method_name'))
      ) {
        $assignmentPreview = if ($Assignment) { $Assignment | ConvertTo-Json -Depth 1 -Compress -WarningAction SilentlyContinue } else { '$null' }
        Write-Warning "Invoke-StatusMonitorCheck: Передан некорректный или неполный объект шага pipeline. Ожидался PSCustomObject с полем 'type' (или 'method_name'). Получено: $assignmentPreview"
        return New-CheckResultObject -IsAvailable $false -ErrorMessage "Некорректный объект шага pipeline передан в Invoke-StatusMonitorCheck."
    }

    # Определяем тип шага (используем 'type', если есть, иначе 'method_name' для совместимости)
    $stepType = $null
    if ($Assignment.PSObject.Properties.Name -contains 'type') {
        $stepType = $Assignment.type
    } elseif ($Assignment.PSObject.Properties.Name -contains 'method_name') {
        $stepType = $Assignment.method_name # Для обратной совместимости или если агент использует 'method_name'
    }
    if ([string]::IsNullOrWhiteSpace($stepType)) {
        return New-CheckResultObject -IsAvailable $false -ErrorMessage "В объекте шага pipeline отсутствует или пусто поле 'type' (или 'method_name')."
    }

    # --- Извлечение остальных данных из объекта шага ($Assignment) ---
    # TargetIP для шага (может быть специфичным для шага, или браться из контекста узла)
    $targetIP = $null
    if ($Assignment.PSObject.Properties.Name -contains 'ip_address') { $targetIP = $Assignment.ip_address }
    elseif ($Assignment.PSObject.Properties.Name -contains 'target') { $targetIP = $Assignment.target } # Для PING, например

    # NodeName для логирования (может браться из контекста узла)
    $nodeNameForLog = "Шаг типа '$stepType'" 
    if ($Assignment.PSObject.Properties.Name -contains 'node_name' -and -not [string]::IsNullOrWhiteSpace($Assignment.node_name)) {
        $nodeNameForLog = $Assignment.node_name + " (Шаг: $stepType)"
    } elseif ($targetIP) {
        $nodeNameForLog = $targetIP + " (Шаг: $stepType)"
    }
    
    # Параметры для скрипта Check-*.ps1 (из поля 'parameters' объекта шага)
    $parametersForCheckScript = @{}
    $stepParametersObject = $null
    if ($Assignment.PSObject.Properties.Name -contains 'parameters') {
        $stepParametersObject = $Assignment.parameters
    }
    if ($null -ne $stepParametersObject) {
        if ($stepParametersObject -is [hashtable]) { $parametersForCheckScript = $stepParametersObject }
        elseif ($stepParametersObject -is [System.Management.Automation.PSCustomObject]) {
            try { $parametersForCheckScript = @{}; $stepParametersObject.PSObject.Properties | ForEach-Object { $parametersForCheckScript[$_.Name] = $_.Value } }
            catch { Write-Warning "[$nodeNameForLog] Не удалось преобразовать 'parameters' шага (PSCustomObject) в Hashtable. Используется пустой объект." }
        } else { Write-Warning "[$nodeNameForLog] Поле 'parameters' шага имеет неожиданный тип '$($stepParametersObject.GetType().FullName)'. Используется пустой объект."}
    }

    # Критерии успеха для скрипта Check-*.ps1 (из поля 'success_criteria' объекта шага)
    $successCriteriaForCheckScript = $null 
    $stepSuccessCriteriaObject = $null
    if ($Assignment.PSObject.Properties.Name -contains 'success_criteria') {
        $stepSuccessCriteriaObject = $Assignment.success_criteria
    }
    if ($null -ne $stepSuccessCriteriaObject) {
        if ($stepSuccessCriteriaObject -is [hashtable]) { $successCriteriaForCheckScript = $stepSuccessCriteriaObject }
        elseif ($stepSuccessCriteriaObject -is [System.Management.Automation.PSCustomObject]) {
            try { $successCriteriaForCheckScript = @{}; $stepSuccessCriteriaObject.PSObject.Properties | ForEach-Object { $successCriteriaForCheckScript[$_.Name] = $_.Value } }
            catch { Write-Warning "[$nodeNameForLog] Не удалось преобразовать 'success_criteria' шага (PSCustomObject) в Hashtable. Критерии не будут применены." }
        } else { Write-Warning "[$nodeNameForLog] Поле 'success_criteria' шага имеет неожиданный тип '$($stepSuccessCriteriaObject.GetType().FullName)'. Критерии не будут применены."}
    }
    
    $targetLogStringForStep = if ($targetIP) { $targetIP } else { '[Локально/Без цели]' }
    Write-Verbose "[$nodeNameForLog] Invoke-StatusMonitorCheck (для шага pipeline): Запуск типа '$stepType' для цели '$targetLogStringForStep'."

    $resultFromCheckScript = $null # Результат от скрипта Check-*.ps1
    try {
        # Определение пути к скриптам Checks/ относительно текущего модуля
        $ModuleBase = $MyInvocation.MyCommand.Module.ModuleBase
        if (-not $ModuleBase) { # Fallback, если запускается не как часть модуля (например, в тестах)
            if ($PSScriptRoot) { $ModuleBase = $PSScriptRoot } 
            else { throw "Не удалось определить базовый путь модуля для поиска скриптов Checks/." }
        }
        $ChecksFolder = Join-Path -Path $ModuleBase -ChildPath "Checks"
        $CheckScriptFile = "Check-$($stepType).ps1" # Имя файла скрипта (например, Check-PING.ps1)
        $CheckScriptPath = Join-Path -Path $ChecksFolder -ChildPath $CheckScriptFile
        Write-Verbose "[$nodeNameForLog] Invoke-StatusMonitorCheck: Поиск скрипта выполнения шага: '$CheckScriptPath'"

        if (-not (Test-Path $CheckScriptPath -PathType Leaf)) { # Если скрипт не найден
            $errMsg = "Скрипт '$CheckScriptFile' для выполнения шага типа '$stepType' не найден в '$ChecksFolder'."
            Write-Warning "[$nodeNameForLog] $errMsg"
            return New-CheckResultObject -IsAvailable $false -ErrorMessage $errMsg -Details @{ AttemptedScriptPath = $CheckScriptPath }
        }
        
        # Параметры, передаваемые в скрипт Check-*.ps1
        $paramsForActualCheckScriptExecution = @{
            TargetIP        = $targetIP         
            Parameters      = $parametersForCheckScript       
            SuccessCriteria = $successCriteriaForCheckScript  
            NodeName        = $nodeNameForLog # Передаем для консистентного логирования внутри скрипта
        }
        Write-Verbose "[$nodeNameForLog] Invoke-StatusMonitorCheck: Запуск скрипта '$CheckScriptFile' с параметрами..."
        # Динамический вызов скрипта
        $resultFromCheckScript = & $checkScriptPath @paramsForActualCheckScriptExecution
        
        # Проверка, что скрипт вернул корректный результат (Hashtable от New-CheckResultObject)
        if ($null -eq $resultFromCheckScript -or -not ($resultFromCheckScript -is [hashtable]) -or -not $resultFromCheckScript.ContainsKey('IsAvailable')) {
            $errMsg = "Скрипт '$CheckScriptFile' (для шага '$stepType') вернул некорректный результат или `$null."
            $resultTypeInfo = if ($null -eq $resultFromCheckScript) { '$null' } else { $resultFromCheckScript.GetType().FullName }
            Write-Warning "[$nodeNameForLog] $errMsg Тип результата: $resultTypeInfo. Ожидалась Hashtable от New-CheckResultObject."
            # Формируем объект ошибки
            $resultFromCheckScript = New-CheckResultObject -IsAvailable $false -ErrorMessage $errMsg -Details @{ ScriptOutput = ($resultFromCheckScript | Out-String -Width 200) }
        } else {
            Write-Verbose "[$nodeNameForLog] Invoke-StatusMonitorCheck: Скрипт '$CheckScriptFile' вернул корректный формат результата."
        }

    } catch { # Обработка критических ошибок при поиске или запуске скрипта Check-*.ps1
        $critErrMsg = "Критическая ошибка при выполнении шага типа '$stepType' для '$nodeNameForLog': $($_.Exception.Message)"
        Write-Warning "[$nodeNameForLog] $critErrMsg"
        $errorDetails = @{ ErrorRecord = $_.ToString(); StackTrace = $_.ScriptStackTrace }
        if ($CheckScriptPath) { $errorDetails.CheckedScriptPath = $CheckScriptPath }
        $resultFromCheckScript = New-CheckResultObject -IsAvailable $false -ErrorMessage $critErrMsg -Details $errorDetails
    }
    
    # Дополняем Details стандартной информацией (если Details существует и является Hashtable)
    if ($resultFromCheckScript -is [hashtable] -and $resultFromCheckScript.ContainsKey('Details') -and $resultFromCheckScript['Details'] -is [hashtable]) {
        $resultFromCheckScript['Details']['execution_target_host'] = $env:COMPUTERNAME # Хост, где реально выполнился скрипт
        $resultFromCheckScript['Details']['execution_mode_for_step'] = 'local_agent_step' # Указывает, что это локальный шаг
        # $targetIP уже должен быть в Details, если он был специфичен для шага (например, Check-PING).
        # Если он был контекстом узла, то агент сам его добавит в общий результат.
    }
    
    $isAvailableStepResult = if($resultFromCheckScript -is [hashtable]){$resultFromCheckScript['IsAvailable']}else{'$null'}
    $checkSuccessStepResult = if($resultFromCheckScript -is [hashtable]){ if ($null -eq $resultFromCheckScript['CheckSuccess']) {'[null]'} else {$resultFromCheckScript['CheckSuccess']} }else{'$null'}
    Write-Verbose "[$nodeNameForLog] Invoke-StatusMonitorCheck (для шага pipeline): Завершение. IsAvailable: $isAvailableStepResult, CheckSuccess: $checkSuccessStepResult"
    
    return $resultFromCheckScript
}
#endregion

# --- Экспорт функций ---
# Экспортируем функции, которые должны быть доступны извне модуля.
# Test-SuccessCriteria и Compare-Values экспортируются для возможного использования в более сложных
# сценариях или для тестирования. Test-ArrayCriteria остается приватной.
Export-ModuleMember -Function Invoke-StatusMonitorCheck, New-CheckResultObject, Test-SuccessCriteria, Compare-Values