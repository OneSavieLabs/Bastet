from typing import Dict, List, Optional, Any
from ..exceptions import APIStatusError
from .._base_client import BaseHttpClient

class UserClient(BaseHttpClient):
    """
    Client for the N8n User API.
    
    This client provides methods to manage users in N8n.
    """
    
    async def get_users(self) -> List[Dict[str, Any]]:
        """
        Get all users.
        
        Returns:
            List of user objects
        """
        return await self.get("users")
    
    async def get_user(self, user_id: str) -> Dict[str, Any]:
        """
        Get a specific user by ID.
        
        Args:
            user_id: The ID of the user
            
        Returns:
            User object
        """
        return await self.get(f"users/{user_id}")
    
    async def create_user(self, 
                         email: str, 
                         first_name: str, 
                         last_name: str, 
                         password: Optional[str] = None,
                         role: str = "default") -> Dict[str, Any]:
        """
        Create a new user.
        
        Args:
            email: Email address of the user
            first_name: First name of the user
            last_name: Last name of the user
            password: Password for the user (optional)
            role: Role of the user (default, owner, admin, member)
            
        Returns:
            Created user object
        """
        user_data = {
            "email": email,
            "firstName": first_name,
            "lastName": last_name,
            "role": role
        }
        
        if password:
            user_data["password"] = password
            
        return await self.post("users", json_data=user_data)
    
    async def update_user(self, 
                         user_id: str, 
                         email: Optional[str] = None,
                         first_name: Optional[str] = None,
                         last_name: Optional[str] = None,
                         role: Optional[str] = None) -> Dict[str, Any]:
        """
        Update a user.
        
        Args:
            user_id: The ID of the user to update
            email: New email address
            first_name: New first name
            last_name: New last name
            role: New role
            
        Returns:
            Updated user object
        """
        user_data = {}
        
        if email:
            user_data["email"] = email
            
        if first_name:
            user_data["firstName"] = first_name
            
        if last_name:
            user_data["lastName"] = last_name
            
        if role:
            user_data["role"] = role
            
        return await self.patch(f"users/{user_id}", json_data=user_data)
    
    async def delete_user(self, user_id: str) -> Dict[str, Any]:
        """
        Delete a user.
        
        Args:
            user_id: The ID of the user to delete
            
        Returns:
            Response data
        """
        return await self.delete(f"users/{user_id}")
    
    async def get_current_user(self) -> Dict[str, Any]:
        """
        Get the current authenticated user.
        
        Returns:
            Current user object
        """
        return await self.get("users/me")
    
    async def update_password(self, 
                             current_password: str, 
                             new_password: str) -> Dict[str, Any]:
        """
        Update the current user's password.
        
        Args:
            current_password: Current password
            new_password: New password
            
        Returns:
            Response data
        """
        password_data = {
            "currentPassword": current_password,
            "newPassword": new_password
        }
        
        return await self.post("users/password", json_data=password_data)
    
    async def reset_password(self, user_id: str, password: str) -> Dict[str, Any]:
        """
        Reset a user's password (admin only).
        
        Args:
            user_id: The ID of the user
            password: New password
            
        Returns:
            Response data
        """
        password_data = {
            "password": password
        }
        
        return await self.post(f"users/{user_id}/password-reset", json_data=password_data)
    
    async def invite_user(self, 
                         email: str, 
                         first_name: str, 
                         last_name: str,
                         role: str = "default") -> Dict[str, Any]:
        """
        Invite a new user.
        
        Args:
            email: Email address of the user
            first_name: First name of the user
            last_name: Last name of the user
            role: Role of the user (default, owner, admin, member)
            
        Returns:
            Created invitation object
        """
        invitation_data = {
            "email": email,
            "firstName": first_name,
            "lastName": last_name,
            "role": role
        }
        
        return await self.post("users/invite", json_data=invitation_data)
