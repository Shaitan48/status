# F:\status\source\powershell\StatusMonitorAgentUtils\Checks\Check-SQL_XML_QUERY.ps1
# --- Версия 2.0 ---
# Изменения:
# - Логика проверки SuccessCriteria вынесена в универсальную функцию Test-SuccessCriteria.
# - Стандартизирован формат $Details (основные данные в extracted_data).
# - Добавлен вызов Test-SuccessCriteria.

<#
.SYNOPSIS
    Выполняет SQL-запрос, извлекает XML, парсит и извлекает значения ключей. (v2.0)
.DESCRIPTION
    Подключается к MS SQL Server, выполняет SQL-запрос, ожидает XML
    в указанном столбце первой строки результата, парсит XML и извлекает
    текстовые значения элементов по заданному списку ключей.
    Формирует стандартизированный $Details с результатом в поле 'extracted_data'.
    Для определения итогового CheckSuccess использует универсальную функцию
    Test-SuccessCriteria, сравнивающую $Details с переданным $SuccessCriteria.
.PARAMETER TargetIP
    [string] Обязательный. Имя или IP-адрес экземпляра SQL Server.
.PARAMETER Parameters
    [hashtable] Обязательный. Содержит параметры:
    - sql_database (string): Имя БД. Обязательно.
    - sql_query (string): SQL-запрос (возвращающий XML). Обязательно.
    - xml_column_name (string): Имя столбца с XML. Обязательно.
    - keys_to_extract (string[]): Массив имен XML-элементов (ключей) для извлечения. Обязательно.
    - sql_username (string): Имя пользователя SQL (опционально).
    - sql_password (string): Пароль SQL (опционально, небезопасно).
    - query_timeout_sec (int): Таймаут запроса (default: 30).
.PARAMETER SuccessCriteria
    [hashtable] Необязательный. Критерии успеха для сравнения с полем 'extracted_data' в $Details.
                Пример: @{ extracted_data = @{ VersionStat = '20231201'; ErrorCode = @{ '<' = 1 } } }
                Обрабатывается функцией Test-SuccessCriteria.
.PARAMETER NodeName
    [string] Необязательный. Имя узла для логирования.
.OUTPUTS
    Hashtable - Стандартизированный объект результата проверки.
                Поле Details (hashtable) содержит:
                - server_instance (string)
                - database_name (string)
                - query_executed (string)
                - xml_source_column (string)
                - rows_returned (int)
                - extracted_data (hashtable): Хэш-таблица с извлеченными ключ-значение.
                - message (string): Опциональное сообщение.
                - error (string): Сообщение об ошибке SQL или парсинга XML.
                - ErrorRecord (string): Полный текст исключения.
                - xml_content_sample (string): Фрагмент XML при ошибке парсинга.
.NOTES
    Версия: 2.0.1 (Добавлены комментарии, форматирование, проверка модуля).
    Зависит от функций New-CheckResultObject и Test-SuccessCriteria.
    Требует наличия модуля PowerShell 'SqlServer'.
    Требует прав доступа к SQL Server.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIP, # Используется как ServerInstance

    [Parameter(Mandatory = $false)]
    [hashtable]$Parameters = @{},

    [Parameter(Mandatory = $false)]
    [hashtable]$SuccessCriteria = $null,

    [Parameter(Mandatory = $false)]
    [string]$NodeName = "Unknown Node"
)

# --- Инициализация переменных ---
$isAvailable = $false
$checkSuccess = $null
$errorMessage = $null
$finalResult = $null
# Инициализируем $Details базовой информацией и пустым extracted_data
$details = @{
    server_instance   = $TargetIP
    database_name     = $null
    query_executed    = $null
    xml_source_column = $null
    rows_returned     = 0
    extracted_data    = @{} # Здесь будут извлеченные ключ-значение
    # Поле message или error будет добавлено при необходимости
}

Write-Verbose "[$NodeName] Check-SQL_XML_QUERY (v2.0.1): Начало выполнения SQL XML запроса на $TargetIP"

