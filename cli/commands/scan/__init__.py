"""This module is a bridge of fetching posts from multiple platforms"""

import typer

from . import scan as scan_tool
from . import scan_v1 as scan_tool_v1

app = typer.Typer()


@app.callback(invoke_without_command=True)
def default(
    ctx: typer.Context,
    folder_path: str = typer.Option(
        "./dataset/scan_queue/",
        "--folder-path",
        help="The folder path to scan",
    ),
    n8n_workflow_webhook_url: str = typer.Option(
        "http://localhost:5678/webhook/main-workflow",
        "--n8n-workflow-webhook-url",
        help="The URL of the n8n main workflow webhook",
    ),
):

    if ctx.invoked_subcommand is None:
        scan_tool.scan(folder_path, n8n_workflow_webhook_url)


@app.command("scan-v1")
def scan_v1(
    folder_path: str = typer.Option(
        "./dataset/scan_queue/",
        "--folder-path",
        help="The folder path to scan",
    ),
    n8n_url: str = typer.Option(
        "http://localhost:5678",
        "--n8n-url",
        help="The url of the n8n.",
    ),
    output_path: str = typer.Option(
        "./",
        "--output-path",
        help="The folder path to store the output",
    ),
):
    """Scan the contracts in the folder and store the result in the database"""
    scan_tool_v1.scan_v1(
        folder_path=folder_path,
        n8n_url=n8n_url,
        output_path=output_path,
    )
