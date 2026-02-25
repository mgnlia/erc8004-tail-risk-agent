"""Entry point for the ERC-8004 Tail Risk Agent."""

import logging
import uvicorn

from .config import settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

if __name__ == "__main__":
    uvicorn.run(
        "src.api:app",
        host=settings.api_host,
        port=settings.api_port,
        reload=False,
        log_level="info",
    )
