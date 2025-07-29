"""This module is a bridge of fetching posts from multiple platforms"""

import typer

from . import eval as evalutation_tool

app = typer.Typer()


@app.callback(invoke_without_command=True)
def eval(
    ctx: typer.Context,
    csv_path: str = typer.Option(
        "./dataset/dataset.csv",
        "--csv-path",
        help="The path to the csv file to estimate, default is ./dataset/dataset_0723.csv",
    ),
    tag: str = typer.Option(
        "Slippage",
        "--tag",
        help="The tag of the n8n workflow to test, view detail at https://www.notion.so/Tag-Definitions-2228aea330a9802ba305c684aff241f7",
    ),
    n8n_workflow_webhook_url: str = typer.Option(
        "http://localhost:5678/webhook/slippage_minAmount",
        "--n8n-workflow-webhook-url",
        help="The URL of the n8n workflow webhook to test ",
    ),
    sample_size: int = typer.Option(
        10,
        "--size",
        help="The number of samples to evaluate, default is 10 (total 20 rows, 10 with tag and 10 without tag)",
    ),
    dataset_root: str = typer.Option(
        "./dataset/",
        "--dataset-root",
        help="The root path of the dataset, default is ./dataset/source_code/",
    ),
):
    if ctx.invoked_subcommand is None:
        evalutation_tool.evaluate(
            csv_path=csv_path,
            tag=tag,
            n8n_workflow_webhook_url=n8n_workflow_webhook_url,
            sample_size=sample_size,
            dataset_root=dataset_root,
        )
