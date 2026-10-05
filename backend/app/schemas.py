from datetime import datetime

from pydantic import BaseModel, Field


class NoteCreate(BaseModel):
    # пустые заметки не добавляем
    text: str = Field(..., min_length=1, max_length=500)


class NoteOut(BaseModel):
    id: int
    text: str
    created_at: datetime

    model_config = {"from_attributes": True}