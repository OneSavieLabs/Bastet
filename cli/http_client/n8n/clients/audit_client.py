from typing import Dict, List, Optional, Any
from ..exceptions import APIStatusError
from .._base_client import BaseHttpClient

class AuditClient(BaseHttpClient):
    """
    Client for the N8n Audit API.
    
    This client provides methods to access audit logs in N8n.
    """
    
    async def get_audit_logs(self, 
                           limit: int = 20,
                           cursor: Optional[str] = None,
                           filter_by_user_id: Optional[str] = None,
                           filter_by_action: Optional[str] = None,
                           filter_by_resource_type: Optional[str] = None,
                           filter_by_resource_id: Optional[str] = None,
                           filter_by_date_from: Optional[str] = None,
                           filter_by_date_to: Optional[str] = None) -> Dict[str, Any]:
        """
        Get audit logs with optional filtering.
        
        Args:
            limit: Maximum number of logs to return
            cursor: Cursor for pagination
            filter_by_user_id: Filter logs by user ID
            filter_by_action: Filter logs by action (e.g., "create", "update", "delete")
            filter_by_resource_type: Filter logs by resource type (e.g., "workflow", "credential")
            filter_by_resource_id: Filter logs by resource ID
            filter_by_date_from: Filter logs from this date (ISO format)
            filter_by_date_to: Filter logs to this date (ISO format)
            
        Returns:
            Dictionary containing logs and pagination info
        """
        params = {"limit": limit}
        
        if cursor:
            params["cursor"] = cursor
            
        if filter_by_user_id:
            params["filterBy[userId]"] = filter_by_user_id
            
        if filter_by_action:
            params["filterBy[action]"] = filter_by_action
            
        if filter_by_resource_type:
            params["filterBy[resourceType]"] = filter_by_resource_type
            
        if filter_by_resource_id:
            params["filterBy[resourceId]"] = filter_by_resource_id
            
        if filter_by_date_from:
            params["filterBy[dateFrom]"] = filter_by_date_from
            
        if filter_by_date_to:
            params["filterBy[dateTo]"] = filter_by_date_to
            
        return await self.get("audit", params=params)
    
    async def get_audit_log(self, log_id: str) -> Dict[str, Any]:
        """
        Get a specific audit log by ID.
        
        Args:
            log_id: The ID of the audit log
            
        Returns:
            Audit log object
        """
        return await self.get(f"audit/{log_id}")
    
    async def get_audit_actions(self) -> List[str]:
        """
        Get all possible audit actions.
        
        Returns:
            List of action strings
        """
        response = await self.get("audit/actions")
        return response.get("actions", [])
    
    async def get_audit_resource_types(self) -> List[str]:
        """
        Get all possible audit resource types.
        
        Returns:
            List of resource type strings
        """
        response = await self.get("audit/resource-types")
        return response.get("resourceTypes", [])
