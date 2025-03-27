import dotenv
import evaluate
import init
import scan
import typer

dotenv.load_dotenv()

app = typer.Typer()
app.add_typer(evaluate.app, name="eval")
app.add_typer(init.app, name="init")
app.add_typer(scan.app, name="scan")
if __name__ == "__main__":
    app()
