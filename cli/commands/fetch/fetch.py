def fetch_on_chain_contracts(
    address: str,
):

    import os
    import requests
    import json
    from tqdm import tqdm

    ETHERSCAN_API_KEY = os.getenv("ETHERSCAN_API_KEY")

    if not ETHERSCAN_API_KEY:
        tqdm.write("\033[91m❌ ETHERSCAN_API_KEY environment variable not set\033[0m")
        return

    if not address.startswith("0x") or len(address) != 42:
        tqdm.write(f"\033[91m❌ Invalid Ethereum address format: {address}\033[0m")
        return

    output_dir = os.path.join("dataset", "onchain_sources", address)
    if os.path.exists(output_dir):
        tqdm.write(f"\033[93m⚠️  Directory already exists. Skip fetching {address}\033[0m")
        return

    tqdm.write(f"Fetching all related contracts from address: {address}")

    api_url = "https://api.etherscan.io/v2/api?chainid=1"
    api_params = {
        "module": "contract",
        "action": "getsourcecode",
        "address": address,
        "apikey": ETHERSCAN_API_KEY,
    }

    response_json = requests.get(api_url, params=api_params, timeout=15).json()
    if response_json.get("status") != "1":
        error_message = response_json.get("result")
        tqdm.write(f"\033[91m❌ Etherscan API request failed: {error_message}\033[0m")
        return
    
    source_entry = response_json.get("result")[0]
    raw_source_code = source_entry.get("SourceCode", "")

    if raw_source_code == "":
        msg = f"❌ Contract {address} is not verified on Etherscan or is not existed"
        tqdm.write(f"\033[91m{msg}\033[0m")
        return

    stripped_code = raw_source_code.strip("{}")
    parsed_code = json.loads("{" + stripped_code + "}")
    source_code = parsed_code.get("sources")

    os.makedirs(output_dir, exist_ok=True)

    contracts_fetched = 0
    
    # save all contracts under dataset/onchain_sources
    for path, code in source_code.items():
        file_path = os.path.join(output_dir, path)
        os.makedirs(os.path.dirname(file_path), exist_ok=True)

        with open(file_path, "w") as f:
            f.write(code.get("content", ""))

        contracts_fetched += 1
        tqdm.write(f"\033[92m✅ Saved contract to: {file_path}\033[0m")

    tqdm.write(f"\033[94mTotal contracts fetched and saved: {contracts_fetched}\033[0m")