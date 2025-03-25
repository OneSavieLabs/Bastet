import os
import dotenv
import typer
import evaluate

dotenv.load_dotenv()

app = typer.Typer()
app.add_typer(evaluate.app, name="eval")

if __name__ == "__main__":
    app()
