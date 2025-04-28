from typing import Dict, List, Optional, Any
from ..exceptions import APIStatusError
from .._base_client import BaseHttpClient

class TagClient(BaseHttpClient):
    """
    Client for the N8n Tag API.
    
    This client provides methods to manage tags in N8n.
    """
    
    async def get_tags(self) -> List[Dict[str, Any]]:
        """
        Get all tags.
        
        Returns:
            List of tag objects
        """
        return await self.get("tags")
    
    async def get_tag(self, tag_id: str) -> Dict[str, Any]:
        """
        Get a specific tag by ID.
        
        Args:
            tag_id: The ID of the tag
            
        Returns:
            Tag object
        """
        return await self.get(f"tags/{tag_id}")
    
    async def create_tag(self, name: str, color: Optional[str] = None) -> Dict[str, Any]:
        """
        Create a new tag.
        
        Args:
            name: Name of the tag
            color: Color of the tag (hex code)
            
        Returns:
            Created tag object
        """
        tag_data = {"name": name}
        
        if color:
            tag_data["color"] = color
            
        return await self.post("tags", json_data=tag_data)
    
    async def update_tag(self, 
                       tag_id: str, 
                       name: Optional[str] = None, 
                       color: Optional[str] = None) -> Dict[str, Any]:
        """
        Update a tag.
        
        Args:
            tag_id: The ID of the tag to update
            name: New name for the tag
            color: New color for the tag
            
        Returns:
            Updated tag object
        """
        tag_data = {}
        
        if name:
            tag_data["name"] = name
            
        if color:
            tag_data["color"] = color
            
        return await self.patch(f"tags/{tag_id}", json_data=tag_data)
    
    async def delete_tag(self, tag_id: str) -> Dict[str, Any]:
        """
        Delete a tag.
        
        Args:
            tag_id: The ID of the tag to delete
            
        Returns:
            Response data
        """
        return await self.delete(f"tags/{tag_id}")
    
    async def get_tag_usage(self, tag_id: str) -> Dict[str, Any]:
        """
        Get usage information for a tag.
        
        Args:
            tag_id: The ID of the tag
            
        Returns:
            Tag usage information
        """
        return await self.get(f"tags/{tag_id}/usage")
    
    async def get_tag_by_name(self, name: str) -> Optional[Dict[str, Any]]:
        """
        Get a tag by its name.
        
        Args:
            name: The name of the tag
            
        Returns:
            Tag object or None if not found
        """
        tags = await self.get_tags()
        for tag in tags:
            if tag.get("name") == name:
                return tag
        return None
