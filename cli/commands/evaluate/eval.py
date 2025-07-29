def evaluate(
    csv_path: str,
    tag: str,
    n8n_workflow_webhook_url: str,
    sample_size: int,
    dataset_root: str,
):

    import os
    from pprint import pprint

    import pandas as pd
    import requests
    import sklearn.metrics
    from charset_normalizer import from_path
    from pandas import read_csv
    from tabulate import tabulate
    from tqdm import tqdm

    support_file_types: list = [".sol"]
    dataset = read_csv(csv_path)
    dataset = dataset[dataset["status"] == "Done"]
    print(f"Found {len(dataset)} rows in dataset. Start separeting...")
    print("-" * 50)
    row_tagged = dataset[dataset["tag"] == tag]
    row_untagged = dataset[dataset["tag"] != tag]

    random_rows_tagged = row_tagged.sample(
        n=min(sample_size, len(row_tagged), len(row_untagged))
    )  # Sample rows with sample_size or less if not enough
    random_rows_untagged = row_untagged.sample(
        n=min(sample_size, len(row_tagged), len(row_untagged))
    )  # Sample 100 rows or less if not enough

    pprint(
        f"Randomly selected {len(random_rows_tagged)} rows with tag {tag}. IDs: {', '.join(random_rows_tagged['Property'].astype(int).astype(str))}"
    )
    pprint(
        f"Randomly selected {len(random_rows_untagged)} rows without tag {tag}. IDs: {', '.join(random_rows_untagged['Property'].astype(int).astype(str))}"
    )

    # Combine the two sampled DataFrames
    combined_rows = pd.concat([random_rows_tagged, random_rows_untagged])
    combined_rows = combined_rows.sample(frac=1).reset_index(drop=True)
    print(f"Total {len(combined_rows)} rows to evaluate.")
    print("-" * 50)

    y_pred = []  # predicted labels
    y_true = []  # true labels
    workflow_answers = []
    for index, row in tqdm(
        combined_rows.iterrows(),
        desc="Processed contracts",
        unit="file",
        ncols=100,
        total=len(combined_rows),
        colour="blue",
        bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} repos [Time: {elapsed}]",
    ):

        repo_path = dataset_root + row["repo_path"]
        # Recursively process all files in the repo_path directory
        ans = 0
        for root, dirs, files in os.walk(repo_path):
            print(f"Processing directory: {root}")
            if ans == 1:  # if one of the file has the tag, break
                break
            for file in files:
                if not any(file.endswith(ext) for ext in support_file_types):
                    continue
                file_path = os.path.join(root, file)
                encoding_result = from_path(file_path).best()
                if encoding_result is not None and hasattr(encoding_result, "encoding"):
                    file_encoding = encoding_result.encoding
                else:
                    continue
                with open(file_path, encoding=file_encoding) as f:
                    file_content = f.read()
                    data = {"prompt": file_content}
                    response = requests.post(n8n_workflow_webhook_url, json=data)
                    if response.status_code != 200:
                        tqdm.write(
                            "\033[91m❌ n8n Workflow response abnormal, retry...: {}\033[0m".format(
                                response.text
                            )
                        )
                        continue

                    try:
                        json_data = response.json()
                        workflow_answers.append(json_data)
                        if any(
                            "output" in obj and obj["output"] != [] for obj in json_data
                        ):
                            y_pred.append(1)
                            y_true.append(tag in row["tag"])
                            ans = 1
                            break
                        tqdm.write(
                            "\033[92m✅ Successfully processed: {}\033[0m".format(
                                file_path
                            )
                        )
                    except Exception as e:
                        tqdm.write(
                            "\033[91m❌ Error processing {}: {}\033[0m".format(
                                row["file_name"], str(e)
                            )
                        )
                        continue
        if ans == 0:
            tqdm.write(
                "\033[92m✅ No vulnerability {} found in repo: {}\033[0m".format(
                    tag, repo_path
                )
            )
            y_pred.append(0)
            y_true.append(tag in row["tag"])

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
    print("accuracy:", (tp + tn) / (tp + tn + fp + fn))
    print("precision:", tp / (tp + fp))
    print("recall:", tp / (tp + fn))
    print("f1:", 2 * tp / (2 * tp + fp + fn))

    df = pd.DataFrame(
        {
            "file_name": combined_rows["repo_path"],
            "predicted_label": y_pred,
            "true_label": y_true,
        }
    )
    df.to_csv("evaluation_results.csv", index=False)
