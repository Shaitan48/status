# F:\status\source\powershell\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1
# Манифест PowerShell модуля для общих утилит агентов Status Monitor

@{

    # --- ОБНОВЛЕНО: Версия модуля ---
    # Версия 2.0.0: Существенно доработана логика проверки критериев (Test-SuccessCriteria)
    ModuleVersion = '2.0.0'

    # Уникальный идентификатор модуля (GUID). Не меняется.
    GUID = 'e5fa7cfe-608d-47c9-898d-215bb6b0ef0d'

    # Автор модуля
    Author = 'User & AI'

    # Компания (опционально)
    # CompanyName = 'Your Company'

    # Авторские права (опционально)
    # Copyright = '(c) 2024 Your Company. All rights reserved.'

    # --- ОБНОВЛЕНО: Описание модуля ---
    Description = 'Общий модуль для Гибридного Агента системы мониторинга Status Monitor. Содержит диспетчер проверок (Invoke-StatusMonitorCheck), функцию форматирования результата (New-CheckResultObject), универсальную функцию проверки критериев (Test-SuccessCriteria) и скрипты для конкретных проверок в папке Checks.'

    # Минимально необходимая версия PowerShell
    PowerShellVersion = '5.1'

    # Зависимости от других модулей (раскомментировать и добавить при необходимости)
    # Например, если бы использовались командлеты ActiveDirectory:
    # RequiredModules = @{ ModuleName = 'ActiveDirectory'; RequiredVersion = '1.0.0.0' }
    # Для SQL проверок модуль SqlServer ДОЛЖЕН БЫТЬ установлен на машине агента,
    # но его не обязательно указывать здесь, т.к. он используется ВНУТРИ Check-*.ps1
    # RequiredModules = @()

    # Основной файл модуля .psm1
    RootModule = 'StatusMonitorAgentUtils.psm1'

    # --- ПОДТВЕРЖДЕНО: Экспортируемые функции ---
    # Список функций, видимых снаружи модуля.
    # Test-SuccessCriteria и Compare-Values экспортируются для возможности
    # их потенциального использования в более сложных сценариях или тестах.
    FunctionsToExport = @(
        'Invoke-StatusMonitorCheck', # Диспетчер для агента
        'New-CheckResultObject',     # Стандартизация результата (для Checks/*.ps1)
        'Test-SuccessCriteria',      # Универсальная проверка критериев
        'Compare-Values'             # Вспомогательная для Test-SuccessCriteria
        # Test-ArrayCriteria является приватной и не экспортируется
    )

    # Список командлетов, экспортируемых модулем (у нас таких нет).
    CmdletsToExport = @()

    # Список переменных, экспортируемых модулем (не рекомендуется).
    VariablesToExport = @() # Явно указываем пустой список

    # Список псевдонимов (aliases), экспортируемых модулем.
    AliasesToExport = @()

    # Остальные поля манифеста (оставлены без изменений)
    # ModuleList = @()
    # ScriptsToProcess = @()
    # TypesToProcess = @()
    # FormatsToProcess = @()
    # RequiredAssemblies = @()
    # FileList = @()
    # PrivateData = @{}
    # HelpInfoURI = ''
    # DefaultCommandPrefix = ''
}