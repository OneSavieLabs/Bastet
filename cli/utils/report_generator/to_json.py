import pandas as pd
import json
from collections import Counter

def to_json(df: pd.DataFrame, json_path: str):
    
    severity_counter = Counter()
    vulnerabilities = []
    file_name = ""
    
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
        
        # Process each row in DataFrame
        for _, row in df.iterrows():
                
            file_name = str(row['File Name']).strip()
            severity = str(row['Severity']).strip().lower()
            vuln_str = str(row['Vulnerability']).strip()
            
            # Format vulnerability description
            formatted_vuln = vuln_str.replace("description", "\ndescription")
            
            vulnerability = {
                'summary': str(row['Summary']).strip(),
                'severity': severity,
                'vulnerability': formatted_vuln,
                'recommendation': str(row['Recommendation']).strip(),
            }
            
            vulnerabilities.append(vulnerability)
            severity_counter[severity] += 1
        
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
            'vulnerabilities': vulnerabilities
        }
        
        # Write JSON file
        with open(json_path, 'w', encoding='utf-8') as jsonfile:
            json.dump(result, jsonfile, indent=2, ensure_ascii=False)
        
    except FileNotFoundError:
        print(f"❌ Error: Could not find file '{json_path}'")
    except Exception as e:
        print(f"❌ Error: {str(e)}")
