import asyncio
import os

from dotenv import load_dotenv
from sqlalchemy import text
from sqlalchemy.exc import OperationalError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from .models import Base

load_dotenv()

DATABASE_URL = os.environ["DATABASE_URL"]

# создаем тут что бы был один объект на весь проект
engine = create_async_engine(DATABASE_URL)

# создаются сессии, expire_on_commit=false что бы после коммита объекты жили
async_session = async_sessionmaker(engine, expire_on_commit=False)


# отдает сессию и сама ее закрывает
async def get_session():
    async with async_session() as session:
        yield session


# бэкенд может стартовать раньше бд, поэтому ждём её перед созданием таблиц
async def wait_for_db(retries: int = 30, delay: float = 1.0) -> None:
    for attempt in range(1, retries + 1):
        try:
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
            return
        except OperationalError:
            if attempt == retries:
                raise
            await asyncio.sleep(delay)


# накатываем схему при старте, миграции в этой лабе не нужны
async def create_tables() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)