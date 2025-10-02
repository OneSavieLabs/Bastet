FROM python:3.10-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Poetry
ENV POETRY_VERSION=2.0.1
RUN pip install "poetry==$POETRY_VERSION"

# Set work directory
WORKDIR /app

# Copy pyproject.toml and poetry.lock
COPY pyproject.toml poetry.lock* ./

# Install dependencies
RUN poetry install --no-root

# Copy application code
COPY ./cli /app/cli
COPY ./n8n_workflow /app/n8n_workflow

# Entrypoint for Typer CLI
CMD ["poetry", "run", "python", "./cli/main.py", "init"]