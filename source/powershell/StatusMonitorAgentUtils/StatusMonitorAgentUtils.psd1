# powershell\StatusMonitorAgentUtils\StatusMonitorAgentUtils.psd1
# �������� PowerShell ������ ��� ����� ������ ������� Status Monitor

@{

    # ������ ������. ������������ ��� �������� ���������.
    ModuleVersion = '1.0.0'
    
    # ���������� ������������� ������ (GUID).
    # �����: �������� ���� GUID �� �����, ��������������� ��������: [guid]::NewGuid()
    GUID = 'e5fa7cfe-608d-47c9-898d-215bb6b0ef0d'
    
    # ����� ������
    Author = 'User & AI'
    
    # �������� (�����������)
    # CompanyName = 'Unknown'
    
    # ��������� ����� (�����������)
    # Copyright = '(c) 2024 User & AI. All rights reserved.'
    
    # �������� ���������� ������
    Description = '����� ������ ��� ������� ������� ����������� Status Monitor, ���������� ������� ���������� �������� � ������ �������.'
    
    # ���������� ����������� ������ PowerShell ��� ������ ������
    PowerShellVersion = '5.1'
    
    # ������ .NET Framework (CLR), ���� ���� ����������� ���������� (������ �� �����)
    # DotNetFrameworkVersion = '4.5'
    
    # ������ PowerShell Host (�����������)
    # PowerShellHostName = ''
    # PowerShellHostVersion = ''
    
    # ����������� ������ .NET (���� ������������)
    # RequiredAssemblies = @()
    
    # ����� ��������, ���������� � ������ (������ RootModule)
    # ScriptsToProcess = @()
    
    # ���� ������, �������������� ������� ���������� ������ (���� ����)
    # TypesToProcess = @()
    # FormatsToProcess = @()
    
    # ������, �� ������� ������� ���� ������
    # RequiredModules = @()
    
    # ��������� �������� ���� ������, ���������� �������
    RootModule = 'StatusMonitorAgentUtils.psm1'
    
    # ������, ������� ����� ��������� ��� ������� ����� ������
    # NestedModules = @()
    
    # ������ �������, ������� ����� �������� ����� ������� ������
    FunctionsToExport = @(
        'Invoke-StatusMonitorCheck' # �������� ������� ���������� ��������
        # �������� ���� ������ �������������� �������, ���� ��� ��������
    )
    
    # ������ �����������, �������������� ������� (� ��� �� ���)
    CmdletsToExport = @()
    
    # ������ ����������, �������������� ������� (������ �� ������������)
    VariablesToExport = '*' # ������������ ��� (�� ������ ������)
    
    # ������ ����������� (aliases), �������������� �������
    AliasesToExport = @()
    
    # ������ ���� ������ (�������, �����������, �����������), ������� ������������� ������
    # ����� �������� ������, ���� ������������ FunctionsToExport, CmdletsToExport � �.�.
    # CommandList = @()
    
    # �������� ������ ������, ������� ������ ����� ������������ (��������, ��� �����������)
    # PrivateData = @{}
    
    # ������ �� ������ (�����������)
    # HelpInfoURI = ''
    
    # ������ ������ (�����������)
    # IconUri = ''
    
    # ���� ��� ������ ������
    # Tags = @('Monitoring', 'Agent', 'Utility')
    
    # �������� (�����������)
    # LicenseUri = ''
    
    # ������ �� ������ (�����������)
    # ProjectUri = ''
    
    # ������� � ������ (�����������)
    # ReleaseNotes = ''
    
    }