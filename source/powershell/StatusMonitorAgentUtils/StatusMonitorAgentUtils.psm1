# F:\status\source\powershell\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psm1
# Версия с полным рефакторингом Test-SuccessCriteria и исправлениями

#--------------------------------------------------------------------------
# Приватные функции (не экспортируются модулем)
#--------------------------------------------------------------------------

#region Функция Compare-Values (v1.1.1 - Улучшено логирование)
# Вспомогательная функция для сравнения значений с операторами
# Возвращает: @{ Passed = $true/$false/$null; Reason = "..."/$null }
# ($null для Passed означает ошибку сравнения/типа)
function Compare-Values {
    param(
        $Value,         # Фактическое значение из Details
        $Operator,      # Оператор сравнения (строка: '>', 'contains', 'matches'...)
        $Threshold      # Пороговое значение из Criteria
    )
    Write-Debug "Compare-Values: Value=`"$($Value | Out-String -Width 100 | ForEach-Object {$_.Trim()})`", Operator=`"$Operator`", Threshold=`"$($Threshold | Out-String -Width 100 | ForEach-Object {$_.Trim()})`""
    $result = @{ Passed = $true; Reason = '' }
    $opLower = $Operator.ToLower()

    try {
        # --- Проверка существования ---
        if ($opLower -eq 'exists') {
            if (($Threshold -eq $true -and $Value -eq $null) -or `
                ($Threshold -eq $false -and $Value -ne $null)) {
                $result.Passed = $false
                $result.Reason = "Проверка существования (exists=$Threshold) не пройдена для значения (Value is `$(if($Value -eq $null){'null'}else{'not null'}))."
            }
            # Для 'exists', если условие выполнено, Reason остается пустым.
            return $result
        }

        # Если Value - $null, а оператор не 'exists', то большинство сравнений не имеют смысла или должны провалиться.
        # Исключение - сравнение с $null ( $null -eq $null -> true)
        if ($Value -eq $null -and $opLower -ne '==' -and $opLower -ne '!=') {
             $result.Passed = $false # или $null, если считать это ошибкой типа для числовых операторов
             $result.Reason = "Невозможно применить оператор '$Operator' к значению `$null (если только оператор не '==' или '!=' для сравнения с `$null)."
             # Для строгости можно вернуть Passed = $null, если оператор числовой, а Value = $null
             if ($opLower -in @('>', '>=', '<', '<=')) { $result.Passed = $null }
             return $result
        }

        # --- Универсальное сравнение для == и != ---
        if ($opLower -eq '==') {
             if (-not ($Value -eq $Threshold)) { # PowerShell сам обработает типы, насколько возможно
                 $result.Passed = $false; $result.Reason = "'$Value' не равно '$Threshold'"
             }
        }
        elseif ($opLower -eq '!=') {
             if (-not ($Value -ne $Threshold)) {
                 $result.Passed = $false; $result.Reason = "'$Value' равно '$Threshold'"
             }
        }
        # --- Числовые сравнения ---
        elseif ($opLower -in @('>', '>=', '<', '<=')) {
            $numValue = 0.0; $numThreshold = 0.0
            $culture = [System.Globalization.CultureInfo]::InvariantCulture # Используем InvariantCulture для консистентности
            
            # Пытаемся преобразовать $Value в число
            $valueIsNumber = $false
            if ($Value -is [ValueType] -and $Value -isnot [bool] -and $Value -isnot [datetime]) { # Уже числовой тип (кроме bool/datetime)
                try { $numValue = [double]$Value; $valueIsNumber = $true } catch {}
            }
            if (-not $valueIsNumber) {
                $valueIsNumber = [double]::TryParse($Value, [System.Globalization.NumberStyles]::Any, $culture, [ref]$numValue)
            }

            # Пытаемся преобразовать $Threshold в число
            $thresholdIsNumber = $false
            if ($Threshold -is [ValueType] -and $Threshold -isnot [bool] -and $Threshold -isnot [datetime]) {
                try { $numThreshold = [double]$Threshold; $thresholdIsNumber = $true } catch {}
            }
            if (-not $thresholdIsNumber) {
                $thresholdIsNumber = [double]::TryParse($Threshold, [System.Globalization.NumberStyles]::Any, $culture, [ref]$numThreshold)
            }

            if (-not $valueIsNumber -or -not $thresholdIsNumber) {
                $result.Passed = $null # Ошибка типа
                $reasonParts = @()
                if (-not $valueIsNumber) { $reasonParts += "Не удалось преобразовать значение '$Value' в число." }
                if (-not $thresholdIsNumber) { $reasonParts += "Не удалось преобразовать порог '$Threshold' в число." }
                $result.Reason = "Ошибка числового сравнения '$opLower': $($reasonParts -join ' ')"
                return $result
            }
            # Выполняем числовое сравнение
            switch ($opLower) {
                '>'  { if (-not ($numValue -gt $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' (`$numValue) не больше (>) '$Threshold' (`$numThreshold)" } }
                '>=' { if (-not ($numValue -ge $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' (`$numValue) не больше или равно (>=) '$Threshold' (`$numThreshold)" } }
                '<'  { if (-not ($numValue -lt $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' (`$numValue) не меньше (<) '$Threshold' (`$numThreshold)" } }
                '<=' { if (-not ($numValue -le $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' (`$numValue) не меньше или равно (<=) '$Threshold' (`$numThreshold)" } }
            }
        }
        # --- Строковые сравнения ---
        elseif ($opLower -in @('contains', 'not_contains', 'matches', 'not_matches')) {
            # Приводим оба операнда к строке для этих операторов
            $strValue = "$Value"
            $strThreshold = "$Threshold"

            switch ($opLower) {
                'contains'     { if ($strValue -notlike "*$strThreshold*") { $result.Passed = $false; $result.Reason = "'$strValue' не содержит '$strThreshold'" } }
                'not_contains' { if ($strValue -like "*$strThreshold*")    { $result.Passed = $false; $result.Reason = "'$strValue' содержит '$strThreshold'" } }
                'matches'      { if ($strValue -notmatch $strThreshold)    { $result.Passed = $false; $result.Reason = "'$strValue' не соответствует регулярному выражению '$strThreshold'" } }
                'not_matches'  { if ($strValue -match $strThreshold)       { $result.Passed = $false; $result.Reason = "'$strValue' соответствует регулярному выражению '$strThreshold'" } }
            }
        } else {
            # Неизвестный оператор
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

#region Вспомогательная функция Test-IsOperatorBlock (v1.0.1 - Исправлено получение ключей для Hashtable)
# Проверяет, является ли объект блоком операторов (все его ключи - известные операторы сравнения)
function Test-IsOperatorBlock {
    param (
        [Parameter(Mandatory=$true)] $CriteriaObject # Объект для проверки
    )
    # Сразу возвращаем false, если это не хэш-таблица или PSCustomObject
    if (-not ($CriteriaObject -is [hashtable] -or $CriteriaObject -is [System.Management.Automation.PSCustomObject])) {
        return $false
    }

    # Список допустимых операторов (в нижнем регистре)
    $validOperators = @('>', '>=', '<', '<=', '==', '!=', 'contains', 'not_contains', 'matches', 'not_matches', 'exists')
    
    $keysInCriteria = $null
    if ($CriteriaObject -is [hashtable]) {
        $keysInCriteria = $CriteriaObject.Keys
    } elseif ($CriteriaObject -is [System.Management.Automation.PSCustomObject]) {
        # Для PSCustomObject свойства могут быть получены так, или через GetEnumerator()
        $keysInCriteria = @($CriteriaObject.PSObject.Properties.Name)
    } else {
        return $false # Неожиданный тип, хотя проверка выше должна была это отсечь
    }

    # Если ключей нет, это не операторный блок
    if ($keysInCriteria.Count -eq 0) {
        return $false
    }

    # Проверяем каждый ключ
    foreach ($key in $keysInCriteria) {
        # Приводим ключ к строке и нижнему регистру перед проверкой
        if ($validOperators -notcontains $key.ToString().ToLower()) {
            return $false # Найден ключ, не являющийся допустимым оператором
        }
    }
    return $true # Все ключи являются допустимыми операторами
}
#endregion

#region Вспомогательная функция Handle-OperatorBlockProcessing (v1.0)
# Обрабатывает операторный блок критериев для одного значения из Details
function Handle-OperatorBlockProcessing {
    param(
        [Parameter(Mandatory=$true)] # Убрали AllowNull=$true
        $DetailsValue,    # Значение из Details, которое проверяется. МОЖЕТ БЫТЬ $null.
        [Parameter(Mandatory=$true)]
        $OperatorBlock,   # Hashtable/PSCustomObject, где ключи - операторы, значения - пороги
        [Parameter(Mandatory=$true)]
        [string]$KeyName, # Имя ключа из Details, для которого этот операторный блок
        [Parameter(Mandatory=$true)]
        [string]$BasePath   # Путь в структуре Details до этого KeyName
    )
    Write-Debug "Handle-OperatorBlockProcessing: Path=`"$BasePath.$KeyName`", DetailsValue=`"$($DetailsValue | Out-String -Width 100 | ForEach-Object {$_.Trim()})`""
    
    # Итерируем по каждому оператору в блоке
    foreach ($operatorEntry in $OperatorBlock.GetEnumerator()) {
        $operator = $operatorEntry.Name
        $threshold = $operatorEntry.Value
        
        # Выполняем сравнение
        $comparisonResult = Compare-Values -Value $DetailsValue -Operator $operator -Threshold $threshold
        
        # Если хоть одно сравнение в операторном блоке не прошло (или вернуло ошибку),
        # весь операторный блок считается не пройденным.
        if ($comparisonResult.Passed -ne $true) {
            return @{ Passed = $comparisonResult.Passed; Reason = "Оператор '$operator' для ключа '$KeyName' не пройден. $($comparisonResult.Reason)" }
        }
    }
    # Все операторы в блоке успешно пройдены
    return @{ Passed = $true; Reason = $null }
}
#endregion

#region Вспомогательная функция Handle-ArrayCriteriaProcessing (v1.0.1 - Улучшена читаемость и обработка пустого filteredArray)
# Обрабатывает критерии для массива (_condition_, _where_, _criteria_, _count_)
function Handle-ArrayCriteriaProcessing {
    param(
        [Parameter(Mandatory=$true)]
        $DetailsArray,    # Массив данных из Details, к которому применяются критерии
        [Parameter(Mandatory=$true)]
        [hashtable]$ArrayCriteria, # Критерий для массива (содержит _condition_, etc.)
        [Parameter(Mandatory=$true)]
        [string]$PathPrefix # Текущий путь в структуре Details до этого массива
    )
    Write-Debug "Handle-ArrayCriteriaProcessing: Path=`"$PathPrefix`", Condition=`"$($ArrayCriteria._condition_)`", ArrayCriteria Keys: $($ArrayCriteria.Keys -join ', ')"
    
    $result = @{ Passed = $null; FailReason = $null } # Инициализация результата

    # 1. Валидация обязательных ключей в ArrayCriteria
    $condition = $ArrayCriteria._condition_
    $whereClause = $ArrayCriteria._where_          # Может быть $null
    $criteriaForItems = $ArrayCriteria._criteria_  # Может быть $null (для _condition_ 'none' или 'count')
    $countCriteria = $ArrayCriteria._count_       # Может быть $null (если _condition_ не 'count')

    if (-not $condition -or $condition.ToString().ToLower() -notin @('all', 'any', 'none', 'count')) {
        $result.Passed = $null
        $result.FailReason = "Отсутствует или неверный ключ '_condition_' в критерии для массива по пути '$PathPrefix'. Допустимые значения: 'all', 'any', 'none', 'count'."
        return $result
    }
    $conditionLower = $condition.ToString().ToLower()

    # Дополнительная валидация для специфичных условий
    if ($conditionLower -in @('all', 'any') -and $null -eq $criteriaForItems) {
        $result.Passed = $null
        $result.FailReason = "Для _condition_ '$condition' в критерии массива по пути '$PathPrefix' требуется непустой ключ '_criteria_'."
        return $result
    }
    if ($conditionLower -eq 'count' -and ($null -eq $countCriteria -or -not (Test-IsOperatorBlock -CriteriaObject $countCriteria))) {
        $result.Passed = $null
        $result.FailReason = "Для _condition_ 'count' в критерии массива по пути '$PathPrefix' требуется ключ '_count_', содержащий операторный блок."
        return $result
    }

    # 2. Фильтрация массива $DetailsArray с использованием _where_ (если он есть)
    $filteredArray = $DetailsArray # По умолчанию работаем со всем массивом
    if ($null -ne $whereClause) {
        Write-Verbose "Фильтрация массива по пути '$PathPrefix' с использованием _where_..."
        $tempFiltered = [System.Collections.Generic.List[object]]::new()
        $itemIndex = -1
        foreach ($item in $DetailsArray) {
            $itemIndex++
            $itemPathForWhere = "$PathPrefix" + "[$itemIndex_where]" # Уникальный путь для отладки _where_
            
            # РЕКУРСИВНЫЙ ВЫЗОВ Test-SuccessCriteria для проверки условия _where_ на каждом элементе
            $filterCheckResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $whereClause -Path $itemPathForWhere
            
            if ($filterCheckResult.Passed -eq $true) {
                $tempFiltered.Add($item) # Элемент соответствует _where_
            } elseif ($filterCheckResult.Passed -eq $null) {
                # Ошибка при проверке _where_ для элемента - вся проверка критерия массива считается ошибочной
                $result.Passed = $null
                $result.FailReason = "Ошибка при фильтрации (проверке _where_) элемента массива [$itemIndex] по пути '$itemPathForWhere': $($filterCheckResult.FailReason)"
                return $result
            }
            # Если $filterCheckResult.Passed -eq $false, элемент просто не добавляется в отфильтрованный список
        }
        $filteredArray = $tempFiltered
        Write-Verbose "Массив по пути '$PathPrefix' отфильтрован с помощью _where_. Исходных: $($DetailsArray.Count), Отфильтрованных: $($filteredArray.Count)."
    }

    # 3. Применение основного условия (_condition_) к (отфильтрованному) массиву
    $finalPassedStatus = $null # Итоговый результат ($true, $false, или $null при ошибке)

    switch ($conditionLower) {
        'all' {
            if ($filteredArray.Count -eq 0) {
                # Если отфильтрованный массив пуст, 'all' считается выполненным
                # (нет элементов, которые бы НЕ соответствовали _criteria_).
                $finalPassedStatus = $true
            } else {
                 $allPassedFlag = $true # Предполагаем, что все пройдут
                 $itemIndex = -1
                 foreach ($item in $filteredArray) {
                     $itemIndex++
                     $itemPathForCriteria = "$PathPrefix" + (if($null -ne $whereClause){"[filtered:$itemIndex]"}else{"[$itemIndex]"})
                     # РЕКУРСИВНЫЙ ВЫЗОВ Test-SuccessCriteria для проверки _criteria_ на каждом элементе
                     $itemProcessingResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteriaForItems -Path $itemPathForCriteria
                     if ($itemProcessingResult.Passed -ne $true) {
                         $allPassedFlag = $itemProcessingResult.Passed # Может быть $false или $null
                         $result.FailReason = "Условие 'all' не выполнено для элемента по пути '$itemPathForCriteria'. Причина: $($itemProcessingResult.FailReason)"
                         break # Прерываем цикл, так как 'all' уже не выполнено
                     }
                 }
                 $finalPassedStatus = $allPassedFlag
            }
        } # Конец 'all'
        'any' {
             $anyPassedFlag = $false # Предполагаем, что ни один не пройдет
             if ($filteredArray.Count -gt 0) {
                 $itemIndex = -1
                 foreach ($item in $filteredArray) {
                     $itemIndex++
                     $itemPathForCriteria = "$PathPrefix" + (if($null -ne $whereClause){"[filtered:$itemIndex]"}else{"[$itemIndex]"})
                     $itemProcessingResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteriaForItems -Path $itemPathForCriteria
                     if ($itemProcessingResult.Passed -eq $true) {
                         $anyPassedFlag = $true
                         $result.FailReason = $null # Сбрасываем причину, т.к. 'any' выполнен
                         break # Нашли один соответствующий, достаточно
                     } elseif ($itemProcessingResult.Passed -eq $null) {
                         $anyPassedFlag = $null # Ошибка при проверке элемента
                         $result.FailReason = "Ошибка проверки элемента по пути '$itemPathForCriteria' для условия 'any': $($itemProcessingResult.FailReason)"
                         break # Прерываем из-за ошибки
                     }
                 }
             }
             # Если цикл завершен, и $anyPassedFlag все еще $false (и не $null), значит ни один не подошел
             if ($anyPassedFlag -eq $false -and $result.FailReason -eq $null) {
                 $result.FailReason = "Условие 'any': ни один элемент в (отфильтрованном) массиве по пути '$PathPrefix' не соответствует указанным _criteria_."
             }
             $finalPassedStatus = $anyPassedFlag
        } # Конец 'any'
        'none' {
             # 'none' означает, что НИ ОДИН элемент (в $filteredArray) не должен соответствовать $criteriaForItems.
             # Если $criteriaForItems не указан (что не должно быть по валидации выше, но для полноты),
             # то 'none' означает, что $filteredArray должен быть пустым.
             $nonePassedFlag = $true # Предполагаем, что 'none' выполнено
             if ($filteredArray.Count -gt 0) {
                 if ($null -eq $criteriaForItems) { # Этот случай не должен происходить из-за валидации выше
                      $nonePassedFlag = $false
                      $result.FailReason = "Условие 'none' без _criteria_: в (отфильтрованном) массиве по пути '$PathPrefix' есть элементы ($($filteredArray.Count) шт.), а ожидалось 0."
                 } else {
                     $itemIndex = -1
                     foreach ($item in $filteredArray) {
                         $itemIndex++
                         $itemPathForCriteria = "$PathPrefix" + (if($null -ne $whereClause){"[filtered:$itemIndex]"}else{"[$itemIndex]"})
                         $itemProcessingResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteriaForItems -Path $itemPathForCriteria
                         if ($itemProcessingResult.Passed -eq $true) { # Нашли элемент, СООТВЕТСТВУЮЩИЙ _criteria_
                             $nonePassedFlag = $false
                             $result.FailReason = "Условие 'none': элемент по пути '$itemPathForCriteria' СООТВЕТСТВУЕТ _criteria_, а не должен был."
                             break
                         } elseif ($itemProcessingResult.Passed -eq $null) {
                             $nonePassedFlag = $null # Ошибка
                             $result.FailReason = "Ошибка проверки элемента по пути '$itemPathForCriteria' для условия 'none': $($itemProcessingResult.FailReason)"
                             break
                         }
                     }
                 }
             }
             # Если $filteredArray пуст, то 'none' всегда выполняется.
             $finalPassedStatus = $nonePassedFlag
        } # Конец 'none'
        'count' {
            $actualItemCount = $filteredArray.Count
            Write-Verbose "Проверка количества элементов ($actualItemCount) по пути '$PathPrefix' для условия '_count_..."
            # Для _count_ используем Handle-OperatorBlockProcessing, так как $countCriteria это операторный блок
            $countCheckResult = Handle-OperatorBlockProcessing -DetailsValue $actualItemCount -OperatorBlock $countCriteria -KeyName "_count_" -BasePath $PathPrefix
            $finalPassedStatus = $countCheckResult.Passed
            if ($finalPassedStatus -ne $true) {
                $result.FailReason = "Критерий количества ('count') элементов по пути '$PathPrefix' не пройден. $($countCheckResult.Reason)"
            }
        } # Конец 'count'
    } # Конец switch ($conditionLower)

    $result.Passed = $finalPassedStatus
    # FailReason уже установлен внутри switch, если что-то пошло не так
    return $result
}
#endregion

#region Основная рефакторенная функция Test-SuccessCriteria (v2.0.1 - Исправлен доступ к свойствам Hashtable)
# Рекурсивно сравнивает объект Details с объектом Criteria.
# Возвращает: @{ Passed = $true/$false/$null; FailReason = "..."/$null }
function Test-SuccessCriteria {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $DetailsObject,
        [Parameter(Mandatory=$true)] $CriteriaObject,
        [string]$Path = '$Details' # Текущий путь в объекте Details для логирования и сообщений об ошибках
    )

    Write-Debug "--- Test-SuccessCriteria [Вход] --- Path: `"$Path`", Details Type: `"$($DetailsObject.GetType().Name)`", Criteria Type: `"$($CriteriaObject.GetType().Name)`""

    # 1. Валидация CriteriaObject: должен быть Hashtable или PSCustomObject
    if (-not ($CriteriaObject -is [hashtable] -or $CriteriaObject -is [System.Management.Automation.PSCustomObject])) {
        return @{ Passed = $null; FailReason = "Объект критерия по пути '$Path' не является Hashtable или PSCustomObject (получен тип: $($CriteriaObject.GetType().FullName))." }
    }

    # 2. Итерация по ключам (критериям) в CriteriaObject
    foreach ($criterionEntry in $CriteriaObject.GetEnumerator()) {
        $criterionKey = $criterionEntry.Name
        $criterionValue = $criterionEntry.Value # Значение критерия (может быть простым, операторным блоком, вложенным объектом или критерием для массива)
        $currentEvaluationPath = "$Path.$criterionKey" # Путь к текущему проверяемому элементу

        Write-Debug "  [Цикл TSC] Path=`"$Path`", Key=`"$criterionKey`", CriteriaValue Type=`"$($criterionValue.GetType().FullName)`""

        # Пропускаем служебные ключи массива (_condition_, _where_, etc.) на этом уровне,
        # они обрабатываются внутри Handle-ArrayCriteriaProcessing.
        if ($criterionKey -in @('_condition_', '_where_', '_criteria_', '_count_') -and -not ($Path -match '\[.+\]$')) { # Пропускаем, если не внутри массива
            Write-Debug "    Пропуск служебного ключа массива '$criterionKey' на уровне объекта '$Path'."
            continue
        }

        # 3. Получение соответствующего значения из DetailsObject по ключу $criterionKey
        $detailsValue = $null       # Значение из DetailsObject
        $keyExistsInDetails = $false  # Флаг, найден ли ключ в DetailsObject
        $propertyAccessError = $null  # Ошибка при доступе к свойству

        if ($null -ne $DetailsObject) {
            if ($DetailsObject -is [hashtable]) {
                if ($DetailsObject.ContainsKey($criterionKey)) {
                    try { $detailsValue = $DetailsObject[$criterionKey]; $keyExistsInDetails = $true }
                    catch { $propertyAccessError = "Исключение при доступе к ключу '$criterionKey' в Hashtable '$Path': $($_.Exception.Message)" }
                }
            } elseif ($DetailsObject -is [System.Management.Automation.PSCustomObject]) {
                # Для PSCustomObject, .PSObject.Properties.Name может быть медленным в цикле.
                # Проще проверить через try-catch или прямой доступ, если ключ точно строка.
                $propInfo = $DetailsObject.PSObject.Properties[$criterionKey]
                if ($null -ne $propInfo) {
                    try { $detailsValue = $propInfo.Value; $keyExistsInDetails = $true }
                    catch { $propertyAccessError = "Исключение при доступе к свойству '$criterionKey' в PSCustomObject '$Path': $($_.Exception.Message)" }
                }
            } elseif ($DetailsObject -is [array] -and $criterionKey -match '^\d+$' -and [int]::TryParse($criterionKey, [ref]$null)) {
                # Доступ по индексу к массиву (если DetailsObject - массив, а ключ - числовой индекс)
                try {
                    $idx = [int]$criterionKey
                    if ($idx -ge 0 -and $idx -lt $DetailsObject.Count) {
                        $detailsValue = $DetailsObject[$idx]; $keyExistsInDetails = $true
                    }
                } catch { $propertyAccessError = "Исключение при доступе по индексу '$criterionKey' к массиву '$Path': $($_.Exception.Message)" }
            }
            # Если $DetailsObject другого типа, $keyExistsInDetails останется false
        }

        if ($null -ne $propertyAccessError) {
            Write-Debug "  [Ошибка доступа к свойству TSC] Path=`"$Path`", Key=`"$criterionKey`", Error=`"$propertyAccessError`""
            return @{ Passed = $null; FailReason = $propertyAccessError }
        }
        
        Write-Debug "    DetailsValue для '$criterionKey' (существует: $keyExistsInDetails): `"$($detailsValue | Out-String -Width 100 | ForEach-Object {$_.Trim()})`""

        # 4. Определение типа критерия ($criterionValue) и его обработка
        $comparisonResult = $null # Результат для текущего criterionKey
        $isCriterionValueComplex = $criterionValue -is [hashtable] -or $criterionValue -is [System.Management.Automation.PSCustomObject]

        if ($isCriterionValueComplex) {
            # --- СЛОЖНЫЙ КРИТЕРИЙ (объект) ---
            if ($criterionValue.PSObject.Properties.Name -contains '_condition_') {
                # --- A. Критерий для массива ---
                Write-Debug "    Тип критерия для '$criterionKey': Массив (_condition_ найден)"
                if (-not $keyExistsInDetails) {
                    $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey', для которого ожидался массив данных, отсутствует в '$Path'." }
                } elseif (-not ($detailsValue -is [array])) {
                    $comparisonResult = @{ Passed = $false; Reason = "Для критерия массива по пути '$currentEvaluationPath' ожидался массив в данных, но получен '$($detailsValue.GetType().FullName)'." }
                } else {
                    $comparisonResult = Handle-ArrayCriteriaProcessing -DetailsArray $detailsValue -ArrayCriteria $criterionValue -PathPrefix $currentEvaluationPath
                }
            } elseif (Test-IsOperatorBlock -CriteriaObject $criterionValue) {
                # --- B. Операторный блок ---
                Write-Debug "    Тип критерия для '$criterionKey': Операторный блок"
                if (-not $keyExistsInDetails -and -not ($criterionValue.Keys -contains 'exists' -and $criterionValue.exists -eq $false)) {
                    # Если ключа нет в данных, И это не проверка на "exists = $false", то это провал для операторного блока.
                    # Проверка "exists = $true" будет обработана в Handle-OperatorBlockProcessing, получив $null как $detailsValue.
                    $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey' отсутствует в данных ('$Path') для применения операторного блока." }
                } else {
                     # Передаем $detailsValue (может быть $null, если ключ не найден, но есть 'exists')
                    $comparisonResult = Handle-OperatorBlockProcessing -DetailsValue $detailsValue -OperatorBlock $criterionValue -KeyName $criterionKey -BasePath $Path
                }
            } else {
                # --- C. Вложенный объект критерия (РЕКУРСИЯ) ---
                Write-Debug "    Тип критерия для '$criterionKey': Вложенный объект (рекурсия)"
                if (-not $keyExistsInDetails) {
                    $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey' из вложенного критерия отсутствует в данных по пути '$Path'."}
                } elseif ($null -eq $detailsValue -and ($criterionValue.PSObject.Properties.Count -gt 0)) {
                     # Если в данных null, а критерий ожидает непустой вложенный объект
                     $comparisonResult = @{ Passed = $false; Reason = "Данные для '$currentEvaluationPath' равны `$null, но вложенный критерий ожидает объект."}
                } elseif (($detailsValue -is [hashtable] -or $detailsValue -is [System.Management.Automation.PSCustomObject]) -or ($null -eq $detailsValue -and $criterionValue.PSObject.Properties.Count -eq 0) ) {
                    # Рекурсивный вызов для вложенной структуры или для случая { ключ = @{} } и в данных ключ = $null (считаем успехом, если во вложенном критерии нет условий)
                    $comparisonResult = Test-SuccessCriteria -DetailsObject $detailsValue -CriteriaObject $criterionValue -Path $currentEvaluationPath
                } else {
                    # Если в Details не объект, а критерий ожидает вложенный объект
                    $comparisonResult = @{ Passed = $false; Reason = "Для вложенного критерия по пути '$currentEvaluationPath' ожидался объект (Hashtable/PSCustomObject) в данных, но получен '$($detailsValue.GetType().FullName)'."}
                }
            }
        } else {
            # --- D. Простое сравнение значения (эквивалентно оператору '==') ---
            Write-Debug "    Тип критерия для '$criterionKey': Простое значение (сравнение '==')"
            if (-not $keyExistsInDetails) {
                $comparisonResult = @{ Passed = $false; Reason = "Ключ '$criterionKey' из критерия отсутствует в данных для простого сравнения по пути '$Path'."}
            } else {
                $comparisonResult = Compare-Values -Value $detailsValue -Operator '==' -Threshold $criterionValue
            }
        }

        # 5. Анализ результата сравнения для текущего ключа $criterionKey
        if ($null -ne $comparisonResult -and $comparisonResult.Passed -ne $true) {
            # Если текущий критерий не пройден ($false) или вызвал ошибку ($null), формируем сообщение и выходим
            $finalFailReasonDetail = if (-not [string]::IsNullOrEmpty($comparisonResult.Reason)) { $comparisonResult.Reason } else { "Неизвестная причина." }
            $finalFailReason = "Критерий для '$criterionKey' по пути '$Path' не пройден. Причина: $finalFailReasonDetail"
            
            Write-Debug "  [Провал TSC] Key=`"$criterionKey`", Path=`"$Path`", CriterionValue=`"$($criterionValue | Out-String -Width 100 | ForEach-Object {$_.Trim()})`", ComparisonPassed=`"$($comparisonResult.Passed)`", Reason=`"$finalFailReason`""
            return @{ Passed = $comparisonResult.Passed; FailReason = $finalFailReason }
        }
        Write-Debug "  [Успех TSC для ключа] Key=`"$criterionKey`", Path=`"$Path`""
    } # Конец foreach ($criterionEntry in $CriteriaObject.GetEnumerator())

    Write-Debug "--- Test-SuccessCriteria [Выход - Успех для всех ключей] --- Path: `"$Path`""
    return @{ Passed = $true; FailReason = $null } # Все критерии на этом уровне (и рекурсивно) пройдены
}
#endregion


#--------------------------------------------------------------------------
# Экспортируемые функции
#--------------------------------------------------------------------------

#region Функция New-CheckResultObject (Экспортируемая, v1.3.1 - Предложенная)
# Создает стандартизированный объект результата проверки (хэш-таблицу).
function New-CheckResultObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [bool]$IsAvailable,
        [Parameter(Mandatory = $false)] [nullable[bool]]$CheckSuccess = $null, # Позволяем передавать $null
        [Parameter(Mandatory = $false)] $Details = $null,
        [Parameter(Mandatory = $false)] [string]$ErrorMessage = $null
    )
    $processedDetails = $null
    if ($null -ne $Details) {
        if ($Details -is [hashtable]) { $processedDetails = $Details }
        # Если это PSCustomObject, преобразуем в Hashtable для единообразия и возможности модификации в Invoke-StatusMonitorCheck
        elseif ($Details -is [System.Management.Automation.PSCustomObject]) {
            $processedDetails = @{}
            $Details.PSObject.Properties | ForEach-Object { $processedDetails[$_.Name] = $_.Value }
        } else { # Для других типов просто оборачиваем
            $processedDetails = @{ Value = $Details }
        }
    }

    $finalCheckSuccess = $CheckSuccess # Изначально CheckSuccess равен тому, что передали

    if (-not $IsAvailable) {
        # Если проверка недоступна, CheckSuccess всегда $null (неприменимо)
        $finalCheckSuccess = $null
    }
    # Если $IsAvailable = $true, то $finalCheckSuccess остается тем, что передали ($true, $false, или $null при ошибке критерия)
    # Скрипты Check-*.ps1 должны сами устанавливать $checkSuccess = $true, если критерии не заданы и проверка прошла.

    # Формирование ErrorMessage, если он пуст и есть основания
    $finalErrorMessage = $ErrorMessage
    if ([string]::IsNullOrEmpty($finalErrorMessage)) {
        if (-not $IsAvailable) {
            $finalErrorMessage = "Ошибка выполнения проверки (IsAvailable=false)."
        } elseif ($finalCheckSuccess -eq $false) {
            # Это сообщение может быть избыточным, если Check-*.ps1 уже установил ErrorMessage на основе FailReason
            # Но как fallback - полезно.
            $finalErrorMessage = "Проверка не прошла по критериям (CheckSuccess=false)."
        } elseif ($finalCheckSuccess -eq $null -and $IsAvailable) {
             $finalErrorMessage = "Не удалось оценить критерии успеха (CheckSuccess=null), хотя проверка доступности прошла."
        }
    }
    
    $result = @{
        IsAvailable  = $IsAvailable
        CheckSuccess = $finalCheckSuccess # Используем переменную из вашей последней версии
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        Details      = $processedDetails 
        ErrorMessage = $finalErrorMessage # Используем переменную из вашей последней версии
    }

    Write-Verbose ("New-CheckResultObject (v1.3.2 - Hashtable): Создан результат: IsAvailable=$($result.IsAvailable), CheckSuccess=$($result.CheckSuccess), ErrorMessage SET: $(!([string]::IsNullOrEmpty($result.ErrorMessage)))")
    return $result # Теперь это System.Collections.Hashtable
}
#endregion

#region Функция Invoke-StatusMonitorCheck (Экспортируемая, v1.2.2 - Улучшенная обработка Details)
# Выполняет проверку мониторинга согласно заданию.
function Invoke-StatusMonitorCheck {
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Assignment # Ожидаем PSCustomObject от агента
    )

    # --- 1. Валидация входного объекта ---
    if ($null -eq $Assignment -or `
        -not ($Assignment -is [System.Management.Automation.PSCustomObject]) -or `
        -not $Assignment.PSObject.Properties.Name.Contains('assignment_id') -or `
        -not $Assignment.PSObject.Properties.Name.Contains('method_name')) {
        Write-Warning "Invoke-StatusMonitorCheck: Передан некорректный или неполный объект задания (ожидался PSCustomObject с assignment_id и method_name)."
        # Используем New-CheckResultObject для возврата стандартизированной ошибки
        return New-CheckResultObject -IsAvailable $false -ErrorMessage "Некорректный объект задания передан в Invoke-StatusMonitorCheck."
    }

    # --- 2. Извлечение данных из Задания ---
    $assignmentId = $Assignment.assignment_id
    $methodName = $Assignment.method_name
    $targetIP = if ($Assignment.PSObject.Properties['ip_address']) { $Assignment.PSObject.Properties['ip_address'].Value } else { $null } # Безопасное извлечение, если свойства нет
    $nodeName = if ($Assignment.PSObject.Properties['node_name']) { 
        $Assignment.PSObject.Properties['node_name'].Value | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_)) { "Задание ID $assignmentId" } else { $_ } } 
    } else { 
        "Задание ID $assignmentId" 
    }

    # Получаем parameters и success_criteria, преобразуя в Hashtable, если они PSCustomObject
    $parameters = @{}
    $assignmentParameters = if ($Assignment.PSObject.Properties['parameters']) { $Assignment.PSObject.Properties['parameters'].Value } else { $null }
    if ($null -ne $assignmentParameters) {
        if ($assignmentParameters -is [hashtable]) { $parameters = $assignmentParameters }
        elseif ($assignmentParameters -is [System.Management.Automation.PSCustomObject]) {
            try { $parameters = @{}; $assignmentParameters.PSObject.Properties | ForEach-Object { $parameters[$_.Name] = $_.Value } }
            catch { Write-Warning "[$($assignmentId) | $nodeName] Не удалось преобразовать 'parameters' (PSCustomObject) в Hashtable. Используется пустой объект." }
        } else { Write-Warning "[$($assignmentId) | $nodeName] Поле 'parameters' имеет неожиданный тип '$($assignmentParameters.GetType().FullName)'. Используется пустой объект."}
    }

    $successCriteria = $null # success_criteria может быть $null
    $assignmentSuccessCriteria = if ($Assignment.PSObject.Properties['success_criteria']) { $Assignment.PSObject.Properties['success_criteria'].Value } else { $null }
    if ($null -ne $assignmentSuccessCriteria) {
        if ($assignmentSuccessCriteria -is [hashtable]) { $successCriteria = $assignmentSuccessCriteria }
        elseif ($assignmentSuccessCriteria -is [System.Management.Automation.PSCustomObject]) {
            try { $successCriteria = @{}; $assignmentSuccessCriteria.PSObject.Properties | ForEach-Object { $successCriteria[$_.Name] = $_.Value } }
            catch { Write-Warning "[$($assignmentId) | $nodeName] Не удалось преобразовать 'success_criteria' (PSCustomObject) в Hashtable. Критерии не будут применены." }
        } else { Write-Warning "[$($assignmentId) | $nodeName] Поле 'success_criteria' имеет неожиданный тип '$($assignmentSuccessCriteria.GetType().FullName)'. Критерии не будут применены."}
    }
    
    $targetLogString = if ($targetIP) { $targetIP } else { '[Локально]' }
    Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Запуск метода '$methodName' для цели '$targetLogString'."

    # --- 3. Поиск и выполнение скрипта проверки ---
    $resultFromCheckScript = $null # Результат, возвращенный скриптом Check-*.ps1
    try {
        # Определение пути к скрипту проверки
        $ModuleBase = $MyInvocation.MyCommand.Module.ModuleBase
        if (-not $ModuleBase) { 
            if ($PSScriptRoot) { $ModuleBase = $PSScriptRoot } # Fallback для случаев запуска вне модуля (например, тесты)
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

        # Подготовка параметров для скрипта проверки
        $paramsForCheckScript = @{
            TargetIP        = $targetIP
            Parameters      = $parameters       # Уже Hashtable
            SuccessCriteria = $successCriteria  # Уже Hashtable или $null
            NodeName        = $nodeName
        }
        Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Запуск скрипта '$CheckScriptFile'..."
        
        # Выполнение скрипта проверки
        # Важно: скрипт Check-*.ps1 ДОЛЖЕН возвращать объект, созданный через New-CheckResultObject
        $resultFromCheckScript = & $checkScriptPath @paramsForCheckScript
        
        # --- 4. Анализ результата от скрипта проверки ---
        # New-CheckResultObject всегда возвращает Hashtable [ordered]
        if ($null -eq $resultFromCheckScript -or -not ($resultFromCheckScript -is [hashtable]) -or -not $resultFromCheckScript.ContainsKey('IsAvailable')) {
            $errMsg = "Скрипт '$CheckScriptFile' вернул некорректный результат или $null."
            $resultTypeInfo = if ($null -eq $resultFromCheckScript) { '$null' } else { $resultFromCheckScript.GetType().FullName }
            Write-Warning "[$($assignmentId) | $nodeName] $errMsg Тип результата: $resultTypeInfo. Ожидалась Hashtable от New-CheckResultObject."
            # Формируем ошибку, если скрипт вернул что-то не то
            $resultFromCheckScript = New-CheckResultObject -IsAvailable $false -ErrorMessage $errMsg -Details @{ ScriptOutput = ($resultFromCheckScript | Out-String -Width 200) }
        } else {
            Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Скрипт '$CheckScriptFile' вернул корректный формат результата."
        }

    } catch {
        # --- 5. Обработка КРИТИЧЕСКИХ ОШИБОК диспетчера или скрипта проверки (исключения) ---
        $critErrMsg = "Критическая ошибка при выполнении метода '$methodName' для '$nodeName': $($_.Exception.Message)"
        Write-Warning "[$($assignmentId) | $nodeName] $critErrMsg"
        $errorDetails = @{ ErrorRecord = $_.ToString(); StackTrace = $_.ScriptStackTrace }
        if ($CheckScriptPath) { $errorDetails.CheckedScriptPath = $CheckScriptPath }
        $resultFromCheckScript = New-CheckResultObject -IsAvailable $false -ErrorMessage $critErrMsg -Details $errorDetails
    }

    # --- 6. Дополнение Details стандартной информацией и возврат результата ---
    # $resultFromCheckScript теперь ГАРАНТИРОВАННО является результатом от New-CheckResultObject (Hashtable)
    # и содержит ключ 'Details', значение которого тоже Hashtable (возможно, пустая) или $null (если $processedDetails был $null).

    Write-Host "DEBUG (Invoke-Check): --- Начало отладки Details в Invoke-StatusMonitorCheck (перед дополнением) ---" -ForegroundColor Cyan

    # Получаем объект Details из результата скрипта проверки
    $detailsFromCheck = $null
    if ($resultFromCheckScript -is [hashtable] -and $resultFromCheckScript.ContainsKey('Details')) {
        $detailsFromCheck = $resultFromCheckScript['Details']
        Write-Host "DEBUG (Invoke-Check): Получен Details из скрипта проверки. Тип: $($detailsFromCheck.GetType().FullName)" -ForegroundColor Cyan
        if ($detailsFromCheck -is [hashtable]) {
            Write-Host "DEBUG (Invoke-Check): Ключи в Details от скрипта: $($detailsFromCheck.Keys -join ', ')" -ForegroundColor Cyan
            Write-Host "DEBUG (Invoke-Check): Содержимое Details от скрипта (JSON): $($detailsFromCheck | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue)" -ForegroundColor DarkCyan
        } else {
            Write-Host "DEBUG (Invoke-Check): Details от скрипта проверки НЕ является Hashtable (это неожиданно, если используется New-CheckResultObject v1.3.2+)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "DEBUG (Invoke-Check): Ключ 'Details' в результате от скрипта проверки НЕ НАЙДЕН или результат не Hashtable (ЭТО ОШИБКА ЛОГИКИ)." -ForegroundColor Red
    }

    # Создаем или используем существующую Hashtable для $resultFromCheckScript['Details']
    if ($null -eq $detailsFromCheck -or -not ($detailsFromCheck -is [hashtable])) {
        # Если Details от скрипта $null или не Hashtable, создаем новую пустую Hashtable.
        # Это перезапишет некорректные Details или создаст их, если их не было.
        Write-Host "DEBUG (Invoke-Check): Инициализация resultFromCheckScript['Details'] новой пустой Hashtable." -ForegroundColor Yellow
        $resultFromCheckScript['Details'] = @{}
    }
    # На этом этапе $resultFromCheckScript['Details'] ГАРАНТИРОВАННО является Hashtable.

    # Добавляем/Обновляем стандартные поля
    $resultFromCheckScript['Details']['execution_target'] = $env:COMPUTERNAME
    $resultFromCheckScript['Details']['execution_mode'] = 'local_agent'
    $resultFromCheckScript['Details']['check_target_ip'] = $targetIP

    Write-Host "DEBUG (Invoke-Check): Содержимое resultFromCheckScript['Details'] ПОСЛЕ дополнения (JSON): $($resultFromCheckScript['Details'] | ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue)" -ForegroundColor DarkCyan
    Write-Host "DEBUG (Invoke-Check): --- Конец отладки Details в Invoke-StatusMonitorCheck (после дополнения) ---" -ForegroundColor Cyan

    $isAvailableStr = $resultFromCheckScript['IsAvailable']
    $checkSuccessStr = if ($null -eq $resultFromCheckScript['CheckSuccess']) { '[null]' } else { $resultFromCheckScript['CheckSuccess'] }
    Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Завершение. IsAvailable: $isAvailableStr, CheckSuccess: $checkSuccessStr"
    
    return $resultFromCheckScript
}
#endregion

# --- Экспорт функций ---
# Test-IsOperatorBlock, Handle-OperatorBlockProcessing, Handle-ArrayCriteriaProcessing НЕ экспортируем, они внутренние
Export-ModuleMember -Function Invoke-StatusMonitorCheck, New-CheckResultObject, Test-SuccessCriteria, Compare-Values