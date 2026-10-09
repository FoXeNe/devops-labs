<#
    проверка пунктов лабы 2 для windows, запуск из корня репозитория:
        powershell -File lab2/scripts/verify.ps1
    вывод дублируется в lab2/docs/verify-output.txt
#>
[CmdletBinding()]
param(
    [string]$OutFile = "lab2/docs/verify-output.txt"
)

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$envFile = 'lab2/.env'
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
Start-Transcript -Path $OutFile -Force | Out-Null

function Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green;  $script:Pass++ }
function Bad  { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:Fail++ }
function Step { param([string]$m) Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }

function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    # без 2>&1: powershell 5.1 на большом выводе сборки с этим зависает,
    # вывод докера пусть идет прямо в консоль
    & docker compose --env-file $envFile -f lab2/docker-compose.yml @Args
}

function Get-Utf8 {
    param([string]$Url, [int]$TimeoutSec = 10)
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.DownloadString($Url)
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "docker не найден в PATH, сначала поставь и запусти Docker Desktop" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 2
}
if (-not (Test-Path $envFile)) {
    Write-Host "нет $envFile, копирую из lab2/.env.example"
    Copy-Item lab2/.env.example $envFile
}

# читаем .env чтобы знать порты и доступы к базе.

$cfg = @{}
Get-Content $envFile | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    $cfg[$k.Trim()] = $v.Trim()
}
$backendPort  = if ($cfg['BACKEND_PORT'])  { $cfg['BACKEND_PORT'] }  else { '8000' }
$frontendPort = if ($cfg['FRONTEND_PORT']) { $cfg['FRONTEND_PORT'] } else { '8080' }
$pgUser = if ($cfg['POSTGRES_USER']) { $cfg['POSTGRES_USER'] } else { 'notes' }
$pgDb   = if ($cfg['POSTGRES_DB'])   { $cfg['POSTGRES_DB'] }   else { 'notesdb' }

Write-Host "проверка стека лабы 2"
Write-Host "дата: $(Get-Date -Format o)"
Write-Host "docker: $(docker --version)"

Step "1. Валидация compose-файла"
$cfgOut = Invoke-Compose config -q
if ($LASTEXITCODE -eq 0) { Ok "docker-compose.yml валиден" } else { Bad "docker-compose.yml невалиден: $cfgOut" }

Step "2. docker compose up, три сервиса одной командой"

Invoke-Compose up -d --build --wait --wait-timeout 180
if ($LASTEXITCODE -eq 0) { Ok "up выполнен, все сервисы дождались готовности" } else { Bad "up вернул код $LASTEXITCODE" }

Start-Sleep -Seconds 5
$running = ((Invoke-Compose ps --status running --services) -join "`n") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
Write-Host "  запущены: $($running -join ' ')"
foreach ($svc in 'db', 'backend', 'frontend') {
    if ($running -contains $svc) { Ok "сервис $svc запущен" } else { Bad "сервис $svc не запущен" }
}

Step "2b. docker ps"
docker ps --filter "name=lab2" --format "table {{.Names}}`t{{.Image}}`t{{.Status}}`t{{.Ports}}" | Out-Host

# если стек не поднялся, дальше проверять нечего

if ($running.Count -lt 3) {
    Write-Host ""
    Write-Host "стек поднялся не полностью, дальше проверять нечего" -ForegroundColor Red
    Write-Host "смотри, что говорит up выше, и логи: docker logs lab2-backend --tail 30"
    Write-Host ""
    Write-Host "итого: пройдено $($script:Pass), провалено $($script:Fail)"
    Stop-Transcript | Out-Null
    exit 1
}

Step "3. Healthcheck-статусы"
Start-Sleep -Seconds 10
foreach ($c in 'lab2-db', 'lab2-backend', 'lab2-frontend') {
    $st = (docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $c 2>&1) -join ''
    
    switch -Regex ($st) {
        '^healthy$' { Ok "${c}: healthy" }
        '^none$'    { Bad "${c}: healthcheck не задан" }
        'No such'   { Bad "${c}: контейнера нет" }
        default     { Bad "${c}: статус $st" }
    }
}

