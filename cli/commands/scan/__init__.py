import typer

from . import scan

app = typer.Typer()


@app.callback(invoke_without_command=True)
def default(
    ctx: typer.Context,
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

    if ctx.invoked_subcommand is None:
        scan.scan_v1(
            folder_path=folder_path,
            n8n_url=n8n_url,
            output_path=output_path,
        )
