"""
N8n API client modules for different API groups.
"""

from .workflow_client import WorkflowClient
from .execution_client import ExecutionClient
from .user_client import UserClient
from .credential_client import CredentialClient
from .variable_client import VariableClient
from .audit_client import AuditClient
from .tag_client import TagClient
from .source_control_client import SourceControlClient

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
