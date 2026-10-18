from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock

from app.database import get_session
from app.main import app


def test_health(client):
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_get_items_returns_list(client, mock_session):
    # эмулируем результат session.execute(...).scalars().all()
    mock_result = MagicMock()
    mock_result.scalars.return_value.all.return_value = [
        MagicMock(id=2, text="second"),
        MagicMock(id=1, text="first"),
    ]
    mock_session.execute.return_value = mock_result

    async def override_get_session():
        yield mock_session

    app.dependency_overrides[get_session] = override_get_session

    response = client.get("/api/items")

    assert response.status_code == 200
    data = response.json()
    assert len(data) == 2
    assert data[0]["id"] == 2
    assert data[0]["text"] == "second"
    assert data[1]["id"] == 1
    assert data[1]["text"] == "first"


def test_items_empty(client, mock_session):
    mock_result = MagicMock()
    mock_result.scalars.return_value.all.return_value = []
    mock_session.execute.return_value = mock_result

    async def override_get_session():
        yield mock_session

    app.dependency_overrides[get_session] = override_get_session

    response = client.get("/api/items")

    assert response.status_code == 200
    assert len(response.json()) == 0


def test_create_item(client, mock_session):
    # эмулируем поведение после commit + refresh
    async def refresh_side_effect(note):
        note.id = 67 
        note.created_at = datetime.now(timezone.utc)

    mock_session.refresh = AsyncMock(side_effect=refresh_side_effect)

    async def override_get_session():
        yield mock_session

    app.dependency_overrides[get_session] = override_get_session

    response = client.post("/api/items", json={"text": "do cloud lab"})

    assert response.status_code == 201
    data = response.json()
    assert data["id"] == 67
    assert data["text"] == "do cloud lab"
    assert "created_at" in data

    mock_session.add.assert_called_once()
    added_item = mock_session.add.call_args.args[0]
    assert added_item.text == "do cloud lab"

    mock_session.commit.assert_awaited_once()
    mock_session.refresh.assert_awaited_once()
