$sourcePath = "F:\status\source\postgres"
$outputFile = "F:\status\combined_postgres.txt"

# Удалим файл, если уже существует
if (Test-Path $outputFile) {
    Remove-Item $outputFile
}

# Функция для определения кодировки файла
function Get-FileEncoding {
    param (
        [string]$FilePath
    )
    
    # Если файл .ps1, считаем UTF-8 с BOM, иначе просто UTF-8
    if ([System.IO.Path]::GetExtension($FilePath).ToLower() -eq '.ps1') {
        return 'UTF8 with BOM'
    }
    return 'UTF8'
}

# Получаем все нужные файлы, исключая .log, .png, .svg, .ico и папки __pycache__
$files = Get-ChildItem -Path $sourcePath -Recurse -File |
    Where-Object {
        $_.Extension -notin '.log', '.png', '.rpu', '.7z', '.svg', '.ico' -and
        $_.FullName -notmatch '__pycache__|.venv|.pytest_cache'
    }

# Собираем информацию о файлах и их кодировках
$fileInfo = @()
foreach ($file in $files) {
    try {
        $encoding = Get-FileEncoding -FilePath $file.FullName
        $fileInfo += [PSCustomObject]@{
            FullPath = $file.FullName
            Encoding = $encoding
        }
    }
    catch {
        Write-Warning "Не удалось определить кодировку для файла $($file.FullName): $_"
    }
}

# Формируем список файлов
$fileList = "=== СПИСОК ФАЙЛОВ ===`n"
$fileList += ($fileInfo | ForEach-Object { "Файл: $($_.FullPath) (Кодировка: $($_.Encoding))" }) -join "`n"
$fileList += "`n`n"

# Формируем дерево каталогов
$tree = "=== ДЕРЕВО КАТАЛОГОВ ===`n"
$directories = $fileInfo.FullPath | Split-Path -Parent | Sort-Object -Unique
foreach ($dir in $directories) {
    $tree += "$dir`n"
    $dirFiles = $fileInfo | Where-Object { $_.FullPath.StartsWith($dir) }
    foreach ($file in $dirFiles) {
        $relativePath = $file.FullPath.Substring($dir.Length + 1)
        $tree += "  |-- $relativePath (Кодировка: $($file.Encoding))`n"
    }
}
$tree += "`n"

# Записываем список и дерево в начало файла
$fileList | Out-File -FilePath $outputFile -Encoding UTF8
$tree | Out-File -FilePath $outputFile -Append -Encoding UTF8

# Обрабатываем содержимое файлов
foreach ($file in $files) {
    try {
        # Определяем кодировку файла
        $encoding = Get-FileEncoding -FilePath $file.FullName
        
        # Метка начала
        "==== BEGIN FILE: $($file.FullName) ====" | Out-File -FilePath $outputFile -Append -Encoding UTF8

        # Читаем содержимое файла (все файлы в UTF-8, с BOM или без)
        Get-Content -Path $file.FullName -Encoding UTF8 | Out-File -FilePath $outputFile -Append -Encoding UTF8

        # Метка конца
        "==== END FILE: $($file.FullName) ====" | Out-File -FilePath $outputFile -Append -Encoding UTF8

        # Пустая строка между файлами
        "" | Out-File -FilePath $outputFile -Append -Encoding UTF8
    }
    catch {
        Write-Warning "Ошибка при обработке файла $($file.FullName): $_"
    }
}

# Открытие итогового файла
Start-Process "code" $outputFile