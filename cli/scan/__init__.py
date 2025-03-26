"""This module is a bridge of fetching posts from multiple platforms"""

import typer

from . import scan as scan_tool

app = typer.Typer()

@app.callback(invoke_without_command=True)
def default(
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
    scan_tool.scan(folder_path, n8n_workflow_webhook_url)
