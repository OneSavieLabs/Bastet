import dotenv
import evaluate
import typer

dotenv.load_dotenv()

app = typer.Typer()
app.add_typer(evaluate.app, name="eval")

if __name__ == "__main__":
    app()