Step "4. Фронт и api"
try {
    $r = Invoke-WebRequest -UseBasicParsing "http://localhost:$frontendPort/" -TimeoutSec 10
    if ($r.StatusCode -eq 200) { Ok "GET / -> 200" } else { Bad "GET / -> $($r.StatusCode)" }
    if ($r.Content -match 'Notes') { Ok "в html есть разметка фронта" } else { Bad "html не похож на наш фронт" }
} catch { Bad "GET / упал: $($_.Exception.Message)" }

foreach ($path in '/api/items', '/api/health') {
    try {
        $r = Invoke-WebRequest -UseBasicParsing "http://localhost:$frontendPort$path" -TimeoutSec 10
        Ok "GET $path через nginx -> $($r.StatusCode)"
    } catch { Bad "GET $path через nginx упал: $($_.Exception.Message)" }
}
try {
    $r = Invoke-WebRequest -UseBasicParsing "http://localhost:$backendPort/api/health" -TimeoutSec 10
    Ok "GET :$backendPort/api/health напрямую -> $($r.StatusCode)"
} catch { Bad "backend health упал: $($_.Exception.Message)" }

Step "5. Запись в базу и чтение из нее"
$mark = "verify-$(Get-Date -UFormat %s)"
try {
    $post = Invoke-WebRequest -UseBasicParsing "http://localhost:$frontendPort/api/items" -Method Post `
        -ContentType 'application/json' -Body (@{ text = $mark } | ConvertTo-Json) -TimeoutSec 10
    if ($post.StatusCode -eq 201) { Ok "POST /api/items -> 201" } else { Bad "POST /api/items -> $($post.StatusCode)" }
    if (-not ($post.Content.Contains($mark))) { Bad "в ответе нет текста записи" } else { Ok "сервер вернул созданную запись" }
} catch { Bad "POST /api/items упал: $($_.Exception.Message)" }

try {
    $items = Get-Utf8 "http://localhost:$frontendPort/api/items"
    if ($items.Contains($mark)) { Ok "запись видна в GET /api/items" } else { Bad "запись не видна в списке" }
} catch { Bad "GET /api/items упал: $($_.Exception.Message)" }

$rows = (docker exec lab2-db psql -U $pgUser -d $pgDb -tAc "select count(*) from notes where text = '$mark';" 2>&1) -join ''
$rowsRc = $LASTEXITCODE
$rows = $rows.Trim() -replace '\D', ''
if ($rowsRc -ne 0) { Bad "не смог запросить базу: $rows" }
elseif ($rows -eq '1') { Ok "строка есть в postgres, select вернул 1" }
else { Bad "в postgres строк не найдено, вернулось '$rows'" }

Step "6. Именованный том: удаляем контейнер и поднимаем заново"
docker rm -f lab2-backend | Out-Null
if ($LASTEXITCODE -eq 0) { Ok "контейнер backend удален" } else { Bad "не удалось удалить контейнер" }
Invoke-Compose up -d --wait --wait-timeout 180 backend | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    try {
        $null = Invoke-WebRequest -UseBasicParsing "http://localhost:$frontendPort/api/items" -TimeoutSec 5
        break
    } catch { Start-Sleep -Seconds 2 }
}
try {
    $items = Get-Utf8 "http://localhost:$frontendPort/api/items"
    if ($items.Contains($mark)) { Ok "после пересоздания запись '$mark' на месте" } else { Bad "после пересоздания запись пропала" }
} catch { Bad "после пересоздания api не отвечает: $($_.Exception.Message)" }
Write-Host "  том: $((docker volume inspect lab2-pgdata --format '{{.Name}} -> {{.Mountpoint}}' 2>&1) -join '')"

Step "7. Пользователь внутри контейнера"
$who = ((docker exec lab2-backend whoami 2>&1) -join '').Trim()
if ($LASTEXITCODE -ne 0) { Bad "не смог выполнить whoami в lab2-backend: $who" }
elseif ($who -and $who -ne 'root') { Ok "docker exec lab2-backend whoami -> $who" }
else { Bad "whoami -> '$who', ожидался не root" }
$uid = ((docker exec lab2-backend id -u 2>&1) -join '').Trim()
if ($LASTEXITCODE -ne 0) { Bad "не смог получить uid: $uid" }
elseif ($uid -eq '10001') { Ok "uid внутри контейнера 10001" }
else { Bad "uid внутри контейнера '$uid'" }

Step "8. Сетевая изоляция"
$resolve = ((docker exec lab2-frontend getent hosts db 2>&1) -join "`n").Trim()
$resolveRc = $LASTEXITCODE
if ($resolveRc -eq 0 -and $resolve -match '^\s*\S') { Bad "фронт резолвит имя db: $resolve" }
else { Ok "фронт не резолвит имя db" }
$conn = ((docker exec lab2-frontend sh -c 'nc -z -w 3 db 5432 && echo CONNECTED || echo FAILED' 2>&1) -join "`n").Trim()
$connRc = $LASTEXITCODE
Write-Host "  попытка соединения фронта с db:5432 -> $conn"
if ($connRc -ne 0 -and $conn -notmatch 'FAILED') { Bad "не смог проверить соединение: $conn" }
elseif ($conn -match 'CONNECTED') { Bad "фронт подключился к базе, изоляции нет" }
else { Ok "соединение фронта с базой невозможно" }

$netsFront = ((docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' lab2-frontend 2>&1) -join '').Trim()
$netsDb    = ((docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' lab2-db 2>&1) -join '').Trim()
Write-Host "  сети frontend: $netsFront"
Write-Host "  сети db:       $netsDb"
if ($netsFront -match 'backend-net') { Bad "фронт подключен к backend-net" } else { Ok "фронт не в сети базы" }
if ($netsDb -match 'frontend-net') { Bad "база подключена к frontend-net" } else { Ok "база не в сети фронта" }

$listen = (Get-NetTCPConnection -State Listen -LocalPort 5432 -ErrorAction SilentlyContinue)
if ($listen) { Bad "порт 5432 слушается на хосте, база опубликована" } else { Ok "порт 5432 на хост не опубликован" }

Step "9. Размеры образов"
docker images --format "{{.Repository}}:{{.Tag}}|{{.Size}}" | Select-String 'notes-(backend|frontend)' | ForEach-Object { Write-Host "  $_" }
$badSize = ((docker image inspect notes-backend:bad --format '{{.Size}}' 2>&1) -join '').Trim()
$goodSize = ((docker image inspect notes-backend:good --format '{{.Size}}' 2>&1) -join '').Trim()
if ($badSize -match '^\d+$' -and $goodSize -match '^\d+$') {
    Write-Host "  плохой backend:  $([math]::Round([int]$badSize/1MB)) МБ"
    Write-Host "  хороший backend: $([math]::Round([int]$goodSize/1MB)) МБ"
    if ([int]$goodSize -lt [int]$badSize) { Ok "хороший образ меньше плохого" } else { Bad "хороший образ не меньше плохого" }
} else {
    Write-Host "  оба образа не собраны, их собирает lab2/scripts/measure-build-time.ps1"
}

Step "10. Итоговое состояние стека"
Invoke-Compose ps | Out-Host

Write-Host ""
Write-Host "итого: пройдено $($script:Pass), провалено $($script:Fail)"
Write-Host "вывод сохранен в $OutFile"
Stop-Transcript | Out-Null
if ($script:Fail -gt 0) { exit 1 }
