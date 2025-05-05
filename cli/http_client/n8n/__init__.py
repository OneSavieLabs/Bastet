"""
N8n API Client

A comprehensive HTTP client for the N8n API.
"""

from ._base_client import BaseHttpClient
from .client import N8n
from .exceptions import (
    APIError,
    APIStatusError,
    APIConnectionError,
    APITimeoutError,
    AuthenticationError,
    RateLimitError,
    NotFoundError,
    N8nWorkflowError
)

__all__ = [
    "N8n",
    "BaseHttpClient",
    "APIError",
    "APIStatusError",
    "APIConnectionError",
    "APITimeoutError",
    "AuthenticationError",
    "RateLimitError",
    "NotFoundError",
    "N8nWorkflowError"
]