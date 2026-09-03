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

## Build Locally

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

## Deploy To Azure

The supported deployment path is the PowerShell script. It derives the resource group and service names from the environment and suffix:

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

The script uses Azure Container Registry Tasks to build the image remotely from `Dockerfile`, pushes it to ACR, deploys the Bicep infrastructure, configures Entra authentication, assigns managed-identity permissions, updates the Container App, and runs authenticated health and Cosmos DB smoke tests. Docker Desktop is not required for deployment.

3. Open the deployed application:

```powershell
$fqdn = az containerapp show --name "ca-eia-dev-1" --resource-group "rg-eia-dev-1" --query properties.configuration.ingress.fqdn -o tsv
Start-Process "https://$fqdn"
```

Check health directly:

```powershell
curl "https://$fqdn/health"
```

Deployment output is written to `scripts\deployment-info.json`. The script also assigns the signed-in user the `Mcp.Tool.Executor` role. If role assignment fails, assign the role in Microsoft Entra Enterprise Applications and rerun the deployment.

To create the Foundry project managed-identity connection after deployment, run the setup script while signed in to the Azure CLI. It derives the resource group as `rg-eia-<environment>-<suffix>`, reads the active subscription, lists the Foundry projects in that resource group, and prompts you to select one:

```powershell
.\scripts\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1
```

The script creates the `ProjectManagedIdentity` connection for the selected project, uses the deployed MCP URL from `deployment-info.json`, assigns the `Mcp.Tool.Executor` app role to the Foundry project managed identity, and configures the MCP audience as `api://<ENTRA_APP_CLIENT_ID>`. It then lists the agents in that project so you can select one or more. For each selected agent, it displays the existing instructions and lets you keep them, use the Cosmos DB example, enter a replacement, or load instructions from a UTF-8 text file. It attaches the MCP tool with approval required and an allow-list of the server's tools.

To apply the same multiline instructions to selected agents without an interactive instruction prompt:

```powershell
.\scripts\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1 -AgentInstructionsFile .\scripts\cosmos-agent-instructions.example.txt
```

To test a configured agent from the same script, add `-TestAgent`. The script prompts for the agent number and the prompt to send:

```powershell
.\scripts\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1 -TestAgent
```

You can provide the prompt non-interactively with `-TestPrompt`:

```powershell
.\scripts\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1 -TestAgent -TestPrompt "List the databases available to you."
```

Agent configuration is idempotent. Re-running the script updates the existing connection and role assignment, and creates a new agent version only when the selected agent's instructions or Cosmos DB MCP tool configuration has changed. Existing non-MCP tools and other agent definition settings are preserved.

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
