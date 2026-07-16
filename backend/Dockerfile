FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN addgroup --system app && adduser --system --ingroup app app

COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir .

FROM base AS test

COPY tests ./tests
RUN pip install --no-cache-dir '.[test]'

USER app
CMD ["pytest", "-q"]

FROM base AS runtime

USER app
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)"]

CMD ["uvicorn", "life_notes_backend.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
