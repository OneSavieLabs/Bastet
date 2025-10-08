"""CLI for fetching related contracts from a given Ethereum address"""

import typer
from . import fetch as fetch_tool

app = typer.Typer()


@app.callback(invoke_without_command=True)
def fetch_contracts(
    address: str = typer.Option(
        "0x0000000000000000000000000000000000000000",
        "--address",
        help="Ethereum contract address to fetch related contracts",
    ),
):
    fetch_tool.fetch_on_chain_contracts(address)
