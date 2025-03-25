def evaluate(csv_path: str, source_code_path: str, n8n_workflow_webhook_url: str):
    import time

    import pandas as pd
    import requests
    import sklearn.metrics
    from pandas import read_csv
    from tabulate import tabulate
    from tqdm import tqdm

    dataset = read_csv(csv_path)
    print(f"Found {len(dataset)} rows in dataset. Start evaluating...")
    print("-" * 50)
    y_pred = []
    y_true = []
    for index, row in tqdm(
        dataset.iterrows(),
        desc="Processed contracts",
        unit="file",
        ncols=100,
        total=len(dataset),
        colour="blue",
        bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} files [Time: {elapsed}]",
    ):

        if pd.isna(row["file_name"]) or pd.isna(row["answer"]):
            print("Invalid row, stop...")
            break

        with open(source_code_path + row["file_name"]) as f:
            file = f.read()
            data = {"prompt": file}
            response = requests.post(n8n_workflow_webhook_url, json=data)
            if response.status_code != 200:
                tqdm.write(
                    "\033[91m❌ n8n Workflow response abnormal, will stop...: {}\033[0m".format(
                        response.text
                    )
                )
                break
            try:
                json_data = response.json()
                y_pred.append(1 if json_data["output"] else 0)
                y_true.append(int(row["answer"]))
                tqdm.write(
                    "\033[92m✅ Successfully processed: {}\033[0m".format(
                        row["file_name"]
                    )
                )
            except Exception as e:
                tqdm.write(
                    "\033[91m❌ Error processing {}: {}\033[0m".format(
                        row["file_name"], str(e)
                    )
                )
                continue

    tn, fp, fn, tp = sklearn.metrics.confusion_matrix(
        y_pred=y_pred, y_true=y_true, labels=[0, 1]
    ).ravel()
    data = [
        ["True Positive", tp],
        ["True Negative", tn],
        ["False Positive", fp],
        ["False Negative", fn],
    ]
    table = tabulate(data, headers=["Metric", "Value"], tablefmt="grid")
    print(table)
