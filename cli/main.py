import dotenv
import typer
from commands import evaluate, init, scan

dotenv.load_dotenv()

app = typer.Typer()
app.add_typer(evaluate.app, name="eval")
app.add_typer(init.app, name="init")
app.add_typer(scan.app, name="scan")
if __name__ == "__main__":
    app()
