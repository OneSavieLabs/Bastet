from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, Field


class Execution(BaseModel):
    id: int
    data: dict
    finished: bool
    mode: str
    retry_of: Optional[int] = Field(None, alias="retryOf")
    retry_success_id: Optional[int] = Field(None, alias="retrySuccessId")
    started_at: Optional[datetime] = Field(None, alias="startedAt")
    stopped_at: Optional[datetime] = Field(None, alias="stoppedAt")
    workflow_id: Optional[int] = Field(None, alias="workflowId")
    wait_till: Optional[datetime] = Field(None, alias="waitTill")
    custom_data: Optional[dict] = Field(None, alias="customData")

    class Config:
        validate_by_name = True
        json_schema_extra = {
            "example": {
                "id": 1000,
                "data": {},
                "finished": True,
                "mode": "cli",
                "retryOf": None,
                "retrySuccessId": "2",
                "startedAt": "2023-01-01T00:00:00Z",
                "stoppedAt": "2023-01-01T01:00:00Z",
                "workflowId": "1000",
                "waitTill": None,
                "customData": {},
            }
        }


class ExecutionList(BaseModel):
    data: List[Execution]
    next_cursor: Optional[str] = Field(
        None,
        alias="nextCursor",
        description=(
            "Paginate through executions by setting the cursor parameter to a "
            "nextCursor attribute returned by a previous request. Default value "
            "fetches the first 'page' of the collection."
        ),
        example="MTIzZTQ1NjctZTg5Yi0xMmQzLWE0NTYtNDI2NjE0MTc0MDA",
    )

    class Config:
        validate_by_name = True
