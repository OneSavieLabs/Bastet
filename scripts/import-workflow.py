import requests
import os
import json
from dotenv import load_dotenv
from tqdm import tqdm

load_dotenv()

# Settings
API_KEY = os.getenv("N8N_API_KEY")
N8N_URL = "http://localhost:5678/api/v1"
HEADERS = {"X-N8N-API-KEY": API_KEY, "Content-Type": "application/json"}
WORKFLOW_FOLDER_PATH = "../n8n/workflows"
ALLOWED_FIELDS = {"name", "nodes", "connections", "settings", "staticData"}

openai_credential_id = os.getenv("N8N_OPENAI_CREDENTIAL_ID")
n8n_api_credential_id = os.getenv("N8N_API_CREDENTIAL_ID")

if openai_credential_id is None:
  tqdm.write("\033[91m❌ OpenAI credential id is not set, please set it in the .env file\033[0m")
  exit(1)

if n8n_api_credential_id is None:
  tqdm.write("\033[91m❌ n8n api credential id is not set, please set it in the .env file\033[0m")
  exit(1)

imported_workflows = []
existing_workflows = requests.get(f"{N8N_URL}/workflows", headers=HEADERS).json()["data"]
existing_workflow_names = [workflow["name"] for workflow in existing_workflows]
main_workflow_name = "main-workflow.json"


# Scan workflow files
workflow_files = [f for f in os.listdir(WORKFLOW_FOLDER_PATH) if f.endswith(".json")]
workflow_files = [f for f in workflow_files if f != main_workflow_name]
if not workflow_files:
  print("No workflow files found in the folder.")
  exit(1)

print(f"Found {len(workflow_files)} processor workflow files.")
for i, filename in enumerate(workflow_files, 1):
    print(f"{i}. {filename}")

# Let user select the processor workflow to import
while True:
    selection = input("\nplease enter the file number to import (comma separated, e.g. '1, 3, 5') or 'all' to import all: \n")
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

print(f"Importing {len(selected_files)} processor workflow files: {', '.join(selected_files)}")

# import main workflow
main_workflow_path = os.path.join(WORKFLOW_FOLDER_PATH, main_workflow_name)
with open(main_workflow_path, "r") as file:
  main_workflow_data = json.load(file)
  main_workflow_name = main_workflow_data['name']

  if main_workflow_name in existing_workflow_names:
    tqdm.write("\033[94mℹ️  Main workflow already exists.\033[0m")
  else:
    filtered_main_workflow_data = {key: main_workflow_data[key] for key in main_workflow_data if key in ALLOWED_FIELDS}
    # update n8n api credential id
    for node in filtered_main_workflow_data["nodes"]:
      if (node["type"] == "n8n-nodes-base.n8n"):
        node["credentials"]["n8nApi"] = {
          "id": n8n_api_credential_id,
          "name": "n8n account"
        }
    try:
      response = requests.post(f"{N8N_URL}/workflows", headers=HEADERS, json=filtered_main_workflow_data)
      tqdm.write("\033[92m✅ Successfully imported main workflow\033[0m")
    except Exception as e:
      tqdm.write(f"\033[91m❌ Failed to import main workflow: {e}\033[0m")

# Import processor workflow files
for filename in selected_files:
  if filename.endswith(".json"):
    file_path = os.path.join(WORKFLOW_FOLDER_PATH, filename)
    with open(file_path, "r") as file:
      workflow_data = json.load(file)
      workflow_id = workflow_data['id']
      workflow_name = workflow_data['name']

      if workflow_name in existing_workflow_names:
        tqdm.write(f"\033[94mℹ️  Processor workflow {filename} already exists.\033[0m")
        continue

      filtered_workflow_data = {key: workflow_data[key] for key in workflow_data if key in ALLOWED_FIELDS}
      # update openai credential id
      for node in filtered_workflow_data["nodes"]:
        if (node["type"] == "@n8n/n8n-nodes-langchain.openAi"):
            node["credentials"]["openAiApi"] = {
              "id": openai_credential_id,
              "name": "OpenAI account"
            }

      try:
        response = requests.post(f"{N8N_URL}/workflows", headers=HEADERS, json=filtered_workflow_data)
        tqdm.write("\033[92m✅ Successfully imported: {}\033[0m".format(filename))
        imported_workflows.append({
          "id": response.json()['id'],
          "name": workflow_name
        })
      except Exception as e:
        tqdm.write("\033[91m❌ Failed to import: {}\033[0m".format(filename))
        print(f"Import {filename} failed: {e}")

if (len(imported_workflows) == 0):
  tqdm.write("\033[9m❌ No workflows imported.\033[0m")
  exit(1)

# Add 'processor' tag to workflows
try:
  tags = requests.get(f"{N8N_URL}/tags", headers=HEADERS).json()
  processor_tag = None
  if any(tag["name"] == "processor" for tag in tags['data']):
    processor_tag = next((tag for tag in tags['data'] if tag["name"] == "processor"), None)
    tqdm.write("\033[94mℹ️  Tag 'processor' already exists.\033[0m")
  else:
      processor_tag = requests.post(f"{N8N_URL}/tags", headers=HEADERS, json={"name": "processor"}).json()
      tqdm.write("\033[92m✅ Tag 'processor' created.\033[0m")
except Exception as e:
  tqdm.write("\033[91m❌ Failed to create 'processor' tag: {e}\033[0m")

for workflow in imported_workflows:
  workflow_id = workflow['id']
  workflow_name = workflow['name']
  updated_tags = [{"id": processor_tag['id']}]
  try:
    response = requests.put(f"{N8N_URL}/workflows/{workflow_id}/tags", headers=HEADERS, json=updated_tags)
    if response.status_code == 200:
      tqdm.write(f"\033[92m✅ Workflow {workflow_name} updated with 'processor' tag.\033[0m")
  except Exception as e:
    tqdm.write(f"\033[91m❌ Failed to update workflow {workflow_name}: {e}\033[0m")

tqdm.write("\033[92m✅ All import tasks completed.\033[0m")
