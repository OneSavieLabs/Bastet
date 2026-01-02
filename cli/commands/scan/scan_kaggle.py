def scan_v2(
    folder_path: str,
    n8n_url: str,
    report_name: str,
    output_path: str,
):

    import os

    import pandas as pd
    import requests
    from models.audit_report import AuditReportV2
    from models.n8n.node import WebhookNode
    from pydantic import ValidationError
    from tqdm import tqdm
    from utils.source_bundler import SourceBundler

    tqdm.write("Scanning contracts...")
    source_bundler = SourceBundler(["solidity"])
    contract_files = source_bundler.bundle_project(folder_path)

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
        vul_key_set = set()
        vulnerabilities: list[AuditReportV2] = []
        # audit_reports: list[AuditReport] = []
        for contract_path, contract_content in tqdm(
            contract_files.items(),
            desc="Processing contracts",
            unit="file",
            ncols=100,
            colour="blue",
            bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} files [Time: {elapsed}]",
            mininterval=0.01,
            # file=sys.stdout,
        ):
            tqdm.write(f"start scanning contract: {contract_path}")
            tqdm.write(f"-" * 50)
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
                                vulnerability = AuditReportV2(**report_json)
                                vul_key = ",".join(
                                    vulnerability.tag + vulnerability.subtag
                                )
                                if vul_key in vul_key_set:
                                    tqdm.write(
                                        "\033[91m❌ Duplicate vulnerability found, skipping...\033[0m"
                                    )
                                    continue
                                vulnerabilities.append(vulnerability)
                                vul_key_set.add(vul_key)
                                cnt += 1
                            except ValidationError as e:
                                tqdm.write(
                                    f"\033[91m❌ Error parsing report: {e}\033[0m"
                                )
                                continue
                    if cnt == 0:
                        tqdm.write(
                            f"\033[92m✅ No vulnerability found in contract: {contract_path}\033[0m"
                        )
                    else:
                        tqdm.write(
                            f"\033[93m⚠️ Found {cnt} vulnerabilities in contract: {contract_path}\033[0m"
                        )
                tqdm.write(f"-" * 50)

            # Create a DataFrame for all vulnerabilities in the current contract
        df = pd.DataFrame(
            [
                {
                    "Tag": ",".join(report.tag),
                    "Subtag": ",".join(report.subtag),
                    "Severity": report.severity,
                    "Description": report.description,
                }
                for report in vulnerabilities
            ]
        )

        if not os.path.exists(output_path):
            os.makedirs(output_path, exist_ok=True)

        csv_file_path = f"{output_path}{report_name}.csv"

        if df.empty:
            with open(csv_file_path, "w") as f:
                f.write("File Name,Tag,Subtag,Severity,Description\n")
        else:
            df.to_csv(csv_file_path, index=False)
            tqdm.write(f"✅ CSV successfully generated : {csv_file_path}")

    else:
        tqdm.write(
            f"\033[91m❌ No active processor workflows found. Please turn on the workflow in n8n or follow README to setup correctly. \033[0m"
        )
        return
