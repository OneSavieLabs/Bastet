# Bastet

<img src="image/cattt.jpg"  width="70%">

Bastet is a comprehensive dataset of common smart contract vulnerabilities in DeFi along with an AI-driven automated detection process to enhance vulnerability detection accuracy and optimize security lifecycle management.

## Overview

Bastet covers common vulnerabilities in DeFi, including medium- to high-risk vulnerabilities found on-chain and in audit competitions, along with corresponding secure implementations. It aims to help developers and researchers gain deeper insights into vulnerability patterns and best security practices.

In addition, Bastet integrates an AI-driven automated vulnerability detection process. By designing tailored detection workflows, Bastet enhances AI's accuracy in identifying vulnerabilities, with the goal of optimizing security lifecycle management—from development and auditing to ongoing monitoring.

We strive to improve overall security coverage and warmly welcome contributions of additional vulnerability types, datasets, or improved AI detection methodologies.
Please refer [here](https://www.notion.so/Bastet-Dataset-217573b5d69a8013b27ac453ef5265b2?source=copy_link) to join and contribute to the Bastet dataset.
Together, we can drive the industry's security development forward.

To download the dataset [here](https://drive.google.com/drive/folders/1b3jp6SaNehX4ccZbrmbqeBUoXijXTOmz)

```
Bastet/
│── cli/                        # Python CLI package
│   │── __init__.py
│   │── main.py                 # CLI entry point
│   │── commands/               # CLI commands
│   │   │── <module>/
│   │   │   │── __init__.py     # CLI routing only, logic will define below
│   │   │   │── <function>.py
│   │── models/                 # Interfaces for python type check
│   │   │── <SAAS>/
│   │   │   │── __init__.py     # For output all models in SAAS
│   │   │   │── <function>.py
│   │   │── audit_report.py     # Main Interface of output in Bastet
│── dataset/                    # dataset location
│   │── reports/                # will be unzipped from the dataset.zip provide in google drive -> audit reports of the projects
│   │   │── <reports>/
│   │── repos/                  # will be unzipped from the dataset.zip provide in google drive -> codebase of the projects
│   │   │── <repos>/
│   │── dataset.csv             # dataset sheet, provide ground truth. (should be clone from google drive)
│   │── README.MD               # Basic information of the dataset
│── n8n_workflows/              # n8n workflow files
│   │── <file>.json             # workflow for analyzing the smart contracts
│── docker-compose.yaml
│── README.md
│── poetry.lock
│── pyproject.toml
│── .gitignore

```

### Features

- Recursive scanning of `.sol` files in specified directories
- Automatic database creation and schema setup
- Integration with n8n workflows via webhooks
- Detailed processing summary and error reporting
- Results stored in PostgreSQL for further analysis
- A dataset for evaluate the prompt
- A cli interface to trigger evaluate workflow
- Python file formatter: Black

## How to install

### Local n8n Setup

**Prerequisites**

- [Python](https://www.python.org/) 3.10 or higher
- [Docker](https://www.docker.com/) installed on your machine
- [Docker Compose](https://docs.docker.com/compose/) installed on your machine
- [Poetry](https://python-poetry.org/) for package management, if you want to follow our instruction the version should> 2.0.1

**Installation Steps**

**_Video tutorial_**

[![IMAGE ALT TEXT HERE](https://img.youtube.com/vi/ouQ0zSDU3pM/0.jpg)](https://www.youtube.com/watch?v=ouQ0zSDU3pM)

1. Setup Python environment:

```bash
# Initialize virtual environment and install dependencies
poetry install
eval $(poetry env activate) # or `source .venv/bin/activate`
```

2. Configure environment variables in `.env`:

```bash
cp .env.example .env
```

Update the environment variables in `.env` file if needed.

3. Start n8n and database:

```bash
docker-compose -f ./docker-compose.yml up -d
```

4. Access the n8n dashboard, Open your browser and navigate to `http://localhost:5678`

5. (First time only) Setup owner account, activate free n8n pro features

6. Click the user icon at the bottom left → Settings → Click the **n8n API** in the sidebar → Create an API key → Label fill Bastet → Expiration select "No Expiration" (If you want to set an expiration time, select it) → Copy the API key and paste it to `N8N_API_KEY` in `.env` file, because the API key will not be visible after creation, you can only create it again → Click Done.

7. Back to the homepage (http://localhost:5678/home/workflows)

8. Click **Create Credential** in the arrow button next to the Create Workflow button → Fill in "OpenAi" in the input → You will see "OpenAi" and select it, click Continue → API Key fill your OpenAi API key, Create OpenAi credentials, and copy the value of the **ID** field and paste it to `N8N_OPENAI_CREDENTIAL_ID` in `.env` file.

9. Import the workflow by executing the following code

**Before the setup, make sure you fill the N8N_API_KEY, N8N_OPENAI_CREDENTIAL_ID in `.env` file.**

```bash
poetry run python cli/main.py init
```

You will see the all workflows we provided currently. (default activated, if you want to skip some workflow, please deactivate it in n8n (http://localhost:5678/home/workflows)

## Usage

### Scan Multiple Contracts with Multiple Processor Workflows

<img src="image/scan.png"  width="70%">

The main script `scan` will recursively scan all `.sol` files in the specified directory:

```bash
poetry run python cli/main.py scan
# or
poetry run python cli/main.py scan --output-format csv
```

By default, the scan will process all contracts in the `dataset/scan_queue` directory using all workflows that you have activated by turning on their respective switch buttons, and generate a `.csv` file containing a spreadsheet-friendly summary of all detected vulnerabilities. The report will be saved in the `scan_report/ `directory.

You can customize the output using the `--output-format` option, supporting multiple formats separated by commas.

```bash
# Example: generate json and md
poetry run python cli/main.py scan --output-format json,md
# Example: generate all formats
poetry run python cli/main.py scan --output-format all
```

- csv : Generates a CSV file for quick analysis in spreadsheet tools.
- json : Outputs structured data suitable for automation or further processing.
- md : Creates a human-readable Markdown summary report.
- pdf : Exports a printable PDF report.
- all : Generates all of the above formats: csv, json, md, and pdf.

> you can use flag `--help` for detail information of flag you can use

### Scan Single Contract with Single Processor Workflow

1. Go into the workflow you want to scan.
2. Click the **Chat** button on the bottom and input the contract content.

### Evaluation

<img src="image/eval.png"  width="70%">

1. import the workflow you want to evaluate

> The output of the workflow need to follow the following json schema.

```json
{
  "type": "array",
  "items": {
    "type": "object",
    "properties": {
      "summary": {
        "type": "string",
        "description": "Brief summary of the vulnerability"
      },
      "severity": {
        "type": "string",
        "items": {
          "type": "string",
          "enum": ["high", "medium", "low"]
        },
        "description": "Severity level of the vulnerability"
      },
      "vulnerability_details": {
        "type": "object",
        "properties": {
          "function_name": {
            "type": "string",
            "description": "Function name where the vulnerability is found"
          },
          "description": {
            "type": "string",
            "description": "Detailed description of the vulnerability"
          }
        },
        "required": ["function_name", "description"]
      },
      "code_snippet": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "description": "Code snippet showing the vulnerability",
        "default": []
      },
      "recommendation": {
        "type": "string",
        "description": "Recommendation to fix the vulnerability"
      }
    },
    "required": [
      "summary",
      "severity",
      "vulnerability_details",
      "code_snippet",
      "recommendation"
    ]
  },
  "additionalProperties": false
}
```

> The trigger point should be a webhook and this workflow should be activated (by clicking the switch at n8n home page)

> You may refer `n8n_workflow/slippage_min_amount.json`

2. download the latest dataset.zip and the dataset.csv from [here](https://drive.google.com/drive/folders/1b3jp6SaNehX4ccZbrmbqeBUoXijXTOmz)

3. unzip the dataset.zip in the ./dataset and the folder structure should look like this

```
dataset/ # dataset location
│── reports/ # will be unzipped from the dataset.zip provide in google drive -> audit reports of the projects
│  │── <reports>/
│── repos/ # will be unzipped from the dataset.zip provide in google drive -> codebase of the projects
│  │── <repos>/
│── dataset.csv # dataset sheet, provide ground truth. (should be clone from google drive and renamed to `dataset.csv`)
│── README.MD # Basic information of the dataset
```

3. run the command

```bash
poetry run python cli/main.py eval
```

> you can use flag `--help` for detail information of flag you can use

#### Demo Case Setup

1. import `slippage_min_amount.json` to your n8n service.

2. provide the openAI credential for the workflow `slippage_min_amount` you just create.

3. make the workflow active

4. download the latest dataset.zip and the dataset.csv from [here](https://drive.google.com/drive/folders/1b3jp6SaNehX4ccZbrmbqeBUoXijXTOmz)

5. unzip the dataset.zip in the ./dataset and the folder structure should look like this

```
dataset/ # dataset location
│── reports/ # will be unzipped from the dataset.zip provide in google drive -> audit reports of the projects
│  │── <reports>/
│── repos/ # will be unzipped from the dataset.zip provide in google drive -> codebase of the projects
│  │── <repos>/
│── dataset.csv # dataset sheet, provide ground truth. (should be clone from google drive and renamed to `dataset.csv`)
│── README.MD # Basic information of the dataset
```

6. run

```bash
poetry run python cli/main.py eval
```

you shell get the confusion metrics. like this

```
+----------------+---------+
| Metric         |   Value |
+================+=========+
| True Positive  |      16 |
+----------------+---------+
| True Negative  |      27 |
+----------------+---------+
| False Positive |       2 |
+----------------+---------+
| False Negative |      13 |
+----------------+---------+
```

Note: the number shell be difference since the answer of LLM model is not stable, the answer here is created by gpt-4o-mini

### Continuous Integration / Continuous Deployment (CI/CD)

Bastet supports automated CI/CD workflows for both GitHub and GitLab, enabling seamless integration into your development pipeline.

#### GitHub Actions

You can find example CI/CD configurations in `.exmaple.github/action` and `.exmaple.github/workflows` directories of this repository. Use these as references to build your own custom CI/CD pipeline for Bastet in GitLab. Adjust stages, environment variables, and workflow steps as needed for your project requirements.

You may customize which vulnerability you want to detect in `.exmaple.github/action/action.yml`

```bash
docker-compose -f docker-compose.cicd.yml exec -T bastet \
bash -c "echo 'all' | poetry run python /app/cli/main.py init --n8n-url http://n8n:5678"
```

##### Video Guide

[![](https://img.youtube.com/vi/ouQ0zSDU3pM/0.jpg)](https://youtu.be/UXLVsn4A2pw)

#### GitLab CI

Add a stage to your `.gitlab-ci.yml` file, follow the `.example.gitlab-ci.yml`

These templates will automatically run Bastet scans on your smart contracts whenever you push changes or open merge requests. Customize the workflow as needed for your project.

You may customize which vulnerability you want to detect in `.example.gitlab-ci.yml`

```bash
docker-compose -f docker-compose.cicd.yml exec -T bastet
bash -c "echo 'all' | poetry run python /app/cli/main.py init --n8n-url http://n8n:5678"
```

##### Video Guide

[![](https://img.youtube.com/vi/ouQ0zSDU3pM/0.jpg)](https://youtu.be/blqctKe_WJs)

## Conference

| Date       | Conference Name | Topic                                                                                     | Slide                                          |
| ---------- | --------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------- |
| 2025-04-02 | ETH TAIPEI 2025 | Exploring AI’s Role in Smart Contract Security                                            | [ETH-TAIPEI-2025](./slide/ETH-TAIPEI-2025.pdf) |
| 2025-04-17 | CyberSec 2025   | AI-Driven Smart Contract Vulnerability Detection                                          | [CyberSec-2025](./slide/CyberSec-2025.pdf)     |
| 2025-08-09 | COSCUP 2025     | AI x Smart Contract: What Static Analysis Tools Can't Do, Leave It to Prompt Engineering! | [COSCUP-2025](./slide/COSCUP-2025.pdf)         |

## Disclaimer

Bastet is for research and educational purposes only. Anyone who discovers a vulnerability should adhere to the principles of Responsible Disclosure and ensure compliance with applicable laws and regulations. We do not encourage or support any unauthorized testing, attacks, or abusive behavior, and users assume all associated risks.

## License

Apache License 2.0
