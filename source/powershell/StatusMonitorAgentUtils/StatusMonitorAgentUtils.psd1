# F:\status\source\powershell\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1
# Манифест PowerShell модуля для общих утилит агентов Status Monitor

@{

    # Версия модуля. Увеличивайте при внесении изменений в экспортируемые функции или общую структуру.
    # Версия 1.1.0: Удалена функция/фильтр Get-OrElse.
    ModuleVersion = '1.1.0'

    # Уникальный идентификатор модуля (GUID). Генерируется один раз.
    # Используйте `[guid]::NewGuid()` для генерации, если это новый модуль.
    GUID = 'e5fa7cfe-608d-47c9-898d-215bb6b0ef0d' # Оставляем существующий

    # Автор модуля
    Author = 'User & AI'

    # Компания (опционально)
    # CompanyName = 'Your Company'

    # Авторские права (опционально)
    # Copyright = '(c) 2024 Your Company. All rights reserved.'

    # Описание назначения модуля
    Description = 'Общий модуль для агентов системы мониторинга Status Monitor. Содержит диспетчер выполнения проверок (Invoke-StatusMonitorCheck), функцию форматирования результата (New-CheckResultObject) и скрипты для конкретных проверок в папке Checks.'

    # Минимально необходимая версия PowerShell для работы модуля
    PowerShellVersion = '5.1'

    # Зависимости от других модулей PowerShell (если есть).
    # Например, если бы проверки SQL были прямо в psm1, добавили бы 'SqlServer'.
    # RequiredModules = @()

    # Указываем основной файл модуля, содержащий скрипты экспортируемых функций.
    RootModule = 'StatusMonitorAgentUtils.psm1'

    # Список функций, которые будут видны и доступны для вызова ИЗВНЕ этого модуля
    # после его импорта (Import-Module). Все остальные функции в .psm1 будут приватными.
    FunctionsToExport = @(
        # Основная функция-диспетчер для запуска проверок агентами.
        'Invoke-StatusMonitorCheck'

        # Вспомогательная функция для создания стандартизированного объекта результата
        # проверки. Используется внутри скриптов Checks/*.ps1.
        'New-CheckResultObject',

        'Test-SuccessCriteria',
        'Compare-Values'
        # Get-OrElse была УДАЛЕНА
    )

    # Список командлетов, экспортируемых модулем (у нас таких нет).
    CmdletsToExport = @()

    # Список переменных, экспортируемых модулем (обычно не рекомендуется).
    VariablesToExport = '*' # Можно заменить на @() для чистоты

    # Список псевдонимов (aliases), экспортируемых модулем (у нас таких нет).
    AliasesToExport = @()

    # Список всех файлов .ps1, .psm1, которые являются частью модуля
    # (PowerShell попытается загрузить их все при импорте).
    # Указание RootModule обычно достаточно, если нет сложной структуры.
    # ModuleList = @()

    # Файлы со скриптами, которые нужно выполнить при импорте модуля (.ps1).
    # ScriptsToProcess = @()

    # Файлы типов (.types.ps1xml) и форматов (.format.ps1xml).
    # TypesToProcess = @()
    # FormatsToProcess = @()

    # Необходимые сборки .NET (если используются напрямую).
    # RequiredAssemblies = @()

    # Список файлов модуля (информационно).
    # FileList = @()

    # Другие метаданные...
    # PrivateData = @{}
    # HelpInfoURI = ''
    # DefaultCommandPrefix = ''
}