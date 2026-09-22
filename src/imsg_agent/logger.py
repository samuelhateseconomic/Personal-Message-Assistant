"""Console and rotating file logging, configured once per logger."""

import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

from rich.logging import RichHandler


def get_logger(name: str = "imsg_agent", log_file: str | Path | None = None) -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    destination = str(Path(log_file).expanduser().resolve()) if log_file else "console"
    if not any(getattr(h, "_imsg_destination", None) == destination for h in logger.handlers):
        if log_file:
            Path(destination).parent.mkdir(parents=True, exist_ok=True)
            handler = RotatingFileHandler(destination, maxBytes=2_000_000, backupCount=3)
            handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        else:
            handler = RichHandler(show_path=False)
        handler._imsg_destination = destination
        logger.addHandler(handler)
    return logger
