"""
Models for N8n workflow objects.
"""

from typing import Dict, List, Optional, Any
from pydantic import BaseModel

from .workflow_node import WorkflowNode
from .workflow_settings import WorkflowSettings

class Workflow(BaseModel):
    """
    A N8n workflow.
    
    Required fields:
    - name: Name of the workflow
    - nodes: List of workflow nodes
    - connections: Connections between nodes
    - settings: Workflow settings
    - staticData: (optional)
    """
    
    name: str
    nodes: List[WorkflowNode]
    connections: Dict[str, Any]
    settings: WorkflowSettings
    staticData: Optional[Dict[str, Any]] = None
    id: Optional[str] = None
    active: bool = False
    
    class Config:
        arbitrary_types_allowed = True
        
    @classmethod
    def model_validate(cls, data: Dict[str, Any]) -> "Workflow":
        """Convert nested dictionaries to their proper model objects"""

        parsed_nodes = []
        for node in data.get('nodes', []):
            if isinstance(node, dict):
                parsed_nodes.append(WorkflowNode.model_validate(node))
            else:
                parsed_nodes.append(node)
        data['nodes'] = parsed_nodes
        
        if isinstance(data.get('settings', {}), dict):
            data['settings'] = WorkflowSettings.model_validate(data['settings'])
            
        return cls(**data)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to the format expected by the N8n API."""
        workflow_dict = {
            "name": self.name,
            "nodes": [node.to_dict() if hasattr(node, "to_dict") else node for node in self.nodes],
            "connections": self.connections,
            "settings": self.settings.to_dict() if hasattr(self.settings, "to_dict") else self.settings,
            "active": self.active,
        }
        
        if self.id:
            workflow_dict["id"] = self.id
            
        if self.staticData:
            workflow_dict["staticData"] = self.staticData
        return workflow_dict
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Workflow":
        """
        Args:
            data: Raw workflow data from API
            
        Returns:
            Workflow: A fully parsed Workflow instance with proper types
        """
        return cls.model_validate(data)