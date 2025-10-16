def import_workflow(workflow_path: str, n8n_url: str):
    import json
    import os

    import requests
    from tqdm import tqdm

    # Settings
    API_KEY = os.getenv("N8N_API_KEY")
    HEADERS = {"X-N8N-API-KEY": API_KEY}
    ALLOWED_FIELDS = {"name", "nodes", "connections", "settings", "staticData"}

    openai_credential_id = os.getenv("N8N_OPENAI_CREDENTIAL_ID")
    openai_model_name = os.getenv("OPENAI_MODEL_NAME", "gpt-4o-mini")
    if openai_credential_id is None:
        openai_api_key = os.getenv("OPENAI_API_KEY")
        openai_base_url = os.getenv("OPENAI_API_BASE", "https://api.openai.com/v1")
        if openai_api_key is not None:
            response = requests.post(
                f"{n8n_url}/api/v1/credentials",
                headers={"X-N8N-API-KEY": API_KEY},
                json={
                    "name": "OpenAI Credentials",
                    "type": "openAiApi",
                    "data": {
                        "headerName": "X-N8N-API-KEY",
                        "headerValue": API_KEY,
                        "apiKey": openai_api_key,
                        "url": openai_base_url,
                    },
                },
            )
            if response.status_code == 200:
                openai_credential_id = response.json()["id"]
                tqdm.write(
                    "\033[92m✅ Successfully create OpenAI credential with id: {}\033[0m".format(
                        openai_credential_id
                    )
                )
            else:
                tqdm.write(
                    "\033[91m❌ Failed to create OpenAI credential: {}\033[0m".format(
                        response.text
                    )
                )
                exit(1)
        else:
            tqdm.write(
                "\033[91m❌ OpenAI credential id is not set, please set it in the .env file\033[0m"
            )
            exit(1)

    existing_workflows = requests.get(
        f"{n8n_url}/api/v1/workflows", headers=HEADERS
    ).json()["data"]
    existing_workflow_names = [workflow["name"] for workflow in existing_workflows]

    # Scan workflow files
    workflow_files = [f for f in os.listdir(workflow_path) if f.endswith(".json")]

    if not workflow_files:
        print("No workflow files found in the folder.")
        exit(1)

    print(f"Found {len(workflow_files)} workflow files.")
    for i, filename in enumerate(workflow_files, 1):
        print(f"{i}. {filename}")

    # Let user select the processor workflow to import
    while True:
        selection = input(
            "\nplease enter the file number to import (comma separated, e.g. '1, 3, 5') or 'all' to import all: \n"
        )
        if selection.strip().lower() == "all":
            selected_files = workflow_files
            break
        try:
            selected_indices = [int(i.strip()) - 1 for i in selection.split(",")]
            if all(0 <= i < len(workflow_files) for i in selected_indices):
                selected_files = [workflow_files[i] for i in selected_indices]
                break
            else:
                print("Error: The input number is out of range, please re-enter!")
        except ValueError:
            print("Error: Please enter a valid number or 'all'!")

    print(
        f"Importing {len(selected_files)} workflow files: {', '.join(selected_files)}"
    )

    is_success = True
    # Import workflow files
    for filename in tqdm(
        selected_files,
        desc="Importing workflows",
        unit="workflow",
        ncols=100,
        colour="green",
        bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} workflows [Time: {elapsed}]",
        mininterval=0.01,
    ):
        if filename.endswith(".json"):
            file_path = os.path.join(workflow_path, filename)
            with open(file_path, "r") as file:
                workflow_data = json.load(file)
                workflow_name = workflow_data["name"]

                if workflow_name in existing_workflow_names:
                    tqdm.write(f"\033[94mℹ️  Workflow {filename} already exists.\033[0m")
                    continue

                filtered_workflow_data = {
                    key: workflow_data[key]
                    for key in workflow_data
                    if key in ALLOWED_FIELDS
                }
                # update openai credential id
                for node in filtered_workflow_data["nodes"]:
                    if node["type"] == "@n8n/n8n-nodes-langchain.lmChatOpenAi":
                        node["credentials"]["openAiApi"] = {
                            "id": openai_credential_id,
                            "name": "OpenAI credential",
                        }
                        node["parameters"]["model"]["value"] = openai_model_name
                try:
                    response = requests.post(
                        f"{n8n_url}/api/v1/workflows",
                        headers=HEADERS,
                        json=filtered_workflow_data,
                    )
                    workflow_id = response.json()["id"]

                    response = requests.post(
                        f"{n8n_url}/api/v1/workflows/{workflow_id}/activate",
                        headers=HEADERS,
                        json=filtered_workflow_data,
                    )

                    response.raise_for_status()

                    tqdm.write(
                        "\033[92m✅ Successfully initialize: {}\033[0m".format(filename)
                    )
                except Exception as e:
                    is_success = False
                    tqdm.write(
                        "\033[91m❌ Failed to initialize: {}\033[0m".format(filename)
                    )
                    print(f"Import {filename} failed: {e}")

    if not is_success:
        tqdm.write(
            "\033[93m⚠️ Some import tasks failed, please check the error messages above.\033[0m"
        )
        exit(1)
    else:
        tqdm.write("\033[92m✅ All import tasks completed sucessfully.\033[0m")
