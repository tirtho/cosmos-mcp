<#
.SYNOPSIS
    Create a managed identity connection in Microsoft Foundry project and assign Entra App role for Cosmos DB MCP Toolkit.

.DESCRIPTION
    This script:
    1. Reads deployment information from deployment-info.json
    2. Retrieves Microsoft Foundry project managed identity details
    3. Creates a managed identity connection in Microsoft Foundry for the Cosmos DB MCP Toolkit server
    4. Assigns the Entra App role to the Microsoft Foundry project managed identity

.PARAMETER Environment
    Environment name used to construct the resource group (for example, dev)

.PARAMETER Suffix
    Numeric or short suffix used to construct the resource group (for example, 1)

.PARAMETER ConnectionName
    Name for the connection in Microsoft Foundry (e.g., "cosmos-mcp-connection")

.PARAMETER AgentInstructionsFile
    Optional UTF-8 text file containing the instructions to apply to selected agents.

.PARAMETER TestAgent
    After setup, prompt for an agent and a test prompt, then invoke the agent through Foundry.

.PARAMETER TestPrompt
    Optional prompt to send when -TestAgent is specified. If omitted, the script prompts for it.

.EXAMPLE
    .\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1

.NOTES
    Prerequisites:
    - Azure CLI installed and authenticated
    - deployment-info.json must exist in the same directory (created by Deploy-Cosmos-MCP-Toolkit.ps1)
    - Appropriate permissions to manage Microsoft Foundry projects and Entra ID app role assignments
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-z0-9-]+$')]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string]$Suffix,
    
    [Parameter(Mandatory=$false)]
    [string]$ConnectionName = "cosmos-mcp-toolkit-connection",

    [Parameter(Mandatory=$false)]
    [string]$AgentInstructionsFile,

    [Parameter(Mandatory=$false)]
    [switch]$TestAgent,

    [Parameter(Mandatory=$false)]
    [string]$TestPrompt
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# Helper functions
function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warning-Message {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Error-Message {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Print-Usage {
    Write-Host @"
Usage: .\Setup-AIFoundry-Connection.ps1 -Environment <environment> -Suffix <suffix> [OPTIONS]

Create a managed identity connection for a selected Microsoft Foundry project and assign the Entra app role.

REQUIRED PARAMETERS:
  -Environment <environment>
                          Environment used in the resource group name (for example, dev)
  -Suffix <suffix>        Suffix used in the resource group name (for example, 1)
  -ConnectionName <name>
                          Connection name
    -AgentInstructionsFile <path>
                                                    Optional UTF-8 file containing replacement instructions
    -TestAgent              Prompt for an agent and test prompt after setup
    -TestPrompt <text>      Prompt to send with -TestAgent

NOTE: deployment-info.json must exist in the same directory as this script.
      This file is produced when running Deploy-Cosmos-MCP-Toolkit.ps1
      It should contain: MCP_SERVER_URI, ENTRA_APP_CLIENT_ID, ENTRA_APP_ROLE_VALUE, ENTRA_APP_ROLE_ID_BY_VALUE, ENTRA_APP_SP_OBJECT_ID
      Connection target is read from MCP_SERVER_URI.
      Connection audience is constructed as api://{ENTRA_APP_CLIENT_ID}.

EXAMPLES:
  .\Setup-AIFoundry-Connection.ps1 -Environment dev -Suffix 1 -ConnectionName "cosmos-mcp-connection"
"@
}

function Parse-Arguments {
    $script:RESOURCE_GROUP = "rg-eia-$Environment-$Suffix"
    $script:AI_FOUNDRY_RESOURCE_GROUP = $script:RESOURCE_GROUP
    $accountInfo = az account show -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $accountInfo) {
        Write-Error-Message "Could not read the active Azure CLI account. Run 'az login' and try again."
        exit 1
    }

    $script:AI_FOUNDRY_SUBSCRIPTION_ID = $accountInfo.id
    $script:AI_FOUNDRY_SUBSCRIPTION_NAME = $accountInfo.name
    Write-Info "[OK] Azure Subscription: $script:AI_FOUNDRY_SUBSCRIPTION_NAME ($script:AI_FOUNDRY_SUBSCRIPTION_ID)"
    Write-Info "[OK] Resource Group: $script:RESOURCE_GROUP"

    $projects = @(az resource list --resource-group $script:RESOURCE_GROUP --resource-type Microsoft.CognitiveServices/accounts/projects --query "[].{name:name,id:id,location:location}" -o json | ConvertFrom-Json)
    if (-not $projects -or $projects.Count -eq 0) {
        Write-Error-Message "No Microsoft Foundry projects were found in '$script:RESOURCE_GROUP' for subscription '$script:AI_FOUNDRY_SUBSCRIPTION_NAME'."
        exit 1
    }

    if ($projects.Count -eq 1) {
        $selectedProject = $projects[0]
        Write-Info "Found one Microsoft Foundry project: $($selectedProject.name)"
    } else {
        Write-Host "Select a Microsoft Foundry project:"
        for ($index = 0; $index -lt $projects.Count; $index++) {
            Write-Host "  [$($index + 1)] $($projects[$index].name) ($($projects[$index].location))"
        }

        do {
            $selection = Read-Host "Enter selection (1-$($projects.Count))"
            $selectionNumber = 0
        } until ([int]::TryParse($selection, [ref]$selectionNumber) -and $selectionNumber -ge 1 -and $selectionNumber -le $projects.Count)

        $selectedProject = $projects[$selectionNumber - 1]
    }

    if ($selectedProject.id -notmatch "/accounts/([^/]+)/projects/([^/]+)$") {
        Write-Error-Message "The selected resource is not a valid Microsoft Foundry project: $($selectedProject.id)"
        exit 1
    }

    $script:AI_FOUNDRY_ACCOUNT_NAME = $Matches[1]
    $script:AI_FOUNDRY_PROJECT_NAME = $Matches[2]
    $script:AI_FOUNDRY_PROJECT_RESOURCE_ID = $selectedProject.id
    
    Write-Info "[OK] Connection Name: $ConnectionName"
    Write-Info "[OK] Using Azure Subscription: $script:AI_FOUNDRY_SUBSCRIPTION_ID"
    Write-Info "[OK] Using Microsoft Foundry Account: $script:AI_FOUNDRY_ACCOUNT_NAME"
    Write-Info "[OK] Using Microsoft Foundry Resource Group: $script:AI_FOUNDRY_RESOURCE_GROUP"
    Write-Info "[OK] Using Microsoft Foundry Project: $script:AI_FOUNDRY_PROJECT_NAME"
    
    # Load deployment info file from same directory as script
    $script:DEPLOYMENT_INFO_FILE = Join-Path $SCRIPT_DIR "deployment-info.json"
    if (-not (Test-Path $script:DEPLOYMENT_INFO_FILE)) {
        Write-Error-Message "Deployment info file not found: $script:DEPLOYMENT_INFO_FILE"
        exit 1
    }
    
    Write-Info "Loading deployment info from: $script:DEPLOYMENT_INFO_FILE"
    $deploymentInfo = Get-Content $script:DEPLOYMENT_INFO_FILE | ConvertFrom-Json
    
    $script:MCP_SERVER_URI = $deploymentInfo.MCP_SERVER_URI
    $script:ENTRA_APP_CLIENT_ID = $deploymentInfo.ENTRA_APP_CLIENT_ID
    $script:ENTRA_APP_ROLE_VALUE = $deploymentInfo.ENTRA_APP_ROLE_VALUE
    $script:ENTRA_APP_ROLE_ID_BY_VALUE = $deploymentInfo.ENTRA_APP_ROLE_ID_BY_VALUE
    $script:ENTRA_APP_SP_OBJECT_ID = $deploymentInfo.ENTRA_APP_SP_OBJECT_ID
    
    if (-not $script:MCP_SERVER_URI -or -not $script:ENTRA_APP_CLIENT_ID -or -not $script:ENTRA_APP_ROLE_VALUE -or -not $script:ENTRA_APP_ROLE_ID_BY_VALUE -or -not $script:ENTRA_APP_SP_OBJECT_ID) {
        Write-Error-Message "Missing required fields in deployment-info.json"
        Write-Error-Message "Required fields: MCP_SERVER_URI, ENTRA_APP_CLIENT_ID, ENTRA_APP_ROLE_VALUE, ENTRA_APP_ROLE_ID_BY_VALUE, ENTRA_APP_SP_OBJECT_ID"
        exit 1
    }
    
    # Foundry uses the connection target as the remote MCP URL during tool discovery.
    $script:MCP_SERVER_ENDPOINT = "$($script:MCP_SERVER_URI.TrimEnd('/'))/mcp"
    $script:CONNECTION_TARGET = $script:MCP_SERVER_ENDPOINT
    $script:CONNECTION_AUDIENCE = "api://$($script:ENTRA_APP_CLIENT_ID)"
    
    Write-Info "[OK] Deployment info loaded successfully"
    Write-Info "[OK] Connection Target: $script:CONNECTION_TARGET"
    Write-Info "[OK] MCP Endpoint: $script:MCP_SERVER_ENDPOINT"
    Write-Info "[OK] Connection Audience: $script:CONNECTION_AUDIENCE"
}

function Check-Prerequisites {
    Write-Info "Checking prerequisites (az-cli)..."
    
    try {
        $null = az version
    } catch {
        Write-Error-Message "Azure CLI is not installed. Please install it from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    }
}

function Login-Azure {
    Write-Info "Checking az cli login status..."
    
    $accountCheck = az account show 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Not logged in to az-cli. Running 'az login'..."
        az login
    }
    
    if ($script:AI_FOUNDRY_SUBSCRIPTION_ID) {
        Write-Info "Setting subscription to $script:AI_FOUNDRY_SUBSCRIPTION_ID"
        az account set --subscription $script:AI_FOUNDRY_SUBSCRIPTION_ID
    }
}

function Get-AccessToken {
    param([string]$ResourceUri)
    
    if (-not $ResourceUri) {
        Write-Error-Message "Resource URI is required"
        exit 1
    }
    
    $tokenJson = az account get-access-token --resource $ResourceUri --query accessToken -o tsv
    
    if ($LASTEXITCODE -ne 0 -or -not $tokenJson) {
        Write-Error-Message "Failed to get access token for $ResourceUri"
        exit 1
    }
    
    return $tokenJson
}

function Get-AIFoundryProjectMI {
    Write-Info "Fetching Microsoft Foundry account region..."
    
    $accountJson = az cognitiveservices account show `
        --name $script:AI_FOUNDRY_ACCOUNT_NAME `
        --resource-group $script:AI_FOUNDRY_RESOURCE_GROUP `
        -o json | ConvertFrom-Json
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Message "Failed to get Microsoft Foundry account details"
        exit 1
    }
    
    $script:AI_FOUNDRY_REGION = $accountJson.location.ToLower() -replace '\s', ''
    
    if (-not $script:AI_FOUNDRY_REGION) {
        Write-Error-Message "Failed to extract region from Microsoft Foundry account"
        exit 1
    }
    
    $armAccessToken = Get-AccessToken -ResourceUri "https://management.azure.com"
    
    Write-Info "Fetching Microsoft Foundry project details..."
    
    $apiEndpoint = "https://$($script:AI_FOUNDRY_REGION).management.azure.com:443/subscriptions/$($script:AI_FOUNDRY_SUBSCRIPTION_ID)/resourcegroups/$($script:AI_FOUNDRY_RESOURCE_GROUP)/providers/Microsoft.CognitiveServices/accounts/$($script:AI_FOUNDRY_ACCOUNT_NAME)/projects/$($script:AI_FOUNDRY_PROJECT_NAME)?api-version=2025-04-01-preview"
    
    $headers = @{
        "Authorization" = "Bearer $armAccessToken"
        "Content-Type" = "application/json"
    }
    
    $response = Invoke-RestMethod -Uri $apiEndpoint -Method Get -Headers $headers
    
    if (-not $response) {
        Write-Error-Message "Empty response from API"
        exit 1
    }
    
    $script:AI_FOUNDRY_PROJECT_MI_PRINCIPAL_ID = $response.identity.principalId
    if (-not $script:AI_FOUNDRY_PROJECT_MI_PRINCIPAL_ID) {
        Write-Error-Message "Failed to extract project MI Principal ID from Microsoft Foundry project"
        Write-Error-Message "Response: $($response | ConvertTo-Json)"
        exit 1
    }
    
    $script:AI_FOUNDRY_PROJECT_MI_TENANT_ID = $response.identity.tenantId
    $script:AI_FOUNDRY_PROJECT_MI_TYPE = $response.identity.type
    
    Write-Info "[OK] Microsoft Foundry Project MI Principal ID: $script:AI_FOUNDRY_PROJECT_MI_PRINCIPAL_ID"
    Write-Info "[OK] Microsoft Foundry Project MI Type: $script:AI_FOUNDRY_PROJECT_MI_TYPE"
}

function Set-AIFoundryMIRoleAssignment {
    Write-Info "Assigning app role to Microsoft Foundry project MI..."
    
    $graphAccessToken = Get-AccessToken -ResourceUri "https://graph.microsoft.com"
    
    Write-Info "Checking for existing role assignment..."
    
    $headers = @{
        "Authorization" = "Bearer $graphAccessToken"
        "Content-Type" = "application/json"
    }
    
    $existingUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$($script:AI_FOUNDRY_PROJECT_MI_PRINCIPAL_ID)/appRoleAssignments"
    $existingAssignments = Invoke-RestMethod -Uri $existingUrl -Method Get -Headers $headers
    
    $existingAssignment = $existingAssignments.value | Where-Object {
        $_.resourceId -eq $script:ENTRA_APP_SP_OBJECT_ID -and $_.appRoleId -eq $script:ENTRA_APP_ROLE_ID_BY_VALUE
    }
    
    if ($existingAssignment) {
        Write-Info "App role assignment already exists for this project MI"
        Write-Info "[OK] Role Assignment ID: $($existingAssignment.id)"
        $script:ENTRA_APP_ROLE_ASSIGNMENT_ID = $existingAssignment.id
    } else {
        Write-Info "Creating app role assignment: '$script:ENTRA_APP_ROLE_VALUE' to project MI..."
        
        $roleAssignmentPayload = @{
            principalId = $script:AI_FOUNDRY_PROJECT_MI_PRINCIPAL_ID
            resourceId = $script:ENTRA_APP_SP_OBJECT_ID
            appRoleId = $script:ENTRA_APP_ROLE_ID_BY_VALUE
        } | ConvertTo-Json
        
        $createUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$($script:AI_FOUNDRY_PROJECT_MI_PRINCIPAL_ID)/appRoleAssignments"
        
        try {
            $response = Invoke-RestMethod -Uri $createUrl -Method Post -Headers $headers -Body $roleAssignmentPayload
            
            $script:ENTRA_APP_ROLE_ASSIGNMENT_ID = $response.id
            if ($script:ENTRA_APP_ROLE_ASSIGNMENT_ID) {
                Write-Info "[OK] Successfully assigned app role to project MI"
                Write-Info "[OK] Role Assignment ID: $script:ENTRA_APP_ROLE_ASSIGNMENT_ID"
            } else {
                Write-Error-Message "Failed to assign app role to project MI"
                Write-Error-Message "Response: $($response | ConvertTo-Json)"
                exit 1
            }
        } catch {
            Write-Error-Message "Failed to create app role assignment: $_"
            exit 1
        }
    }
}

function Create-AIFoundryMIConnection {
    Write-Info "Creating managed identity connection: $ConnectionName..."
    
    $armAccessToken = Get-AccessToken -ResourceUri "https://management.azure.com"
    
    $connectionPayload = @{
        name = $ConnectionName
        type = "Microsoft.CognitiveServices/accounts/projects/connections"
        properties = @{
            authType = "ProjectManagedIdentity"
            audience = $script:CONNECTION_AUDIENCE
            group = "GenericProtocol"
            category = "RemoteTool"
            target = $script:CONNECTION_TARGET
            useWorkspaceManagedIdentity = $false
            isSharedToAll = $false
            sharedUserList = @()
            metadata = @{
                type = "custom_MCP"
            }
        }
    } | ConvertTo-Json -Depth 10
    
    $apiEndpoint = "https://$($script:AI_FOUNDRY_REGION).management.azure.com:443/subscriptions/$($script:AI_FOUNDRY_SUBSCRIPTION_ID)/resourcegroups/$($script:AI_FOUNDRY_RESOURCE_GROUP)/providers/Microsoft.CognitiveServices/accounts/$($script:AI_FOUNDRY_ACCOUNT_NAME)/projects/$($script:AI_FOUNDRY_PROJECT_NAME)/connections/${ConnectionName}?api-version=2025-04-01-preview"
    
    $headers = @{
        "Authorization" = "Bearer $armAccessToken"
        "Content-Type" = "application/json"
    }
    
    try {
        $response = Invoke-RestMethod -Uri $apiEndpoint -Method Put -Headers $headers -Body $connectionPayload
        
        if (-not $response) {
            Write-Error-Message "Empty response from API"
            exit 1
        }
        
        $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_NAME = $response.name
        if (-not $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_NAME) {
            Write-Error-Message "Failed to read connection name from response"
            Write-Error-Message "Response: $($response | ConvertTo-Json)"
            exit 1
        }
        
        $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_TARGET = $response.properties.target
        if (-not $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_TARGET) {
            Write-Error-Message "Failed to read connection target from response"
            Write-Error-Message "Response: $($response | ConvertTo-Json)"
            exit 1
        }
        
        $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_AUDIENCE = $response.properties.audience
        if (-not $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_AUDIENCE) {
            Write-Error-Message "Failed to read connection audience from response"
            Write-Error-Message "Response: $($response | ConvertTo-Json)"
            exit 1
        }
        
        Write-Info "[OK] Connection created successfully"
        Write-Info "[OK] Connection Name: $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_NAME"
        Write-Info "[OK] Connection Target: $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_TARGET"
        Write-Info "[OK] Connection Audience: $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_AUDIENCE"
        
    } catch {
        Write-Error-Message "Failed to create connection: $_"
        exit 1
    }
}

function Get-FoundryProjectEndpoint {
    return "https://$($script:AI_FOUNDRY_ACCOUNT_NAME).services.ai.azure.com/api/projects/$($script:AI_FOUNDRY_PROJECT_NAME)"
}

function Get-FoundryAgentAccessToken {
    $token = az account get-access-token --scope "https://ai.azure.com/.default" --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        Write-Error-Message "Failed to get an access token for the Foundry project data plane"
        exit 1
    }

    return $token
}

function Get-FoundryAgents {
    $headers = @{ Authorization = "Bearer $(Get-FoundryAgentAccessToken)" }
    $uri = "$(Get-FoundryProjectEndpoint)/agents?api-version=v1"
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    $agents = if ($response.data) { $response.data } elseif ($response.value) { $response.value } else { $response }
    return @($agents | Where-Object { $_.name })
}

function Select-FoundryAgents {
    $agents = Get-FoundryAgents
    if ($agents.Count -eq 0) {
        Write-Warning-Message "No agents were found in the selected Foundry project."
        return @()
    }

    Write-Host "Select Foundry agents to configure:"
    for ($index = 0; $index -lt $agents.Count; $index++) {
        Write-Host "  [$($index + 1)] $($agents[$index].name)"
    }
    Write-Host "  [A] All agents"

    do {
        $selection = Read-Host "Enter agent numbers separated by commas, or A"
        if ($selection -match '^[Aa]$') {
            return $agents
        }

        $indexes = @($selection -split ',' | ForEach-Object {
            $number = 0
            if ([int]::TryParse($_.Trim(), [ref]$number) -and $number -ge 1 -and $number -le $agents.Count) {
                $number - 1
            }
        } | Select-Object -Unique)
    } until ($indexes.Count -gt 0)

    return @($indexes | ForEach-Object { $agents[$_] })
}

function Get-AgentDefinition {
    param([object]$Agent)

    $headers = @{ Authorization = "Bearer $(Get-FoundryAgentAccessToken)" }
    $agentName = [uri]::EscapeDataString([string]$Agent.name)
    $uri = "$(Get-FoundryProjectEndpoint)/agents/$agentName/versions?api-version=v1"
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    $versions = if ($response.data) { @($response.data) } elseif ($response.value) { @($response.value) } else { @($response) }
    $latestVersion = $versions |
        Where-Object { $_.definition } |
        Sort-Object { [int]$_.version } -Descending |
        Select-Object -First 1

    if (-not $latestVersion) {
        Write-Error-Message "No readable agent version was found for '$($Agent.name)'"
        return $null
    }

    $script:CURRENT_AGENT_VERSION = $latestVersion.version
    $script:CURRENT_AGENT_INSTANCE_PRINCIPAL_ID = $latestVersion.instance_identity.principal_id
    return $latestVersion.definition
}

function Ensure-AgentInstanceRoleAssignment {
    param([string]$PrincipalId)

    if (-not $PrincipalId) {
        Write-Warning-Message "The latest agent version has no instance identity; skipping agent role assignment."
        return
    }

    $graphAccessToken = Get-AccessToken -ResourceUri "https://graph.microsoft.com"
    $headers = @{
        Authorization = "Bearer $graphAccessToken"
        "Content-Type" = "application/json"
    }
    $existingUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments"
    $existingAssignments = Invoke-RestMethod -Uri $existingUrl -Method Get -Headers $headers
    $existingAssignment = $existingAssignments.value | Where-Object {
        $_.resourceId -eq $script:ENTRA_APP_SP_OBJECT_ID -and $_.appRoleId -eq $script:ENTRA_APP_ROLE_ID_BY_VALUE
    }

    if ($existingAssignment) {
        Write-Info "[OK] App role already assigned to agent instance identity $PrincipalId"
        return
    }

    $payload = @{
        principalId = $PrincipalId
        resourceId = $script:ENTRA_APP_SP_OBJECT_ID
        appRoleId = $script:ENTRA_APP_ROLE_ID_BY_VALUE
    } | ConvertTo-Json
    Invoke-RestMethod -Uri $existingUrl -Method Post -Headers $headers -Body $payload | Out-Null
    Write-Info "[OK] Assigned '$script:ENTRA_APP_ROLE_VALUE' to agent instance identity $PrincipalId"
}

function Read-AgentInstructions {
    param([string]$CurrentInstructions)

    $example = @"
You are a Cosmos DB data assistant. Use the available Cosmos DB MCP tools to answer questions about data. Discover databases with list_databases and containers with list_collections before querying when the database or container is unknown. For tools that require a database and container, use arguments in this format:
{
  "databaseId": "<database name>",
  "containerId": "<container name>"
}
Never invent database or container names. Explain which database and container you used, and ask the user to clarify when they are ambiguous.
For document searches, use the search tool. The server caches the container schema and indexing capabilities on the first search, chooses the best available strategy, and returns the top N results ordered by descending score. N defaults to 5.
"@

Write-Host ""
Write-Host "Current agent instructions:"
Write-Host $(if ($CurrentInstructions) { $CurrentInstructions } else { "<none>" })
Write-Host ""
Write-Host "[K] Keep current  [E] Use example  [C] Enter one-line replacement  [F] Read replacement from file"
do {
    $choice = (Read-Host "Choose instruction source").Trim().ToUpperInvariant()
    switch ($choice) {
        "K" { return $CurrentInstructions }
        "E" { return $example }
        "C" {
            $replacement = Read-Host "Enter replacement instructions"
            if ($replacement) { return $replacement }
        }
        "F" {
            $path = Read-Host "Enter UTF-8 instruction file path"
            if (Test-Path $path) { return (Get-Content -Raw -Path $path) }
        }
    }
} until ($false)
}

function Test-McpToolMatches {
    param(
        [object]$Tool,
        [object]$DesiredTool
    )

    if (-not $Tool -or $Tool.type -ne $DesiredTool.type -or $Tool.server_label -ne $DesiredTool.server_label -or $Tool.server_url -ne $DesiredTool.server_url -or $Tool.require_approval -ne $DesiredTool.require_approval -or $Tool.project_connection_id -ne $DesiredTool.project_connection_id) {
        return $false
    }

    $actualAllowedTools = if ($Tool.allowed_tools.tool_names) { @($Tool.allowed_tools.tool_names) } else { @($Tool.allowed_tools) }
    $desiredAllowedTools = if ($DesiredTool.allowed_tools.tool_names) { @($DesiredTool.allowed_tools.tool_names) } else { @($DesiredTool.allowed_tools) }
    $actualAllowedTools = @($actualAllowedTools | ForEach-Object { [string]$_ } | Sort-Object)
    $desiredAllowedTools = @($desiredAllowedTools | ForEach-Object { [string]$_ } | Sort-Object)
    return (($actualAllowedTools -join "|") -eq ($desiredAllowedTools -join "|"))
}

function Update-FoundryAgents {
    $selectedAgents = Select-FoundryAgents
    if ($selectedAgents.Count -eq 0) {
        return
    }

    $allowedTools = @(
        "search",
        "list_databases",
        "list_collections",
        "get_recent_documents",
        "text_search",
        "find_document_by_id",
        "get_approximate_schema",
        "vector_search",
        "hybrid_search"
    )
    $mcpTool = [pscustomobject]@{
        type = "mcp"
        server_label = "cosmos-mcp"
        server_url = $script:MCP_SERVER_ENDPOINT
        require_approval = "always"
        project_connection_id = $ConnectionName
        allowed_tools = @{ tool_names = $allowedTools }
    }

    foreach ($agent in $selectedAgents) {
        Write-Info "Reading agent '$($agent.name)'..."
        $currentDefinition = Get-AgentDefinition -Agent $agent
        if (-not $currentDefinition) {
            Write-Error-Message "Could not read the definition for agent '$($agent.name)'"
            exit 1
        }
        Ensure-AgentInstanceRoleAssignment -PrincipalId $script:CURRENT_AGENT_INSTANCE_PRINCIPAL_ID

        $currentInstructions = $currentDefinition.instructions
        Write-Host ""
        Write-Host "Current agent instructions for '$($agent.name)':"
        Write-Host $(if ($currentInstructions) { $currentInstructions } else { "<none>" })

        $instructions = if ($AgentInstructionsFile) {
            if (-not (Test-Path $AgentInstructionsFile)) {
                Write-Error-Message "Agent instructions file not found: $AgentInstructionsFile"
                exit 1
            }
            Get-Content -Raw -Path $AgentInstructionsFile
        } else {
            Read-AgentInstructions -CurrentInstructions $currentDefinition.instructions
        }

        $updatedDefinition = $currentDefinition | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $updatedDefinition.instructions = $instructions
        $existingTools = @($updatedDefinition.tools | Where-Object { $_ })
        $matchingTools = @($existingTools | Where-Object { $_.type -eq "mcp" -and ($_.server_label -eq $mcpTool.server_label -or $_.project_connection_id -eq $ConnectionName) })
        $matchingTool = $matchingTools | Select-Object -First 1
        $existingTools = @($existingTools | Where-Object { $_ -notin $matchingTools })
        $updatedDefinition.tools = @($existingTools + $mcpTool)

        $instructionsChanged = $currentInstructions -ne $instructions
        if (-not $instructionsChanged -and (Test-McpToolMatches -Tool $matchingTool -DesiredTool $mcpTool) -and $matchingTools.Count -eq 1) {
            Write-Info "Agent '$($agent.name)' is already configured; no new version required."
            continue
        }

        $headers = @{
            Authorization = "Bearer $(Get-FoundryAgentAccessToken)"
            "Content-Type" = "application/json"
        }
        $payload = @{ definition = $updatedDefinition } | ConvertTo-Json -Depth 100
        $uri = "$(Get-FoundryProjectEndpoint)/agents/$([uri]::EscapeDataString($agent.name))/versions?api-version=v1"
        Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $payload | Out-Null
        Write-Info "[OK] Created a new version for agent '$($agent.name)' with the Cosmos DB MCP tool."
    }
}

function Test-FoundryAgent {
    param([string]$Prompt)

    $agents = Get-FoundryAgents
    if ($agents.Count -eq 0) {
        Write-Error-Message "No Foundry agents are available to test."
        return
    }

    Write-Host ""
    Write-Host "Select an agent to test:"
    for ($index = 0; $index -lt $agents.Count; $index++) {
        Write-Host "  [$($index + 1)] $($agents[$index].name)"
    }

    do {
        $selection = Read-Host "Enter agent number"
        $selectionNumber = 0
    } until ([int]::TryParse($selection, [ref]$selectionNumber) -and $selectionNumber -ge 1 -and $selectionNumber -le $agents.Count)

    $agentName = $agents[$selectionNumber - 1].name
    Get-AgentDefinition -Agent $agents[$selectionNumber - 1] | Out-Null
    Ensure-AgentInstanceRoleAssignment -PrincipalId $script:CURRENT_AGENT_INSTANCE_PRINCIPAL_ID
    if (-not $Prompt) {
        $Prompt = Read-Host "Enter a prompt for $agentName"
    }
    if (-not $Prompt) {
        Write-Error-Message "A non-empty test prompt is required."
        return
    }

    $headers = @{
        Authorization = "Bearer $(Get-FoundryAgentAccessToken)"
        "Content-Type" = "application/json"
    }
    $payload = @{
        input = $Prompt
        agent_reference = @{
            type = "agent_reference"
            name = $agentName
        }
    } | ConvertTo-Json -Depth 10
    $uri = "$(Get-FoundryProjectEndpoint)/openai/v1/responses"

    Write-Info "Invoking Foundry agent '$agentName'..."
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $payload
        Write-Host ""
        $finalText = @(
            $response.output |
                Where-Object { $_.type -eq "message" -and $_.role -eq "assistant" } |
                ForEach-Object {
                    $_.content |
                        Where-Object { $_.type -eq "output_text" -and $_.text } |
                        ForEach-Object { $_.text }
                }
        ) -join "`n"

        Write-Host "Agent response from Foundry ($agentName):"
        if ($response.output_text) {
            Write-Host $response.output_text
        } elseif ($finalText) {
            Write-Host $finalText
        } else {
            Write-Warning-Message "Foundry returned no final assistant message."
            return $false
        }

        $toolCalls = @($response.output | Where-Object { $_.type -eq "mcp_call" -and $_.name })
        if ($toolCalls.Count -gt 0) {
            Write-Host ""
            Write-Host "Foundry MCP tool calls ($($toolCalls.Count)):"
            $toolCalls | ForEach-Object {
                Write-Host "  - $($_.name) [$($_.status)]"
            }
        }
    } catch {
        Write-Error-Message "Foundry agent invocation failed: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            Write-Error-Message $_.ErrorDetails.Message
        }
        return $false
    }

    return $true
}

