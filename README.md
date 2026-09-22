# Azure Cosmos DB MCP Toolkit

An ASP.NET Core .NET 9 MCP server that lets authenticated AI agents discover and query Azure Cosmos DB data through MCP tools. It supports database and container discovery, document lookup, text search, vector search, hybrid search, and schema discovery.

## Architecture

```text
AI agent or browser client
          |
          | HTTPS + Microsoft Entra JWT
          v
Azure Container App
  ASP.NET Core MCP server
  /mcp, /mcp/http, /health
          |
          | system-assigned managed identity
          +--> Azure Cosmos DB for NoSQL
          +--> Azure AI Services or Microsoft Foundry embeddings
          +--> Azure Container Registry image pulls
```

The server exposes MCP tools through `/mcp` and the HTTP MCP endpoint through `/mcp/http`. The health endpoint is `/health`. Production endpoints require the `Mcp.Tool.Executor` Entra app role. The Container App uses managed identity for Azure resource access; production deployments do not use Cosmos keys, registry passwords, or OpenAI API keys.

## Azure Components

The deployment creates or updates:

- Azure Container Apps Environment
- Azure Container App with external HTTPS ingress on port 8080
- Azure Container Registry with admin credentials disabled
- System-assigned managed identity for the Container App
- A Microsoft Entra application and `Mcp.Tool.Executor` app role
- RBAC assignments for ACR image pulls, Cosmos DB data access, and embedding access

Cosmos DB and the embedding service are existing dependencies selected from the deployment resource group. They are not created or retagged by this deployment. Development and test resources created by the templates receive `SecurityControl=Ignore`; obtain security-owner approval before using that tag in production.

## Prerequisites

- Azure subscription and permission to create resources and assign RBAC roles
- Existing Azure Cosmos DB account in the deployment resource group
- Existing Microsoft Foundry project or Azure AI Services account with an embedding deployment
- Azure CLI, signed in with `az login`
- PowerShell 7+
- .NET 9 SDK is optional for deployment; it is required only for local builds and tests

## Deploy To Azure

The supported deployment path uses two PowerShell scripts after the resource group has been prepared. The scripts derive the resource group and service names from the environment and suffix:

```text
Resource group: rg-eia-<environment>-<suffix>
ACR:            acr<environment><suffix> (lowercase alphanumeric only)
Container App:  ca-eia-<environment>-<suffix>
Entra app:      entra-eia-<environment>-<suffix>
```

1. Select the target subscription and create the resource group. The resource group must contain the Cosmos DB account and Microsoft Foundry project used by the server.

```powershell
az login
az account set --subscription "<subscription-id>"
az group create --name "rg-eia-dev-1" --location "eastus2"
```

2. From the repository root, run the deployment script:

```powershell
.\scripts\Deploy-Cosmos-MCP-Toolkit.ps1 -Environment dev -Suffix 1 -Location eastus2
```

The deployment script automatically discovers or prompts you to select the Cosmos DB account, Foundry project, and embedding deployment. It then creates the Entra application, deploys the infrastructure, builds and pushes the image with Azure Container Registry Tasks, assigns the required permissions, updates the Container App, writes `scripts\deployment-info.json`, and runs authenticated health and Cosmos DB smoke tests. Docker Desktop is not required for deployment.

If Azure Container Apps or ACR reports a regional capacity or availability error, the script removes only resources created by the failed deployment, shows the three nearest eligible regions, and prompts you to select one or enter another region. Existing Cosmos DB, Foundry, ACR, Container App, and Entra resources are preserved.

3. Create the Foundry connection and configure agents by running the setup script while signed in to the Azure CLI:

```powershell
.\scripts\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1
```

The setup script reads `scripts\deployment-info.json`, prompts you to select the Foundry project and agents, creates or updates the `ProjectManagedIdentity` connection, assigns the `Mcp.Tool.Executor` app role to the Foundry project managed identity and selected agent identities, and attaches the MCP tool with approval required. For each selected agent, it lets you keep the existing instructions, use the Cosmos DB example, enter a replacement, or load instructions from a UTF-8 text file.

Agent configuration is idempotent. Re-running the script updates the existing connection and role assignment, and creates a new agent version only when the selected agent's instructions or Cosmos DB MCP tool configuration has changed. Existing non-MCP tools and other agent definition settings are preserved.

## Build Locally (optional)

Restore, build, and test the solution:

```powershell
dotnet restore .\AzureCosmosDB.MCP.Toolkit.sln
dotnet build .\AzureCosmosDB.MCP.Toolkit.sln --configuration Release
dotnet test .\tests\AzureCosmosDB.MCP.Toolkit.Tests\AzureCosmosDB.MCP.Toolkit.Tests.csproj --configuration Release --no-restore
```

Run the server locally with the .NET SDK:

```powershell
dotnet run --project .\src\AzureCosmosDB.MCP.Toolkit\AzureCosmosDB.MCP.Toolkit.csproj
```

For the local Docker Compose setup:

```powershell
docker compose up --build
```

## Troubleshooting

The deployment script also assigns the signed-in user the `Mcp.Tool.Executor` role. If that assignment fails, assign the role in Microsoft Entra Enterprise Applications and rerun the deployment.

The separate `Assign-Role-To-*.ps1` and `Verify-Role-Assignments.ps1` scripts are administrative troubleshooting tools and are not required for a standard deployment.

To verify the deployed application manually:

```powershell
$fqdn = az containerapp show --name "ca-eia-dev-1" --resource-group "rg-eia-dev-1" --query properties.configuration.ingress.fqdn -o tsv
Start-Process "https://$fqdn"
curl "https://$fqdn/health"
```

To apply the same multiline instructions to selected agents without an interactive instruction prompt:

```powershell
.\scripts\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1 -AgentInstructionsFile .\scripts\cosmos-agent-instructions.example.txt
```

To test a configured agent from the same script, add `-TestAgent`. The script prompts for the agent number and the prompt to send. This is optional:

```powershell
.\scripts\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1 -TestAgent
```

You can provide the prompt non-interactively with `-TestPrompt`:

```powershell
.\scripts\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1 -TestAgent -TestPrompt "List the databases available to you."
```

## Infrastructure Files

- `infrastructure/main.bicep`: template used by the deployment script
- `infrastructure/main.json`: generated ARM version of the primary template
- `infrastructure/main-simple.bicep`: simplified alternate template
- `infrastructure/deploy-all-resources.bicep`: legacy/manual template
- `scripts/Deploy-Cosmos-MCP-Toolkit.ps1`: build, deploy, permission, and smoke-test automation

## Repository Layout

```text
src/       .NET MCP server
tests/     automated tests
infrastructure/  Bicep and generated ARM templates
scripts/   deployment and role-management scripts
client/    optional Microsoft Foundry client example
```
