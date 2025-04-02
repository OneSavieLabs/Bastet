from typing import List, Literal

from pydantic import BaseModel


class VulnerabilityDetails(BaseModel):
    function_name: str
    description: str


class AuditReport(BaseModel):
    summary: str
    severity: Literal["high", "medium", "low"]
    vulnerability_details: VulnerabilityDetails
    code_snippet: List[str] = []
    recommendation: str

    def __init__(self, **data):
        data["severity"] = data.get("severity", "").lower()
        super().__init__(**data)
