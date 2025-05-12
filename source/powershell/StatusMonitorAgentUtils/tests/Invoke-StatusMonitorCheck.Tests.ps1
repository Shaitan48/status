# Invoke-StatusMonitorCheck.Tests.ps1 (v8 - ���������� $PSScriptRoot � BeforeAll)

# --- ���� ���������� ---
# BeforeAll ����������� ���� ��� ����� ����� ������� � ���� Describe �����.
BeforeAll {
    # ���������� $PSScriptRoot, ������� ��������� �� ���������� �������� ����� ����� (.Tests.ps1)
    Write-Host "INFO: PSScriptRoot ��������� ���: $PSScriptRoot" # ��� ��� �������
    if (-not $PSScriptRoot) {
        throw "�� ������� ���������� ���������� ����� (\$PSScriptRoot). ���������� ����� ������."
    }

    # ������ ���� � ��������� ������������ ����� tests
    $moduleManifestRelativePath = '..\StatusMonitorAgentUtils.psd1'
    $moduleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath $moduleManifestRelativePath

    # ���������� Resolve-Path ��� ��������� ������� ���� � �������� �������������
    try {
        $resolvedModulePath = Resolve-Path -Path $moduleManifestPath -ErrorAction Stop
        Write-Host "INFO: ������ ���� � ��������� ������: $resolvedModulePath"
    } catch {
        # ��������� ����� ��������� ��������� �� ������
        Write-Error "�� ������� �����/���������� ���� � ��������� ������ '$moduleManifestPath'. ���������, ��� ��������� ����� �����: tests/ ��������� ������ StatusMonitorAgentUtils/. ������ Resolve-Path: $($_.Exception.Message)"
        throw "�� ������� ����� ������ ��� ������������." # ��������� ����������
    }

    # ����������� ������ �� ������� ����
    Write-Host "INFO: �������� ������ �� $resolvedModulePath ��� ������..."
    Remove-Module StatusMonitorAgentUtils -Force -ErrorAction SilentlyContinue
    Import-Module $resolvedModulePath -Force
    Write-Host "INFO: ������ StatusMonitorAgentUtils ��������."
}

