def scan_v1(folder_path: str, n8n_url: str, output_path: str):
    import glob
    import os

    import pandas as pd
    import requests
    from models.audit_report import AuditReport
    from models.n8n.node import WebhookNode
    from pydantic import ValidationError
    from tqdm import tqdm

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
        audit_reports: list[AuditReport] = []
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
                    json={
                        "prompt": contract_content,
                    },
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
                                audit_report = AuditReport(**report_json)
                                audit_reports.append(audit_report)
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
        df = pd.DataFrame(
            [
                {
                    "File Name": contract_file,
                    "Summary": report.summary,
                    "Severity": report.severity,
                    "Vulnerability": report.vulnerability_details,
                    "Recommendation": report.recommendation,
                }
                for report in audit_reports
            ]
        )
        df.to_csv(output_path + "audit_reports.csv", index=False)

    else:
        tqdm.write(
            f"\033[91m❌ No active processor workflows found. Please turn on the workflow in n8n or follow README to setup correctly. \033[0m"
        )
        return
