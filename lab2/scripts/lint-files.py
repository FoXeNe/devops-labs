# быстрая проверка файлов лабы без докера. запускать из корня репозитория:
#   python lab2/scripts/lint-files.py
# смотрю, что yaml не разъехался, что все пути в COPY существуют, что в хорошем
# докерфайле код копируется после зависимостей и что ссылки в отчете живые
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LAB = REPO / "lab2"
problems = []
warnings = []
checks = 0


def check(cond, msg):
    global checks
    checks += 1
    if not cond:
        problems.append(msg)


def check_yaml(path):
    text = path.read_text(encoding="utf-8")
    check("\t" not in text, f"{path}: в yaml попал таб")
    for i, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        check(indent % 2 == 0, f"{path}:{i}: отступ не кратен двум, получилось {indent}")
        check(line.count('"') % 2 == 0, f"{path}:{i}: непарная двойная кавычка")
    check(text.count("[") == text.count("]"), f"{path}: непарные квадратные скобки")
    check(text.count("{") == text.count("}"), f"{path}: непарные фигурные скобки")
    return text


def check_compose(path, services):
    text = check_yaml(path)
    for svc in services:
        check(
            re.search(rf"^  {re.escape(svc)}:\s*$", text, re.M) is not None,
            f"{path}: не нашел сервис {svc}",
        )
    return text


check_compose(LAB / "docker-compose.yml", ["db", "backend", "frontend"])
check_compose(LAB / "docker-compose.bad.yml", ["db", "backend", "frontend"])


def check_dockerfile(path):
    text = path.read_text(encoding="utf-8")
    check("FROM " in text, f"{path}: нет FROM")
    for line in text.splitlines():
        m = re.match(r"^\s*COPY\s+(.+)$", line)
        if not m or "--from=" in m.group(1):
            continue
        parts = m.group(1).split()
        for src in parts[:-1]:
            if src.startswith("--"):
                continue
            target = REPO / src
            if src.startswith("backend/"):
                # backend это лаба 0 из этого же репозитория. если ее нет в
                # чекауте, проверять нечего, это не ошибка
                if target.exists():
                    checks += 1
                else:
                    warnings.append(f"{path.name}: COPY {src} проверять нечего, backend нет в этом чекауте")
                continue
            check(target.exists(), f"{path.name}: COPY {src}, такого файла в контексте сборки нет")
    return text


bad = check_dockerfile(LAB / "bad" / "Dockerfile.backend")
good = check_dockerfile(LAB / "good" / "Dockerfile.backend")
check_dockerfile(LAB / "good" / "Dockerfile.frontend")

# в плохом варианте намеренно latest и нет USER, в хорошем наоборот
check("latest" in bad, "плохой докерфайл: ждал тег latest")
check("3.11" in good, "хороший докерфайл: базовая версия не зафиксирована")
check("AS builder" in good and "AS runtime" in good, "хороший докерфайл: нет multi-stage")
check("USER app" in good, "хороший докерфайл: не переключились на пользователя app")
check("HEALTHCHECK" in good, "хороший докерфайл: нет healthcheck")
check(
    good.index("requirements.txt") < good.index("backend/app"),
    "хороший докерфайл: код копируется раньше зависимостей, кеш слоев сломается",
)
check(
    bad.index("COPY . .") < bad.index("pip install"),
    "плохой докерфайл: ждал COPY . . до pip install",
)

nginx = (LAB / "good" / "nginx.conf").read_text(encoding="utf-8")
check(nginx.count("{") == nginx.count("}"), "nginx.conf: непарные фигурные скобки")
check("proxy_pass http://backend_upstream" in nginx, "nginx.conf: нет proxy_pass на upstream")
check("server backend:8000;" in nginx, "nginx.conf: upstream не смотрит на backend:8000")

ignore = (REPO / ".dockerignore").read_text(encoding="utf-8")
for needle in [".git", ".venv", ".env", "__pycache__"]:
    check(needle in ignore, f".dockerignore: не исключил {needle}")

env_example = (LAB / ".env.example").read_text(encoding="utf-8")
for var in ["POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD", "BACKEND_PORT", "FRONTEND_PORT"]:
    check(re.search(rf"^{var}=", env_example, re.M) is not None, f".env.example: нет {var}")

# ссылки в отчете и ридми должны вести на существующие файлы
for md in [LAB / "REPORT.md", LAB / "README.md"]:
    text = md.read_text(encoding="utf-8")
    for link in re.findall(r"\]\((?!https?:)([^)#]+)\)", text):
        # ссылки бывают от папки файла и от корня репозитория, проверяю оба варианта
        target = (md.parent / link).resolve()
        check(
            target.exists() or (REPO / link).exists(),
            f"{md.name}: ссылка ведет в никуда, {link}",
        )

for p in list(LAB.rglob("*")) + [REPO / "frontend" / "index.html"]:
    if not p.is_file() or p.suffix not in {".md", ".ps1", ".sh", ".py", ".yml", ".html", ".conf"}:
        continue
    raw = p.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        continue
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError:
        problems.append(f"{p}: файл не в utf-8")

print(f"проверок: {checks}")
if warnings:
    print(f"предупреждения ({len(warnings)}):")
    for w in dict.fromkeys(warnings):
        print("  -", w)
if problems:
    print(f"проблемы ({len(problems)}):")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("все проверки прошли")
