def fetch_on_chain_contracts(
    address: str,
):

    import os
    import requests
    import json
    import shutil
    from tqdm import tqdm

    ETHERSCAN_API_KEY = os.getenv("ETHERSCAN_API_KEY")

    print(f"Fetching all related contracts from address: {address}")

    if not ETHERSCAN_API_KEY:
        raise RuntimeError("ETHERSCAN_API_KEY not set")

    url = "https://api.etherscan.io/v2/api?chainid=1"
    params = {
        "module": "contract",
        "action": "getsourcecode",
        "address": address,
        "apikey": ETHERSCAN_API_KEY,
    }

    response = requests.get(url, params=params, timeout=15).json()
    # if res.status != 1:
    #     raise RuntimeError(f"Etherscan API request failed with status code {res.status}")
    
    raw_source_code = response["result"][0]["SourceCode"]

    if raw_source_code == "":
        msg = f"❌ Contract {address} is not verified on Etherscan or is not existed"
        tqdm.write(f"\033[91m{msg}\033[0m")

    cleaned = raw_source_code.strip("{}")
    parsed = json.loads("{" + cleaned + "}")
    source_code = parsed["sources"]

    base_dir = os.path.join("dataset", "scan_queue")
    if os.path.exists(base_dir):
        shutil.rmtree(base_dir)

    os.makedirs(base_dir, exist_ok=True)

    contracts_fetched = 0
    
    # save all contracts under dataset/scan_queue
    for path, code in source_code.items():
        file_path = os.path.join(base_dir, path)
        os.makedirs(os.path.dirname(file_path), exist_ok=True)

        with open(file_path, "w") as f:
            f.write(code["content"])

        contracts_fetched += 1
        tqdm.write(f"\033[92m✅ Saved contract to: {file_path}\033[0m")

    tqdm.write(f"\033[94mTotal contracts fetched and saved: {contracts_fetched}\033[0m")