from typing import Dict, List, Optional, Any
from ..exceptions import APIStatusError
from .._base_client import BaseHttpClient

class VariableClient(BaseHttpClient):
    """
    Client for the N8n Variable API.
    
    This client provides methods to manage variables in N8n.
    """
    
    async def get_variables(self) -> List[Dict[str, Any]]:
        """
        Get all variables.
        
        Returns:
            List of variable objects
        """
        return await self.get("variables")
    
    async def get_variable(self, variable_id: str) -> Dict[str, Any]:
        """
        Get a specific variable by ID.
        
        Args:
            variable_id: The ID of the variable
            
        Returns:
            Variable object
        """
        return await self.get(f"variables/{variable_id}")
    
    async def create_variable(self, 
                            key: str,
                            value: str,
                            description: Optional[str] = None) -> Dict[str, Any]:
        """
        Create a new variable.
        
        Args:
            key: Key of the variable
            value: Value of the variable
            description: Optional description of the variable
            
        Returns:
            Created variable object
        """
        variable_data = {
            "key": key,
            "value": value
        }
        
        if description:
            variable_data["description"] = description
            
        return await self.post("variables", json_data=variable_data)
    
    async def update_variable(self,
                            variable_id: str,
                            key: Optional[str] = None,
                            value: Optional[str] = None,
                            description: Optional[str] = None) -> Dict[str, Any]:
        """
        Update a variable.
        
        Args:
            variable_id: The ID of the variable to update
            key: New key for the variable
            value: New value for the variable
            description: New description for the variable
            
        Returns:
            Updated variable object
        """
        variable_data = {}
        
        if key:
            variable_data["key"] = key
            
        if value is not None:  # Allow empty string values
            variable_data["value"] = value
            
        if description is not None:  # Allow empty string descriptions
            variable_data["description"] = description
            
        return await self.patch(f"variables/{variable_id}", json_data=variable_data)
    
    async def delete_variable(self, variable_id: str) -> Dict[str, Any]:
        """
        Delete a variable.
        
        Args:
            variable_id: The ID of the variable to delete
            
        Returns:
            Response data
        """
        return await self.delete(f"variables/{variable_id}")
    
    async def get_variable_by_key(self, key: str) -> Dict[str, Any]:
        """
        Get a variable by its key.
        
        Args:
            key: The key of the variable
            
        Returns:
            Variable object or None if not found
        """
        variables = await self.get_variables()
        for variable in variables:
            if variable.get("key") == key:
                return variable
        
        # If variable not found, raise an exception
        raise APIStatusError(
            message=f"Variable with key '{key}' not found",
            response=None,
            body=None
        )
