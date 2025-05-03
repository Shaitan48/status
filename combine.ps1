$sourcePath = "F:\status\source"
$outputFile = "F:\status\combined.txt"
$encoding = [System.Text.Encoding]::UTF8

# Удалим файл, если уже существует
if (Test-Path $outputFile) {
    Remove-Item $outputFile
}

# Получаем все нужные файлы, исключая .log, .png, .svg, .ico и папки __pycache__
$files = Get-ChildItem -Path $sourcePath -Recurse -File |
    Where-Object {
        $_.Extension -notin '.log', '.png', '.rpu','.7z', '.svg', '.ico' -and
        $_.FullName -notmatch '__pycache__'
    }

foreach ($file in $files) {
    # Метка начала
    "==== BEGIN FILE: $($file.FullName) ====" | Out-File -FilePath $outputFile -Append -Encoding UTF8

    # Содержимое файла
    Get-Content -Path $file.FullName -Encoding UTF8 | Out-File -FilePath $outputFile -Append -Encoding UTF8

    # Метка конца
    "==== END FILE: $($file.FullName) ====" | Out-File -FilePath $outputFile -Append -Encoding UTF8

    # Пустая строка между файлами
    "" | Out-File -FilePath $outputFile -Append -Encoding UTF8
}

# Открытие итогового файла
Start-Process "code" $outputFile
