# Import necessary libraries

import os
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition, MCPTool
from azure.identity import AzureCliCredential
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()
project_endpoint = os.getenv("PROJECT_ENDPOINT")
model_deployment = os.getenv("MODEL_DEPLOYMENT_NAME")
connection_name = os.getenv("CONNECTION_NAME")

# Get MCP server configuration from environment variables
mcp_server_url = os.environ.get("MCP_SERVER_URL")
mcp_server_label = os.environ.get("MCP_SERVER_LABEL" )

# Agent configuration
agent_name = os.environ.get("AGENT_NAME")

project_client = AIProjectClient(
    endpoint=project_endpoint,
    credential=AzureCliCredential(),
)

# Initialize MCP tool
mcp_tool = MCPTool(
    server_label=mcp_server_label,
    server_url=mcp_server_url,
    require_approval="never",
    project_connection_id=connection_name,
)

# Create the agent with MCP tool
agent = project_client.agents.create_version(
    agent_name=agent_name,
    definition=PromptAgentDefinition(
        model=model_deployment,
        instructions="""
        You are a helpful agent that can use MCP tools to assist users with Azure Cosmos DB queries.
        Respect each tool's declared input schema exactly.
        Do not invent argument names, and keep free-form text inputs concise and relevant.
        If a tool call fails with an invalid-parameters style error, correct the arguments and retry with a valid payload.
        
        Available tools:
        - list_databases: Lists all databases in the Cosmos DB account
        - list_collections: Lists all containers in a specific database
        - get_recent_documents: Gets the most recent documents from a container
        - text_search: Searches for documents containing specific text in a property
        - find_document_by_id: Finds a specific document by its ID
        - get_approximate_schema: Gets the schema of a container by sampling documents
        - vector_search: Performs semantic search using Azure OpenAI embeddings
        
        When a user asks about their data, use these tools to explore and query the Cosmos DB database.
        Always be helpful and explain what you're doing.
        """,
        tools=[mcp_tool],
    ),
)
print(f"Agent created (name: {agent.name}, version: {agent.version})")
print(f"MCP Server: {mcp_server_label} at {mcp_server_url}")

print("The MCP server enforces strict parameter validation and rejects unknown or malformed tool arguments.")

# Sample questions for testing
input_text = [
    "Can you list all the databases in my Cosmos DB account?",
    "Show me the containers in the first database",
    "What does the schema look like for the first container?",
    "Get me the 5 most recent documents from the first container",
    "Search for documents containing 'test' in the name property",
]

# Use the Responses API via OpenAI client
openai_client = project_client.get_openai_client()

# Create a conversation for multi-turn context
conversation = openai_client.conversations.create()
print(f"Created conversation (id: {conversation.id})")

print(f"Question: {input_text[0]}")

response = openai_client.responses.create(
    conversation=conversation.id,
    input=input_text[0],  # Change index to test different questions
    extra_body={
        "agent_reference": {
            "name": agent.name,
            "type": "agent_reference",
        }
    },
)

print(f"\nResponse output: {response.output_text}")

# Display tool calls from the response
for item in response.output:
    if item.type == "mcp_call":
        print(f"\n  MCP Tool call: {item}")

# Clean-up: delete the agent version when done
# NOTE: Comment out this line if you plan to reuse the agent later.
# project_client.agents.delete_version(agent_name=agent.name, agent_version=agent.version)
# print("Agent deleted")
