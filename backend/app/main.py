from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .database import create_tables, engine, get_session, wait_for_db
from .models import Note
from .schemas import NoteCreate, NoteOut

load_dotenv()


@asynccontextmanager
async def lifespan(app: FastAPI):
    await wait_for_db()
    await create_tables()
    yield
    await engine.dispose()


app = FastAPI(title="Notes API", lifespan=lifespan)

# фронт в лабе открывается как обычный файл, поэтому разрешаем кросс-домен
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/health")
async def health() -> dict:
    return {"status": "ok"}


# новые сверху, так удобнее проверять что запись вообще создалась
@app.get("/api/items", response_model=list[NoteOut])
async def get_items(session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(Note).order_by(Note.id.desc()))
    return list(result.scalars().all())


@app.post("/api/items", response_model=NoteOut, status_code=201)
async def create_item(payload: NoteCreate, session: AsyncSession = Depends(get_session)):
    note = Note(text=payload.text)
    session.add(note)
    await session.commit()
    await session.refresh(note)
    return note