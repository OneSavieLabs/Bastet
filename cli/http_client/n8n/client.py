from typing import Dict, Optional, Any
from ._base_client import BaseHttpClient
from .clients import (
    WorkflowClient,
    ExecutionClient,
    UserClient,
    CredentialClient,
    VariableClient,
    AuditClient,
    TagClient,
    SourceControlClient
)

class N8nClientFactory:
    """
    Factory class for creating N8n API clients for different API groups.
    
    This factory provides access to specialized clients for different parts of the N8n API,
    such as workflows, executions, users, etc.
    """
    
    def __init__(
        self,
        X_N8N_API: str,
        N8N_API_BASE_URL: str,
        timeout: int = 30,
        verify_ssl: bool = True,
        max_retries: int = 3
    ):
        """
        Initialize the N8n client factory.
        
        Args:
            X_N8N_API: N8n API key
            N8N_API_BASE_URL: Base URL for the N8n API
            timeout: Request timeout in seconds
            verify_ssl: Whether to verify SSL certificates
            max_retries: Maximum number of retries for failed requests
        """
        self.api_key = X_N8N_API
        self.base_url = N8N_API_BASE_URL
        self.timeout = timeout
        self.verify_ssl = verify_ssl
        self.max_retries = max_retries
        
        # Initialize client instances
        self._workflow_client = None
        self._execution_client = None
        self._user_client = None
        self._credential_client = None
        self._variable_client = None
        self._audit_client = None
        self._tag_client = None
        self._source_control_client = None
        
    def workflows(self) -> WorkflowClient:
        """Get the workflow client for managing workflows."""
        if not self._workflow_client:
            self._workflow_client = WorkflowClient(
                X_N8N_API=self.api_key,
                N8N_API_BASE_URL=self.base_url,
                timeout=self.timeout,
                verify_ssl=self.verify_ssl,
                max_retries=self.max_retries
            )
        return self._workflow_client
    
    def executions(self) -> ExecutionClient:
        """Get the execution client for managing workflow executions."""
        if not self._execution_client:
            self._execution_client = ExecutionClient(
                X_N8N_API=self.api_key,
                N8N_API_BASE_URL=self.base_url,
                timeout=self.timeout,
                verify_ssl=self.verify_ssl,
                max_retries=self.max_retries
            )
        return self._execution_client
    
    def users(self) -> UserClient:
        """Get the user client for managing users."""
        if not self._user_client:
            self._user_client = UserClient(
                X_N8N_API=self.api_key,
                N8N_API_BASE_URL=self.base_url,
                timeout=self.timeout,
                verify_ssl=self.verify_ssl,
                max_retries=self.max_retries
            )
        return self._user_client
    
    def credentials(self) -> CredentialClient:
        """Get the credential client for managing credentials."""
        if not self._credential_client:
            self._credential_client = CredentialClient(
                X_N8N_API=self.api_key,
                N8N_API_BASE_URL=self.base_url,
                timeout=self.timeout,
                verify_ssl=self.verify_ssl,
                max_retries=self.max_retries
            )
        return self._credential_client
    
    def variables(self) -> VariableClient:
        """Get the variable client for managing variables."""
        if not self._variable_client:
            self._variable_client = VariableClient(
                X_N8N_API=self.api_key,
                N8N_API_BASE_URL=self.base_url,
                timeout=self.timeout,
                verify_ssl=self.verify_ssl,
                max_retries=self.max_retries
            )
        return self._variable_client
    
    def audit(self) -> AuditClient:
        """Get the audit client for accessing audit logs."""
        if not self._audit_client:
            self._audit_client = AuditClient(
                X_N8N_API=self.api_key,
                N8N_API_BASE_URL=self.base_url,
                timeout=self.timeout,
                verify_ssl=self.verify_ssl,
                max_retries=self.max_retries
            )
        return self._audit_client
    
    def tags(self) -> TagClient:
        """Get the tag client for managing tags."""
        if not self._tag_client:
            self._tag_client = TagClient(
                X_N8N_API=self.api_key,
                N8N_API_BASE_URL=self.base_url,
                timeout=self.timeout,
                verify_ssl=self.verify_ssl,
                max_retries=self.max_retries
            )
        return self._tag_client
    
    def source_control(self) -> SourceControlClient:
        """Get the source control client for managing source control."""
        if not self._source_control_client:
            self._source_control_client = SourceControlClient(
                X_N8N_API=self.api_key,
                N8N_API_BASE_URL=self.base_url,
                timeout=self.timeout,
                verify_ssl=self.verify_ssl,
                max_retries=self.max_retries
            )
        return self._source_control_client
    
    def close(self) -> None:
        """Close all client connections."""
        clients = [
            self._workflow_client,
            self._execution_client,
            self._user_client,
            self._credential_client,
            self._variable_client,
            self._audit_client,
            self._tag_client,
            self._source_control_client
        ]
        
        for client in clients:
            if client:
                client.close()
    
    def __enter__(self) -> 'N8nClientFactory':
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()
