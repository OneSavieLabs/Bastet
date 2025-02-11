<img src="cattt.jpg"  width="70%">

## Bastet
Bastet is a comprehensive dataset of common smart contract vulnerabilities in DeFi along with an AI-driven automated detection process to enhance vulnerability detection accuracy and optimize security lifecycle management.

## How to install

### Local n8n Setup

**Prerequisites**

- Docker installed on your machine
- Docker Compose installed on your machine

**Installation Steps**

1. Start n8n:

```bash
docker compose up -d
```

2. Access the n8n dashboard, Open your browser and navigate to `http://localhost:5678`

3. Create a new workflow, import the workflow from the `n8n/workflows` directory.

4. Click the OpenAI node, and add your OpenAI API key.

5. Click the Save button to save the workflow.

6. Click the Run button to run the workflow.

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
├── workflow/ 
│   ├── README.md    
├── README.md

```


## Disclaimer
Bastet is for research and educational purposes only. Anyone who discovers a vulnerability should adhere to the principles of Responsible Disclosure and ensure compliance with applicable laws and regulations. We do not encourage or support any unauthorized testing, attacks, or abusive behavior, and users assume all associated risks.


## License
Apache License 2.0

