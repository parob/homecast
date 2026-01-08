import os
import logging
from typing import Any

from dotenv import load_dotenv


load_dotenv()


# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')

# Server Configuration
PORT: int = 8080

# Allowed CORS origins
ALLOWED_CORS_ORIGINS: list[str] = [
    "http://localhost:3000",
    "https://homecast.cloud",
    "https://www.homecast.cloud",
    "https://fc18532a-51b0-461b-8f4d-d9ab847d3c95.lovableproject.com",
    "https://id-preview--fc18532a-51b0-461b-8f4d-d9ab847d3c95.lovable.app",
    "https://homecast.lovable.app",
    "https://preview--homecast.lovable.app",
]

# Allowed CORS origin patterns (for wildcard matching)
ALLOWED_CORS_ORIGIN_PATTERNS: list[str] = [
    r"https://.*\.lovable\.app",
    r"https://.*\.lovableproject\.com",
]

# Database Configuration
DATABASE_URL: str = "sqlite:///./homecast.db"

# Cross-instance routing (GCP Pub/Sub)
GCP_PROJECT_ID: str = ""  # e.g., "my-project-id" - empty means local-only mode
GCP_PUBSUB_TOPIC_PREFIX: str = "homecast-instance"  # Topics will be: homecast-instance-a7f2, etc.

# JWT Configuration
JWT_SECRET: str = "change-me-in-production"
JWT_ALGORITHM: str = "HS256"
JWT_EXPIRY_HOURS: int = 24 * 7  # 1 week

# Database startup behavior
VALIDATE_OR_WIPE_DB_ON_STARTUP: bool = True
CREATE_DB_ON_STARTUP: bool = True


def _get_env_value(key: str, default_value: Any) -> Any:
    """
    Retrieves a configuration value from the environment, with type casting.
    """
    value = os.getenv(key)

    if value is None:
        return default_value

    # Handle type casting based on the default value's type
    if default_value is not None:
        if isinstance(default_value, list):
            return [item.strip() for item in value.split(',')]
        if isinstance(default_value, bool):
            return value.lower() in ('true', '1', 't')
        if isinstance(default_value, int):
            try:
                return int(value)
            except (ValueError, TypeError):
                return default_value

    return value


def _load_from_environment():
    """
    Dynamically loads configuration from environment variables by inspecting
    module-level variables and overwriting them if an environment variable
    with the same name is found.
    """
    g = globals()
    for key, default_value in g.copy().items():
        # We only consider uppercase variables to be configuration settings
        if key.isupper():
            g[key] = _get_env_value(key, default_value)


# Load overrides from the environment when the module is imported
_load_from_environment()
