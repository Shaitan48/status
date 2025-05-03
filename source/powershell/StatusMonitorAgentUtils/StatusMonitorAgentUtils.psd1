# powershell\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1
# Манифест PowerShell модуля для общих утилит агентов Status Monitor

@{

    # Версия модуля. Увеличивайте при внесении изменений.
    ModuleVersion = '1.0.0'
    
    # Уникальный идентификатор модуля (GUID).
    # ВАЖНО: Замените этот GUID на новый, сгенерированный командой: [guid]::NewGuid()
    GUID = 'e5fa7cfe-608d-47c9-898d-215bb6b0ef0d'
    
    # Автор модуля
    Author = 'User & AI'
    
    # Компания (опционально)
    # CompanyName = 'Unknown'
    
    # Авторские права (опционально)
    # Copyright = '(c) 2024 User & AI. All rights reserved.'
    
    # Описание назначения модуля
    Description = 'Общий модуль для агентов системы мониторинга Status Monitor, содержащий функции выполнения проверок и другие утилиты.'
    
    # Минимально необходимая версия PowerShell для работы модуля
    PowerShellVersion = '5.1'
    
    # Версия .NET Framework (CLR), если есть специфичные требования (обычно не нужно)
    # DotNetFrameworkVersion = '4.5'
    
    # Версия PowerShell Host (опционально)
    # PowerShellHostName = ''
    # PowerShellHostVersion = ''
    
    # Необходимые сборки .NET (если используются)
    # RequiredAssemblies = @()
    
    # Файлы скриптов, включаемые в модуль (помимо RootModule)
    # ScriptsToProcess = @()
    
    # Типы данных, форматирование которых определяет модуль (если есть)
    # TypesToProcess = @()
    # FormatsToProcess = @()
    
    # Модули, от которых зависит этот модуль
    # RequiredModules = @()
    
    # Указываем основной файл модуля, содержащий скрипты
    RootModule = 'StatusMonitorAgentUtils.psm1'
    
    # Модули, которые будут загружены при импорте этого модуля
    # NestedModules = @()
    
    # Список функций, которые будут доступны после импорта модуля
    FunctionsToExport = @(
        'Invoke-StatusMonitorCheck' # Основная функция выполнения проверок
        # Добавьте сюда другие экспортируемые функции, если они появятся
    )
    
    # Список командлетов, экспортируемых модулем (у нас их нет)
    CmdletsToExport = @()
    
    # Список переменных, экспортируемых модулем (обычно не используется)
    VariablesToExport = '*' # Экспортируем все (на всякий случай)
    
    # Список псевдонимов (aliases), экспортируемых модулем
    AliasesToExport = @()
    
    # Список всех команд (функций, командлетов, псевдонимов), которые предоставляет модуль
    # Можно оставить пустым, если используется FunctionsToExport, CmdletsToExport и т.д.
    # CommandList = @()
    
    # Закрытый список данных, которые модуль может использовать (например, для локализации)
    # PrivateData = @{}
    
    # Помощь по модулю (опционально)
    # HelpInfoURI = ''
    
    # Иконка модуля (опционально)
    # IconUri = ''
    
    # Теги для поиска модуля
    # Tags = @('Monitoring', 'Agent', 'Utility')
    
    # Лицензия (опционально)
    # LicenseUri = ''
    
    # Ссылка на проект (опционально)
    # ProjectUri = ''
    
    # Заметки о релизе (опционально)
    # ReleaseNotes = ''
    
    }