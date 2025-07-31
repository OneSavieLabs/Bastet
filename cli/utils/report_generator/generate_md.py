def generate_md(df) -> str:
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
| Severity      | Count |
| ------------- | ----- |
{{SEVERITY_ROWS}}

<div style="page-break-before: always;"></div>

# Findings
{{FINDINGS}}"""
    
    severity_counter = dict()
    findings = ""
    
    # Check if DataFrame is empty
    if df.empty:
        print("⚠️ DataFrame is empty, cannot generate report")
        exit(1)
    
    # Check if required columns exist
    required_columns = {'File Name', 'Summary', 'Severity', 'Vulnerability', 'Recommendation'}
    missing = required_columns - set(df.columns)
    if missing:
        print(f"❌ Missing required columns: {', '.join(missing)}")
        exit(1)
    
    # Get file name
    file_name = str(df['File Name'].iloc[0]).strip()
    
    # Process findings and count severity levels
    for _, row in df.iterrows():
        
        severity = str(row['Severity']).strip().lower()
        summary = str(row['Summary']).strip()
        recommendation = str(row['Recommendation']).strip()
        vulnerability = str(row['Vulnerability']).strip()
        
        # Format vulnerability description
        formatted_vuln = vulnerability.replace("description", "<br>description")

        # Update severity count
        severity_counter[severity] = severity_counter.get(severity, 0) + 1

        # Append finding entry to the Markdown block
        findings += f"""### {summary}
* **Severity**: {severity.capitalize()}
* **Vulnerability**: 
{formatted_vuln}
* **Recommendation**: 
{recommendation}

---

"""
    
    # Build severity table rows
    severity_levels = ['high', 'medium', 'low', 'informational']
    severity_rows = ""
    
    for level in severity_levels:
        count = severity_counter.get(level, 0)
        severity_rows += f"| {level.capitalize():<13} | {count:^5} |\n"
    
    total_vulnerabilities = sum(severity_counter.values())
    severity_rows += f"| **Total**     | {total_vulnerabilities:^5} |"
    
    # Replace placeholders in the template
    result = (
        BASTET_TEMPLATE.replace("{{FILE_NAME}}", file_name)
                        .replace("{{SEVERITY_ROWS}}", severity_rows)
                        .replace("{{FINDINGS}}", findings)
    )
    
    return result
