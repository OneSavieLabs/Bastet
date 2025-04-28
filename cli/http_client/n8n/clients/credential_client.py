from typing import Dict, List, Optional, Any
from ..exceptions import APIStatusError
from .._base_client import BaseHttpClient

class CredentialClient(BaseHttpClient):
    """
    Client for the N8n Credential API.
    
    This client provides methods to manage credentials in N8n.
    """
    
    async def get_credentials(self) -> List[Dict[str, Any]]:
        """
        Get all credentials.
        
        Returns:
            List of credential objects
        """
        return await self.get("credentials")
    
    async def get_credential(self, credential_id: str) -> Dict[str, Any]:
        """
        Get a specific credential by ID.
        
        Args:
            credential_id: The ID of the credential
            
        Returns:
            Credential object
        """
        return await self.get(f"credentials/{credential_id}")
    
    async def create_credential(self, 
                              name: str,
                              type: str,
                              data: Dict[str, Any],
                              shared_with: Optional[List[str]] = None) -> Dict[str, Any]:
        """
        Create a new credential.
        
        Args:
            name: Name of the credential
            type: Type of the credential (e.g., "githubApi")
            data: Credential data (keys and values)
            shared_with: List of user IDs to share the credential with
            
        Returns:
            Created credential object
        """
        credential_data = {
            "name": name,
            "type": type,
            "data": data
        }
        
        if shared_with:
            credential_data["sharedWith"] = shared_with
            
        return await self.post("credentials", json_data=credential_data)
    
    async def update_credential(self,
                              credential_id: str,
                              name: Optional[str] = None,
                              data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Update a credential.
        
        Args:
            credential_id: The ID of the credential to update
            name: New name for the credential
            data: New credential data
            
        Returns:
            Updated credential object
        """
        credential_data = {}
        
        if name:
            credential_data["name"] = name
            
        if data:
            credential_data["data"] = data
            
        return await self.patch(f"credentials/{credential_id}", json_data=credential_data)
    
    async def delete_credential(self, credential_id: str) -> Dict[str, Any]:
        """
        Delete a credential.
        
        Args:
            credential_id: The ID of the credential to delete
            
        Returns:
            Response data
        """
        return await self.delete(f"credentials/{credential_id}")
    
    async def get_credential_types(self) -> List[Dict[str, Any]]:
        """
        Get all credential types.
        
        Returns:
            List of credential type objects
        """
        return await self.get("credentials/types")
    
    async def get_credential_type(self, credential_type: str) -> Dict[str, Any]:
        """
        Get a specific credential type.
        
        Args:
            credential_type: The type of credential (e.g., "githubApi")
            
        Returns:
            Credential type object
        """
        return await self.get(f"credentials/types/{credential_type}")
    
    async def share_credential(self, 
                             credential_id: str, 
                             share_with_ids: List[str]) -> Dict[str, Any]:
        """
        Share a credential with users.
        
        Args:
            credential_id: The ID of the credential
            share_with_ids: List of user IDs to share the credential with
            
        Returns:
            Response data
        """
        return await self.put(
            f"credentials/{credential_id}/share", 
            json_data={"shareWithIds": share_with_ids}
        )
