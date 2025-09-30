import dotenv
import typer
from commands import evaluate, init, scan, fetch

dotenv.load_dotenv()

app = typer.Typer()
app.add_typer(evaluate.app, name="eval")
app.add_typer(init.app, name="init")
app.add_typer(scan.app, name="scan")
app.add_typer(fetch.app, name="fetch")
if __name__ == "__main__":
    app()
