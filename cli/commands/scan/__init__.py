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
        "csv",
        "--output-format",
        help="Output formats: csv, json, md, pdf, or all. Use comma to separate multiple formats.",
    ),
):
    # Normalize and split formats
    output_format_list = [f.lower() for f in output_format.replace(",", " ").split()]
    
    valid_choices = {"csv", "json", "md", "pdf", "all"}

    # Validate
    if not set(output_format_list).issubset(valid_choices):
        invalid = set(output_format_list) - valid_choices
        typer.echo(f"❌ Invalid format(s): {', '.join(invalid)}. Choose from: {', '.join(valid_choices)}")
        raise typer.Exit(1)

    # Expand 'all' into all formats
    if "all" in output_format_list:
        output_format_list = ["csv", "json", "md", "pdf"]

    if ctx.invoked_subcommand is None:
        scan.scan_v1(
            folder_path=folder_path,
            n8n_url=n8n_url,
            output_path=output_path,
            output_format=output_format_list,
        )
