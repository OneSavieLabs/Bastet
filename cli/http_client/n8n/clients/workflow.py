from typing import Dict, List, Optional, Any, Union, cast
from ..exceptions import N8nWorkflowError
from .._base_client import BaseHttpClient
from ..model.workflow import Workflow, WorkflowNode, WorkflowSettings

class WorkflowClient(BaseHttpClient):
    """
    Client for the N8n Workflow API.
    """
    
    async def get_workflows(self, 
                          active: Optional[bool] = None,
                          tags: Optional[List[str]] = None,
                          name: Optional[str] = None,
                          project_id: Optional[str] = None,
                          exclude_pinned_data: Optional[bool] = None,
                          limit: Optional[int] = None,
                          cursor: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Retrieve all workflows in your instance.
        
        Args:
            active: Filter by active status (true/false)
            tags: Filter by tag IDs
            name: Search term to filter workflows by name
            project_id: Filter by project ID
            exclude_pinned_data: Set to true to avoid retrieving pinned data
            limit: Maximum number of items to return (default: 100, max: 250)
            cursor: Cursor for pagination
            
        Returns:
            List of workflow objects
        """
        params = {}
        
        if active is not None:
            params["active"] = active
            
        if tags:
            params["tags"] = ",".join(tags)
            
        if name:
            params["name"] = name
            
        if project_id:
            params["projectId"] = project_id
            
        if exclude_pinned_data is not None:
            params["excludePinnedData"] = exclude_pinned_data
            
        if limit:
            params["limit"] = limit
            
        if cursor:
            params["cursor"] = cursor
            
        try:
            response = await self.get("workflows", params=params)
            return response.get("data", [])
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to retrieve workflows: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
    
    async def get_workflow(self, workflow_id: str, exclude_pinned_data: Optional[bool] = None) -> Dict[str, Any]:
        """
        Retrieve a specific workflow by ID.
        
        Args:
            workflow_id: The ID of the workflow to retrieve
            exclude_pinned_data: Set to true to avoid retrieving pinned data
            
        Returns:
            Workflow object
        """
            params = {}
        
            if exclude_pinned_data is not None:
                params["excludePinnedData"] = exclude_pinned_data
                
        try:
            return await self.get(f"workflows/{workflow_id}", params=params)
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to retrieve workflow {workflow_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
    
    async def create_workflow(self, workflow_data: Union[Dict[str, Any], Workflow]) -> Dict[str, Any]:
        """
        Create a new workflow in your instance.
        
        Args:
            workflow_data: Workflow definition with the following required fields:
                - name (str): The name of the workflow
                - nodes (List): Array of workflow nodes
                - connections (Dict): Object containing the node connections
                - settings (Dict): Workflow settings
                
        Optional fields:
            - staticData (str or Dict): Static data for the workflow
        
        Returns:
            Created workflow object
        
        Raises:
            N8nWorkflowError: If workflow creation fails
        """
        if isinstance(workflow_data, Workflow):
            workflow_data = workflow_data.to_dict()
        
        required_fields = ["name", "nodes", "connections", "settings"]
        missing_fields = [field for field in required_fields if field not in workflow_data]
        
        if missing_fields:
            raise N8nWorkflowError(
                message=f"Missing required fields for workflow creation: {', '.join(missing_fields)}",
                response=None,
                body=None
            )
            
        try:
            return await self.post("workflows", json_data=workflow_data)
        except Exception as e:
            raise N8nWorkflowError(
                message=f"Failed to create workflow: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
    
    async def update_workflow(self, workflow_id: str, workflow_data: Union[Dict[str, Any], Workflow]) -> Dict[str, Any]:
        """
        Update a workflow.
        
        Args:
            workflow_id: The ID of the workflow to update
            workflow_data: Updated workflow definition with the following required fields:
                - name (str): The name of the workflow
                - nodes (List): Array of workflow nodes
                - connections (Dict): Object containing the node connections
                - settings (Dict): Workflow settings
                
        Optional fields:
            - staticData (str or Dict): Static data for the workflow
            
        Returns:
            Updated workflow object
        """
        # Convert Workflow object to dict if needed
        if isinstance(workflow_data, Workflow):
            workflow_data = workflow_data.to_dict()
        
        # Validate required fields
        required_fields = ["name", "nodes", "connections", "settings"]
        missing_fields = [field for field in required_fields if field not in workflow_data]
        
        if missing_fields:
            raise N8nWorkflowError(
                message=f"Missing required fields for workflow update: {', '.join(missing_fields)}",
                response=None,
                body=None
            )
            
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