# --- Основной блок Try/Catch ---
try {
    # --- 1. Валидация и извлечение параметров ---
    Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Обработка параметров..."
    $SqlServerInstance = $TargetIP
    $DatabaseName = $Parameters.sql_database
    $SqlQuery = $Parameters.sql_query
    $XmlColumnName = $Parameters.xml_column_name
    $KeysToExtract = $Parameters.keys_to_extract
    $SqlUsername = $Parameters.sql_username
    $SqlPassword = $Parameters.sql_password

    # Заполняем детали известными параметрами
    $details.database_name = $DatabaseName
    $details.query_executed = $SqlQuery
    $details.xml_source_column = $XmlColumnName

    # Проверка обязательных параметров
    if (-not $DatabaseName) { throw "Отсутствует обязательный параметр 'sql_database'." }
    if (-not $SqlQuery) { throw "Отсутствует обязательный параметр 'sql_query'." }
    if (-not $XmlColumnName) { throw "Отсутствует обязательный параметр 'xml_column_name'." }
    if (-not ($KeysToExtract -is [array]) -or $KeysToExtract.Count -eq 0) {
        throw "Параметр 'keys_to_extract' должен быть непустым массивом строк."
    }
    if ($SqlUsername -and (-not $SqlPassword)) { throw "Параметр 'sql_password' обязателен при указании 'sql_username'." }

    # Таймаут запроса
    $QueryTimeoutSec = 30
    if ($Parameters.ContainsKey('query_timeout_sec') -and $Parameters.query_timeout_sec -ne $null) {
        $parsedTimeout = 0
        if ([int]::TryParse($Parameters.query_timeout_sec, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
            $QueryTimeoutSec = $parsedTimeout
        } else { Write-Warning "[$NodeName] Check-SQL_XML_QUERY: Некорректное 'query_timeout_sec', используется $QueryTimeoutSec сек." }
    }
    Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Используется query_timeout_sec: $QueryTimeoutSec сек."

    # --- 2. Формирование параметров для Invoke-Sqlcmd ---
    $invokeSqlParams = @{
        ServerInstance = $SqlServerInstance
        Database       = $DatabaseName
        Query          = $SqlQuery
        QueryTimeout   = $QueryTimeoutSec
        ErrorAction    = 'Stop' # Перехватываем ошибки SQL        
        TrustServerCertificate = $true
    }
    if ($SqlUsername) {
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Используется SQL аутентификация для '$SqlUsername'."
        $securePassword = ConvertTo-SecureString -String $SqlPassword -AsPlainText -Force
        $invokeSqlParams.Credential = New-Object System.Management.Automation.PSCredential($SqlUsername, $securePassword)
    } else {
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Используется Windows аутентификация."
    }

    # --- 3. Проверка и загрузка модуля SqlServer ---
    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
         if (-not (Get-Module -ListAvailable -Name SqlServer)) { throw "Модуль PowerShell 'SqlServer' не найден. Установите его." }
         try { Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Загрузка модуля SqlServer..."; Import-Module SqlServer -ErrorAction Stop }
         catch { throw "Не удалось загрузить модуль 'SqlServer'. Ошибка: $($_.Exception.Message)" }
    }

    # --- 4. Выполнение SQL-запроса ---
    Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Выполнение запроса к '$SqlServerInstance/$DatabaseName'..."
    $queryResult = Invoke-Sqlcmd @invokeSqlParams
    # Если нет исключения - считаем, что SQL-часть выполнена успешно
    $isAvailable = $true # Установим в $false, если парсинг XML или поиск столбца не удастся

    # --- 5. Обработка результата SQL и извлечение XML ---
    $xmlString = $null
    $parseXml = $false
    $errorMessageFromSqlOrXml = $null # Внутренняя ошибка этого шага

    if ($queryResult -ne $null) {
        if ($queryResult -isnot [array]) { $queryResult = @($queryResult) }
        $details.rows_returned = $queryResult.Count

        if ($queryResult.Count -gt 0) {
            $firstRow = $queryResult[0]
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Запрос вернул $($queryResult.Count) строк. Обработка первой."
            # Проверка наличия столбца
            if ($firstRow.PSObject.Properties.Name -contains $XmlColumnName) {
                $xmlValue = $firstRow.$XmlColumnName
                if ($xmlValue -ne $null -and $xmlValue -ne [System.DBNull]::Value) {
                    $xmlString = $xmlValue.ToString()
                    if (-not [string]::IsNullOrWhiteSpace($xmlString)) {
                         $parseXml = $true # Есть что парсить
                         Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Получен непустой XML из '$XmlColumnName'."
                    } else { $errorMessageFromSqlOrXml = "Столбец '$XmlColumnName' пуст (строка)." }
                } else { $errorMessageFromSqlOrXml = "Столбец '$XmlColumnName' пуст (NULL)." }
            } else { $errorMessageFromSqlOrXml = "Столбец '$XmlColumnName' не найден в результате запроса." }
        } else { $details.message = "SQL-запрос не вернул строк."; Write-Verbose "[$NodeName] $($details.message)" }
    } else { $details.message = "SQL-запрос не вернул данных."; Write-Verbose "[$NodeName] $($details.message)" }

    # Если на этапе извлечения XML возникла ошибка, считаем проверку неуспешной
    if ($errorMessageFromSqlOrXml) {
        $isAvailable = $false # Не смогли получить/найти XML
        $errorMessage = $errorMessageFromSqlOrXml
        $details.error = $errorMessage
        Write-Warning "[$NodeName] Check-SQL_XML_QUERY: $errorMessage"
    }

    # --- 6. Парсинг XML и извлечение ключей (только если есть что парсить и не было ошибок) ---
    if ($isAvailable -and $parseXml) {
        Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Попытка парсинга XML..."
        $xmlContentSample = $null
        $xmlDoc = $null
        try {
            # --- Шаг 1: Получаем значение из объекта DataRow ---
            # Invoke-Sqlcmd возвращает массив объектов PSCustomObject или одиночный объект
            # Доступ к свойству может вернуть разные типы, включая System.DBNull
            $xmlRawValue = $firstRow.$XmlColumnName # Получаем значение столбца

            # --- Шаг 2: Преобразуем в строку и очищаем ---
            $xmlStringForParsing = "" # Инициализируем пустой строкой
            if ($xmlRawValue -ne $null -and $xmlRawValue -ne [System.DBNull]::Value) {
                # Явно преобразуем в строку
                $xmlStringForParsing = [string]$xmlRawValue
                Write-Debug "[$NodeName] Check-SQL_XML_QUERY: Исходное значение столбца '$XmlColumnName' (тип $($xmlRawValue.GetType().Name)):`n$xmlStringForParsing"

                # Удаляем BOM и пробелы
                $xmlStringForParsing = $xmlStringForParsing.Trim()
                if ($xmlStringForParsing.StartsWith([char]0xFEFF) -or $xmlStringForParsing.StartsWith([char]0xFFFE)) {
                    $xmlStringForParsing = $xmlStringForParsing.Substring(1)
                    Write-Debug "[$NodeName] Check-SQL_XML_QUERY: Убран BOM из XML."
                }
            } else {
                Write-Warning "[$NodeName] Check-SQL_XML_QUERY: Значение в столбце '$XmlColumnName' пусто (NULL или DBNull)."
                # Оставляем $xmlStringForParsing пустым
            }

            Write-Debug "[$NodeName] Check-SQL_XML_QUERY: Очищенная строка XML для парсинга:`n$xmlStringForParsing"

            # --- Шаг 3: Проверка и парсинг ---
            if ([string]::IsNullOrWhiteSpace($xmlStringForParsing)) {
                throw "После очистки строка XML оказалась пустой."
            }
            if (-not $xmlStringForParsing.StartsWith('<')) {
                throw "Строка из столбца '$XmlColumnName' не начинается с '<' после очистки."
            }

            # Сохраняем образец для логов
            if ($xmlStringForParsing.Length > 500) { $xmlContentSample = $xmlStringForParsing.Substring(0, 500) + "..." }
            else { $xmlContentSample = $xmlStringForParsing }

            # Парсинг через .NET
            $xmlDoc = New-Object System.Xml.XmlDocument
            $xmlDoc.LoadXml($xmlStringForParsing)
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: XML успешно распарсен через .NET XmlDocument."

            if ($null -eq $xmlDoc.DocumentElement) { throw "Корневой элемент в XML не найден после парсинга." }

            # --- Шаг 4: Извлечение данных (код без изменений) ---
            $extractedData = @{}
            foreach ($key in $KeysToExtract) {
                $value = $null
                $xmlElement = $xmlDoc.DocumentElement.SelectSingleNode("./*[local-name()='$key']")
                if ($xmlElement -ne $null) { $value = $xmlElement.InnerText }
                $extractedData[$key] = $value
                Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Ключ '$key' = '$value'"
            }
            $details.extracted_data = $extractedData

        } catch {
            # Обработка ошибок парсинга / извлечения
            $isAvailable = $false
            $errorMessage = "Ошибка парсинга/обработки XML из '$XmlColumnName': $($_.Exception.Message)"
            if ($errorMessage.Length > 500) { $errorMessage = $errorMessage.Substring(0, 500) + "..." }
            $details.error = $errorMessage
            $details.ErrorRecord = $_.ToString()
            if ($xmlContentSample) { $details.xml_content_sample = $xmlContentSample }
            Write-Warning "[$NodeName] Check-SQL_XML_QUERY: $errorMessage"
        }
    }

    # --- 7. Вызов универсальной функции проверки критериев ---
    $failReason = $null

    # Проверяем критерии только если проверка прошла успешно
    # (т.е. SQL выполнен, столбец найден, XML распарсен, данные извлечены)
    if ($isAvailable) {
        if ($SuccessCriteria -ne $null -and $SuccessCriteria.Keys.Count -gt 0) {
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: Вызов Test-SuccessCriteria..."
            # Передаем $Details (где есть extracted_data) и $SuccessCriteria
            # Функция Test-SuccessCriteria должна уметь работать с вложенной структурой,
            # например, если критерий @{ extracted_data = @{ VersionStat = '2023' } }
            $criteriaResult = Test-SuccessCriteria -DetailsObject $details -CriteriaObject $SuccessCriteria
            $checkSuccess = $criteriaResult.Passed
            $failReason = $criteriaResult.FailReason

            if ($checkSuccess -eq $null) {
                $errorMessage = "Ошибка при обработке SuccessCriteria: $failReason"
                Write-Warning "[$NodeName] $errorMessage"
            } elseif ($checkSuccess -eq $false) {
                $errorMessage = $failReason # Причина провала
                Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: SuccessCriteria НЕ пройдены: $failReason"
            } else {
                $errorMessage = $null # Критерии пройдены
                Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: SuccessCriteria пройдены."
            }
        } else {
            # Критерии не заданы
            $checkSuccess = $true
            $errorMessage = $null
            Write-Verbose "[$NodeName] Check-SQL_XML_QUERY: SuccessCriteria не заданы, CheckSuccess=true."
        }
    } else {
        # Если IsAvailable = $false
        $checkSuccess = $null
        # $errorMessage уже должен быть установлен при ошибке SQL или парсинга XML
        if ([string]::IsNullOrEmpty($errorMessage)) {
            $errorMessage = "Ошибка выполнения SQL XML запроса (IsAvailable=false)."
        }
    }

    # --- 8. Формирование итогового результата ---
    $finalResult = New-CheckResultObject -IsAvailable $isAvailable `
                                         -CheckSuccess $checkSuccess `
                                         -Details $details `
                                         -ErrorMessage $errorMessage

# <<< Закрываем основной try >>>
} catch {
    # --- Обработка КРИТИЧЕСКИХ ОШИБОК ---
    # Ошибки валидации параметров, загрузки модуля, Invoke-Sqlcmd
    $isAvailable = $false
    $checkSuccess = $null
    $exceptionMessage = $_.Exception.Message
    if ($exceptionMessage.Length -gt 500) { $exceptionMessage = $exceptionMessage.Substring(0, 500) + "..." }
    $critErrorMessage = "Критическая ошибка при выполнении SQL XML запроса: {0}" -f $exceptionMessage

    # Формируем Details с ошибкой, сохраняя исходные параметры
    $detailsError = @{
        error             = $critErrorMessage
        ErrorRecord       = $_.ToString()
        server_instance   = $TargetIP
        database_name     = $Parameters.sql_database # Используем из параметров
        query_executed    = $Parameters.sql_query
        xml_source_column = $Parameters.xml_column_name
    }

    # Создаем финальный результат ВРУЧНУЮ
    $finalResult = @{
        IsAvailable  = $isAvailable
        CheckSuccess = $checkSuccess
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        Details      = $detailsError
        ErrorMessage = $critErrorMessage
    }
    Write-Error "[$NodeName] Check-SQL_XML_QUERY: Критическая ошибка: $critErrorMessage"
} # <<< Закрываем основной catch >>>

# --- Возврат результата ---
$isAvailableStr = if ($finalResult) { $finalResult.IsAvailable } else { '[result is null]' }
$checkSuccessStr = if ($finalResult) { $finalResult.CheckSuccess } else { '[result is null]' }
Write-Verbose "[$NodeName] Check-SQL_XML_QUERY (v2.0.1): Завершение. IsAvailable=$isAvailableStr, CheckSuccess=$checkSuccessStr"

return $finalResult