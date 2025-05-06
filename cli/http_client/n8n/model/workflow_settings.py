from dataclasses import dataclass, asdict
from typing import Dict, Optional, Any, Literal

@dataclass
class WorkflowSettings:
    """
    Settings for a N8n workflow.

    params:
        saveExecutionProgress (bool): Whether to save execution progress.
        saveManualExecutions (bool): Whether to save manual executions.
        saveDataErrorExecution (Literal["all", "none"]): Save data on error execution.
        saveDataSuccessExecution (Literal["all", "none"]): Save data on successful execution.
        executionTimeout (int): Execution timeout in seconds (max 3600).
        errorWorkflow (Optional[str]): ID of the workflow containing the error trigger node.
        timezone (str): Timezone for the workflow.
        executionOrder (str): Order of execution for the workflow.
    """
    
    saveExecutionProgress: bool = False
    saveManualExecutions: bool = True
    saveDataErrorExecution: Literal["all", "none"] = "all"
    saveDataSuccessExecution: Literal["all", "none"] = "all"
    executionTimeout: int = 3600
    errorWorkflow: Optional[str] = None
    timezone: str = "Taiwan/Taipei"
    executionOrder: str = "v1"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to the format expected by the N8n API."""
        settings_dict = asdict(self)
        return {k: v for k, v in settings_dict.items() if v is not None}