function Show-Results {
    Write-Host ""
    
    $results = @{
        AI_FOUNDRY_PROJECT_RESOURCE_ID = $script:AI_FOUNDRY_PROJECT_RESOURCE_ID
        AI_FOUNDRY_SUBSCRIPTION_ID = $script:AI_FOUNDRY_SUBSCRIPTION_ID
        AI_FOUNDRY_RESOURCE_GROUP = $script:AI_FOUNDRY_RESOURCE_GROUP
        AI_FOUNDRY_ACCOUNT_NAME = $script:AI_FOUNDRY_ACCOUNT_NAME
        AI_FOUNDRY_PROJECT_NAME = $script:AI_FOUNDRY_PROJECT_NAME
        AI_FOUNDRY_REGION = $script:AI_FOUNDRY_REGION
        AI_FOUNDRY_PROJECT_MI_PRINCIPAL_ID = $script:AI_FOUNDRY_PROJECT_MI_PRINCIPAL_ID
        AI_FOUNDRY_PROJECT_MI_TYPE = $script:AI_FOUNDRY_PROJECT_MI_TYPE
        AI_FOUNDRY_PROJECT_MI_TENANT_ID = $script:AI_FOUNDRY_PROJECT_MI_TENANT_ID
        AI_FOUNDRY_PROJECT_MI_CONNECTION_NAME = $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_NAME
        AI_FOUNDRY_PROJECT_MI_CONNECTION_TARGET = $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_TARGET
        AI_FOUNDRY_PROJECT_MI_CONNECTION_AUDIENCE = $script:AI_FOUNDRY_PROJECT_MI_CONNECTION_AUDIENCE
    }
    
    Write-Host ($results | ConvertTo-Json -Depth 10)
    Write-Host ""
}

# Main function
function Main {
    Check-Prerequisites
    Login-Azure
    Parse-Arguments
    Get-AIFoundryProjectMI
    Create-AIFoundryMIConnection
    Set-AIFoundryMIRoleAssignment
    $mcpAppName = ([uri]$script:MCP_SERVER_URI).Host.Split('.')[0]
    az containerapp update --name $mcpAppName --resource-group $script:RESOURCE_GROUP --set-env-vars "AzureAd__TrustedPrincipalObjectIds=$script:AI_FOUNDRY_PROJECT_MI_PRINCIPAL_ID" --output none
    Write-Info "[OK] Configured Foundry project identity allow-list on the MCP server"
    if ($TestAgent) {
        if (-not (Test-FoundryAgent -Prompt $TestPrompt)) {
            exit 1
        }
    } else {
        Update-FoundryAgents
    }
    Show-Results
}

# Run main function
Main
