# F:\status\source\powershell\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1
# Манифест PowerShell модуля для общих утилит агентов Status Monitor

@{

    # --- ОБНОВЛЕНО: Версия модуля ---
    # Версия 2.1.3: Соответствует последним изменениям в .psm1 (комментарии и логика для pipeline).
    ModuleVersion = '2.1.3'

    # Уникальный идентификатор модуля (GUID). Не меняется.
    GUID = 'e5fa7cfe-608d-47c9-898d-215bb6b0ef0d'

    # Автор модуля
    Author = 'User & AI'

    # Компания (опционально)
    # CompanyName = 'Your Company'

    # Авторские права (опционально)
    # Copyright = '(c) 2024 Your Company. All rights reserved.'

    # --- ОБНОВЛЕНО: Описание модуля ---
    Description = 'Общий модуль для Гибридного Агента системы мониторинга Status Monitor (v5.x+). Содержит диспетчер для выполнения одного шага pipeline (Invoke-StatusMonitorCheck), функцию форматирования результата шага (New-CheckResultObject), универсальную функцию проверки критериев (Test-SuccessCriteria) и скрипты для конкретных типов шагов в папке Checks.'

    # Минимально необходимая версия PowerShell
    PowerShellVersion = '5.1'

    # Зависимости от других модулей (раскомментировать и добавить при необходимости)
    # RequiredModules = @()

    # Основной файл модуля .psm1
    RootModule = 'StatusMonitorAgentUtils.psm1'

    # --- ПОДТВЕРЖДЕНО: Экспортируемые функции ---
    # Список функций, видимых снаружи модуля.
    # Invoke-StatusMonitorCheck теперь используется для выполнения ОДНОГО ШАГА pipeline.
    FunctionsToExport = @(
        'Invoke-StatusMonitorCheck', # Диспетчер для выполнения шага pipeline
        'New-CheckResultObject',     # Стандартизация результата (для Checks/*.ps1)
        'Test-SuccessCriteria',      # Универсальная проверка критериев
        'Compare-Values'             # Вспомогательная для Test-SuccessCriteria
    )

    # Список командлетов, экспортируемых модулем (у нас таких нет).
    CmdletsToExport = @()

    # Список переменных, экспортируемых модулем (не рекомендуется).
    VariablesToExport = @()

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