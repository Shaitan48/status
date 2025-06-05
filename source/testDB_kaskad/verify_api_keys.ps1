# Скрипт для проверки хешей API ключей
$ErrorActionPreference = "Stop"

function Get-SHA256Hash {
    param([string]$InputString)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha256.ComputeHash($bytes)
    return [System.BitConverter]::ToString($hash).Replace("-", "").ToLower()
}

# Тестовые ключи
$testKeys = @{
    "test_agent_key_for_9999" = "8f7d3b2c1a9e6f4d5c8b7a2e1f9d6c5b4a3e2d1c8b7a6f5e4d3c2b1a9e8f7d6c5b4"
    "test_loader_key" = "9e8d7c6b5a4f3e2d1c8b7a6f5e4d3c2b1a9e8f7d6c5b4a3e2d1c8b7a6f5e4d3c2b1"
    "test_configurator_key_for_9999" = "7d6c5b4a3f2e1d8c7b6a5f4e3d2c1b9a8f7e6d5c4b3a2e1d8c7b6a5f4e3d2c1b9a8"
}

Write-Host "Проверка хешей API ключей..."
foreach ($key in $testKeys.GetEnumerator()) {
    $calculatedHash = Get-SHA256Hash -InputString $key.Key
    $storedHash = $key.Value
    $isValid = $calculatedHash -eq $storedHash
    Write-Host "Ключ: $($key.Key)"
    Write-Host "  Ожидаемый хеш: $storedHash"
    Write-Host "  Вычисленный хеш: $calculatedHash"
    Write-Host "  Валидность: $isValid"
    Write-Host ""
} 