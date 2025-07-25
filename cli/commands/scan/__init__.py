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
        "./scan_report/",
        "--output-path",
        help="The folder path to store the output",
    ),
    output_format: str = typer.Option(
        "default",
        "--output-format",
        help="Output format group: 'default' for json+md, 'office' for docx+pdf",
        case_sensitive=False,
    ),
):

    if ctx.invoked_subcommand is None:
        valid_choices = ["default", "office"]
        if output_format not in valid_choices:
            typer.echo(f"Error: Invalid choice '{output_format}'. Choose from: {valid_choices}")
            raise typer.Exit(1)
        
        scan.scan_v1(
            folder_path=folder_path,
            n8n_url=n8n_url,
            output_path=output_path,
            output_format=output_format,
        )
