from typing import Any, Dict, Optional

from pydantic import BaseModel


class Node(BaseModel):
    parameters: Dict[str, Any]
    type: str
    typeVersion: float
    position: Optional[list[int]] = None
    id: str  # should be UUID
    name: str

    class Config:
        validate_by_name = True
        extra = "allow"


class WebhookNodeParams(BaseModel):
    httpMethod: str
    path: str
    responseMode: str
    options: Dict[str, Any]

    class Config:
        validate_by_name = True
        extra = "allow"


class WebhookNode(Node):
    parameters: WebhookNodeParams

    def get_webhook_url(self, n8n_url: str) -> str:
        webhook_path = self.parameters.path.replace("=", "")
        return f"{n8n_url}/webhook/{webhook_path}"
