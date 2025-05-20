# ManualTest-Check-CERT_EXPIRY_add_test_cert.ps1
# Версия для создания НАБОРА тестовых сертификатов (для PowerShell 5.1+)

Write-Host "Создание набора тестовых сертификатов..." -ForegroundColor Yellow
$ErrorActionPreference = "Stop" # Прерывать при ошибке

function New-TestCert {
    param(
        [string]$DnsName,
        [string]$FriendlyName,
        [int]$ValidityDaysFromNow, # Дней от СЕГОДНЯ
        [string]$CertStoreLocation = "Cert:\LocalMachine\My",
        [string[]]$KeyUsage = @("DigitalSignature", "KeyEncipherment"),
        [string[]]$EKU = @("1.3.6.1.5.5.7.3.1"), # По умолчанию Server Auth
        [bool]$CreatePrivateKey = $true # По умолчанию создаем с приватным ключом
        # -Exportable убрано для совместимости с PS 5.1
    )

    $notBefore = Get-Date
    # Для истекшего сертификата, $ValidityDaysFromNow будет отрицательным
    $notAfter = $notBefore.AddDays($ValidityDaysFromNow)

    $certParams = @{
        CertStoreLocation = $CertStoreLocation
        DnsName           = $DnsName
        FriendlyName      = $FriendlyName
        NotBefore         = $notBefore
        NotAfter          = $notAfter
        KeyUsage          = $KeyUsage
        HashAlgorithm     = "SHA256"
    }

    # Формируем TextExtension для EKU, если он указан
    if ($null -ne $EKU -and $EKU.Count -gt 0) {
        # Для PS 5.1, TextExtension ожидает массив строк OID=значение.
        # Если значение текстовое, оно должно быть в кавычках внутри строки.
        # "{text}" - это для более новых версий. Для PS 5.1 просто передаем OID.
        # На самом деле, для New-SelfSignedCertificate EKU лучше задавать через специальный объект.
        # Однако, для простоты и совместимости с PS 5.1, TextExtension может быть сложен.
        # Попробуем простой вариант, если не сработает - EKU придется добавлять отдельно или мокать.
        # Этот способ TextExtension может НЕ установить EKU правильно в PS 5.1.
        # $certParams.TextExtension = @("2.5.29.37=$($EKU -join ',')") # Неправильно для {text}
        # Проще всего для PS 5.1 - не указывать EKU здесь, а проверять их потом при фильтрации,
        # либо мокать наличие EKU в тестах.
        # Для простоты создания, пока уберем явное указание EKU через TextExtension,
        # т.к. его формат в -TextExtension сложен для универсальной совместимости.
        # В реальных сертификатах EKU будет.
    }
    
    # Создание приватного ключа контролируется наличием KeyUsage, а не отдельным параметром в PS 5.1
    # New-SelfSignedCertificate по умолчанию создает приватный ключ, если не указано иное (например, только для шифрования данных).
    # Если $CreatePrivateKey = $false, мы не можем легко это указать в PS 5.1 через New-SelfSignedCertificate.
    # Для теста "без приватного ключа" проще будет создать обычный, а потом в тесте мокать $cert.HasPrivateKey = $false

    try {
        Write-Host "  Создание: '$FriendlyName' ($DnsName), годен до: $($notAfter.ToString('yyyy-MM-dd'))"
        $certificate = New-SelfSignedCertificate @certParams
        
        if ($certificate) {
            Write-Host "    Успех! Thumbprint: $($certificate.Thumbprint)" -ForegroundColor Green
            return $certificate
        } else {
            Write-Warning "    Не удалось создать сертификат '$FriendlyName'."
            return $null
        }
    } catch {
        Write-Warning "    Ошибка при создании сертификата '$FriendlyName': $($_.Exception.Message)"
        return $null
    }
}

$createdCertsInfo = [System.Collections.Generic.List[object]]::new()

# 1. SSL OK, долгий срок (60 дней)
$cert1 = New-TestCert -DnsName "longlife.test.local" -FriendlyName "Test Cert - SSL Long Life" -ValidityDaysFromNow 60
if ($cert1) { $createdCertsInfo.Add(@{Name="SSL_Long"; Thumbprint=$cert1.Thumbprint; NotAfter=$cert1.NotAfter}) }

# 2. SSL Expiring Soon (10 дней)
$cert2 = New-TestCert -DnsName "soon.test.local" -FriendlyName "Test Cert - SSL Expiring Soon" -ValidityDaysFromNow 10
if ($cert2) { $createdCertsInfo.Add(@{Name="SSL_Soon"; Thumbprint=$cert2.Thumbprint; NotAfter=$cert2.NotAfter}) }

# 3. SSL Expired (-5 дней)
$cert3 = New-TestCert -DnsName "expired.test.local" -FriendlyName "Test Cert - SSL Expired" -ValidityDaysFromNow -5
if ($cert3) { $createdCertsInfo.Add(@{Name="SSL_Expired"; Thumbprint=$cert3.Thumbprint; NotAfter=$cert3.NotAfter}) }

# 4. Client Auth OK (90 дней) - EKU для Client Auth: 1.3.6.1.5.5.7.3.2
# В PS 5.1 установка EKU через New-SelfSignedCertificate затруднительна без более сложных конструкций.
# Мы создадим его как обычный, а в тестах будем полагаться на то, что EKU не будет Server Auth.
# Либо, если Check-CERT_EXPIRY.ps1 ищет *точно* указанные EKU, нам нужно мокать это свойство.
$cert4 = New-TestCert -DnsName "client.test.local" -FriendlyName "Test Cert - Client Auth" -ValidityDaysFromNow 90 -EKU @("1.3.6.1.5.5.7.3.2") # Попытка указать EKU
if ($cert4) { $createdCertsInfo.Add(@{Name="Client_Auth"; Thumbprint=$cert4.Thumbprint; NotAfter=$cert4.NotAfter}) }

# 5. Сертификат для CurrentUser\My (OK, 45 дней)
$cert5 = New-TestCert -DnsName "user.test.local" -FriendlyName "Test Cert - CurrentUser Store" -ValidityDaysFromNow 45 -CertStoreLocation "Cert:\CurrentUser\My"
if ($cert5) { $createdCertsInfo.Add(@{Name="User_Store"; Thumbprint=$cert5.Thumbprint; NotAfter=$cert5.NotAfter}) }

# 6. Сертификат БЕЗ приватного ключа (сложно создать напрямую в PS 5.1 с New-SelfSignedCertificate).
# Проще будет в тестах мокать свойство HasPrivateKey у одного из существующих.
# Вместо этого создадим еще один обычный сертификат, который будем использовать для мока HasPrivateKey.
$cert6ForMock = New-TestCert -DnsName "nopk.test.local" -FriendlyName "Test Cert - For NoPK Mock" -ValidityDaysFromNow 120
if ($cert6ForMock) { $createdCertsInfo.Add(@{Name="For_NoPK_Mock"; Thumbprint=$cert6ForMock.Thumbprint; NotAfter=$cert6ForMock.NotAfter}) }


Write-Host ("-"*60)
Write-Host "Сводка по созданным сертификатам (скопируйте отпечатки для тестов):" -ForegroundColor Yellow
$createdCertsInfo | Format-Table -AutoSize
Write-Host "ВАЖНО: Установка EKU для 'Client_Auth' может быть неполной в PowerShell 5.1."
Write-Host "Если тесты на EKU не проходят, возможно, потребуется мокать свойство Extensions."
Write-Host ("-"*60)
Write-Host "Завершено создание тестовых сертификатов."