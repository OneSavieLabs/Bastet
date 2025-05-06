from dataclasses import dataclass, field, asdict
from typing import Dict, List, Optional, Any, Union, Literal

@dataclass
class WorkflowNodePosition:
    """
    Position of a node in the workflow editor.
    """
    
    x: int
    y: int
    
    def to_dict(self) -> List[int]:
        """Convert to the format expected by the N8n API."""
        return [self.x, self.y]


@dataclass
class WorkflowNodeParameters:
    """Parameters for a workflow node."""
    
    # This is a flexible structure that depends on the node type
    # We use a dict to allow any parameters
    parameters: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to the format expected by the N8n API."""
        return self.parameters


@dataclass
class WorkflowNode:
    """
    A node in an N8n workflow.
    
    params:
    - id: Unique identifier for the node
    - name: Display name of the node
    - webhookId: ID for webhook nodes
    - disabled: Whether the node is disabled
    - notesInFlow: Whether to show notes in the workflow editor
    - notes: Node description or notes
    - type: Type of the node (e.g., 'n8n-nodes-base.httpRequest')
    - typeVersion: Version of the node type (default: 1)
    - executeOnce: Whether to execute the node only once
    - alwaysOutputData: Whether to always output data even if the node is skipped
    - retryOnFail: Whether to retry on failure
    - maxTries: Maximum number of retry attempts
    - waitBetweenTries: Wait time between retries (milliseconds)
    - onError: Error handling strategy
    - position: Position in the workflow editor [x, y]
    - parameters: Configuration parameters specific to the node type
    - credentials: Authentication credentials for the node
    """
    
    id: str
    name: str
    type: str
    position: Union[WorkflowNodePosition, List[int]]
    webhookId: Optional[str] = None
    disabled: bool = False
    notesInFlow: bool = False
    notes: Optional[str] = None
    typeVersion: int = 1
    executeOnce: bool = False
    alwaysOutputData: bool = False
    retryOnFail: bool = False
    maxTries: int = 1
    waitBetweenTries: int = 0
    onError: Optional[str] = None
    parameters: Union[WorkflowNodeParameters, Dict[str, Any]] = field(default_factory=dict)
    credentials: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to the format expected by the N8n API."""
        node_dict = {
            "id": self.id,
            "name": self.name,
            "type": self.type,
            "position": self.position.to_dict() if hasattr(self.position, "to_dict") else self.position,
            "parameters": self.parameters.to_dict() if hasattr(self.parameters, "to_dict") else self.parameters,
            "typeVersion": self.typeVersion,
            "disabled": self.disabled,
            "continueOnFail": self.continueOnFail,
            "executeOnce": self.executeOnce,
            "alwaysOutputData": self.alwaysOutputData,
            "retryOnFail": self.retryOnFail,
            "maxTries": self.maxTries,
            "waitBetweenTries": self.waitBetweenTries,
            "notesInFlow": self.notesInFlow,
        }
        
        if self.webhookId:
            node_dict["webhookId"] = self.webhookId
        if self.notes:
            node_dict["notes"] = self.notes
        if self.onError:
            node_dict["onError"] = self.onError
        if self.credentials:
            node_dict["credentials"] = self.credentials
            
        return node_dict
