# F:\status\source\powershell\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psm1
# --- Версия 2.1.0 --- (внутренне это скорее 2.0.4 для Test-SuccessCriteria)
# Включает все исправления для Check-PING и Check-PROCESS_LIST

#--------------------------------------------------------------------------
# Приватные функции (не экспортируются модулем)
#--------------------------------------------------------------------------

#region Функция Compare-Values (v1.1.2 - Убраны атрибуты Parameter у $Value)
# Вспомогательная функция для сравнения значений с операторами
# Возвращает: @{ Passed = $true/$false/$null; Reason = "..."/$null }
# ($null для Passed означает ошибку сравнения/типа)
function Compare-Values {
    param(
        $Value,         # Фактическое значение из Details. Может быть $null.
        $Operator,      # Оператор сравнения (строка: '>', 'contains', 'matches'...)
        $Threshold      # Пороговое значение из Criteria
    )
    Write-Debug "Compare-Values: Value=`"$($Value | Out-String -Width 100 | ForEach-Object {$_.Trim()})`", Operator=`"$Operator`", Threshold=`"$($Threshold | Out-String -Width 100 | ForEach-Object {$_.Trim()})`""
    $result = @{ Passed = $true; Reason = '' }
    $opLower = $Operator.ToString().ToLower() # Убедимся, что оператор - строка

    try {
        if ($opLower -eq 'exists') {
            if (($Threshold -eq $true -and $Value -eq $null) -or `
                ($Threshold -eq $false -and $Value -ne $null)) {
                $result.Passed = $false
                $result.Reason = "Проверка существования (exists=$Threshold) не пройдена для значения (Value is `$(if($Value -eq $null){'null'}else{'not null'}))."
            }
            return $result
        }

        if ($Value -eq $null -and $opLower -ne '==' -and $opLower -ne '!=') {
             $result.Passed = $false
             $result.Reason = "Невозможно применить оператор '$Operator' к значению `$null (если только оператор не '==' или '!=' для сравнения с `$null)."
             if ($opLower -in @('>', '>=', '<', '<=')) { $result.Passed = $null } # Ошибка типа для числовых операторов
             return $result
        }

        if ($opLower -eq '==') {
             if (-not ($Value -eq $Threshold)) {
                 $result.Passed = $false; $result.Reason = "'$Value' не равно '$Threshold'"
             }
        }
        elseif ($opLower -eq '!=') {
             if (-not ($Value -ne $Threshold)) {
                 $result.Passed = $false; $result.Reason = "'$Value' равно '$Threshold'"
             }
        }
        elseif ($opLower -in @('>', '>=', '<', '<=')) {
            $numValue = 0.0; $numThreshold = 0.0
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            
            $valueIsNumber = $false
            if ($Value -is [ValueType] -and $Value -isnot [bool] -and $Value -isnot [datetime]) {
                try { $numValue = [double]$Value; $valueIsNumber = $true } catch {}
            }
            if (-not $valueIsNumber) {
                $valueIsNumber = [double]::TryParse($Value, [System.Globalization.NumberStyles]::Any, $culture, [ref]$numValue)
            }

            $thresholdIsNumber = $false
            if ($Threshold -is [ValueType] -and $Threshold -isnot [bool] -and $Threshold -isnot [datetime]) {
                try { $numThreshold = [double]$Threshold; $thresholdIsNumber = $true } catch {}
            }
            if (-not $thresholdIsNumber) {
                $thresholdIsNumber = [double]::TryParse($Threshold, [System.Globalization.NumberStyles]::Any, $culture, [ref]$numThreshold)
            }

            if (-not $valueIsNumber -or -not $thresholdIsNumber) {
                $result.Passed = $null 
                $reasonParts = @()
                if (-not $valueIsNumber) { $reasonParts += "Не удалось преобразовать значение '$Value' в число." }
                if (-not $thresholdIsNumber) { $reasonParts += "Не удалось преобразовать порог '$Threshold' в число." }
                $result.Reason = "Ошибка числового сравнения '$opLower': $($reasonParts -join ' ')"
                return $result
            }
            switch ($opLower) {
                '>'  { if (-not ($numValue -gt $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' ($numValue) не больше (>) '$Threshold' ($numThreshold)" } }
                '>=' { if (-not ($numValue -ge $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' ($numValue) не больше или равно (>=) '$Threshold' ($numThreshold)" } }
                '<'  { if (-not ($numValue -lt $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' ($numValue) не меньше (<) '$Threshold' ($numThreshold)" } }
                '<=' { if (-not ($numValue -le $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' ($numValue) не меньше или равно (<=) '$Threshold' ($numThreshold)" } }
            }
        }
        elseif ($opLower -in @('contains', 'not_contains', 'matches', 'not_matches')) {
            $strValue = "$Value"
            $strThreshold = "$Threshold"
            switch ($opLower) {
                'contains'     { if ($strValue -notlike "*$strThreshold*") { $result.Passed = $false; $result.Reason = "'$strValue' не содержит '$strThreshold'" } }
                'not_contains' { if ($strValue -like "*$strThreshold*")    { $result.Passed = $false; $result.Reason = "'$strValue' содержит '$strThreshold'" } }
                'matches'      { if ($strValue -notmatch $strThreshold)    { $result.Passed = $false; $result.Reason = "'$strValue' не соответствует регулярному выражению '$strThreshold'" } }
                'not_matches'  { if ($strValue -match $strThreshold)       { $result.Passed = $false; $result.Reason = "'$strValue' соответствует регулярному выражению '$strThreshold'" } }
            }
        } else {
            $result.Passed = $null
            $result.Reason = "Неизвестный оператор сравнения: '$Operator'"
        }
    } catch {
        $result.Passed = $null
        $result.Reason = "Исключение при сравнении оператором '$Operator' для '$Value' и '$Threshold': $($_.Exception.Message)"
    }
    Write-Debug "Compare-Values Result: Passed=$($result.Passed), Reason=`"$($result.Reason)`""
    return $result
}
#endregion

#region Вспомогательная функция Test-IsOperatorBlock (v1.0.1)
function Test-IsOperatorBlock {
    param (
        [Parameter(Mandatory=$true)] $CriteriaObject 
    )
    if (-not ($CriteriaObject -is [hashtable] -or $CriteriaObject -is [System.Management.Automation.PSCustomObject])) {
        return $false
    }
    $validOperators = @('>', '>=', '<', '<=', '==', '!=', 'contains', 'not_contains', 'matches', 'not_matches', 'exists')
    $keysInCriteria = $null
    if ($CriteriaObject -is [hashtable]) {
        $keysInCriteria = $CriteriaObject.Keys
    } elseif ($CriteriaObject -is [System.Management.Automation.PSCustomObject]) {
        $keysInCriteria = @($CriteriaObject.PSObject.Properties.Name)
    } else {
        return $false 
    }
    if ($keysInCriteria.Count -eq 0) { return $false }
    foreach ($key in $keysInCriteria) {
        if ($validOperators -notcontains $key.ToString().ToLower()) {
            return $false 
        }
    }
    return $true 
}
#endregion

#region Вспомогательная функция Handle-OperatorBlockProcessing (v1.0.1 - Удален AllowNull для PS 5.1)
function Handle-OperatorBlockProcessing {
    param(
        [Parameter(Mandatory=$true)] # Убрали AllowNull=$true; $DetailsValue МОЖЕТ быть $null
        $DetailsValue,    
        [Parameter(Mandatory=$true)]
        $OperatorBlock,   
        [Parameter(Mandatory=$true)]
        [string]$KeyName, 
        [Parameter(Mandatory=$true)]
        [string]$BasePath   
    )
    Write-Debug "Handle-OperatorBlockProcessing: Path=`"$BasePath.$KeyName`", DetailsValue=`"$($DetailsValue | Out-String -Width 100 | ForEach-Object {$_.Trim()})`""
    foreach ($operatorEntry in $OperatorBlock.GetEnumerator()) {
        $operator = $operatorEntry.Name
        $threshold = $operatorEntry.Value
        $comparisonResult = Compare-Values -Value $DetailsValue -Operator $operator -Threshold $threshold
        if ($comparisonResult.Passed -ne $true) {
            return @{ Passed = $comparisonResult.Passed; Reason = "Оператор '$operator' для ключа '$KeyName' не пройден. $($comparisonResult.Reason)" }
        }
    }
    return @{ Passed = $true; Reason = $null }
}
#endregion

#region Вспомогательная функция Handle-ArrayCriteriaProcessing (v1.0.2 - Исправлена конкатенация для Path, улучшено логирование)
# Обрабатывает критерии для массива (_condition_, _where_, _criteria_, _count_)
function Handle-ArrayCriteriaProcessing {
    param(
        [Parameter(Mandatory=$true)]
        $DetailsArray,    # Массив данных из Details, к которому применяются критерии (ожидается System.Array)
        [Parameter(Mandatory=$true)]
        [hashtable]$ArrayCriteria, # Критерий для массива (содержит _condition_, etc.)
        [Parameter(Mandatory=$true)]
        [string]$PathPrefix # Текущий путь в структуре Details до этого массива (например, '$details.processes')
    )
    # Логирование входа
    Write-Debug ("Handle-ArrayCriteriaProcessing: Начало обработки для пути `"{0}`". Условие: `"{1}`". Критерии массива: {2}" -f `
        $PathPrefix, $ArrayCriteria._condition_, ($ArrayCriteria | ConvertTo-Json -Depth 2 -Compress -WarningAction SilentlyContinue))

    $result = @{ Passed = $null; FailReason = $null } # Инициализация результата

    # 1. Извлечение и валидация управляющих ключей из ArrayCriteria
    $condition = $ArrayCriteria._condition_
    $whereClause = $ArrayCriteria._where_          # Может быть $null (Hashtable)
    $criteriaForItems = $ArrayCriteria._criteria_  # Может быть $null (Hashtable)
    $countCriteria = $ArrayCriteria._count_       # Может быть $null (Hashtable - операторный блок)

    if (-not $condition -or $condition.ToString().ToLower() -notin @('all', 'any', 'none', 'count')) {
        $result.Passed = $null
        $result.FailReason = "Отсутствует или неверный ключ '_condition_' в критерии для массива по пути '$PathPrefix'. Допустимые значения: 'all', 'any', 'none', 'count'."
        Write-Debug ("Handle-ArrayCriteriaProcessing: Ошибка валидации _condition_. Result: $($result | ConvertTo-Json -Compress)")
        return $result
    }
    $conditionLower = $condition.ToString().ToLower()

    # Дополнительная валидация для специфичных условий
    if ($conditionLower -in @('all', 'any') -and ($null -eq $criteriaForItems -or ($criteriaForItems -is [hashtable] -and $criteriaForItems.Count -eq 0))) {
        $result.Passed = $null
        $result.FailReason = "Для _condition_ '$condition' в критерии массива по пути '$PathPrefix' требуется непустой ключ '_criteria_' (Hashtable)."
        Write-Debug ("Handle-ArrayCriteriaProcessing: Ошибка валидации _criteria_ для '$condition'. Result: $($result | ConvertTo-Json -Compress)")
        return $result
    }
    if ($conditionLower -eq 'count' -and ($null -eq $countCriteria -or -not (Test-IsOperatorBlock -CriteriaObject $countCriteria))) {
        $result.Passed = $null
        $result.FailReason = "Для _condition_ 'count' в критерии массива по пути '$PathPrefix' требуется ключ '_count_', содержащий корректный операторный блок."
        Write-Debug ("Handle-ArrayCriteriaProcessing: Ошибка валидации _count_. Result: $($result | ConvertTo-Json -Compress)")
        return $result
    }

    # 2. Фильтрация массива $DetailsArray с использованием _where_ (если он есть)
    $filteredArray = $DetailsArray # По умолчанию работаем со всем массивом (который уже должен быть System.Array)
    if ($null -ne $whereClause) {
        Write-Verbose "[$PathPrefix] Фильтрация массива (исходный размер: $($DetailsArray.Count)) с использованием _where_..."
        $tempFiltered = [System.Collections.Generic.List[object]]::new() # Используем List для удобного Add
        $itemIndex = -1
        foreach ($item in $DetailsArray) {
            $itemIndex++
            # Формируем путь к элементу для логирования внутри Test-SuccessCriteria
            $itemPathForWhere = "$PathPrefix" + "[$itemIndex_where]" 
            
            $filterCheckResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $whereClause -Path $itemPathForWhere
            
            if ($filterCheckResult.Passed -eq $true) {
                $tempFiltered.Add($item)
            } elseif ($filterCheckResult.Passed -eq $null) {
                $result.Passed = $null
                $result.FailReason = "Ошибка при фильтрации (проверке _where_) элемента массива [$itemIndex] по пути '$itemPathForWhere': $($filterCheckResult.FailReason)"
                Write-Debug ("Handle-ArrayCriteriaProcessing: Ошибка фильтрации элемента. Result: $($result | ConvertTo-Json -Compress)")
                return $result
            }
        }
        $filteredArray = $tempFiltered.ToArray() # Преобразуем обратно в System.Array для единообразия
        Write-Verbose "[$PathPrefix] Массив отфильтрован. Размер после _where_: $($filteredArray.Count)."
    }

    # 3. Применение основного условия (_condition_) к (отфильтрованному) массиву
    $finalPassedStatus = $null 

    switch ($conditionLower) {
        'all' {
            # 'all' означает, что ВСЕ элементы в $filteredArray должны соответствовать $criteriaForItems.
            # Если $filteredArray пуст (например, после _where_), 'all' считается выполненным.
            if ($filteredArray.Count -eq 0) {
                $finalPassedStatus = $true
                Write-Debug "[$PathPrefix] Условие 'all': отфильтрованный массив пуст, результат = true."
            } else {
                 $allPassedFlag = $true 
                 $itemIndex = -1
                 foreach ($item in $filteredArray) {
                     $itemIndex++
                     # --- ИСПРАВЛЕНО: Конкатенация строки с использованием $() для if ---
                     $itemPathForCriteria = "$PathPrefix" + $(if ($null -ne $whereClause) { "[filtered:$itemIndex]" } else { "[$itemIndex]" })
                     # --- КОНЕЦ ИСПРАВЛЕНИЯ ---
                     $itemProcessingResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteriaForItems -Path $itemPathForCriteria
                     if ($itemProcessingResult.Passed -ne $true) {
                         $allPassedFlag = $itemProcessingResult.Passed 
                         $result.FailReason = "Условие 'all' не выполнено для элемента по пути '$itemPathForCriteria'. Причина: $($itemProcessingResult.FailReason)"
                         break 
                     }
                 }
                 $finalPassedStatus = $allPassedFlag
                 Write-Debug "[$PathPrefix] Условие 'all': результат для элементов = $finalPassedStatus. Причина (если fail/null): $($result.FailReason)"
            }
        } 
        'any' {
             # 'any' означает, что ХОТЯ БЫ ОДИН элемент в $filteredArray должен соответствовать $criteriaForItems.
             $anyPassedFlag = $false 
             if ($filteredArray.Count -gt 0) {
                 $itemIndex = -1
                 foreach ($item in $filteredArray) {
                     $itemIndex++
                     # --- ИСПРАВЛЕНО: Конкатенация строки с использованием $() для if ---
                     $itemPathForCriteria = "$PathPrefix" + $(if ($null -ne $whereClause) { "[filtered:$itemIndex]" } else { "[$itemIndex]" })
                     # --- КОНЕЦ ИСПРАВЛЕНИЯ ---
                     $itemProcessingResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteriaForItems -Path $itemPathForCriteria
                     if ($itemProcessingResult.Passed -eq $true) {
                         $anyPassedFlag = $true
                         $result.FailReason = $null 
                         break 
                     } elseif ($itemProcessingResult.Passed -eq $null) {
                         $anyPassedFlag = $null 
                         $result.FailReason = "Ошибка проверки элемента по пути '$itemPathForCriteria' для условия 'any': $($itemProcessingResult.FailReason)"
                         break 
                     }
                 }
             }
             if ($anyPassedFlag -eq $false -and $result.FailReason -eq $null) { # Если не нашли и не было ошибки
                 $result.FailReason = "Условие 'any': ни один элемент в (отфильтрованном) массиве по пути '$PathPrefix' не соответствует указанным _criteria_."
             }
             $finalPassedStatus = $anyPassedFlag
             Write-Debug "[$PathPrefix] Условие 'any': результат = $finalPassedStatus. Причина (если fail/null): $($result.FailReason)"
        } 
        'none' {
             # 'none' означает, что НИ ОДИН элемент в $filteredArray не должен соответствовать $criteriaForItems.
             # Если $criteriaForItems не указан (это было бы ошибкой валидации выше), то 'none' означает, что $filteredArray должен быть пустым.
             $nonePassedFlag = $true 
             if ($filteredArray.Count -gt 0) {
                 # Если $criteriaForItems $null, то само наличие элементов в $filteredArray после _where_ означает провал 'none'.
                 # Однако, валидация выше должна гарантировать, что $criteriaForItems не $null, если $conditionLower не 'count' или 'none' без _where_.
                 # Для 'none' _criteria_ может быть, а может и не быть. Если его нет, то $filteredArray должен быть пуст.
                 if ($null -eq $criteriaForItems) {
                     $nonePassedFlag = $false # Так как $filteredArray.Count -gt 0
                     $result.FailReason = "Условие 'none' (без _criteria_): в (отфильтрованном) массиве по пути '$PathPrefix' есть элементы ($($filteredArray.Count) шт.), а ожидалось 0."
                 } else {
                     $itemIndex = -1
                     foreach ($item in $filteredArray) {
                         $itemIndex++
                         # --- ИСПРАВЛЕНО: Конкатенация строки с использованием $() для if ---
                         $itemPathForCriteria = "$PathPrefix" + $(if ($null -ne $whereClause) { "[filtered:$itemIndex]" } else { "[$itemIndex]" })
                         # --- КОНЕЦ ИСПРАВЛЕНИЯ ---
                         $itemProcessingResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteriaForItems -Path $itemPathForCriteria
                         if ($itemProcessingResult.Passed -eq $true) { 
                             $nonePassedFlag = $false
                             $result.FailReason = "Условие 'none': элемент по пути '$itemPathForCriteria' СООТВЕТСТВУЕТ _criteria_, а не должен был."
                             break
                         } elseif ($itemProcessingResult.Passed -eq $null) {
                             $nonePassedFlag = $null 
                             $result.FailReason = "Ошибка проверки элемента по пути '$itemPathForCriteria' для условия 'none': $($itemProcessingResult.FailReason)"
                             break
                         }
                     }
                 }
             }
             # Если $filteredArray пуст, то 'none' всегда выполняется.
             $finalPassedStatus = $nonePassedFlag
             Write-Debug "[$PathPrefix] Условие 'none': результат = $finalPassedStatus. Причина (если fail/null): $($result.FailReason)"
        } 
        'count' {
            $actualItemCount = $filteredArray.Count
            Write-Verbose "[$PathPrefix] Проверка количества элементов ($actualItemCount) для условия '_count_..."
            $countCheckResult = Handle-OperatorBlockProcessing -DetailsValue $actualItemCount -OperatorBlock $countCriteria -KeyName "_count_" -BasePath $PathPrefix # BasePath здесь для контекста логов
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

#region Основная рефакторенная функция Test-SuccessCriteria (v2.0.4 - Исправлена проверка ключа _condition_ и типа массива)
function Test-SuccessCriteria {
    [CmdletBinding()] 
    param(
        [Parameter(Mandatory=$true)] $DetailsObject,
        [Parameter(Mandatory=$true)] $CriteriaObject,
        [string]$Path = '$Details' 
    )
    Write-Debug "--- Test-SuccessCriteria [Вход] --- Path: `"$Path`", Details Type: `"$($DetailsObject.GetType().Name)`", Criteria Type: `"$($CriteriaObject.GetType().Name)`""
    if (-not ($CriteriaObject -is [hashtable] -or $CriteriaObject -is [System.Management.Automation.PSCustomObject])) {
        return @{ Passed = $null; FailReason = "Объект критерия по пути '$Path' не является Hashtable или PSCustomObject (получен тип: $($CriteriaObject.GetType().FullName))." }
    }

    foreach ($criterionEntry in $CriteriaObject.GetEnumerator()) {
        $criterionKey = $criterionEntry.Name
        $criterionValue = $criterionEntry.Value 
        $currentEvaluationPath = "$Path.$criterionKey" 
        Write-Debug "  [Цикл TSC] Path=`"$Path`", Key=`"$criterionKey`", CriteriaValue Type=`"$($criterionValue.GetType().FullName)`""

        if ($criterionKey -in @('_condition_', '_where_', '_criteria_', '_count_') -and -not ($Path -match '\[.+\]$')) {
            Write-Debug "    Пропуск служебного ключа массива '$criterionKey' на уровне объекта '$Path'."
            continue
        }

        $detailsValue = $null       
        $keyExistsInDetails = $false  
        $propertyAccessError = $null  

        if ($null -ne $DetailsObject) {
            if ($DetailsObject -is [hashtable]) {
                if ($DetailsObject.ContainsKey($criterionKey)) {
                    try { $detailsValue = $DetailsObject[$criterionKey]; $keyExistsInDetails = $true }
                    catch { $propertyAccessError = "Исключение при доступе к ключу '$criterionKey' в Hashtable '$Path': $($_.Exception.Message)" }
                }
            } elseif ($DetailsObject -is [System.Management.Automation.PSCustomObject]) {
                $propInfo = $DetailsObject.PSObject.Properties[$criterionKey]
                if ($null -ne $propInfo) {
                    try { $detailsValue = $propInfo.Value; $keyExistsInDetails = $true }
                    catch { $propertyAccessError = "Исключение при доступе к свойству '$criterionKey' в PSCustomObject '$Path': $($_.Exception.Message)" }
                }
            } elseif ($DetailsObject -is [array] -and $criterionKey -match '^\d+$' -and [int]::TryParse($criterionKey, [ref]$null)) {
                try {
                    $idx = [int]$criterionKey
                    if ($idx -ge 0 -and $idx -lt $DetailsObject.Count) {
                        $detailsValue = $DetailsObject[$idx]; $keyExistsInDetails = $true
                    }
                } catch { $propertyAccessError = "Исключение при доступе по индексу '$criterionKey' к массиву '$Path': $($_.Exception.Message)" }
            }
        }

        if ($null -ne $propertyAccessError) {
            Write-Debug "  [Ошибка доступа к свойству TSC] Path=`"$Path`", Key=`"$criterionKey`", Error=`"$propertyAccessError`""
            return @{ Passed = $null; FailReason = $propertyAccessError }
        }
        
        Write-Debug "    DetailsValue для '$criterionKey' (существует: $keyExistsInDetails): `"$($detailsValue | Out-String -Width 100 | ForEach-Object {$_.Trim()})`""

        $comparisonResult = $null 
        $isCriterionValueComplex = $criterionValue -is [hashtable] -or $criterionValue -is [System.Management.Automation.PSCustomObject]

        if ($isCriterionValueComplex) {
            $isCriterionForArray = $false
            $criterionValueContainsCondition = $false
            if ($criterionValue -is [hashtable]) {
                $criterionValueContainsCondition = $criterionValue.ContainsKey('_condition_')
            } elseif ($criterionValue -is [System.Management.Automation.PSCustomObject]) { # Должно быть $criterionValue.PSObject
                $criterionValueContainsCondition = $criterionValue.PSObject.Properties.Name -contains '_condition_'
            }

            if ($criterionValueContainsCondition) {
                 $condVal = $null
                 if ($criterionValue -is [hashtable]) {$condVal = $criterionValue['_condition_']} else {$condVal = $criterionValue._condition_}

                 if ($condVal -and $condVal.ToString().ToLower() -in @('all', 'any', 'none', 'count')) {
                    $isCriterionForArray = $true
                 } else {
                    $comparisonResult = @{ Passed = $null; Reason = "Ключ '_condition_' в критерии для '$currentEvaluationPath' имеет недопустимое значение '$($condVal | Out-String -Width 50)'. Ожидались 'all', 'any', 'none', 'count'." }
                 }
            }
            
            if ($null -eq $comparisonResult) { # Продолжаем, только если не было ошибки с _condition_
                if ($isCriterionForArray) {
                    Write-Debug "    Тип критерия для '$criterionKey': Массив (_condition_ найден и валиден)"
                    $isDetailsValueACollection = $false
                    if ($null -ne $detailsValue) {
                        if (($detailsValue -is [array]) -or ($detailsValue -is [System.Collections.IList])) {
                            $isDetailsValueACollection = $true
                        }
                    }
                    if (-not $keyExistsInDetails) {
                         $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey', для которого ожидался массив данных, отсутствует в '$Path'." }
                    } elseif (-not $isDetailsValueACollection) {
                        $actualType = if ($null -eq $detailsValue) { '$null' } else { $detailsValue.GetType().FullName }
                        $comparisonResult = @{ Passed = $false; Reason = "Для критерия массива по пути '$currentEvaluationPath' ожидался массив или коллекция (System.Array или System.Collections.IList) в данных, но получен '$actualType'." }
                    } else {
                        $detailsArrayForProcessing = @($detailsValue) 
                        $comparisonResult = Handle-ArrayCriteriaProcessing -DetailsArray $detailsArrayForProcessing -ArrayCriteria $criterionValue -PathPrefix $currentEvaluationPath
                    }
                } elseif (Test-IsOperatorBlock -CriteriaObject $criterionValue) {
                    Write-Debug "    Тип критерия для '$criterionKey': Операторный блок"
                    if (-not $keyExistsInDetails -and -not ($criterionValue.Keys -contains 'exists' -and $criterionValue.exists -eq $false)) {
                        $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey' отсутствует в данных ('$Path') для применения операторного блока." }
                    } else {
                        $comparisonResult = Handle-OperatorBlockProcessing -DetailsValue $detailsValue -OperatorBlock $criterionValue -KeyName $criterionKey -BasePath $Path
                    }
                } else {
                    Write-Debug "    Тип критерия для '$criterionKey': Вложенный объект (рекурсия)"
                    if (-not $keyExistsInDetails) {
                        $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey' из вложенного критерия отсутствует в данных по пути '$Path'."}
                    } elseif ($null -eq $detailsValue -and ($criterionValue.PSObject.Properties.Count -gt 0)) {
                         $comparisonResult = @{ Passed = $false; Reason = "Данные для '$currentEvaluationPath' равны `$null, но вложенный критерий ожидает объект."}
                    } elseif (($detailsValue -is [hashtable] -or $detailsValue -is [System.Management.Automation.PSCustomObject]) -or `
                              ($null -eq $detailsValue -and $criterionValue.PSObject.Properties.Count -eq 0) ) {
                        $comparisonResult = Test-SuccessCriteria -DetailsObject $detailsValue -CriteriaObject $criterionValue -Path $currentEvaluationPath
                    } else {
                        $comparisonResult = @{ Passed = $false; Reason = "Для вложенного критерия по пути '$currentEvaluationPath' ожидался объект (Hashtable/PSCustomObject) в данных, но получен '$($detailsValue.GetType().FullName)'."}
                    }
                }
            } 
        } else {
            Write-Debug "    Тип критерия для '$criterionKey': Простое значение (сравнение '==')"
            if (-not $keyExistsInDetails) {
                $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey' из критерия отсутствует в данных для простого сравнения по пути '$Path'."}
            } else {
                $comparisonResult = Compare-Values -Value $detailsValue -Operator '==' -Threshold $criterionValue
            }
        }

        if ($null -ne $comparisonResult -and $comparisonResult.Passed -ne $true) {
            $finalFailReasonDetail = if (-not [string]::IsNullOrEmpty($comparisonResult.Reason)) { $comparisonResult.Reason } else { "Неизвестная причина." }
            $finalFailReason = "Критерий для '$criterionKey' по пути '$Path' не пройден. Причина: $finalFailReasonDetail"
            Write-Debug "  [Провал TSC] Key=`"$criterionKey`", Path=`"$Path`", CriterionValue=`"$($criterionValue | Out-String -Width 100 | ForEach-Object {$_.Trim()})`", ComparisonPassed=`"$($comparisonResult.Passed)`", Reason=`"$finalFailReason`""
            return @{ Passed = $comparisonResult.Passed; FailReason = $finalFailReason }
        }
        Write-Debug "  [Успех TSC для ключа] Key=`"$criterionKey`", Path=`"$Path`""
    } 

    Write-Debug "--- Test-SuccessCriteria [Выход - Успех для всех ключей] --- Path: `"$Path`""
    return @{ Passed = $true; FailReason = $null } 
}
#endregion


#--------------------------------------------------------------------------
# Экспортируемые функции
#--------------------------------------------------------------------------

#region Функция New-CheckResultObject (Экспортируемая, v1.3.2 - Возвращает Hashtable)
function New-CheckResultObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [bool]$IsAvailable,
        [Parameter(Mandatory = $false)] [nullable[bool]]$CheckSuccess = $null, 
        [Parameter(Mandatory = $false)] $Details = $null,
        [Parameter(Mandatory = $false)] [string]$ErrorMessage = $null
    )
    $processedDetails = $null
    if ($null -ne $Details) {
        if ($Details -is [hashtable]) { 
            $processedDetails = $Details 
        } elseif ($Details -is [System.Management.Automation.PSCustomObject]) {
            $processedDetails = @{}
            $Details.PSObject.Properties | ForEach-Object { $processedDetails[$_.Name] = $_.Value }
        } else { 
            $processedDetails = @{ Value = $Details }
        }
    }

    $finalCheckSuccess = $CheckSuccess 
    if (-not $IsAvailable) {
        $finalCheckSuccess = $null
    }
    
    $finalErrorMessage = $ErrorMessage
    if ([string]::IsNullOrEmpty($finalErrorMessage)) {
        if (-not $IsAvailable) {
            $finalErrorMessage = "Ошибка выполнения проверки (IsAvailable=false)."
        } elseif ($finalCheckSuccess -eq $false) {
            $finalErrorMessage = "Проверка не прошла по критериям (CheckSuccess=false)."
        } elseif ($finalCheckSuccess -eq $null -and $IsAvailable) {
             $finalErrorMessage = "Не удалось оценить критерии успеха (CheckSuccess=null), хотя проверка доступности прошла."
        }
    }
    
    # Возвращаем обычную Hashtable
    $result = @{
        IsAvailable  = $IsAvailable
        CheckSuccess = $finalCheckSuccess
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        Details      = $processedDetails 
        ErrorMessage = $finalErrorMessage
    }

    Write-Verbose ("New-CheckResultObject (v1.3.2 - Hashtable): Создан результат: IsAvailable=$($result.IsAvailable), CheckSuccess=$($result.CheckSuccess), ErrorMessage SET: $(!([string]::IsNullOrEmpty($result.ErrorMessage)))")
    return $result
}
#endregion

#region Функция Invoke-StatusMonitorCheck (Экспортируемая, v1.2.3 - Улучшенная обработка Details)
function Invoke-StatusMonitorCheck {
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Assignment 
    )

    # --- 1. Валидация входного объекта ---
    if ($null -eq $Assignment -or `
        -not ($Assignment -is [System.Management.Automation.PSCustomObject]) -or `
        -not $Assignment.PSObject.Properties.Name.Contains('assignment_id') -or `
        -not $Assignment.PSObject.Properties.Name.Contains('method_name')) {
        Write-Warning "Invoke-StatusMonitorCheck: Передан некорректный или неполный объект задания (ожидался PSCustomObject с assignment_id и method_name)."
        return New-CheckResultObject -IsAvailable $false -ErrorMessage "Некорректный объект задания передан в Invoke-StatusMonitorCheck."
    }

    # --- 2. Извлечение данных из Задания (PS 5.1 compatible) ---
    $assignmentId = $Assignment.assignment_id
    $methodName = $Assignment.method_name
    
    # --- ИСПРАВЛЕНО: Безопасное извлечение для PS 5.1 ---
    $targetIP = $null
    if ($Assignment.PSObject.Properties.Name -contains 'ip_address') {
        $targetIP = $Assignment.ip_address
    }

    $nodeName = "Задание ID $assignmentId" # Значение по умолчанию
    if ($Assignment.PSObject.Properties.Name -contains 'node_name') {
        $tempNodeName = $Assignment.node_name
        if (-not [string]::IsNullOrWhiteSpace($tempNodeName)) {
            $nodeName = $tempNodeName
        }
    }
    # --- КОНЕЦ ИСПРАВЛЕНИЯ ---

    $parameters = @{}
    # --- ИСПРАВЛЕНО: Безопасное извлечение для PS 5.1 ---
    $assignmentParameters = $null
    if ($Assignment.PSObject.Properties.Name -contains 'parameters') {
        $assignmentParameters = $Assignment.parameters
    }
    # --- КОНЕЦ ИСПРАВЛЕНИЯ ---
    if ($null -ne $assignmentParameters) {
        if ($assignmentParameters -is [hashtable]) { $parameters = $assignmentParameters }
        elseif ($assignmentParameters -is [System.Management.Automation.PSCustomObject]) {
            try { $parameters = @{}; $assignmentParameters.PSObject.Properties | ForEach-Object { $parameters[$_.Name] = $_.Value } }
            catch { Write-Warning "[$($assignmentId) | $nodeName] Не удалось преобразовать 'parameters' (PSCustomObject) в Hashtable. Используется пустой объект." }
        } else { Write-Warning "[$($assignmentId) | $nodeName] Поле 'parameters' имеет неожиданный тип '$($assignmentParameters.GetType().FullName)'. Используется пустой объект."}
    }

    $successCriteria = $null 
    # --- ИСПРАВЛЕНО: Безопасное извлечение для PS 5.1 ---
    $assignmentSuccessCriteria = $null
    if ($Assignment.PSObject.Properties.Name -contains 'success_criteria') {
        $assignmentSuccessCriteria = $Assignment.success_criteria
    }
    # --- КОНЕЦ ИСПРАВЛЕНИЯ ---
    if ($null -ne $assignmentSuccessCriteria) {
        if ($assignmentSuccessCriteria -is [hashtable]) { $successCriteria = $assignmentSuccessCriteria }
        elseif ($assignmentSuccessCriteria -is [System.Management.Automation.PSCustomObject]) {
            try { $successCriteria = @{}; $assignmentSuccessCriteria.PSObject.Properties | ForEach-Object { $successCriteria[$_.Name] = $_.Value } }
            catch { Write-Warning "[$($assignmentId) | $nodeName] Не удалось преобразовать 'success_criteria' (PSCustomObject) в Hashtable. Критерии не будут применены." }
        } else { Write-Warning "[$($assignmentId) | $nodeName] Поле 'success_criteria' имеет неожиданный тип '$($assignmentSuccessCriteria.GetType().FullName)'. Критерии не будут применены."}
    }
    
    $targetLogString = if ($targetIP) { $targetIP } else { '[Локально]' }
    Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Запуск метода '$methodName' для цели '$targetLogString'."

    $resultFromCheckScript = $null 
    try {
        $ModuleBase = $MyInvocation.MyCommand.Module.ModuleBase
        if (-not $ModuleBase) { 
            if ($PSScriptRoot) { $ModuleBase = $PSScriptRoot } 
            else { throw "Не удалось определить базовый путь модуля для поиска скриптов Checks/." }
        }
        $ChecksFolder = Join-Path -Path $ModuleBase -ChildPath "Checks"
        $CheckScriptFile = "Check-$($methodName).ps1"
        $CheckScriptPath = Join-Path -Path $ChecksFolder -ChildPath $CheckScriptFile
        Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Поиск скрипта проверки: '$CheckScriptPath'"

        if (-not (Test-Path $CheckScriptPath -PathType Leaf)) {
            $errMsg = "Скрипт проверки '$CheckScriptFile' не найден в '$ChecksFolder'."
            Write-Warning "[$($assignmentId) | $nodeName] $errMsg"
            return New-CheckResultObject -IsAvailable $false -ErrorMessage $errMsg -Details @{ CheckedScriptPath = $CheckScriptPath }
        }
        
        $paramsForCheckScript = @{
            TargetIP        = $targetIP         # Может быть $null, если не Mandatory в Check-*.ps1
            Parameters      = $parameters       
            SuccessCriteria = $successCriteria  
            NodeName        = $nodeName
        }
        Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Запуск скрипта '$CheckScriptFile'..."
        $resultFromCheckScript = & $checkScriptPath @paramsForCheckScript
        
        if ($null -eq $resultFromCheckScript -or -not ($resultFromCheckScript -is [hashtable]) -or -not $resultFromCheckScript.ContainsKey('IsAvailable')) {
            $errMsg = "Скрипт '$CheckScriptFile' вернул некорректный результат или `$null."
            $resultTypeInfo = if ($null -eq $resultFromCheckScript) { '$null' } else { $resultFromCheckScript.GetType().FullName }
            Write-Warning "[$($assignmentId) | $nodeName] $errMsg Тип результата: $resultTypeInfo. Ожидалась Hashtable от New-CheckResultObject."
            $resultFromCheckScript = New-CheckResultObject -IsAvailable $false -ErrorMessage $errMsg -Details @{ ScriptOutput = ($resultFromCheckScript | Out-String -Width 200) }
        } else {
            Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Скрипт '$CheckScriptFile' вернул корректный формат результата."
        }

    } catch {
        $critErrMsg = "Критическая ошибка при выполнении метода '$methodName' для '$nodeName': $($_.Exception.Message)"
        Write-Warning "[$($assignmentId) | $nodeName] $critErrMsg"
        $errorDetails = @{ ErrorRecord = $_.ToString(); StackTrace = $_.ScriptStackTrace }
        if ($CheckScriptPath) { $errorDetails.CheckedScriptPath = $CheckScriptPath }
        $resultFromCheckScript = New-CheckResultObject -IsAvailable $false -ErrorMessage $critErrMsg -Details $errorDetails
    }
    
    Write-Host "DEBUG (Invoke-Check): --- Начало отладки Details в Invoke-StatusMonitorCheck (перед дополнением) ---" -ForegroundColor Cyan
    $detailsFromCheck = $null
    if ($resultFromCheckScript -is [hashtable] -and $resultFromCheckScript.ContainsKey('Details')) {
        $detailsFromCheck = $resultFromCheckScript['Details']
        Write-Host "DEBUG (Invoke-Check): Получен Details из скрипта проверки. Тип: $($detailsFromCheck.GetType().FullName)" -ForegroundColor Cyan
        if ($detailsFromCheck -is [hashtable]) {
            Write-Host "DEBUG (Invoke-Check): Ключи в Details от скрипта: $($detailsFromCheck.Keys -join ', ')" -ForegroundColor Cyan
            Write-Host "DEBUG (Invoke-Check): Содержимое Details от скрипта (JSON): $($detailsFromCheck | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue)" -ForegroundColor DarkCyan
        } else {
            Write-Host "DEBUG (Invoke-Check): Details от скрипта проверки НЕ является Hashtable (это НЕ ожидалось, т.к. New-CheckResultObject v1.3.2+ возвращает Hashtable)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "DEBUG (Invoke-Check): Ключ 'Details' в результате от скрипта проверки НЕ НАЙДЕН или результат не Hashtable (ЭТО ОШИБКА ЛОГИКИ в New-CheckResultObject или выше)." -ForegroundColor Red
    }

    if ($null -eq $detailsFromCheck -or -not ($detailsFromCheck -is [hashtable])) {
        Write-Host "DEBUG (Invoke-Check): Инициализация resultFromCheckScript['Details'] новой пустой Hashtable (т.к. он был $null или не Hashtable)." -ForegroundColor Yellow
        $resultFromCheckScript['Details'] = @{} 
    } 
    
    $resultFromCheckScript['Details']['execution_target'] = $env:COMPUTERNAME
    $resultFromCheckScript['Details']['execution_mode'] = 'local_agent'
    $resultFromCheckScript['Details']['check_target_ip'] = $targetIP 

    Write-Host "DEBUG (Invoke-Check): Содержимое resultFromCheckScript['Details'] ПОСЛЕ дополнения (JSON): $($resultFromCheckScript['Details'] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue)" -ForegroundColor DarkCyan
    Write-Host "DEBUG (Invoke-Check): --- Конец отладки Details в Invoke-StatusMonitorCheck (после дополнения) ---" -ForegroundColor Cyan

    $isAvailableStr = $resultFromCheckScript['IsAvailable']
    $checkSuccessStrForLog = if ($null -eq $resultFromCheckScript['CheckSuccess']) { '[null]' } else { $resultFromCheckScript['CheckSuccess'] }
    Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Завершение. IsAvailable: $isAvailableStr, CheckSuccess: $checkSuccessStrForLog"
    
    return $resultFromCheckScript
}
#endregion

# --- Экспорт функций ---
Export-ModuleMember -Function Invoke-StatusMonitorCheck, New-CheckResultObject, Test-SuccessCriteria, Compare-Values