# --- ����� ---
Describe 'Invoke-StatusMonitorCheck (��������� ��������)' {

    # --- Mocking (��� ���������) ---
    Mock New-CheckResultObject { Param($IsAvailable, $CheckSuccess, $Details, $ErrorMessage)
        return @{ Mocked = $true; IsAvailable = $IsAvailable; CheckSuccess = $CheckSuccess; ErrorMessage = $ErrorMessage; Details = $Details }
    } -ModuleName StatusMonitorAgentUtils

    Mock Test-Path { Param($Path)
        if ($Path -like "*Checks\Check-*.ps1") { return $true }
        return Test-Path @using:PSBoundParameters
    } -ModuleName Microsoft.PowerShell.Management

    Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
        Write-Verbose "��� Invoke-CheckScript: ���������� ����� '$ScriptPath'"
        return @{ IsAvailable = $true; CheckSuccess = $true; Timestamp = (Get-Date).ToUniversalTime().ToString("o"); Details = @{ CalledScript = $ScriptPath; ParamsPassed = $ParametersForScript }; ErrorMessage = $null }
    } -ModuleName StatusMonitorAgentUtils

    # --- �������� ������ (��� ���������) ---
    $baseAssignment = @{
        assignment_id = 101; node_id = 1; node_name = 'TestNode'; ip_address = '127.0.0.1'
        parameters = @{ timeout = 500 }; success_criteria = @{ max_rtt_ms = 100 }
    }

    # --- ����� (��� ���������) ---

    It '������ �������� Invoke-CheckScript ��� ������ PING � ����������� �����������' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'PING'
        Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
            $ScriptPath | Should -EndWith '\Checks\Check-PING.ps1'
            $ParametersForScript | Should -Not -BeNull
            $ParametersForScript.TargetIP | Should -Be $using:assignment.ip_address
            $ParametersForScript.Parameters | Should -Be $using:assignment.parameters
            $ParametersForScript.SuccessCriteria | Should -Be $using:assignment.success_criteria
            $ParametersForScript.NodeName | Should -Be $using:assignment.node_name
            return @{ IsAvailable = $true; CheckSuccess = $true; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=@{mocked_call_for='PING'}; ErrorMessage=$null }
        } -ModuleName StatusMonitorAgentUtils -Verifiable
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        $result.IsAvailable | Should -BeTrue
        $result.Details.mocked_call_for | Should -Be 'PING'
        Should -Invoke Invoke-CheckScript -Times 1 -ModuleName StatusMonitorAgentUtils
    }

    It '������ �������� Invoke-CheckScript ��� SERVICE_STATUS � ����������� �����������' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'SERVICE_STATUS'
        $assignment.parameters = @{ service_name = 'Spooler' }
        $assignment.success_criteria = @{ status = 'Running' }
        Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
            $ScriptPath | Should -EndWith '\Checks\Check-SERVICE_STATUS.ps1'
            $ParametersForScript.TargetIP | Should -Be $using:assignment.ip_address
            $ParametersForScript.Parameters.service_name | Should -Be 'Spooler'
            $ParametersForScript.SuccessCriteria.status | Should -Be 'Running'
            return @{ IsAvailable = $true; CheckSuccess = $true; Timestamp=(Get-Date).ToUniversalTime().ToString("o"); Details=@{mocked_call_for='SERVICE'}; ErrorMessage=$null }
        } -ModuleName StatusMonitorAgentUtils -Verifiable
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        $result.IsAvailable | Should -BeTrue
        $result.Details.mocked_call_for | Should -Be 'SERVICE'
        Should -Invoke Invoke-CheckScript -Times 1 -ModuleName StatusMonitorAgentUtils
    }

    It '������ ���������� ������, ���� ������ �������� �� ������ (Test-Path ������ false)' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'NON_EXISTENT_METHOD'
        Mock Test-Path { Param($Path)
            if ($Path -like "*Check-NON_EXISTENT_METHOD.ps1") { return $false }
            return $true
        } -ModuleName Microsoft.PowerShell.Management -Verifiable
        Mock Invoke-CheckScript { throw "Invoke-CheckScript �� ������ ��� ���������!" } -ModuleName StatusMonitorAgentUtils -Verifiable -Scope It
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        Should -Invoke Test-Path -Times 1 -ModuleName Microsoft.PowerShell.Management
        Should -Invoke Invoke-CheckScript -Times 0 -ModuleName StatusMonitorAgentUtils
        $result.Mocked | Should -BeTrue
        $result.IsAvailable | Should -BeFalse
        $result.ErrorMessage | Should -Contain '�� ������'
        $result.ErrorMessage | Should -Contain 'Check-NON_EXISTENT_METHOD.ps1'
    }

    It '������ ���������� ������, ���� ����� �� ������ � �������' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.PSObject.Properties.Remove('method_name')
        Mock Invoke-CheckScript { throw "�� ������ ���� ����� �� ������ �������" } -ModuleName StatusMonitorAgentUtils -Verifiable -Scope It
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        Should -Invoke Invoke-CheckScript -Times 0 -ModuleName StatusMonitorAgentUtils
        $result.Mocked | Should -BeTrue
        $result.IsAvailable | Should -BeFalse
        $result.ErrorMessage | Should -Contain '������������ ������ �������'
    }

     It '������ ���������� ������, ���� Invoke-CheckScript ����������� ����������' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'SCRIPT_WITH_ERROR'
        $errorMessageFromInvoke = "����������� ������ ��� ������ �������"
        Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
            if ($ScriptPath -like "*Check-SCRIPT_WITH_ERROR.ps1") {
                throw $errorMessageFromInvoke
            }
        } -ModuleName StatusMonitorAgentUtils -Verifiable
        Mock Test-Path { return $true } -ModuleName Microsoft.PowerShell.Management
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        Should -Invoke Invoke-CheckScript -Times 1 -ModuleName StatusMonitorAgentUtils
        $result.Mocked | Should -BeTrue
        $result.IsAvailable | Should -BeFalse
        $result.ErrorMessage | Should -Contain $errorMessageFromInvoke
        $result.ErrorMessage | Should -Contain '������ ���������� ������� ��������'
    }

     It '������ ���������� ������, ���� Invoke-CheckScript ������ ������������ ������' {
        $assignment = $script:baseAssignment.PSObject.Copy()
        $assignment.method_name = 'BAD_FORMAT_SCRIPT'
        Mock Invoke-CheckScript { Param($ScriptPath, $ParametersForScript)
            if ($ScriptPath -like "*Check-BAD_FORMAT_SCRIPT.ps1") {
                return "��� ������ ������, � �� ���-�������"
            }
        } -ModuleName StatusMonitorAgentUtils -Verifiable
        Mock Test-Path { return $true } -ModuleName Microsoft.PowerShell.Management
        $result = Invoke-StatusMonitorCheck -Assignment ([PSCustomObject]$assignment)
        Should -Invoke Invoke-CheckScript -Times 1 -ModuleName StatusMonitorAgentUtils
        $result.Mocked | Should -BeTrue
        $result.IsAvailable | Should -BeFalse
        $result.ErrorMessage | Should -Contain '������ ������������ ������'
    }
}