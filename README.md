<img src="cattt.jpg"  width="70%">

# Bastet

Bastet is a comprehensive dataset of common smart contract vulnerabilities in DeFi along with an AI-driven automated detection process to enhance vulnerability detection accuracy and optimize security lifecycle management.

## How to install

### Local n8n Setup

**Prerequisites**

- Python 3.10 or higher
- Docker installed on your machine
- Docker Compose installed on your machine
- n8n instance with webhook endpoint configured
- Poetry for dependency management

**Installation Steps**

1. Setup Python environment:

```bash
# Initialize virtual environment and install dependencies
poetry shell
poetry install
```

2. Configure environment variables in `.env`:

```bash
cp .env.example .env
```

Update the environment variables in `.env` file if needed.

3. Add your smart contracts:

- Place your `.sol` files in `n8n/scripts/smart-contracts/`
- Remove `example.sol`

4. Start n8n:

```bash
docker-compose -f ./docker-compose.yml up -d
```

5. Access the n8n dashboard, Open your browser and navigate to `http://localhost:5678`

6. (First time only) Setup owner account, activate free n8n pro features

7. Click the user icon at the bottom left → Settings → Click the **n8n API** in the sidebar → Create an API key → Label fill Bastet → Expiration select "No Expiration" (If you want to set an expiration time, select it) → Copy the API key and paste it to `N8N_API_KEY` in `.env` file, because the API key will not be visible after creation, you can only create it again → Click Done.

8. Import the workflow

**Before the setup, make sure you fill the N8N_API_KEY in `.env` file.**

```bash
cd scripts
poetry run python import-workflow.py
```

9. Back to the homepage (http://localhost:5678/home/workflows), you will the Main workflow and the Sub workflow(We call it processor) you selected with "processor" tag in the n8n homepage.

10. Click **Create Credential** in the arrow button next to the Create Workflow button → Fill in "n8n" in the input → You will see "n8n API" and select it, click Continue → API Key fill in the API key you just created, Base URL fill in http://host.docker.internal:5678/api/v1, click the Save button and you will see Connection tested successfully message.

11. Based on previous step, Create OpenAi credentials, create a new credential with your OpenAi Key.

12. Go into the Main workflow, double click the **n8n node**, and select the credential you just created (should be called **n8n account**) in the Credential to connect with field. close the node window and click the **Save** button (or use Command(Ctrl)+S to save).

13. Based on previous step, Click all the OpenAI nodes in the Sub workflow and connect them to your OpenAi credential. remember to click the **Save** button after each connection.

14. Turn on the switch button of Main workflow and the Sub workflow in the n8n homepage.

## Usage

### Scan Multiple Contracts with Multiple Processor Workflows

Navigate to the scripts directory containing the scanning scripts:

```bash
cd /scripts
```

The main script `scan.py` will recursively scan all `.sol` files in the specified directory:

```bash
poetry run python scan.py ../smart-contracts
```

The script will scan all contracts in the `smart-contracts` directory using the processor workflows that you have activated by turning on their respective switch buttons.

### Scan Single Contract with Single Processor Workflow

1. Go into Processor workflow you want to scan.
2. Click the **Chat** button on the bottom and input the contract content.

### Features

- Recursive scanning of `.sol` files in specified directories
- Automatic database creation and schema setup
- Integration with n8n workflows via webhooks
- Detailed processing summary and error reporting
- Results stored in PostgreSQL for further analysis

### Database Schema

The script create the `analysis` table. We will create the table automatically when the first scan is started:

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

## Overview

Bastet covers common vulnerabilities in DeFi, including medium- to high-risk vulnerabilities found on-chain and in audit competitions, along with corresponding secure implementations. It aims to help developers and researchers gain deeper insights into vulnerability patterns and best security practices.

In addition, Bastet integrates an AI-driven automated vulnerability detection process. By designing tailored detection workflows, Bastet enhances AI's accuracy in identifying vulnerabilities, with the goal of optimizing security lifecycle management—from development and auditing to ongoing monitoring.

We strive to improve overall security coverage and warmly welcome contributions of additional vulnerability types, datasets, or improved AI detection methodologies.
Please refer to our [Contributing Guidelines](CONTRIBUTING.md).
Together, we can drive the industry's security development forward.

```
Bastet/
│── categories/
│   ├── (Type)/
│   │   ├── (Scenario)/
│   │   │   ├── on-chain-vulnerabilities/
│   │   │   ├── audit-competitions-findings/
│   │   │   ├── secure-implementations/
│   │   │   ├── README.md
├── n8n/
│   ├── workflows/
├── scripts/
├── smart-contracts/
├── README.md

```

## Disclaimer

Bastet is for research and educational purposes only. Anyone who discovers a vulnerability should adhere to the principles of Responsible Disclosure and ensure compliance with applicable laws and regulations. We do not encourage or support any unauthorized testing, attacks, or abusive behavior, and users assume all associated risks.

## License

Apache License 2.0
