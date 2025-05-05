"""
N8n API client modules for different API groups.
"""

from .workflow import WorkflowClient
from .execution import ExecutionClient
from .user import UserClient
from .credential import CredentialClient
from .variable import VariableClient
from .audit import AuditClient
from .tag import TagClient
from .source_control import SourceControlClient

__all__ = [
    "WorkflowClient",
    "ExecutionClient",
    "UserClient",
    "CredentialClient",
    "VariableClient",
    "AuditClient",
    "TagClient",
    "SourceControlClient"
]
