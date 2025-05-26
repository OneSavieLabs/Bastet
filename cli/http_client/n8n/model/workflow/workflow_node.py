from typing import Dict, List, Optional, Any, Union
from pydantic import BaseModel

class WorkflowNodePosition(BaseModel):
    """Position of a workflow node."""
    x: int
    y: int

class WorkflowNodeParameters(BaseModel):
    """Parameters for a workflow node."""
    parameters: Dict[str, Any] = {}

    def to_dict(self) -> Dict[str, Any]:
        return self.parameters

    @classmethod
    def model_validate(cls, data: Dict[str, Any]) -> "WorkflowNodeParameters":
        if isinstance(data, dict):
            return cls(parameters=data)
        return data

class WorkflowNode(BaseModel):
    """A node in a workflow."""
    id: str
    name: str
    type: str
    position: Union[WorkflowNodePosition, List[int]]
    webhookId: Optional[str] = None
    disabled: bool = False
    notesInFlow: bool = False
    notes: Optional[str] = None
    executeOnce: bool = False
    alwaysOutputData: bool = False
    retryOnFail: bool = False
    maxTries: int = 1
    waitBetweenTries: int = 0
    onError: Optional[str] = None
    credentials: Optional[Dict[str, Any]] = None

    class Config:
        arbitrary_types_allowed = True

    def to_dict(self) -> Dict[str, Any]:
        """Convert to the format expected by the N8n API."""
        node_dict = {
            "id": self.id,
            "name": self.name,
            "type": self.type,
            "position": self.position,
            "parameters": self.parameters,
            "typeVersion": self.typeVersion,
        }
        
        if self.webhookId:
            node_dict["webhookId"] = self.webhookId
            
        if self.disabled:
            node_dict["disabled"] = self.disabled
            
        if self.notesInFlow:
            node_dict["notesInFlow"] = self.notesInFlow
            
        if self.notes:
            node_dict["notes"] = self.notes
            
        if self.executeOnce:
            node_dict["executeOnce"] = self.executeOnce
            
        if self.alwaysOutputData:
            node_dict["alwaysOutputData"] = self.alwaysOutputData
            
        if self.retryOnFail:
            node_dict["retryOnFail"] = self.retryOnFail
            
        if self.maxTries != 1:
            node_dict["maxTries"] = self.maxTries
            
        if self.waitBetweenTries != 0:
            node_dict["waitBetweenTries"] = self.waitBetweenTries
            
        if self.onError:
            node_dict["onError"] = self.onError
            
        if self.credentials:
            node_dict["credentials"] = self.credentials
            
        return node_dict
        
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "WorkflowNode":
        """Create a WorkflowNode from a dictionary."""
        return cls.model_validate(data)
