# Smart Contract Scanning Scripts

A collection of Python scripts for batch scanning and analyzing smart contracts. The system stores analysis results in a PostgreSQL database and integrates with n8n workflows.

## Prerequisites

- Python 3.10 or higher
- Docker and Docker Compose installed (use `docker-compose up` in the n8n folder)
- n8n instance with webhook endpoint configured
- Poetry for dependency management

## Installation

1. Install dependencies using Poetry:

```bash
poetry install
```

2. Configure environment variables in `.env`:

```env
POSTGRES_HOST=localhost
POSTGRES_USER=your_user
POSTGRES_PASSWORD=your_password
POSTGRES_PORT=5432
N8N_WEBHOOK_URL=your_n8n_webhook_url
```

## Usage

### Scan Contracts

The main script `scan.py` will recursively scan all `.sol` files in the specified directory:

```bash
poetry run python scan.py <folder_path>
```

Example:

```bash
poetry run python scan.py ./n8n/examples
```

### Features

- Recursive scanning of `.sol` files in specified directories
- Automatic database creation and schema setup
- Integration with n8n workflows via webhooks
- Detailed processing summary and error reporting
- Results stored in PostgreSQL for further analysis

### Database Schema

The script creates a `bastet` database with an `analysis` table:

```sql
CREATE TABLE analysis (
    id SERIAL PRIMARY KEY,
    contract_name VARCHAR(1024),
    contract_path TEXT,
    audit_result JSONB,
    audit_result_review BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
```
