"""This module is a bridge of fetching posts from multiple platforms"""

import typer

from . import eval as evalutation_tool
from . import eval_reentrancy

app = typer.Typer()


@app.callback(invoke_without_command=True)
def default(
    ctx: typer.Context,
    csv_path: str = typer.Option(
        "./dataset/dataset.csv",
        "--csv-path",
        help="The path to the csv file to estimate",
    ),
    source_code_path: str = typer.Option(
        "./dataset/source_code/",
        "--source-code-path",
        help="The path to the source code directory",
    ),
    n8n_workflow_webhook_url: str = typer.Option(
        "http://localhost:5678/webhook/slippage_minAmount",
        "--n8n-workflow-webhook-url",
        help="The URL of the n8n workflow webhook to test",
    ),
):
    if ctx.invoked_subcommand is None:
        evalutation_tool.evaluate(csv_path, source_code_path, n8n_workflow_webhook_url)


@app.command()
def reentrancy(
    csv_path: str = typer.Option(
        "./dataset/dataset_reentrancy.csv",
        "--csv-path",
        help="The path to the csv file to estimate",
    ),
    source_code_path: str = typer.Option(
        "./dataset/reentrancy/",
        "--source-code-path",
        help="The path to the source code directory",
    ),
    n8n_workflow_webhook_url: str = typer.Option(
        "http://localhost:5678/webhook/reentrancy",
        "--n8n-workflow-webhook-url",
        help="The URL of the n8n workflow webhook to test",
    ),
):
    eval_reentrancy.evaluate_reentrancy(
        csv_path, source_code_path, n8n_workflow_webhook_url
    )
