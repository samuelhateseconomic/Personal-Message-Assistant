"""Entry Point — Allows running the agent via `python -m imsg_agent`.

Delegates to the Typer CLI app defined in cli.py.
"""

from imsg_agent.cli import app


def main():
    app()


if __name__ == "__main__":
    main()
