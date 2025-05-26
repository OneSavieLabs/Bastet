"""
Exceptions for the N8n HTTP client.
"""

from ._base_client import (
    APIError,
    APIStatusError,
    APIConnectionError,
    APITimeoutError,
    AuthenticationError,
    RateLimitError,
    NotFoundError
)

class N8nWorkflowError(APIStatusError):
    """Raised when there's an error with a workflow operation."""
    pass

class N8nExecutionError(APIStatusError):
    """Raised when there's an error with workflow execution."""
    pass

class N8nValidationError(APIStatusError):
    """Raised when the request data is invalid."""
    pass

__all__ = [
    "APIError",
    "APIStatusError",
    "APIConnectionError",
    "APITimeoutError",
    "AuthenticationError",
    "RateLimitError",
    "NotFoundError",
    "N8nWorkflowError",
    "N8nExecutionError",
    "N8nValidationError"
]
