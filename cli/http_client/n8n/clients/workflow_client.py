from typing import Dict, List, Optional, Any, Union, cast
from ..exceptions import N8nWorkflowError
from .._base_client import BaseHttpClient

class WorkflowClient(BaseHttpClient):
    """
    Client for the N8n Workflow API.
    
    This client provides methods to manage workflows in N8n.
    """
    
    async def get_workflows(self, 
                          active: Optional[bool] = None,
                          tags: Optional[List[str]] = None,
                          search: Optional[str] = None,
                          limit: Optional[int] = None,
                          cursor: Optional[str] = None,
                          include: Optional[List[str]] = None) -> List[Dict[str, Any]]:
        """
        Retrieve all workflows.
        
        Args:
            active: Filter by active status (true/false)
            tags: Filter by tag IDs
            search: Search term to filter workflows by name
            limit: Maximum number of results to return
            cursor: Cursor for pagination
            include: Additional properties to include (e.g., ['full'])
            
        Returns:
            List of workflow objects
        """
        params = {}
        
        if active is not None:
            params["active"] = active
            
        if tags:
            params["tags"] = ",".join(tags)
            
        if search:
            params["search"] = search
            
        if limit is not None:
            params["limit"] = limit
            
        if cursor:
            params["cursor"] = cursor
            
        if include:
            params["include"] = ",".join(include)
            
        return await self.get("workflows", params=params)
    
    async def get_workflow(self, workflow_id: str) -> Dict[str, Any]:
        """
        Get a specific workflow by ID.
        
        Args:
            workflow_id: The ID of the workflow
            
        Returns:
            Workflow object
        """
        try:
            return await self.get(f"workflows/{workflow_id}")
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to get workflow {workflow_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
    
    async def create_workflow(self, workflow_data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Create a new workflow.
        
        Args:
            workflow_data: Workflow definition
            
        Returns:
            Created workflow object
        """
        try:
            return await self.post("workflows", json_data=workflow_data)
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to create workflow: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
    
    async def update_workflow(self, workflow_id: str, workflow_data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Update an existing workflow.
        
        Args:
            workflow_id: The ID of the workflow to update
            workflow_data: Updated workflow definition
            
        Returns:
            Updated workflow object
        """
        try:
            return await self.put(f"workflows/{workflow_id}", json_data=workflow_data)
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to update workflow {workflow_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
    
    async def delete_workflow(self, workflow_id: str) -> Dict[str, Any]:
        """
        Delete a workflow.
        
        Args:
            workflow_id: The ID of the workflow to delete
            
        Returns:
            Response data
        """
        try:
            return await self.delete(f"workflows/{workflow_id}")
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to delete workflow {workflow_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
    
    async def activate_workflow(self, workflow_id: str, active: bool = True) -> Dict[str, Any]:
        """
        Activate or deactivate a workflow.
        
        Args:
            workflow_id: The ID of the workflow
            active: Whether to activate (True) or deactivate (False) the workflow
            
        Returns:
            Updated workflow object
        """
        try:
            return await self.post(f"workflows/{workflow_id}/activate", json_data={"active": active})
        except Exception as e:
            action = "activate" if active else "deactivate"
            raise N8nWorkflowError(
                message=f"Failed to {action} workflow {workflow_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
            
    async def execute_workflow(self, workflow_id: str, execution_data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Execute a workflow.
        
        Args:
            workflow_id: The ID of the workflow to execute
            execution_data: Data to pass to the workflow execution
            
        Returns:
            Execution result
        """
        try:
            return await self.post(f"workflows/{workflow_id}/execute", json_data=execution_data or {})
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to execute workflow {workflow_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
            
    async def get_workflow_tags(self, workflow_id: str) -> List[Dict[str, Any]]:
        """
        Get tags for a specific workflow.
        
        Args:
            workflow_id: The ID of the workflow
            
        Returns:
            List of tag objects
        """
        try:
            return await self.get(f"workflows/{workflow_id}/tags")
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to get tags for workflow {workflow_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
            
    async def update_workflow_tags(self, workflow_id: str, tag_ids: List[str]) -> Dict[str, Any]:
        """
        Update tags for a workflow.
        
        Args:
            workflow_id: The ID of the workflow
            tag_ids: List of tag IDs to assign to the workflow
            
        Returns:
            Updated workflow object
        """
        try:
            return await self.put(f"workflows/{workflow_id}/tags", json_data={"tagIds": tag_ids})
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to update tags for workflow {workflow_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
            
    async def share_workflow(self, workflow_id: str, share_with_ids: List[str]) -> Dict[str, Any]:
        """
        Share a workflow with users.
        
        Args:
            workflow_id: The ID of the workflow
            share_with_ids: List of user IDs to share the workflow with
            
        Returns:
            Response data
        """
        try:
            return await self.put(f"workflows/{workflow_id}/share", json_data={"shareWithIds": share_with_ids})
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to share workflow {workflow_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
