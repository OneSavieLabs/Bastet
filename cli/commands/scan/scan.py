def scan_v1(
    folder_path: str,
    n8n_url: str,
    report_name: str,
    output_path: str,
    output_formats: set[str],
):
    import glob
    import os

    import pandas as pd
    import requests
    from models.audit_report import AuditReport
    from models.n8n.node import WebhookNode
    from pydantic import ValidationError
    from tqdm import tqdm
    from utils.report_generator import generate_json, generate_md, generate_pdf

    tqdm.write("Scanning contracts...")

    contract_files = glob.glob(os.path.join(folder_path, "**/*.sol"), recursive=True)
    total_files = len(contract_files)
    tqdm.write(f"Found {total_files} contract files.")

    response = requests.get(
        f"{n8n_url}/api/v1/workflows",
        headers={"X-N8N-API-KEY": os.getenv("N8N_API_KEY")},
    )
    if response.status_code != 200:
        tqdm.write(
            f"\033[91m❌ Error fetching workflows: {response.status_code} - {response.text}\033[0m"
        )
        return
    workflows = []
    for workflow in response.json()["data"]:
        if workflow["active"]:
            workflows.append(workflow)

    if workflows:
        tqdm.write(f"Found {len(workflows)} active processor workflows.")
        tqdm.write(f"-" * 50)
        vulnerabilities: list[tuple[str, AuditReport]] = []
        # audit_reports: list[AuditReport] = []
        for contract_file in tqdm(
            contract_files,
            desc="Processing contracts",
            unit="file",
            ncols=100,
            colour="blue",
            bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} files [Time: {elapsed}]",
            mininterval=0.01,
            # file=sys.stdout,
        ):
            tqdm.write(f"start scanning contract: {contract_file}")
            tqdm.write(f"-" * 50)
            contract_name = os.path.basename(contract_file)
            with open(contract_file, "r") as file:
                contract_content = file.read()
                file.close()

            for workflow in tqdm(
                workflows,
                desc="Fetching workflows",
                unit="workflow",
                ncols=100,
                colour="red",
                bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} workflows [Time: {elapsed}]",
                mininterval=0.01,
            ):
                workflow_name = workflow["name"]
                tqdm.write(f"\033[92mstart workflow: {workflow_name}\033[0m")

                webhook_node = next(
                    (
                        WebhookNode(**node)
                        for node in workflow["nodes"]
                        if node["type"] == "n8n-nodes-base.webhook"
                    ),
                    None,
                )
                if not webhook_node:
                    tqdm.write(
                        f"\033[91m❌ No valid webhook node found in workflow: {workflow['name']}\033[0m"
                    )
                    continue
                webhook_url = webhook_node.get_webhook_url(n8n_url)
                response = requests.post(
                    webhook_url,
                    json={"prompt": contract_content, "mode": "trace"},
                    headers={"Content-Type": "application/json"},
                )
                execution_id = response.text

                execution_url = (
                    f"{n8n_url}/api/v1/executions/{execution_id}?includeData=true"
                )
                headers = {"X-N8N-API-KEY": os.getenv("N8N_API_KEY")}
                current_stage = ""
                while True:
                    response = requests.get(execution_url, headers=headers)
                    execution_data = response.json()

                    if execution_data["finished"]:
                        break

                    node_execution_stack = execution_data["data"]["executionData"].get(
                        "nodeExecutionStack", []
                    )

                    if (
                        node_execution_stack
                        and current_stage != node_execution_stack[0]["node"]["name"]
                    ):
                        current_stage = node_execution_stack[0]["node"]["name"]

                        tqdm.write(f"Current Node: {current_stage}")
                # final data parsing:
                final_node_name = execution_data["data"]["resultData"][
                    "lastNodeExecuted"
                ]
                workflow_reports = execution_data["data"]["resultData"]["runData"][
                    final_node_name
                ][0]["data"]["main"][0]
                if workflow_reports:
                    cnt = 0

                    for report in workflow_reports:
                        for report_json in report["json"].get("output", ["exception"]):
                            if report_json == "exception":
                                tqdm.write(
                                    f"\033[91m❌ Model output doesn't fit required format, escape one\033[0m"
                                )
                                continue
                            try:
                                vulnerability = AuditReport(**report_json)
                                vulnerabilities.append((contract_name, vulnerability))
                                cnt += 1
                            except ValidationError as e:
                                tqdm.write(
                                    f"\033[91m❌ Error parsing report: {e}\033[0m"
                                )
                                continue
                    if cnt == 0:
                        tqdm.write(
                            f"\033[92m✅ No vulnerability found in contract: {contract_file}\033[0m"
                        )
                    else:
                        tqdm.write(
                            f"\033[93m⚠️ Found {cnt} vulnerabilities in contract: {contract_file}\033[0m"
                        )
                tqdm.write(f"-" * 50)

            # Create a DataFrame for all vulnerabilities in the current contract
        df = pd.DataFrame(
            [
                {
                    "File Name": contract_name,
                    "Summary": report.summary,
                    "Severity": report.severity,
                    "Vulnerability": report.vulnerability_details,
                    "Recommendation": report.recommendation,
                }
                for contract_name, report in vulnerabilities
            ]
        )

        md_content = ""
        if not os.path.exists(output_path):
            os.makedirs(output_path, exist_ok=True)

        csv_file_path = f"{output_path}{report_name}.csv"
        json_file_path = f"{output_path}{report_name}.json"
        md_file_path = f"{output_path}{report_name}.md"
        pdf_file_path = f"{output_path}{report_name}.pdf"
        if df.empty:
            if "csv" in output_formats:
                with open(csv_file_path, "w") as f:
                    f.write("File Name,Summary,Severity,Vulnerability,Recommendation\n")
            elif "json" in output_formats:
                with open(json_file_path, "w") as f:
                    f.write("[]")
            elif "md" in output_formats:
                with open(md_file_path, "w") as f:
                    f.write("# Audit Report\n\nNo vulnerabilities found.\n")
            elif "pdf" in output_formats:
                generate_pdf(
                    "# Audit Report\n\nNo vulnerabilities found.\n",
                    pdf_file_path,
                )
        else:
            if "csv" in output_formats:
                df.to_csv(csv_file_path, index=False)
                tqdm.write(f"✅ CSV successfully generated : {csv_file_path}")

            if "json" in output_formats:
                # Generate JSON file (even if empty)
                generate_json(df, json_file_path)
                tqdm.write(f"✅ Json successfully generated: {json_file_path}")

            if "md" in output_formats:
                # Generate Markdown file (even if empty)
                md_content = generate_md(df, md_file_path)
                tqdm.write(f"✅ Markdown successfully generated: {md_file_path}")

            if "pdf" in output_formats:
                # Generate PDF file (even if empty)
                if not md_content:
                    md_content = generate_md(df, None)
                generate_pdf(md_content, pdf_file_path)
                tqdm.write(f"✅ PDF successfully generated: {pdf_file_path}")

    else:
        tqdm.write(
            f"\033[91m❌ No active processor workflows found. Please turn on the workflow in n8n or follow README to setup correctly. \033[0m"
        )
        return