"""Load configuration without overwriting existing settings."""

from pathlib import Path

from imsg_agent.models import AppConfig


def load_config(path: str | Path | None = None) -> AppConfig:
    config_path = Path(path).expanduser() if path else Path.home() / ".imsg-agent/config.json"
    config_path = config_path.resolve()
    if config_path.exists():
        config = AppConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
    else:
        config = AppConfig(data_dir=str(config_path.parent))
        config_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with config_path.open("x", encoding="utf-8") as handle:
                handle.write(config.model_dump_json(indent=2) + "\n")
        except FileExistsError:
            config = AppConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
    data_dir = Path(config.data_dir).expanduser()
    if not data_dir.is_absolute():
        data_dir = config_path.parent / data_dir
    config.data_dir = str(data_dir.resolve())
    return config
