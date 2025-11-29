# # Dev configuration for Superset embedded dashboards with relaxed security.
import logging
import os

logger = logging.getLogger(__name__)

# # Enable embedded dashboards/guest tokens without RBAC complexity.
FEATURE_FLAGS = { "EMBEDDED_SUPERSET": True, "EMBEDDABLE_CHARTS": True, "ENABLE_TEMPLATE_PROCESSING": True, 'DASHBOARD_RBAC': True }
GUEST_ROLE_NAME = "Admin"
GUEST_TOKEN_JWT_SECRET = os.environ.get("GUEST_TOKEN_JWT_SECRET", "guest-token")
GUEST_TOKEN_JWT_EXP_SECONDS = 1800

ENABLE_CORS = False
WTF_CSRF_ENABLED = False
WTF_CSRF_EXEMPT_LIST = ["*"]

# # Cookies wide open so embeds and HTTP proxying just work locally.
# SESSION_COOKIE_HTTPONLY = False
# SESSION_COOKIE_SECURE = False
# SESSION_COOKIE_SAMESITE = "None"

# HTTP headers configuration.
# According to the official docs, X-Frame-Options defaults to SAMEORIGIN.
# Here we explicitly override it to ALLOWALL to allow embedding.
# ENABLE_PROXY_FIX = True
# PROXY_FIX_CONFIG = {"x_for": 1, "x_proto": 1, "x_host": 1, "x_port": 1, "x_prefix": 1}
# PREFERRED_URL_SCHEME = "http"
OVERRIDE_HTTP_HEADERS = { "X-Frame-Options": "ALLOWALL" }

# Disable Talisman so it does not re-impose restrictive security headers
# that would conflict with the custom X-Frame-Options above.
TALISMAN_ENABLED = False

# # Verbose logging makes debugging easier.
log_level_text = os.getenv("SUPERSET_LOG_LEVEL", "DEBUG")
LOG_LEVEL = getattr(logging, log_level_text.upper(), logging.DEBUG)
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "secret-key")

try:
    import superset_config_docker
    from superset_config_docker import *  # noqa

    logger.info(
        f"Loaded your Docker configuration at " f"[{superset_config_docker.__file__}]"
    )
except ImportError:
    logger.info("Using default Docker config...")

