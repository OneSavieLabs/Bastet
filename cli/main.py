import dotenv
import evaluate
import import_workflow
import scan
import typer

dotenv.load_dotenv()

app = typer.Typer()
app.add_typer(evaluate.app, name="eval")
app.add_typer(import_workflow.app, name="import_workflow")
app.add_typer(scan.app, name="scan")
if __name__ == "__main__":
    app()
