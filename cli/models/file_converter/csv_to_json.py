import csv
import json
from collections import Counter

def csv_to_json(csv_path: str, json_path: str) :
    severity_counter = Counter()
    vulnerabilities = []
    file_name = ""

    try :
        # Read CSV file
        with open(csv_path, 'r', encoding='utf-8') as csvfile:
            reader = csv.DictReader(csvfile)
            
            for row in reader:
                if not any(row.values()):
                    continue

                file_name = row['File Name'].strip()
                severity = row['Severity'].strip().lower()
                vuln_str = row['Vulnerability'].strip()

                formatted_vuln = vuln_str.replace("description", "\ndescription")

                vulnerability = {
                    'summary': row['Summary'].strip(),
                    'severity': severity,
                    'vulnerability': formatted_vuln,
                    'recommendation': row['Recommendation'].strip(),
                }

                vulnerabilities.append(vulnerability)
                severity_counter[severity] += 1

        severity_counts = {
            'high': severity_counter.get('high', 0),
            'medium': severity_counter.get('medium', 0),
            'low': severity_counter.get('low', 0),
            'informational': severity_counter.get('informational', 0)
        }

        result = {
            'file_name': file_name,
            'severity_counts': severity_counts,
            'total_vulnerabilities': sum(severity_counts.values()),
            'vulnerabilities': vulnerabilities
        }

        # Write JSON output
        with open(json_path, 'w', encoding='utf-8') as jsonfile:
            json.dump(result, jsonfile, indent=2, ensure_ascii=False)
        
        print(f"Json successfully generated: {json_path}")

    except FileNotFoundError:
        print(f"❌ Error: Could not find file '{csv_path}'")
    except Exception as e:
        print(f"❌ Error: {str(e)}")
        

        
    
