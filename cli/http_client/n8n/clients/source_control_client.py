from typing import Dict, List, Optional, Any
from ..exceptions import APIStatusError
from .._base_client import BaseHttpClient

class SourceControlClient(BaseHttpClient):
    """
    Client for the N8n Source Control API.
    
    This client provides methods to manage source control in N8n.
    """
    
    async def get_status(self) -> Dict[str, Any]:
        """
        Get the current source control status.
        
        Returns:
            Source control status object
        """
        return await self.get("source-control/status")
    
    async def get_preferences(self) -> Dict[str, Any]:
        """
        Get source control preferences.
        
        Returns:
            Source control preferences object
        """
        return await self.get("source-control/preferences")
    
    async def set_preferences(self, 
                            repo_url: Optional[str] = None,
                            branch_name: Optional[str] = None,
                            branch_color: Optional[str] = None,
                            read_only_instance: Optional[bool] = None,
                            connected_git_repo_url: Optional[str] = None) -> Dict[str, Any]:
        """
        Set source control preferences.
        
        Args:
            repo_url: URL of the Git repository
            branch_name: Name of the branch
            branch_color: Color of the branch
            read_only_instance: Whether the instance is read-only
            connected_git_repo_url: URL of the connected Git repository
            
        Returns:
            Updated source control preferences object
        """
        preferences = {}
        
        if repo_url is not None:
            preferences["repoUrl"] = repo_url
            
        if branch_name is not None:
            preferences["branchName"] = branch_name
            
        if branch_color is not None:
            preferences["branchColor"] = branch_color
            
        if read_only_instance is not None:
            preferences["readOnlyInstance"] = read_only_instance
            
        if connected_git_repo_url is not None:
            preferences["connectedGitRepoUrl"] = connected_git_repo_url
            
        return await self.post("source-control/preferences", json_data=preferences)
    
    async def push(self, commit_message: str, force: bool = False) -> Dict[str, Any]:
        """
        Push changes to the remote repository.
        
        Args:
            commit_message: Commit message
            force: Whether to force push
            
        Returns:
            Push result object
        """
        push_data = {
            "commitMessage": commit_message,
            "force": force
        }
        
        return await self.post("source-control/push", json_data=push_data)
    
    async def pull(self, force: bool = False) -> Dict[str, Any]:
        """
        Pull changes from the remote repository.
        
        Args:
            force: Whether to force pull
            
        Returns:
            Pull result object
        """
        pull_data = {
            "force": force
        }
        
        return await self.post("source-control/pull", json_data=pull_data)
    
    async def get_branches(self) -> List[Dict[str, Any]]:
        """
        Get all branches from the remote repository.
        
        Returns:
            List of branch objects
        """
        return await self.get("source-control/branches")
    
    async def switch_branch(self, branch_name: str, force: bool = False) -> Dict[str, Any]:
        """
        Switch to a different branch.
        
        Args:
            branch_name: Name of the branch to switch to
            force: Whether to force switch
            
        Returns:
            Switch result object
        """
        switch_data = {
            "branchName": branch_name,
            "force": force
        }
        
        return await self.post("source-control/switch-branch", json_data=switch_data)
    
    async def get_commits(self, 
                        page: int = 1, 
                        per_page: int = 20) -> List[Dict[str, Any]]:
        """
        Get commit history.
        
        Args:
            page: Page number
            per_page: Number of commits per page
            
        Returns:
            List of commit objects
        """
        params = {
            "page": page,
            "perPage": per_page
        }
        
        return await self.get("source-control/commits", params=params)
    
    async def get_diff(self, file_path: Optional[str] = None) -> Dict[str, Any]:
        """
        Get the diff between local and remote.
        
        Args:
            file_path: Optional path to a specific file
            
        Returns:
            Diff object
        """
        params = {}
        
        if file_path:
            params["filePath"] = file_path
            
        return await self.get("source-control/diff", params=params)
