# F:\status\source\powershell\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psm1
# Основной скрипт модуля StatusMonitorAgentUtils.
# Содержит экспортируемые функции и приватные хелперы.
# Версия модуля: 1.1.0 (согласно PSD1)
# Версия этого файла: Включает Test-SuccessCriteria v2.1.8, Compare-Values v1.1, New-CheckResultObject v1.3, Invoke-StatusMonitorCheck v1.2.1

#--------------------------------------------------------------------------
# Приватные функции (не экспортируются)
#--------------------------------------------------------------------------

#region Функция Compare-Values (Приватная, v1.1 - Улучшено сравнение ==/!=)
# Вспомогательная функция для сравнения значений с операторами
# Возвращает: @{ Passed = $true/$false/$null; Reason = "..."/$null }
# ($null для Passed означает ошибку сравнения/типа)
function Compare-Values {
    param(
        $Value, # Фактическое значение из Details
        $Operator, # Оператор сравнения (строка: '>', 'contains', 'matches'...)
        $Threshold # Пороговое значение из Criteria
    )

    $result = @{ Passed = $true; Reason = '' }
    $opLower = $Operator.ToLower()

    try {
        # --- Проверка существования ---
        if ($opLower -eq 'exists') {
            if (($Threshold -eq $true -and $Value -eq $null) -or ($Threshold -eq $false -and $Value -ne $null)) {
                $result.Passed = $false
                $result.Reason = "Проверка существования (exists=$Threshold) не пройдена для значения '$Value'"
            }
            return $result
        }

        # --- Универсальное сравнение для == и != ---
        # Используем стандартный оператор PowerShell
        elseif ($opLower -eq '==') {
             if (-not ($Value -eq $Threshold)) {
                 $result.Passed = $false; $result.Reason = "'$Value' не равно '$Threshold'"
             }
        }
        elseif ($opLower -eq '!=') {
             if (-not ($Value -ne $Threshold)) {
                 $result.Passed = $false; $result.Reason = "'$Value' равно '$Threshold'"
             }
        }
        # --- Числовые сравнения (остаются с преобразованием) ---
        elseif ($opLower -in @('>', '>=', '<', '<=')) {
            $numValue = 0.0; $numThreshold = 0.0
            # Используем региональные настройки текущей культуры для парсинга чисел
            $culture = [System.Globalization.CultureInfo]::CurrentCulture
            $valueParsed = [double]::TryParse($Value, [System.Globalization.NumberStyles]::Any, $culture, [ref]$numValue)
            $thresholdParsed = [double]::TryParse($Threshold, [System.Globalization.NumberStyles]::Any, $culture, [ref]$numThreshold)

            if (-not $valueParsed -or -not $thresholdParsed) {
                $result.Passed = $null # Ошибка типа
                $result.Reason = "Ошибка числового сравнения '$opLower': Не удалось преобразовать '$Value' или '$Threshold' в число."
                return $result
            }
            # Выполняем числовое сравнение
            switch ($opLower) {
                '>'  { if (-not ($numValue -gt $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' не больше (>) '$Threshold'" } }
                '>=' { if (-not ($numValue -ge $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' не больше или равно (>=) '$Threshold'" } }
                '<'  { if (-not ($numValue -lt $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' не меньше (<) '$Threshold'" } }
                '<=' { if (-not ($numValue -le $numThreshold)) { $result.Passed = $false; $result.Reason = "'$Value' не меньше или равно (<=) '$Threshold'" } }
            }
        }
        # --- Строковые сравнения (только специфичные для строк) ---
        elseif ($opLower -in @('contains', 'not_contains', 'matches', 'not_matches')) {
            # Приводим оба операнда к строке
            $strValue = "$Value"
            $strThreshold = "$Threshold"

            # Выполняем сравнение
            switch ($opLower) {
                'contains' { if ($strValue -notlike "*$strThreshold*") { $result.Passed = $false; $result.Reason = "'$strValue' не содержит '$strThreshold'" } }
                'not_contains' { if ($strValue -like "*$strThreshold*") { $result.Passed = $false; $result.Reason = "'$strValue' содержит '$strThreshold'" } }
                'matches' { if ($strValue -notmatch $strThreshold) { $result.Passed = $false; $result.Reason = "'$strValue' не соответствует regex '$strThreshold'" } }
                'not_matches' { if ($strValue -match $strThreshold) { $result.Passed = $false; $result.Reason = "'$strValue' соответствует regex '$strThreshold'" } }
            }
        } else {
            # Неизвестный оператор
            $result.Passed = $null
            $result.Reason = "Неизвестный оператор сравнения: '$Operator'"
        }
    } catch {
        $result.Passed = $null
        $result.Reason = "Ошибка при сравнении оператором '$Operator' для '$Value' и '$Threshold': $($_.Exception.Message)"
    }
    return $result
}
#endregion

#region Функция Test-ArrayCriteria (Приватная, v1.0 - Реализованная, но требует тестов)
# Обрабатывает критерии для массивов (_condition_, _where_, _criteria_, _count_)
function Test-ArrayCriteria {
    param(
        [Parameter(Mandatory=$true)] $DetailsArray,    # Массив данных из Details
        [Parameter(Mandatory=$true)] [hashtable]$ArrayCriteria, # Критерий для массива (содержит _condition_, etc.)
        [string]$Path                             # Текущий путь для логов/ошибок
    )

    $result = @{ Passed = $null; FailReason = $null } # Начинаем с неопределенного

    # 1. Проверка, что DetailsArray - это действительно массив
    if ($DetailsArray -isnot [array]) {
        $result.Passed = $false
        $result.FailReason = "Ошибка критерия массива по пути '$Path': Ожидался массив в данных, но получен '$($DetailsArray.GetType().Name)'."
        return $result
    }

    # 2. Извлечение управляющих ключей из критерия
    $condition = $ArrayCriteria._condition_
    $whereClause = $ArrayCriteria._where_       # Может быть $null или hashtable
    $criteria = $ArrayCriteria._criteria_     # Может быть $null или hashtable (для all, any, none)
    $countCriteria = $ArrayCriteria._count_    # Может быть $null или hashtable (для count)

    # 3. Валидация управляющих ключей
    if (-not $condition -or $condition.ToLower() -notin @('all', 'any', 'none', 'count')) {
        $result.Passed = $null
        $result.FailReason = "Ошибка критерия массива по пути '$Path': Отсутствует или неверный ключ '_condition_'. Допустимые: 'all', 'any', 'none', 'count'."
        return $result
    }
    $conditionLower = $condition.ToLower() # Приводим к нижнему регистру для switch

    if ($conditionLower -in @('all', 'any') -and $null -eq $criteria) {
        $result.Passed = $null
        $result.FailReason = "Ошибка критерия массива по пути '$Path': Для _condition_ '$condition' требуется ключ '_criteria_'."
        return $result
    }
    if ($conditionLower -eq 'count' -and ($null -eq $countCriteria -or -not ($countCriteria.PSObject -ne $null))) { # Проверяем, что countCriteria - объект
        $result.Passed = $null
        $result.FailReason = "Ошибка критерия массива по пути '$Path': Для _condition_ 'count' требуется ключ '_count_' с объектом операторов."
        return $result
    }

    # 4. Фильтрация массива (если есть _where_)
    $filteredArray = $DetailsArray # По умолчанию работаем со всем массивом
    if ($whereClause -ne $null) {
        Write-Verbose "Фильтрация массива по пути '$Path' с использованием _where_..."
        $tempFiltered = [System.Collections.Generic.List[object]]::new()
        $indexCounter = -1 # Счетчик для логов
        foreach ($item in $DetailsArray) {
            $indexCounter++
            # Рекурсивно проверяем КАЖДЫЙ элемент на соответствие _where_
            $filterCheck = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $whereClause -Path "$Path[$indexCounter]" # Передаем индекс
            if ($filterCheck.Passed -eq $true) {
                $tempFiltered.Add($item)
            } elseif ($filterCheck.Passed -eq $null) {
                # Если ошибка при фильтрации элемента - вся проверка критерия массива считается ошибочной
                $result.Passed = $null
                $result.FailReason = "Ошибка при фильтрации элемента массива ($indexCounter) по пути '$Path': $($filterCheck.FailReason)"
                return $result
            }
        }
        $filteredArray = $tempFiltered
        Write-Verbose "Массив по пути '$Path' отфильтрован. Осталось элементов: $($filteredArray.Count)"
    }

    # 5. Применение основного условия (_condition_)
    $finalPassed = $null # Итоговый результат условия

    switch ($conditionLower) {
        'all' {
            if ($filteredArray.Count -eq 0) { $finalPassed = $true }
            else {
                 $allPassed = $true
                 for ($i = 0; $i -lt $filteredArray.Count; $i++) {
                     $item = $filteredArray[$i]
                     $itemResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteria -Path "$Path[$i]"
                     if ($itemResult.Passed -ne $true) {
                         $allPassed = $false; $result.FailReason = "Условие 'all' не выполнено для элемента [$i] по пути '$Path'. Причина: $($itemResult.FailReason)"; break
                     }
                 }
                 $finalPassed = $allPassed
            }
        } # Конец 'all'
        'any' {
             $anyPassed = $false
             if ($filteredArray.Count -gt 0) {
                 for ($i = 0; $i -lt $filteredArray.Count; $i++) {
                     $item = $filteredArray[$i]
                     $itemResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteria -Path "$Path[$i]"
                     if ($itemResult.Passed -eq $true) { $anyPassed = $true; $result.FailReason = $null; break }
                     elseif ($itemResult.Passed -eq $null) { $anyPassed = $null; $result.FailReason = "Ошибка проверки элемента [$i] для 'any' ($($itemResult.FailReason))"; break }
                 }
             }
             if ($anyPassed -eq $false -and $result.FailReason -eq $null) { $result.FailReason = "Условие 'any': ни один элемент в '$Path' не соответствует критериям." }
             $finalPassed = $anyPassed
        } # Конец 'any'
        'none' {
             $nonePassed = $true
             if ($filteredArray.Count -gt 0) {
                 if ($criteria -ne $null) {
                     for ($i = 0; $i -lt $filteredArray.Count; $i++) {
                         $item = $filteredArray[$i]
                         $itemResult = Test-SuccessCriteria -DetailsObject $item -CriteriaObject $criteria -Path "$Path[$i]"
                         if ($itemResult.Passed -eq $true) { $nonePassed = $false; $result.FailReason = "Условие 'none': элемент [$i] в '$Path' СООТВЕТСТВУЕТ критериям."; break }
                         elseif ($itemResult.Passed -eq $null) { $nonePassed = $null; $result.FailReason = "Ошибка проверки элемента [$i] для 'none' ($($itemResult.FailReason))"; break }
                     }
                 } else { $nonePassed = $false; $result.FailReason = "Условие 'none': найдены элементы ($($filteredArray.Count) шт.), соответствующие _where_ в '$Path'." }
             }
             $finalPassed = $nonePassed
        } # Конец 'none'
        'count' {
            $itemCount = $filteredArray.Count
            Write-Verbose "Проверка количества элементов ($itemCount) по пути '$Path'..."
            $countCheckPassed = $true
            # Итерируем по операторам в _count_ (это должна быть Hashtable)
            foreach ($operatorProperty in $countCriteria.PSObject.Properties) {
                $operator = $operatorProperty.Name
                $threshold = $operatorProperty.Value
                $comparisonResult = Compare-Values -Value $itemCount -Operator $operator -Threshold $threshold
                if ($comparisonResult.Passed -ne $true) {
                    $countCheckPassed = $comparisonResult.Passed # $false или $null
                    $result.FailReason = "Критерий количества ('count') не пройден ($($comparisonResult.Reason)) по пути '$Path'."
                    break
                }
            }
            $finalPassed = $countCheckPassed
        } # Конец 'count'
    } # Конец switch ($conditionLower)

    $result.Passed = $finalPassed
    # FailReason уже установлен внутри switch
    return $result
}
#endregion

#region Функция Test-SuccessCriteria (Приватная, v2.1.8 - Исправлен доступ к свойству)
# Рекурсивно сравнивает объект Details с объектом Criteria
# Возвращает: @{ Passed = $true/$false/$null; FailReason = "..."/$null }
#region Функция Test-SuccessCriteria (Приватная, v2.1.12 - Убрана рекурсия для не-операторов)
function Test-SuccessCriteria {
    param(
        [Parameter(Mandatory=$true)] $DetailsObject,
        [Parameter(Mandatory=$true)] $CriteriaObject,
        [string]$Path = '$Details'
    )
    # ... (Отладка входа) ...
    Write-Host "--- Test-SuccessCriteria [Вход] ---" # ...

    $overallResult = @{ Passed = $true; FailReason = $null }
    if ($null -eq $CriteriaObject.PSObject) { <# ... ошибка ... #> return $overallResult }
    # ... (проверка DetailsObject) ...

    # --- ИТЕРАЦИЯ ПО КЛЮЧАМ КРИТЕРИЯ ---
    foreach ($entry in $CriteriaObject.GetEnumerator()) {
        $key = $entry.Name
        $currentCriteriaValue = $entry.Value
        $currentPath = "$Path.$key"
        Write-Host "  [Цикл] Path='$Path', Key='$key', CriteriaValue Type='$($currentCriteriaValue.GetType().FullName)'" -ForegroundColor DarkYellow

        # ... (проверка _condition_ ...) ...
        if ($key -in @('_condition_', '_where_', '_criteria_', '_count_')) { <#...#> continue }

        # --- Проверка наличия ключа '$key' в $DetailsObject ---
        $keyExists = $false; $currentDetailsValue = $null; $propertyAccessError = $null
        if ($null -ne $DetailsObject.PSObject) { <# ... код проверки и получения значения v2.1.8 ... #> }
        if (-not $keyExists) { <# ... обработка отсутствия ключа ... #> continue }
        elseif ($null -ne $propertyAccessError) { $overallResult.Passed = $null; $overallResult.FailReason = $propertyAccessError; break }

        # --- КЛЮЧ НАЙДЕН, ЗНАЧЕНИЕ В $currentDetailsValue ---
        $isCriteriaComplex = $currentCriteriaValue -is [hashtable] -or $currentCriteriaValue -is [System.Management.Automation.PSCustomObject]
        if ($isCriteriaComplex) {
            # --- СЛОЖНЫЙ КРИТЕРИЙ ---
            if ($currentCriteriaValue.PSObject.Properties.Name -contains '_condition_') {
                # Критерий для массива
                $arrayResult = Test-ArrayCriteria -DetailsArray $currentDetailsValue -ArrayCriteria $currentCriteriaValue -Path $currentPath
                if ($arrayResult.Passed -ne $true) { $overallResult = $arrayResult; break }
            } else {
                # --- Операторы ИЛИ НЕПОДДЕРЖИВАЕМЫЙ ВЛОЖЕННЫЙ ОБЪЕКТ ---
                $isOperatorObject = $false; $operators = @('>', '>=', '<', '<=', '==', '!=', 'contains', 'not_contains', 'matches', 'not_matches', 'exists'); $keysInCriteriaValue = @($currentCriteriaValue.PSObject.Properties.Name)
                if ($keysInCriteriaValue.Count -gt 0) { $allKeysAreOperators = $true; foreach($ckey in $keysInCriteriaValue){ if($operators -notcontains $ckey.ToLower()){ $allKeysAreOperators = $false; break } }; if($allKeysAreOperators){ $isOperatorObject = $true } }

                if ($isOperatorObject) {
                    # --- ОБРАБОТКА ОПЕРАТОРОВ (код без изменений) ---
                    Write-Verbose "Сравнение операторами для '$currentPath'"
                    foreach ($operatorProperty in $currentCriteriaValue.PSObject.Properties) {
                        $operator = $operatorProperty.Name; $threshold = $operatorProperty.Value
                        Write-Host "      [Оператор] Compare-Values: Value='$currentDetailsValue', Operator='$operator', Threshold='$threshold'" -ForegroundColor DarkMagenta
                        $comparisonResult = Compare-Values -Value $currentDetailsValue -Operator $operator -Threshold $threshold
                        if ($comparisonResult.Passed -ne $true) { $overallResult.Passed = $comparisonResult.Passed; $overallResult.FailReason = "Критерий '$key' не пройден ($($comparisonResult.Reason)) по пути '$Path'."; break }
                    }
                    if ($overallResult.Passed -ne $true) { break }
                } else {
                    # --- НЕПОДДЕРЖИВАЕМЫЙ ВЛОЖЕННЫЙ КРИТЕРИЙ ---
                    # <<< ИЗМЕНЕНО: Вместо рекурсии - ошибка >>>
                    $overallResult.Passed = $null # Ошибка формата критерия
                    $overallResult.FailReason = "Ошибка критерия по пути '$currentPath'. Вложенные объекты без операторов сравнения не поддерживаются (кроме критериев для массивов с _condition_)."
                    Write-Warning $overallResult.FailReason
                    break # Прерываем проверку
                }
            }
        } else {
            # --- Простое сравнение (код без изменений) ---
            Write-Verbose "Простое сравнение для '$currentPath'"
            Write-Host "      [Простое] Compare-Values: Value='$currentDetailsValue', Operator='==', Threshold='$currentCriteriaValue'" -ForegroundColor DarkMagenta
            $comparisonResult = Compare-Values -Value $currentDetailsValue -Operator '==' -Threshold $currentCriteriaValue
            if ($comparisonResult.Passed -ne $true) {
                $overallResult.Passed = $comparisonResult.Passed
                $overallResult.FailReason = "Критерий '$key' не пройден ($($comparisonResult.Reason)) по пути '$Path'."
                break
            }
        }
    } # Конец foreach

    Write-Host "--- Test-SuccessCriteria [Выход] --- Path: $Path, Passed: $($overallResult.Passed), Reason: $($overallResult.FailReason)" -ForegroundColor Yellow
    return $overallResult
}
#endregion

#--------------------------------------------------------------------------
# Экспортируемые функции
#--------------------------------------------------------------------------

#region Функция New-CheckResultObject (Экспортируемая, v1.3)
<#
.SYNOPSIS
    Создает стандартизированный объект результата проверки (хэш-таблицу).
# ... (описание New-CheckResultObject без изменений) ...
#>
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
        if ($Details -is [hashtable]) { $processedDetails = $Details }
        elseif ($Details.PSObject -ne $null) { try { $processedDetails = [hashtable]$Details } catch { $processedDetails = @{ OriginalDetails = $Details } } }
        else { $processedDetails = @{ Value = $Details } }
    }
    $result = [ordered]@{
        IsAvailable = $IsAvailable; CheckSuccess = $CheckSuccess; Timestamp = (Get-Date).ToUniversalTime().ToString("o"); Details = $processedDetails; ErrorMessage = $ErrorMessage
    }
    if ($result.IsAvailable) { if ($result.CheckSuccess -eq $null) { $result.CheckSuccess = $true } }
    else { $result.CheckSuccess = $null }
    if ([string]::IsNullOrEmpty($result.ErrorMessage)) { if (-not $result.IsAvailable) { $result.ErrorMessage = "Ошибка выполнения проверки (IsAvailable=false)." } }
    Write-Verbose ("New-CheckResultObject (v1.3): Создан результат: IsAvailable=$($result.IsAvailable), CheckSuccess=$($result.CheckSuccess), Error='$($result.ErrorMessage)'")
    return $result
}
#endregion

#region Функция Invoke-StatusMonitorCheck (Экспортируемая, v1.2.1 - Улучшена обработка parameters/success_criteria)
<#
.SYNOPSIS
    Выполняет проверку мониторинга согласно заданию.
# ... (описание Invoke-StatusMonitorCheck без изменений) ...
#>
function Invoke-StatusMonitorCheck {
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Assignment
    )

    # --- 1. Валидация входного объекта ---
    if ($null -eq $Assignment.PSObject -or -not ($Assignment.PSObject.Properties.Name -contains 'assignment_id') -or -not ($Assignment.PSObject.Properties.Name -contains 'method_name')) {
        Write-Warning "Invoke-StatusMonitorCheck: Передан некорректный объект задания."; return New-CheckResultObject -IsAvailable $false -ErrorMessage "Некорректный объект задания."
    }

    # --- 2. Извлечение данных ---
    $assignmentId = $Assignment.assignment_id; $methodName = $Assignment.method_name; $targetIP = $null; $nodeName = "Задание ID $assignmentId"
    if ($Assignment.PSObject.Properties.Name -contains 'ip_address') { $targetIP = $Assignment.ip_address }
    if (($Assignment.PSObject.Properties.Name -contains 'node_name') -and $Assignment.node_name) { $nodeName = $Assignment.node_name }
    # Получаем parameters и success_criteria, преобразуя в Hashtable
    $parameters = @{}; $successCriteria = $null
    if (($Assignment.PSObject.Properties.Name -contains 'parameters') -and $Assignment.parameters) { if ($Assignment.parameters.PSObject -ne $null) { try { $parameters = [hashtable]$Assignment.parameters } catch { Write-Warning "[$($assignmentId) | $nodeName] Не удалось преобразовать 'parameters' в Hashtable. Используется пустой объект." } } else { Write-Warning "[$($assignmentId) | $nodeName] Поле 'parameters' не является объектом. Используется пустой объект."} }
    if (($Assignment.PSObject.Properties.Name -contains 'success_criteria') -and $Assignment.success_criteria) { if ($Assignment.success_criteria.PSObject -ne $null) { try { $successCriteria = [hashtable]$Assignment.success_criteria } catch { Write-Warning "[$($assignmentId) | $nodeName] Не удалось преобразовать 'success_criteria' в Hashtable. Критерии не будут применены." } } else { Write-Warning "[$($assignmentId) | $nodeName] Поле 'success_criteria' не является объектом. Критерии не будут применены." } }
    $targetLogString = if ($targetIP) { $targetIP } else { '[Local]' }; Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Запуск '$methodName' (Target: $targetLogString)"

    # --- 3. Поиск и выполнение скрипта ---
    $result = $null
    try {
        $ModuleBase = $MyInvocation.MyCommand.Module.ModuleBase; if (-not $ModuleBase) { if ($PSScriptRoot) { $ModuleBase = $PSScriptRoot } else { throw "Не удалось определить путь модуля." } }
        $ChecksFolder = Join-Path -Path $ModuleBase -ChildPath "Checks"; $CheckScriptFile = "Check-$($methodName).ps1"; $CheckScriptPath = Join-Path -Path $ChecksFolder -ChildPath $CheckScriptFile
        Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Поиск скрипта: $CheckScriptPath"
        if (-not (Test-Path $CheckScriptPath -PathType Leaf)) { $errorMessage = "Скрипт '$CheckScriptFile' не найден."; Write-Warning "[$($assignmentId) | $nodeName] $errorMessage"; return New-CheckResultObject -IsAvailable $false -ErrorMessage $errorMessage -Details @{ CheckedScriptPath = $CheckScriptPath } }

        $checkParams = [hashtable]@{ TargetIP = $targetIP; Parameters = $parameters; SuccessCriteria = $successCriteria; NodeName = $nodeName }
        Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Запуск '$CheckScriptFile'..."
        try { $result = & $checkScriptPath @checkParams } catch { throw } # Переброс ошибки из скрипта

        # --- 4. Анализ результата ---
        $resultIsValid = $false; if ($null -ne $result) { try { $null = $result.IsAvailable; $resultIsValid = $true } catch { } }
        if (-not $resultIsValid) {
            $errorMessage = "Скрипт '$CheckScriptFile' вернул некорректный результат."; $resultType = if ($null -eq $result) { '$null' } else { $result.GetType().FullName }; Write-Warning "... $resultType ..."; $result = New-CheckResultObject -IsAvailable $false -ErrorMessage $errorMessage -Details @{ ScriptOutput = ($result | Out-String -Width 200) }
        } else {
            Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Скрипт '$CheckScriptFile' вернул результат."
            if ($result.PSObject.Properties.Name -contains 'Details') { if ($result.Details.PSObject -ne $null -and $result.Details -isnot [hashtable]) { try { $result.Details = [hashtable]$result.Details } catch { $result.Details = @{ OriginalDetails = $result.Details } } } } else { $result.Details = @{} }
            $result.Details.execution_target = $env:COMPUTERNAME; $result.Details.execution_mode = 'local_agent'; $result.Details.check_target_ip = $targetIP
        }
    } catch {
        # --- 5. Обработка КРИТИЧЕСКИХ ОШИБОК диспетчера ---
        $errorMessage = "Критическая ошибка '$methodName' для '$nodeName': $($_.Exception.Message)"; Write-Warning "[$($assignmentId) | $nodeName] $errorMessage"; $result = New-CheckResultObject -IsAvailable $false -ErrorMessage $errorMessage -Details @{ ErrorRecord = $_.ToString() }
    }

    # --- 6. Возвращаем результат ---
    $isAvailableStr = if ($result -and $result.PSObject.Properties.Name -contains 'IsAvailable') { $result.IsAvailable } else { '[N/A]' }
    $checkSuccessStr = if ($result -and $result.PSObject.Properties.Name -contains 'CheckSuccess') { $result.CheckSuccess } else { '[N/A]' }
    Write-Verbose "[$($assignmentId) | $nodeName] Invoke-StatusMonitorCheck: Завершение. IsAvailable: $isAvailableStr, CheckSuccess: $checkSuccessStr"
    return $result
}
#endregion


# --- Экспорт функций ---
Export-ModuleMember -Function Invoke-StatusMonitorCheck, New-CheckResultObject, Test-SuccessCriteria, Compare-Values