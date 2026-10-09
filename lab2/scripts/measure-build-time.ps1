<#
    замер времени пересборки после правки одной строки кода, для windows
    запуск из корня репозитория:
        powershell -ExecutionPolicy Bypass -File lab2/scripts/measure-build-time.ps1
    вывод дублируется в lab2/docs/build-timing.txt
#>
[CmdletBinding()]
param(
    [string]$OutFile = "lab2/docs/build-timing.txt"
)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
Start-Transcript -Path $OutFile -Force | Out-Null

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "docker недоступен, запусти Docker Desktop" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 2
}

# если внутри функции глушить вывод docker через *> $null, то вместе с ним
# глушится и возвращаемое значение, поэтому из функции приходил null
$script:lastSeconds = 0

function Build-Timed {
    param([string]$Tag, [string]$Dockerfile)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    docker build -q -f $Dockerfile -t $Tag . > $null 2>&1
    $sw.Stop()
    $script:lastSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    if ($LASTEXITCODE -ne 0) { $script:lastSeconds = -1 }
}

Write-Host "время пересборки после правки одной строки кода"
Write-Host "дата: $(Get-Date -Format o)"
Write-Host "docker: $(docker --version)"
Write-Host ""

Write-Host "=== Шаг 1. Холодная сборка обоих образов, --no-cache ==="
docker build --no-cache -f lab2/bad/Dockerfile.backend -t notes-backend:bad . > $null 2>&1
Write-Host $(if ($LASTEXITCODE -eq 0) { "  notes-backend:bad собран" } else { "  notes-backend:bad НЕ собран" })
docker build --no-cache -f lab2/good/Dockerfile.backend -t notes-backend:good . > $null 2>&1
Write-Host $(if ($LASTEXITCODE -eq 0) { "  notes-backend:good собран" } else { "  notes-backend:good НЕ собран" })
Write-Host ""

Write-Host "=== Шаг 2. Пересборка без правок, все должно взяться из кеша ==="
Build-Timed -Tag 'notes-backend:bad' -Dockerfile 'lab2/bad/Dockerfile.backend'
$warmBad = $script:lastSeconds
Write-Host "  плохой:  $warmBad с"
Build-Timed -Tag 'notes-backend:good' -Dockerfile 'lab2/good/Dockerfile.backend'
$warmGood = $script:lastSeconds
Write-Host "  хороший: $warmGood с"
Write-Host ""

Write-Host "=== Шаг 3. Меняем одну строку кода и пересобираем ==="
$appFile = 'backend/app/main.py'
$bak = "$appFile.lab2bak"
Copy-Item $appFile $bak -Force
Add-Content -Path $appFile -Value "`n# lab2: метка для замера кеша слоев $(Get-Date -UFormat %s)"
Write-Host "  изменен файл: $appFile"
Write-Host ""

Build-Timed -Tag 'notes-backend:bad' -Dockerfile 'lab2/bad/Dockerfile.backend'
$rebuildBad = $script:lastSeconds
Write-Host "  плохой:  $rebuildBad с"
Build-Timed -Tag 'notes-backend:good' -Dockerfile 'lab2/good/Dockerfile.backend'
$rebuildGood = $script:lastSeconds
Write-Host "  хороший: $rebuildGood с"

Move-Item $bak $appFile -Force
Write-Host "  файл кода вернули как был"
Write-Host ""

Write-Host "=== Итог ==="
"{0,-24} {1,-14} {2,-14}" -f "образ", "без правки", "после правки" | Write-Host
"{0,-24} {1,-14} {2,-14}" -f "notes-backend:bad", "$warmBad с", "$rebuildBad с" | Write-Host
"{0,-24} {1,-14} {2,-14}" -f "notes-backend:good", "$warmGood с", "$rebuildGood с" | Write-Host
Write-Host ""
if ($rebuildBad -gt 0 -and $rebuildGood -gt 0) {
    Write-Host ("  разница: {0} с" -f [math]::Round($rebuildBad - $rebuildGood, 2))
    Write-Host ("  хороший быстрее в {0} раз" -f [math]::Round($rebuildBad / $rebuildGood, 1))
}
Write-Host ""
Write-Host "  почему так:"
Write-Host "   - в плохом Dockerfile сначала COPY . . и только потом pip install, поэтому правка"
Write-Host "     кода сбрасывает слой и зависимости ставятся заново;"
Write-Host "   - в хорошем сначала копируется requirements.txt и ставится отдельным слоем, а код"
Write-Host "     копируется после, поэтому пересобирается только слой с исходниками."
Write-Host ""
Write-Host "  размеры образов:"
docker images --format "  {{.Repository}}:{{.Tag}}  {{.Size}}" | Select-String 'notes-backend' | ForEach-Object { Write-Host $_ }
Write-Host "вывод сохранен в $OutFile"
Stop-Transcript | Out-Null
