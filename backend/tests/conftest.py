'''Фикстуры для тестов'''

from contextlib import asynccontextmanager
from unittest.mock import AsyncMock

import pytest
from app.main import app
from fastapi.testclient import TestClient


# Моковый lifespan
@asynccontextmanager
async def _test_lifespan(app):
    yield


@pytest.fixture
def client():
    original = app.router.lifespan_context
    # Подменяем lifespan на время тестирования
    app.router.lifespan_context = _test_lifespan
    with TestClient(app) as c:
        yield c
    app.router.lifespan_context = original


# Моковая асинхронная сессия БД
@pytest.fixture
def mock_session():
    return AsyncMock()


# Автоматическая очистка перезаписанных зависимостей
@pytest.fixture(autouse=True)
def clear_overrides():
    yield
    app.dependency_overrides.clear()
