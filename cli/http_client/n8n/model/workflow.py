"""
Models for N8n workflow objects.
"""

from typing import Dict, List, Optional, Any, Union
from dataclasses import dataclass, field

from .workflow_node import WorkflowNode
from .workflow_settings import WorkflowSettings

@dataclass
class Workflow:
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
    nodes: List[Union[WorkflowNode, Dict[str, Any]]]
    connections: Dict[str, Any]
    settings: Union[WorkflowSettings, Dict[str, Any]]
    staticData: Optional[Union[str, Dict[str, Any]]] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to the format expected by the N8n API."""
        workflow_dict = {
            "name": self.name,
            "nodes": [node.to_dict() if hasattr(node, "to_dict") else node for node in self.nodes],
            "connections": self.connections,
            "settings": self.settings.to_dict() if hasattr(self.settings, "to_dict") else self.settings,
            "staticData": self.staticData,
        }
        return workflow_dict
