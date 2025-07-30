import pandas as pd
from collections import Counter

# Bastet Markdown Template
BASTET_TEMPLATE = """<div style="display: flex; justify-content: center; align-items: center; gap: 10px;">
  <img src="image/Bastet.png" width="60">
  <span style="font-size: 30px; font-weight: bold;">Bastet AI Scanning Report</span>
</div>

<br><br>

# About Bastet
Bastet is a comprehensive dataset of common smart contract vulnerabilities in DeFi along with an AI-driven automated detection process to enhance vulnerability detection accuracy and optimize security lifecycle management.

# Risk Classification
| Severity Level | Impact: High | Impact: Medium | Impact: Low   |
| ------------------- | -------- | ------------- | ------------- |
| Likelihood: High    | High     | Medium        | Low           |
| Likelihood: Medium  | Medium   | Low           | Informational |
| Likelihood: Low     | Low      | Informational | Informational |

## Impact
* **High**: leads to a loss of assets in the protocol, or significant harm to a majority of users.
* **Medium**: function or availability of the protocol could be impacted or losses to only a subset of users.
* **Low**: State handling, function incorrect as to spec, issues with clarity, losses will be annoying but bearable.

## Likelihood
* **High**: almost certain to happen, easy to perform, or not easy but highly incentivized.
* **Medium**: only conditionally possible or incentivized, but still relatively likely.
* **Low**: requires stars to align, or little-to-no incentive.

<div style="page-break-before: always;"></div>

# Security Assessment Summary
This security assessment is supported by [Bastet](https://github.com/OneSavieLabs/Bastet.git). Bastet is an AI vulnerability detection infrastructure that includes a dataset of common DeFi smart contract vulnerabilities as well as multiple vulnerability detection processes. It is capable of identifying medium- to high-risk issues observed on-chain and in past audit competitions and, through its customizable detection workflows, improves the accuracy of automated vulnerability discovery. Bastet also supports comprehensive security evaluations during development, auditing, and monitoring phases.

## Project Summary
### File in Scope : {{FILE_NAME}}
### Issues Found : 
{{SEVERITY_TABLE}}

<div style="page-break-before: always;"></div>

# Findings
{{FINDINGS}}"""


def to_md(df: pd.DataFrame, md_path: str):
    severity_counter = Counter()
    
    try:
        # Check if DataFrame is empty
        if df.empty:
            print("⚠️ DataFrame is empty, cannot generate report")
            return
        
        # Check if required columns exist
        required_columns = ['File Name', 'Summary', 'Severity', 'Vulnerability', 'Recommendation']
        missing_columns = [col for col in required_columns if col not in df.columns]
        if missing_columns:
            raise ValueError(f"DataFrame missing required columns: {missing_columns}")
        
        # Get file name
        file_name = str(df['File Name'].iloc[0]).strip()
        
        # Count severities and prepare vulnerabilities
        for _, row in df.iterrows():   
            severity = str(row['Severity']).strip().lower()
            vuln_str = str(row['Vulnerability']).strip()
            
            formatted_vuln = vuln_str.replace("description", "<br>description")
            severity_counter[severity] += 1
        
        total_vulnerabilities = sum(severity_counter.values())
        
        # Build severity table string
        severity_table = f"""| Severity      | Count |
| ------------- | ----- |
| High          | {severity_counter['high']} |
| Medium        | {severity_counter['medium']} |
| Low           | {severity_counter['low']} |
| Informational | {severity_counter['informational']} |
| **Total**     | {total_vulnerabilities} |"""
        
        # Build findings section
        vuln_sections = ""
        for _, row in df.iterrows():            
            vuln_sections += f"""### {str(row['Summary']).strip()}
* **Severity**: {str(row['Severity']).strip().capitalize()}
* **Vulnerability**: 
{formatted_vuln.strip()}
* **Recommendation**: 
{str(row['Recommendation']).strip()}

---

"""
        
        # Replace placeholders in the template
        output = (
            BASTET_TEMPLATE.replace("{{FILE_NAME}}", file_name)
                          .replace("{{SEVERITY_TABLE}}", severity_table)
                          .replace("{{FINDINGS}}", vuln_sections)
        )
        
        # Write to Markdown file
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(output)
    
    except FileNotFoundError:
        print(f"❌ Error: Could not find file '{md_path}'")
    except Exception as e:
        print(f"❌ Error: {str(e)}")
