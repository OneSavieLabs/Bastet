def import_workflow(workflow_path: str, n8n_api_url: str):
    import json
    import os

    import requests
    from tqdm import tqdm

    # Settings
    API_KEY = os.getenv("N8N_API_KEY")
    HEADERS = {"X-N8N-API-KEY": API_KEY, "Content-Type": "application/json"}
    ALLOWED_FIELDS = {"name", "nodes", "connections", "settings", "staticData"}

    openai_credential_id = os.getenv("N8N_OPENAI_CREDENTIAL_ID")

    if openai_credential_id is None:
        tqdm.write(
            "\033[91m❌ OpenAI credential id is not set, please set it in the .env file\033[0m"
        )
        exit(1)

    imported_workflows = []
    existing_workflows = requests.get(
        f"{n8n_api_url}/workflows", headers=HEADERS
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

    # Import processor workflow files
    for filename in selected_files:
        if filename.endswith(".json"):
            file_path = os.path.join(workflow_path, filename)
            with open(file_path, "r") as file:
                workflow_data = json.load(file)
                workflow_name = workflow_data["name"]

                if workflow_name in existing_workflow_names:
                    tqdm.write(f"\033[94mℹ️ Workflow {filename} already exists.\033[0m")
                    continue

                filtered_workflow_data = {
                    key: workflow_data[key]
                    for key in workflow_data
                    if key in ALLOWED_FIELDS
                }
                # update openai credential id
                for node in filtered_workflow_data["nodes"]:
                    if node["type"] == "@n8n/n8n-nodes-langchain.openAi":
                        node["credentials"]["openAiApi"] = {
                            "id": openai_credential_id,
                            "name": "OpenAI account",
                        }
                try:
                    response = requests.post(
                        f"{n8n_api_url}/workflows",
                        headers=HEADERS,
                        json=filtered_workflow_data,
                    )
                    imported_workflows.append(
                        {"id": response.json()["id"], "name": workflow_name}
                    )
                    tqdm.write(
                        "\033[92m✅ Successfully imported: {}\033[0m".format(filename)
                    )
                except Exception as e:
                    tqdm.write(
                        "\033[91m❌ Failed to import: {}\033[0m".format(filename)
                    )
                    print(f"Import {filename} failed: {e}")

    if len(imported_workflows) == 0:
        tqdm.write("\033[9m❌ No workflows imported.\033[0m")
        exit(1)

    tqdm.write("\033[92m✅ All import tasks completed.\033[0m")
