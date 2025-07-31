def generate_json(df, json_path: str):
    import json
    
    severity_counter = dict()
    findings = list()
    file_name = ""
    
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

    # Process each row in DataFrame
    for _, row in df.iterrows():
            
        file_name = str(row['File Name']).strip()
        summary = str(row['Summary']).strip()
        severity = str(row['Severity']).strip().lower()
        vulnerability = str(row['Vulnerability']).strip()
        recommendation = str(row['Recommendation']).strip()
        
        # Format vulnerability description
        formatted_vuln = vulnerability.replace("description", "\ndescription")
        
        # Update severity count
        severity_counter[severity] = severity_counter.get(severity, 0) + 1
        
        finding = {
            'summary': summary,
            'severity': severity.capitalize(),
            'vulnerability': formatted_vuln,
            'recommendation': recommendation,
        }
        findings.append(finding)
        
    # Build severity statistics
    severity_counts = {
        'high': severity_counter.get('high', 0),
        'medium': severity_counter.get('medium', 0),
        'low': severity_counter.get('low', 0),
        'informational': severity_counter.get('informational', 0)
    }
    
    # Build final result
    result = {
        'file_name': file_name,
        'severity_counts': severity_counts,
        'total_vulnerabilities': sum(severity_counts.values()),
        'vulnerabilities': findings
    }
    
    # Write JSON file
    with open(json_path, 'w', encoding='utf-8') as jsonfile:
        json.dump(result, jsonfile, indent=2, ensure_ascii=False)
