from typing import Dict, List, Optional, Any, Union, cast
from ..exceptions import N8nExecutionError
from .._base_client import BaseHttpClient

class ExecutionClient(BaseHttpClient):
    """
    Client for the N8n Execution API.
    
    This client provides methods to manage workflow executions in N8n.
    """
    
    async def get_executions(self, 
                            workflow_id: Optional[str] = None, 
                            limit: int = 20,
                            last_id: Optional[str] = None,
                            status: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Get workflow executions.
        
        Args:
            workflow_id: Optional workflow ID to filter executions
            limit: Maximum number of executions to return
            last_id: ID of the last execution for pagination
            status: Filter by execution status (e.g., "success", "error")
            
        Returns:
            List of execution objects
        """
        params = {"limit": limit}
        
        if workflow_id:
            params["workflowId"] = workflow_id
            
        if last_id:
            params["lastId"] = last_id
            
        if status:
            params["status"] = status
            
        return await self.get("executions", params=params)
    
    async def get_execution(self, execution_id: str) -> Dict[str, Any]:
        """
        Get a specific execution by ID.
        
        Args:
            execution_id: The ID of the execution
            
        Returns:
            Execution object
        """
        try:
            return await self.get(f"executions/{execution_id}")
        except Exception as e:
            raise N8nExecutionError(
                message=f"Failed to get execution {execution_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
    
    async def delete_execution(self, execution_id: str) -> Dict[str, Any]:
        """
        Delete an execution.
        
        Args:
            execution_id: The ID of the execution to delete
            
        Returns:
            Response data
        """
        try:
            return await self.delete(f"executions/{execution_id}")
        except Exception as e:
            raise N8nExecutionError(
                message=f"Failed to delete execution {execution_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
            
    async def delete_executions(self, 
                               workflow_id: Optional[str] = None,
                               delete_before: Optional[str] = None,
                               delete_all: bool = False) -> Dict[str, Any]:
        """
        Delete multiple executions.
        
        Args:
            workflow_id: Optional workflow ID to filter executions to delete
            delete_before: Delete executions before this date (ISO format)
            delete_all: Whether to delete all executions
            
        Returns:
            Response data with deletion status
        """
        data = {}
        
        if workflow_id:
            data["workflowId"] = workflow_id
            
        if delete_before:
            data["deleteBefore"] = delete_before
            
        if delete_all:
            data["deleteAll"] = True
            
        try:
            return await self.post("executions/delete", json_data=data)
        except Exception as e:
            raise N8nExecutionError(
                message=f"Failed to delete executions: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
            
    async def retry_execution(self, execution_id: str) -> Dict[str, Any]:
        """
        Retry a failed execution.
        
        Args:
            execution_id: The ID of the execution to retry
            
        Returns:
            New execution object
        """
        try:
            return await self.post(f"executions/{execution_id}/retry")
        except Exception as e:
            raise N8nExecutionError(
                message=f"Failed to retry execution {execution_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
            
    async def stop_execution(self, execution_id: str) -> Dict[str, Any]:
        """
        Stop a running execution.
        
        Args:
            execution_id: The ID of the execution to stop
            
        Returns:
            Response data
        """
        try:
            return await self.post(f"executions/{execution_id}/stop")
        except Exception as e:
            raise N8nExecutionError(
                message=f"Failed to stop execution {execution_id}: {str(e)}",
                response=getattr(e, "response", None),
                body=getattr(e, "body", None)
            )
