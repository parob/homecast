# syntax=docker/dockerfile:1.6
ARG PYTHON_VERSION=3.13-alpine

# Builder stage: install build deps and dependencies with UV
FROM python:${PYTHON_VERSION} AS builder

# Install UV
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Cache APK index and packages between builds
RUN --mount=type=cache,target=/var/cache/apk apk add \
    build-base \
    gcc \
    musl-dev \
    libffi-dev \
    openssl-dev \
    postgresql-dev

WORKDIR /app

# Copy dependency files and source code
COPY pyproject.toml uv.lock VERSION ./
COPY homecast ./homecast

# Create virtual environment and install dependencies
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv && \
    uv pip install -r <(uv export --no-dev --no-emit-project)

# Build and install package as a wheel
RUN --mount=type=cache,target=/root/.cache/uv \
    uv build && \
    uv pip install dist/*.whl

# Final runtime image
FROM python:${PYTHON_VERSION}
WORKDIR /app

# Copy UV installation
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Copy the virtual environment from builder stage
COPY --from=builder /app/.venv /app/.venv

# Activate the virtual environment
ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8080
ENV PORT=8080

# Run application
CMD ["sh", "-c", "uvicorn homecast.app:app --host 0.0.0.0 --port ${PORT:-8080} --timeout-keep-alive 120"]
