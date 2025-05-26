"""
Example usage of the N8n API client.
This script demonstrates how to use the N8n client to interact with the N8n API.
"""

import asyncio
import logging

from http_client.n8n import N8n
from http_client.n8n.exceptions import APIError
from http_client.n8n.model.workflow.workflow import Workflow
from http_client.n8n.model.workflow.workflow_settings import WorkflowSettings
from http_client.n8n.model.workflow.workflow_node import WorkflowNode, WorkflowNodePosition

from os import getenv
import dotenv

dotenv.load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

N8N_API_KEY = getenv("N8N_API_KEY")  # Replace with your actual API key
N8N_API_BASE_URL = getenv("N8N_API_BASE_URL")  # Replace with your N8n instance URL


async def example_workflow_operations():
    logger.info("=== Workflow Client TESTING ===")
    
    # Create the client factory
    client = N8n(
        X_N8N_API_KEY=N8N_API_KEY,
        N8N_API_BASE_URL=N8N_API_BASE_URL,
        timeout=30,
        max_retries=3
    )
    
    try:
        # Get all workflows
        logger.info("Getting all workflows...")
        workflows = await client.workflows().get_workflows()
            
        logger.info(f"Found {len(workflows)} workflows")
        
        # Get workflows by project ID
        project_id = "ERfhTxouVBTw1wVo"
        logger.info(f"Getting workflows for project: {project_id}")
        project_workflows = await client.workflows().get_workflows(project_id=project_id)
        logger.info(f"Found {len(project_workflows)} workflows in project")
        
        # Get a workflow by ID
        workflow_id = "va8MTPdYK4MDdtnp"
        logger.info(f"Getting workflow with ID: {workflow_id}")
        workflow = await client.workflows().get_workflow(workflow_id=workflow_id)
        
        logger.info(f"Workflow name: {workflow.name}")
        logger.info(f"Workflow ID: {workflow.id}")
        logger.info(f"Workflow active: {workflow.active}")
        logger.info(f"Workflow has {len(workflow.nodes)} nodes")
        
        if workflow.nodes:
            node = workflow.nodes[0]
            logger.info(f"First node: {node.name} (type: {node.type})")
            
        # Create a new workflow using the model classes
        logger.info("Creating a new workflow...")
        
        # Create a workflow node
        # workflow_node = WorkflowNode(
        #     id=str(uuid.uuid4()),
        #     name="HTTP Request",
        #     type="n8n-nodes-base.httpRequest",
        #     position=WorkflowNodePosition(x=100, y=200),
        #     parameters={
        #         "url": "https://example.com",
        #         "method": "GET",
        #         "authentication": "none"
        #     },
        #     typeVersion=1
        # )
        
        # workflow_settings = WorkflowSettings(
        #     saveManualExecutions=True,
        #     saveDataErrorExecution="all",
        #     saveDataSuccessExecution="all",
        #     executionOrder="v1"
        # )
        
        # new_workflow = Workflow(
        #     name="Pydantic Model Example Workflow",
        #     nodes=[workflow_node],
        #     connections={},
        #     settings=workflow_settings,
        #     active=False
        # )
        
        # created_workflow = await client.workflows().create_workflow(new_workflow.to_dict())
        # logger.info(f"Created workflow with ID: {created_workflow.id}")
        
        # created_workflow.name = "Updated Pydantic Workflow"
        # updated_workflow = await client.workflows().update_workflow(
        #     created_workflow.id, 
        #     created_workflow.to_dict()
        # )
        # logger.info(f"Updated workflow name to: {updated_workflow.name}")
        
        # logger.info("Activating workflow...")
        # activated_workflow = await client.workflows().activate_workflow(created_workflow.id)
        # logger.info(f"Workflow active status: {activated_workflow.active}")
        
        # logger.info("Deactivating workflow...")
        # deactivated_workflow = await client.workflows().deactivate_workflow(created_workflow.id)
        # logger.info(f"Workflow active status: {deactivated_workflow.active}")
        
        # logger.info("Deleting the workflow...")
        # await client.workflows().delete_workflow(created_workflow.id)
        # logger.info("Workflow deleted successfully")
        
    except APIError as e:
        logger.error(f"API Error: {e.message}")
        if hasattr(e, 'status_code'):
            logger.error(f"Status Code: {e.status_code}")
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}")
    finally:
        if client:
            await client.close()


async def main():
    """Run all examples."""
    logger.info("Starting N8n client examples...")
    
    await example_workflow_operations()
    
    logger.info("All examples completed")


if __name__ == "__main__":
    asyncio.run(main())
