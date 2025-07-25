import json

def json_to_md(json_path : str, md_template_path : str, md_path : str):
    try:
        # Load JSON data
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        # Check if required fields are present
        required_keys = ["severity_counts", "total_vulnerabilities", "vulnerabilities", "file_name"]
        for key in required_keys:
            if key not in data:
                raise KeyError(f"Missing required field: {key}")

        # Build severity table string
        severity_table = f"""| Severtity     | Count |
| ------------- | ----- |
| High          | {data['severity_counts']['high']} |
| Medium        | {data['severity_counts']['medium']} |
| Low           | {data['severity_counts']['low']} |
| Informational | {data['severity_counts']['informational']} |
| **Total**     | {data['total_vulnerabilities']} |
"""

        # Build findings section
        vuln_sections = ""
        for vuln in data["vulnerabilities"]:
            vuln_sections += f"""### {vuln['summary']}
**Severity**: {vuln['severity'].capitalize()}
**Vulnerability**: {vuln["vulnerability"]}
**Recommendation**: {vuln['recommendation']}

---
"""

        # Read the Markdown template
        with open(md_template_path, "r", encoding="utf-8") as f:
            template = f.read()

        # Replace placeholders in the template
        output = (
            template.replace("{{FILE_NAME}}", data["file_name"])
                    .replace("{{SEVERITY_TABLE}}", severity_table)
                    .replace("{{FINDINGS}}", vuln_sections)
        )

        # Write to new Markdown file
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(output)

        print(f"Markdown successfully generated: {md_path}")

    except FileNotFoundError as e:
        print(f"[Error] File not found: {e.filename}")
    except json.JSONDecodeError as e:
        print(f"[Error] Failed to decode JSON: {str(e)}")
    except KeyError as e:
        print(f"[Error] Missing field in JSON data: {str(e)}")
    except Exception as e:
        print(f"[Error] An unexpected error occurred: {str(e)}")

