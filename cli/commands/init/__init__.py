"""This module is a bridge of fetching posts from multiple platforms"""

import typer

from . import import_workflow as import_workflow_tool

app = typer.Typer()


@app.callback(invoke_without_command=True)
def default(
    workflow_path: str = typer.Option(
        "./n8n_workflow",
        "--workflow-path",
        help="The path to the workflow directory",
    ),
    n8n_url: str = typer.Option(
        "http://localhost:5678",
        "--n8n-url",
        help="The URL of the n8n",
    ),
):
    import_workflow_tool.import_workflow(workflow_path, n8n_url)
