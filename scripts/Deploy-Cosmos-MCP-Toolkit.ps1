#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploy Azure Cosmos DB MCP Toolkit to Azure Container App
.DESCRIPTION
    This script performs the complete MCP deployment following the PostgreSQL team's pattern:
    1. Creates Entra app with proper authentication and role
    2. Deploys infrastructure if needed
    3. Builds and pushes Docker image
    4. Assigns necessary permissions (Cosmos DB, Container Registry)
    5. Updates container app with new image and authentication
    6. Creates deployment-info.json for Microsoft Foundry integration
.PARAMETER Environment
    Environment name used to construct the resource group (for example, dev)
.PARAMETER Suffix
    Numeric or short suffix used to construct the resource group (for example, 1)
.PARAMETER Location
    Optional Azure region override. When omitted, the resource group's region is used.
.EXAMPLE
    ./Deploy-Cosmos-MCP-Toolkit.ps1 -Environment dev -Suffix 1
.EXAMPLE
    ./Deploy-Cosmos-MCP-Toolkit.ps1 -Environment dev -Suffix 1 -Location "westus2"
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-z0-9-]+$')]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string]$Suffix,
    
    [Parameter(Mandatory=$false)]
    [string]$Location = ""
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# Entra App Configuration (following PostgreSQL pattern)
$ENTRA_APP_ROLE_DESC = "Executor role for MCP Tool operations on Cosmos DB"
$ENTRA_APP_ROLE_DISPLAY = "MCP Tool Executor"
$ENTRA_APP_ROLE_VALUE = "Mcp.Tool.Executor"

# Color functions
function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Error { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Select-Resource {
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$Resources,
        [Parameter(Mandatory=$true)]
        [string]$Label
    )

    if (-not $Resources -or $Resources.Count -eq 0) {
        Write-Error "No $Label resources were found in resource group '$($script:RESOURCE_GROUP)' and the selected subscription."
        exit 1
    }

    if ($Resources.Count -eq 1) {
        $resourceLabel = if ($Resources[0].displayName) { $Resources[0].displayName } else { $Resources[0].name }
        Write-Info "Found one $Label resource: $resourceLabel"
        return $Resources[0]
    }

    Write-Host "Select a $($Label):"
    for ($index = 0; $index -lt $Resources.Count; $index++) {
        $resourceLabel = if ($Resources[$index].displayName) { $Resources[$index].displayName } else { $Resources[$index].name }
        Write-Host "  [$($index + 1)] $resourceLabel"
    }

    do {
        $selection = Read-Host "Enter selection (1-$($Resources.Count))"
        $selectionNumber = 0
    } until ([int]::TryParse($selection, [ref]$selectionNumber) -and $selectionNumber -ge 1 -and $selectionNumber -le $Resources.Count)

    return $Resources[$selectionNumber - 1]
}

function Select-Cosmos-Account {
    $cosmosAccounts = @(az cosmosdb list --resource-group $script:RESOURCE_GROUP --query "[].{name:name,id:id,location:location,documentEndpoint:documentEndpoint}" -o json | ConvertFrom-Json)
    if (-not $cosmosAccounts -or $cosmosAccounts.Count -eq 0) {
        Write-Error "No Azure Cosmos DB accounts were found in '$($script:RESOURCE_GROUP)' for subscription '$($script:SUBSCRIPTION_NAME)' ($($script:SUBSCRIPTION_ID))."
        Write-Error "Create or move a Cosmos DB account into this resource group, then run the deployment again."
        exit 1
    }

    $selectedAccount = Select-Resource -Resources $cosmosAccounts -Label "Azure Cosmos DB account"
    $script:CosmosAccountName = $selectedAccount.name
    $script:COSMOS_ENDPOINT = $selectedAccount.documentEndpoint
    $cosmosRegionSlug = ($selectedAccount.location -replace '\s', '').ToLowerInvariant()
    $script:COSMOS_SEMANTIC_RERANKER_INFERENCE_ENDPOINT = "https://$($selectedAccount.name).$cosmosRegionSlug.dbinference.azure.com"
    Write-Info "Selected Cosmos DB account: $($script:CosmosAccountName)"
    Write-Info "Semantic reranker inference endpoint: $($script:COSMOS_SEMANTIC_RERANKER_INFERENCE_ENDPOINT)"
}

function Select-Foundry-Project {
    # Foundry projects can be represented as either legacy ML workspaces or
    # current Cognitive Services account project child resources. Neither query
    # applies a location filter; resources may be in any Azure region.
    $legacyProjects = @(az resource list --resource-group $script:RESOURCE_GROUP --resource-type Microsoft.MachineLearningServices/workspaces --query "[?kind=='Project' || kind=='project'].{name:name,id:id,kind:kind}" -o json | ConvertFrom-Json)
    $cognitiveServiceProjects = @(az resource list --resource-group $script:RESOURCE_GROUP --resource-type Microsoft.CognitiveServices/accounts/projects --query "[?kind=='AIServices' || kind=='aiservices' || kind=='Project' || kind=='project'].{name:name,id:id,kind:kind}" -o json | ConvertFrom-Json)
    $projects = @($legacyProjects + $cognitiveServiceProjects)
    if (-not $projects -or $projects.Count -eq 0) {
        Write-Error "No Microsoft Foundry projects were found in '$($script:RESOURCE_GROUP)' for subscription '$($script:SUBSCRIPTION_NAME)' ($($script:SUBSCRIPTION_ID))."
        Write-Error "Create a Microsoft Foundry project in this resource group, then run the deployment again."
        exit 1
    }

    $selectedProject = Select-Resource -Resources $projects -Label "Microsoft Foundry project"
    $script:AIF_PROJECT_RESOURCE_ID = $selectedProject.id
    $script:AIF_PROJECT_NAME = $selectedProject.name

    $projectDetails = az resource show --ids $selectedProject.id -o json | ConvertFrom-Json
    $script:OPENAI_ENDPOINT = $projectDetails.properties.discoveryUrl
    if ([string]::IsNullOrWhiteSpace($script:OPENAI_ENDPOINT)) {
        $script:OPENAI_ENDPOINT = $projectDetails.properties.endpoint
    }
    if ([string]::IsNullOrWhiteSpace($script:OPENAI_ENDPOINT) -and $projectDetails.properties.endpoints) {
        $script:OPENAI_ENDPOINT = $projectDetails.properties.endpoints.'AI Foundry API'
    }
    if ([string]::IsNullOrWhiteSpace($script:OPENAI_ENDPOINT)) {
        Write-Error "The selected Foundry project '$($script:AIF_PROJECT_NAME)' does not expose a discovery or endpoint URL."
        Write-Error "Open the project in Azure AI Foundry, copy its project endpoint, and retry after the project is fully provisioned."
        exit 1
    }

    Write-Info "Selected Foundry project: $($script:AIF_PROJECT_NAME)"
    Write-Info "Foundry project endpoint: $($script:OPENAI_ENDPOINT)"
}

function Select-Embedding-Deployment {
    $cognitiveAccounts = @(az cognitiveservices account list --resource-group $script:RESOURCE_GROUP --query "[].{name:name,id:id,kind:kind,endpoint:properties.endpoint}" -o json | ConvertFrom-Json)
    $deployments = @()
    foreach ($account in $cognitiveAccounts) {
        $accountDeployments = @(az cognitiveservices account deployment list --name $account.name --resource-group $script:RESOURCE_GROUP -o json 2>$null | ConvertFrom-Json)
        foreach ($deployment in $accountDeployments) {
            if ($deployment.name -match 'embedding|ada|text-embedding') {
                $deployments += [pscustomobject]@{
                    name = $deployment.name
                    accountName = $account.name
                    accountId = $account.id
                    modelName = $deployment.properties.model.name
                    modelVersion = $deployment.properties.model.version
                    endpoint = $account.endpoint
                }
            }
        }
    }

    $duplicateDeploymentNames = @($deployments | Group-Object -Property name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    foreach ($deployment in $deployments) {
        if ($duplicateDeploymentNames -contains $deployment.name) {
            $deployment | Add-Member -NotePropertyName displayName -NotePropertyValue "$($deployment.name) (AI service: $($deployment.accountName))"
        }
    }

    if (-not $deployments -or $deployments.Count -eq 0) {
        Write-Warn "No embedding deployment was found in the selected resource group."
        $deploy = Read-Host "Deploy an embedding model now? (y/n)"
        if ($deploy -notmatch '^(y|yes)$') {
            Write-Error "An embedding deployment is required for vector and hybrid search. Deployment cancelled."
            exit 1
        }

        if (-not $cognitiveAccounts -or $cognitiveAccounts.Count -eq 0) {
            Write-Error "No Azure AI Services account was found to host the embedding deployment."
            Write-Error "Create the backing Azure AI Services account in '$($script:RESOURCE_GROUP)' and rerun this script."
            exit 1
        }

        $embeddingAccount = Select-Resource -Resources $cognitiveAccounts -Label "Azure AI Services account for embeddings"
        $deploymentName = Read-Host "Embedding deployment name (default: text-embedding-3-small)"
        if ([string]::IsNullOrWhiteSpace($deploymentName)) { $deploymentName = "text-embedding-3-small" }
        $modelName = Read-Host "Model name (default: $deploymentName)"
        if ([string]::IsNullOrWhiteSpace($modelName)) { $modelName = $deploymentName }
        $modelVersion = Read-Host "Model version (required, for example 1)"
        $capacity = Read-Host "Deployment capacity in thousands of tokens per minute (default: 1)"
        if ([string]::IsNullOrWhiteSpace($capacity)) { $capacity = "1" }
        Write-Info "Creating '$deploymentName' for model '$modelName' version '$modelVersion' on '$($embeddingAccount.name)'."
        $confirmDeployment = Read-Host "Proceed with this Azure model deployment? (y/n)"
        if ($confirmDeployment -notmatch '^(y|yes)$') {
            Write-Error "Embedding deployment cancelled."
            exit 1
        }

        az cognitiveservices account deployment create --name $embeddingAccount.name --resource-group $script:RESOURCE_GROUP --deployment-name $deploymentName --model-format OpenAI --model-name $modelName --model-version $modelVersion --sku-name Standard --sku-capacity $capacity --output table
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create embedding deployment '$deploymentName'."
            exit 1
        }
        $script:EMBEDDING_DEPLOYMENT = $deploymentName
        $script:OPENAI_ENDPOINT = $embeddingAccount.endpoint
        $script:EMBEDDING_ACCOUNT_ID = $embeddingAccount.id
        Write-Info "Embedding deployment created successfully."
    }
    else {
        $selectedDeployment = Select-Resource -Resources $deployments -Label "embedding deployment"
        $script:EMBEDDING_DEPLOYMENT = $selectedDeployment.name
        $script:OPENAI_ENDPOINT = $selectedDeployment.endpoint
        $script:EMBEDDING_ACCOUNT_ID = $selectedDeployment.accountId
        Write-Info "Selected embedding deployment: $($selectedDeployment.name) ($($selectedDeployment.modelName) $($selectedDeployment.modelVersion))"
    }

    $confirmation = Read-Host "Confirm this is the same embedding model used to vectorize the selected Cosmos DB data? (y/n)"
    if ($confirmation -notmatch '^(y|yes)$') {
        Write-Error "Embedding model confirmation was not provided. Deployment cancelled to avoid incompatible vector dimensions."
        exit 1
    }
}

function Auto-Detect-Resources {
    Write-Info "Discovering resources in resource group: $($script:RESOURCE_GROUP)"
    Select-Cosmos-Account
    Select-Foundry-Project
    Select-Embedding-Deployment
    
}

function Show-Usage {
    Write-Host "Usage: $($MyInvocation.MyCommand.Name) -Environment <environment> -Suffix <suffix> [-Location <location>]"
    Write-Host ""
    Write-Host "Arguments:"
    Write-Host "  -Environment             Environment used in resource group name rg-eia-<environment>-<suffix>"
    Write-Host "  -Suffix                  Suffix used in resource group name"
    Write-Host "  -Location               Optional region override (defaults to the resource group's region)"
    Write-Host "  Names are derived as acr<environment><suffix>, ca-eia-<environment>-<suffix>, and entra-eia-<environment>-<suffix>"
    Write-Host ""
    exit 1
}

function Parse-Arguments {
    # Set script-level variables for use in all functions
    $script:ENVIRONMENT = $Environment.ToLowerInvariant()
    $script:SUFFIX = $Suffix.ToLowerInvariant()
    $script:RESOURCE_GROUP = "rg-eia-$($script:ENVIRONMENT)-$($script:SUFFIX)"
    $script:ResourceGroup = $script:RESOURCE_GROUP
    $script:LOCATION = $Location
    $script:ENTRA_APP_NAME = "entra-eia-$($script:ENVIRONMENT)-$($script:SUFFIX)"
    # ACR names are globally unique and allow only lowercase letters and numbers.
    $acrNameSuffix = "$($script:ENVIRONMENT)$($script:SUFFIX)" -replace '[^a-z0-9]', ''
    $script:ACR_NAME = "acr$acrNameSuffix"
    if ($script:ACR_NAME.Length -gt 50) {
        $script:ACR_NAME = $script:ACR_NAME.Substring(0, 50)
    }
    $script:ContainerAppName = "ca-eia-$($script:ENVIRONMENT)-$($script:SUFFIX)"
    $script:COSMOS_RESOURCE_GROUP = $script:RESOURCE_GROUP
    $script:ACR_RESOURCE_GROUP = $script:RESOURCE_GROUP
    $script:USE_EXISTING_ACR = $false
    
    Write-Info "Using Azure Resource Group: $($script:RESOURCE_GROUP)"
    if (-not [string]::IsNullOrWhiteSpace($Location)) {
        Write-Info "Requested location override: $Location"
    }
    else {
        Write-Info "Location will be resolved from the selected resource group"
    }
    Write-Info "Using Cosmos Resource Group: $($script:COSMOS_RESOURCE_GROUP)"
    Write-Info "Using ACR Resource Group: $($script:ACR_RESOURCE_GROUP)"
    Write-Info "Using derived ACR Name: $($script:ACR_NAME)"
    Write-Info "Using Container App Name: $($script:ContainerAppName)"
    Write-Info "Using Entra App Name: $($script:ENTRA_APP_NAME)"
}

function Create-Entra-App {
    Write-Info "Checking for existing Entra App registration: $ENTRA_APP_NAME"

    # Check if app already exists
    $existingApp = az ad app list --display-name $ENTRA_APP_NAME --query "[0]" | ConvertFrom-Json
    
    if ($existingApp -and $existingApp.appId) {
        Write-Info "Found existing Entra App with name: $ENTRA_APP_NAME"
        Write-Info "Using existing app registration (skipping ownership checks)"
        
        # Use existing app
        $ENTRA_APP_CLIENT_ID = $existingApp.appId
        $ENTRA_APP_OBJECT_ID = $existingApp.id
        
        Write-Info "ENTRA_APP_CLIENT_ID=$ENTRA_APP_CLIENT_ID"
        Write-Info "ENTRA_APP_OBJECT_ID=$ENTRA_APP_OBJECT_ID"
    }
    else {
        Write-Info "Creating new Entra App registration: $ENTRA_APP_NAME"
        
        # Try without service-management-reference first (works for most subscriptions)
        # Capture output and suppress PowerShell error handling temporarily
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        
        $appJson = (az ad app create --display-name $ENTRA_APP_NAME 2>&1) | Out-String
        $firstExitCode = $LASTEXITCODE
        
        $ErrorActionPreference = $oldErrorActionPreference
        
        # If it failed due to service-management-reference requirement, try to auto-detect
        if ($firstExitCode -ne 0) {
            if ($appJson -match "ServiceManagementReference") {
                Write-Warn "Subscription requires service-management-reference parameter"
                Write-Info "Attempting to auto-detect service-management-reference GUID from existing apps..."
                Write-Info "(This may take 10-20 seconds...)"
                
                # Query with a timeout to avoid hanging indefinitely
                # Use --top to limit the number of apps fetched from the API
                $job = Start-Job -ScriptBlock {
                    az ad app list --top 5 --query "[?serviceManagementReference != null] | [0].{name:displayName, smRef:serviceManagementReference}" 2>$null
                }
                
                # Wait for up to 30 seconds
                $completed = Wait-Job -Job $job -Timeout 30
                
                if ($completed) {
                    $result = Receive-Job -Job $job
                    Remove-Job -Job $job
                    
                    if ($result) {
                        $existingApps = $result | ConvertFrom-Json
                    }
                    else {
                        $existingApps = $null
                    }
                }
                else {
                    Write-Warn "Auto-detection timed out after 30 seconds"
                    Stop-Job -Job $job
                    Remove-Job -Job $job
                    $existingApps = $null
                }
                
                if ($existingApps -and $existingApps.Count -gt 0) {
                    $smRef = $existingApps[0].serviceManagementReference
                    Write-Info "Found service-management-reference from existing app '$($existingApps[0].name)': $smRef"
                    Write-Info "Attempting to create Entra App with detected GUID..."
                    
                    $appJson = az ad app create --display-name $ENTRA_APP_NAME --service-management-reference $smRef 2>&1
                    $secondExitCode = $LASTEXITCODE
                    
                    if ($secondExitCode -eq 0) {
                        Write-Info "Successfully created Entra App with auto-detected service-management-reference"
                    }
                    else {
                        Write-Error @"
Failed to create Entra App with auto-detected service-management-reference.

The detected GUID '$smRef' from existing app '$($existingApps[0].name)' didn't work.

MANUAL SOLUTION:
1. Find the correct service-management-reference GUID from your IT department
2. Create the app manually:
   az ad app create --display-name "$ENTRA_APP_NAME" --service-management-reference YOUR_SERVICE_GUID

3. Then re-run this script with the same `-Environment` and `-Suffix` values.
"@
                        exit 1
                    }
                }
                else {
                    Write-Error @"
================================================================================
SUBSCRIPTION POLICY REQUIRES SERVICE-MANAGEMENT-REFERENCE
================================================================================

Your subscription requires the --service-management-reference parameter.
Auto-detection failed or timed out.

FASTEST SOLUTION - SKIP AUTO-DETECTION:

If you already created the derived Entra App manually, rerun with the same `-Environment` and `-Suffix` values.

MANUAL CREATION OPTIONS:

1. CREATE WITH A KNOWN GUID:
   Ask your IT department for the service-management-reference GUID, then:
   
   az ad app create --display-name "Azure Cosmos DB MCP Toolkit API" \
     --service-management-reference YOUR_SERVICE_GUID
   
    Then re-run this script with the same `-Environment` and `-Suffix` values.

2. FIND AN EXISTING APP'S GUID:
   Run: az ad app show --id <any-existing-app-id> --query serviceManagementReference
   Then use that GUID to create your app.

For more information: https://aka.ms/service-management-reference-error
================================================================================
"@
                    exit 1
                }
            }
            else {
                Write-Error "Failed to create Entra App: $appJson"
                exit 1
            }
        }
        
        # Parse the JSON response
        $appJson = $appJson | ConvertFrom-Json
        
        $ENTRA_APP_CLIENT_ID = $appJson.appId
        $ENTRA_APP_OBJECT_ID = $appJson.id
        
        if (-not $ENTRA_APP_CLIENT_ID -or -not $ENTRA_APP_OBJECT_ID) {
            Write-Error "Failed to create Entra App or retrieve app details"
            exit 1
        }
        
        Write-Info "ENTRA_APP_CLIENT_ID=$ENTRA_APP_CLIENT_ID"
        Write-Info "ENTRA_APP_OBJECT_ID=$ENTRA_APP_OBJECT_ID"
    }

    $GRAPH_BASE = "https://graph.microsoft.com/v1.0"
    $ENTRA_APP_URL = "$GRAPH_BASE/applications/$ENTRA_APP_OBJECT_ID"
    $ENTRA_APP_ROLE_ID = [guid]::NewGuid().ToString()

    # Set Application ID (audience) URI for the Entra App
    Write-Info "Setting Application ID URI..."
    try {
        # Use az ad app update instead of az rest for better compatibility
        az ad app update --id $ENTRA_APP_CLIENT_ID --identifier-uris "api://$ENTRA_APP_CLIENT_ID" | Out-Null
    }
    catch {
        Write-Warn "Failed to set Application ID URI, but continuing deployment..."
    }

    # Add OAuth2 permission scope and pre-authorize Azure CLI
    # This is required for `az account get-access-token --resource <clientId>` to work
    Write-Info "Configuring OAuth2 permission scope for token acquisition..."
    try {
        $appDetails = az rest --method GET --url $ENTRA_APP_URL | ConvertFrom-Json
        $existingScopes = $appDetails.api.oauth2PermissionScopes
        $hasAccessScope = $existingScopes | Where-Object { $_.value -eq "access_as_user" }

        if (-not $hasAccessScope) {
            Write-Info "Adding 'access_as_user' OAuth2 permission scope..."
            $scopeId = [guid]::NewGuid().ToString()
            $scopePayload = @{
                api = @{
                    oauth2PermissionScopes = @(
                        @{
                            adminConsentDescription = "Allow the application to access the Cosmos DB MCP Toolkit API on behalf of the signed-in user."
                            adminConsentDisplayName = "Access Cosmos DB MCP Toolkit API"
                            id = $scopeId
                            isEnabled = $true
                            type = "User"
                            userConsentDescription = "Allow the application to access the Cosmos DB MCP Toolkit API on your behalf."
                            userConsentDisplayName = "Access Cosmos DB MCP Toolkit API"
                            value = "access_as_user"
                        }
                    )
                }
            } | ConvertTo-Json -Depth 10

            $tempScopeFile = [System.IO.Path]::GetTempFileName()
            $scopePayload | Out-File -FilePath $tempScopeFile -Encoding utf8 -NoNewline
            az rest --method PATCH --url $ENTRA_APP_URL --headers "Content-Type=application/json" --body "@$tempScopeFile" | Out-Null
            Remove-Item $tempScopeFile -Force
            Write-Info "OAuth2 permission scope 'access_as_user' added successfully"
        } else {
            $scopeId = $hasAccessScope.id
            Write-Info "OAuth2 permission scope 'access_as_user' already exists"
        }

        # Pre-authorize Azure CLI (04b07795-8ddb-461a-bbee-02f9e1bf7b46) for the scope
        Write-Info "Pre-authorizing Azure CLI for token acquisition..."
        $azureCliAppId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

        $refreshedApp = az rest --method GET --url $ENTRA_APP_URL | ConvertFrom-Json
        $existingPreAuth = $refreshedApp.api.preAuthorizedApplications | Where-Object { $_.appId -eq $azureCliAppId }

        if (-not $existingPreAuth) {
            $preAuthPayload = @{
                api = @{
                    preAuthorizedApplications = @(
                        @{
                            appId = $azureCliAppId
                            delegatedPermissionIds = @($scopeId)
                        }
                    )
                }
            } | ConvertTo-Json -Depth 10

            $tempPreAuthFile = [System.IO.Path]::GetTempFileName()
            $preAuthPayload | Out-File -FilePath $tempPreAuthFile -Encoding utf8 -NoNewline
            az rest --method PATCH --url $ENTRA_APP_URL --headers "Content-Type=application/json" --body "@$tempPreAuthFile" | Out-Null
            Remove-Item $tempPreAuthFile -Force
            Write-Info "Azure CLI pre-authorized successfully"
        } else {
            Write-Info "Azure CLI already pre-authorized"
        }
    }
    catch {
        Write-Warn "Failed to configure OAuth2 scope/pre-authorization: $_"
        Write-Warn "You may need to manually add a scope and authorize Azure CLI in the Azure Portal."
        Write-Warn "See: Entra App > Expose an API > Add a scope, then Add a client application"
    }

    # Define the app-role in the Entra App
    Write-Info "Checking for existing app role: $ENTRA_APP_ROLE_VALUE"

    # Check if the role already exists
    $appDetails = az rest --method GET --url $ENTRA_APP_URL | ConvertFrom-Json
    $existingRole = $appDetails.appRoles | Where-Object { $_.value -eq $ENTRA_APP_ROLE_VALUE }

    if (-not $existingRole) {
        Write-Info "Role does not exist, adding app role: $ENTRA_APP_ROLE_VALUE"

        # Prepare the app-roles payload by fetching existing roles, appending a new one
        $existingRoles = $appDetails.appRoles
        $newRole = @{
            allowedMemberTypes = @("User", "Application")
            description = $ENTRA_APP_ROLE_DESC
            displayName = $ENTRA_APP_ROLE_DISPLAY
            id = $ENTRA_APP_ROLE_ID
            isEnabled = $true
            value = $ENTRA_APP_ROLE_VALUE
            origin = "Application"
        }
        
        $updatedRoles = $existingRoles + $newRole
        $rolesPayload = @{ appRoles = $updatedRoles } | ConvertTo-Json -Depth 10

        # Create a temporary file for the body to avoid issues with special characters
        $tempRolesFile = [System.IO.Path]::GetTempFileName()
        $rolesPayload | Out-File -FilePath $tempRolesFile -Encoding utf8 -NoNewline
        
        # PATCH back the updated app-roles
        az rest --method PATCH --url $ENTRA_APP_URL --headers "Content-Type=application/json" --body "@$tempRolesFile" | Out-Null
        
        # Clean up temp file
        Remove-Item $tempRolesFile -Force

        Write-Info "App role added successfully"
        $script:ENTRA_APP_ROLE_ID_BY_VALUE = $ENTRA_APP_ROLE_ID
    }
    else {
        Write-Info "App role '$ENTRA_APP_ROLE_VALUE' already exists, extracting role ID"
        $script:ENTRA_APP_ROLE_ID_BY_VALUE = $existingRole.id
    }

    # Print the app-roles to verify
    $appRoles = az rest --method GET --url $ENTRA_APP_URL --query appRoles | ConvertFrom-Json
    Write-Info "Roles in Entra App:"
    Write-Host ($appRoles | ConvertTo-Json)
    
    # Get the service principal object ID for the Entra App
    Write-Info "Getting Entra App Service Principal Object ID..."
    
    # Helper function to look up SP object ID using multiple methods
    function Get-SpObjectId {
        param([string]$AppId)
        
        $oldEAP = $ErrorActionPreference
        $spId = $null
        
        # Method 1: az ad sp show --id <appId> (fastest)
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $spRaw = az ad sp show --id $AppId --output json 2>$null
            if ($LASTEXITCODE -eq 0 -and $spRaw) {
                $spObj = $spRaw | ConvertFrom-Json
                if ($spObj -and $spObj.id) {
                    $spId = $spObj.id
                }
            }
        } catch { }
        $ErrorActionPreference = $oldEAP
        if ($spId) { return $spId }
        
        # Method 2: az ad sp list --filter (handles replication delays)
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $spList = az ad sp list --filter "appId eq '$AppId'" --query "[0].id" -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and $spList -and $spList -ne "null" -and $spList.Trim() -ne "") {
                $spId = $spList.Trim()
            }
        } catch { }
        $ErrorActionPreference = $oldEAP
        if ($spId) { return $spId }
        
        # Method 3: Graph API direct query (works when az ad sp commands fail)
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $graphUrl = "https://graph.microsoft.com/v1.0/servicePrincipals?\`$filter=appId eq '$AppId'&\`$select=id"
            $graphResult = az rest --method GET --url $graphUrl 2>$null
            if ($LASTEXITCODE -eq 0 -and $graphResult) {
                $graphObj = $graphResult | ConvertFrom-Json
                if ($graphObj -and $graphObj.value -and $graphObj.value.Count -gt 0) {
                    $spId = $graphObj.value[0].id
                }
            }
        } catch { }
        $ErrorActionPreference = $oldEAP
        
        return $spId
    }
    
    # Small delay to allow Entra ID to propagate the app registration
    Start-Sleep -Seconds 3
    
    $ENTRA_APP_SP_OBJECT_ID = Get-SpObjectId -AppId $ENTRA_APP_CLIENT_ID
    
    if (-not $ENTRA_APP_SP_OBJECT_ID) {
        Write-Info "Service Principal not found, creating one..."
        
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $createResult = az ad sp create --id $ENTRA_APP_CLIENT_ID 2>&1
        $createExitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldEAP
        
        if ($createExitCode -ne 0) {
            $createResultStr = $createResult | Out-String
            if ($createResultStr -match "already exists|conflicting object") {
                Write-Info "Service Principal already exists (creation returned conflict). Retrying lookup..."
            } else {
                Write-Warn "az ad sp create returned non-zero exit code."
                Write-Warn "Output: $createResultStr"
                Write-Info "Will retry lookup in case the SP was created despite the error..."
            }
        } else {
            Write-Info "Service Principal created successfully"
            # If creation returned JSON output, try to extract the SP ID directly
            if ($createResult) {
                try {
                    $createObj = ($createResult | Out-String) | ConvertFrom-Json
                    if ($createObj -and $createObj.id) {
                        $ENTRA_APP_SP_OBJECT_ID = $createObj.id
                        Write-Info "Extracted SP Object ID from creation response: $ENTRA_APP_SP_OBJECT_ID"
                    }
                } catch { }
            }
        }
        
        # If we didn't extract the ID from the create response, retry lookup with increasing delays
        if (-not $ENTRA_APP_SP_OBJECT_ID) {
            $retryDelays = @(5, 10, 15)
            foreach ($delay in $retryDelays) {
                Write-Info "Waiting $delay seconds for Service Principal to propagate..."
                Start-Sleep -Seconds $delay
                $ENTRA_APP_SP_OBJECT_ID = Get-SpObjectId -AppId $ENTRA_APP_CLIENT_ID
                if ($ENTRA_APP_SP_OBJECT_ID) {
                    Write-Info "Service Principal found after retry"
                    break
                }
            }
        }
    }
    
    if (-not $ENTRA_APP_SP_OBJECT_ID) {
        Write-Error "Failed to get or create Service Principal for Entra App"
        Write-Error ""
        Write-Error "MANUAL FIX:"
        Write-Error "1. Create the SP manually:  az ad sp create --id $ENTRA_APP_CLIENT_ID"
        Write-Error "2. Get the SP Object ID:    az ad sp show --id $ENTRA_APP_CLIENT_ID --query id -o tsv"
        Write-Error "3. Re-run this script"
        exit 1
    }
    
    Write-Info "Entra App Service Principal Object ID: $ENTRA_APP_SP_OBJECT_ID"

    # Export variables for use in other functions
    $script:ENTRA_APP_CLIENT_ID = $ENTRA_APP_CLIENT_ID
    $script:ENTRA_APP_OBJECT_ID = $ENTRA_APP_OBJECT_ID
    $script:ENTRA_APP_ROLE_VALUE = $ENTRA_APP_ROLE_VALUE
    $script:ENTRA_APP_SP_OBJECT_ID = $ENTRA_APP_SP_OBJECT_ID

    # Ensure current user is an owner of the app
    Write-Info "Ensuring current user is an owner of the Entra App..."
    try {
        $currentUserEmail = az account show --query "user.name" -o tsv
        $currentUserObjectId = $null
        try {
            $currentUserObjectId = az ad user show --id $currentUserEmail --query "id" -o tsv 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $currentUserObjectId = $null
            }
        } catch {
            $currentUserObjectId = $null
        }
        
        if ($currentUserObjectId -and $currentUserObjectId -ne "null") {
            # Check if user is already an owner
            $owners = az ad app owner list --id $ENTRA_APP_CLIENT_ID --query "[].id" -o tsv 2>$null
            
            if ($owners -notcontains $currentUserObjectId) {
                Write-Info "Adding current user as owner of the Entra App..."
                az ad app owner add --id $ENTRA_APP_CLIENT_ID --owner-object-id $currentUserObjectId 2>$null
                Write-Info "User added as owner successfully"
            }
            else {
                Write-Info "Current user is already an owner of the Entra App"
            }
        }
    }
    catch {
        Write-Warn "Could not ensure user is owner of Entra App: $_"
        Write-Warn "This may affect automatic role assignment"
    }

    Write-Info "Entra App registration completed successfully!"
}

function Assign-Current-User-Role {
    Write-Info "Assigning Mcp.Tool.Executor role to current user..."
    
    # Get current user
    $currentUserEmail = az account show --query "user.name" -o tsv
    Write-Info "Current user: $currentUserEmail"
    
    # Get user object ID - try standard method first (suppress errors)
    $userObjectId = $null
    try {
        $userObjectId = (az ad user show --id $currentUserEmail --query "id" -o tsv 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            $userObjectId = $null
        }
    } catch {
        $userObjectId = $null
    }
    
    if (-not $userObjectId -or $userObjectId -eq "null" -or $userObjectId -eq "") {
        Write-Info "Standard user lookup failed, trying Graph API /me endpoint..."
        Write-Info "(This is common for Visual Studio subscriptions, personal accounts, or guest users)"
        
        # Fallback: Use Graph API /me endpoint - works for all account types
        try {
            $meResult = az rest --method GET --url "https://graph.microsoft.com/v1.0/me" 2>&1
            
            if ($LASTEXITCODE -eq 0 -and $meResult) {
                $meData = $meResult | ConvertFrom-Json
                $userObjectId = $meData.id
                $userDisplayName = $meData.displayName
                $userUPN = $meData.userPrincipalName
                
                Write-Info "Found user via Graph API:"
                Write-Info "  Display Name: $userDisplayName"
                Write-Info "  UPN: $userUPN"
                Write-Info "  Object ID: $userObjectId"
            }
            else {
                throw "Graph API /me endpoint failed"
            }
        }
        catch {
            Write-Warn "Could not find user object ID using any method"
            Write-Warn ""
            Write-Warn "This can happen with:"
            Write-Warn "  - Visual Studio subscriptions with Microsoft Accounts"
            Write-Warn "  - Personal Azure subscriptions"
            Write-Warn "  - Limited directory permissions"
            Write-Warn ""
            Write-Warn "MANUAL ROLE ASSIGNMENT REQUIRED:"
            Write-Warn "Run this command to get your Object ID:"
            Write-Warn "  az rest --method GET --url `"https://graph.microsoft.com/v1.0/me`" --query id -o tsv"
            Write-Warn ""
            Write-Warn "Then assign the role manually or see the deployment instructions in README.md."
            return
        }
    }
    else {
        Write-Info "User Object ID: $userObjectId"
    }
    
    # Check if role assignment already exists
    $existingAssignment = az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($script:ENTRA_APP_SP_OBJECT_ID)/appRoleAssignedTo" --query "value[?principalId=='$userObjectId' && appRoleId=='$($script:ENTRA_APP_ROLE_ID_BY_VALUE)']" | ConvertFrom-Json
    
    if ($existingAssignment -and $existingAssignment.Count -gt 0) {
        Write-Info "User already has the Mcp.Tool.Executor role assigned"
        return
    }
    
    # Assign the role
    Write-Info "Assigning role to user..."
    
    $body = @{
        principalId = $userObjectId
        resourceId = $script:ENTRA_APP_SP_OBJECT_ID
        appRoleId = $script:ENTRA_APP_ROLE_ID_BY_VALUE
    } | ConvertTo-Json
    
    try {
        # Create a temporary file for the body to avoid shell escaping issues
        $tempBodyFile = [System.IO.Path]::GetTempFileName()
        $body | Out-File -FilePath $tempBodyFile -Encoding utf8 -NoNewline
        
        $output = az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($script:ENTRA_APP_SP_OBJECT_ID)/appRoleAssignedTo" --headers "Content-Type=application/json" --body "@$tempBodyFile" 2>&1
        
        # Clean up temp file
        Remove-Item $tempBodyFile -Force
        
        # Check if the command succeeded
        if ($LASTEXITCODE -eq 0) {
            Write-Info "Successfully assigned Mcp.Tool.Executor role to $currentUserEmail"
            Write-Info "Note: Sign out and sign in again in the browser for the role to take effect"
        }
        else {
            # Check if it's a permissions error
            if ($output -match "Authorization_RequestDenied|Insufficient privileges") {
                Write-Warn "Insufficient permissions to assign the Entra App role automatically."
                Write-Warn ""
                Write-Warn "REQUIRED ACTION:"
                Write-Warn "1. Ask an Azure AD administrator or application owner to assign you the role"
                Write-Warn "2. They can use this command:"
                Write-Warn "   az ad app permission grant --id $($script:ENTRA_APP_CLIENT_ID) --api 00000003-0000-0000-c000-000000000000 --scope AppRoleAssignment.ReadWrite.All"
                Write-Warn ""
                Write-Warn "OR manually assign the role in Azure Portal:"
                Write-Warn "1. Go to Azure Portal > Enterprise Applications"
                Write-Warn "2. Search for app: $($script:ENTRA_APP_NAME)"
                Write-Warn "3. Go to 'Users and groups'"
                Write-Warn "4. Click 'Add user/group'"
                Write-Warn "5. Select your user ($currentUserEmail) and assign the 'Mcp.Tool.Executor' role"
                Write-Warn ""
                Write-Warn "Deployment will continue, but you won't be able to use the web UI until the role is assigned."
            }
            else {
                throw "Azure CLI command failed: $output"
            }
        }
    }
    catch {
        Write-Error "Failed to assign Mcp.Tool.Executor to the signed-in user: $_"
        Write-Error "The deployment cannot provide MCP access until this role is assigned."
        exit 1
    }
}

function Check-Prerequisites {
    Write-Info "Checking prerequisites (az-cli, ACR build)..."

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Error "Azure CLI is not installed. Please install it from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    }

    Write-Info "Prerequisites satisfied."
}

function Login-Azure {
    Write-Info "Checking az cli login status..."

    try {
        az account show | Out-Null
    }
    catch {
        Write-Info "Not logged in to az-cli. running 'az login'..."
        az login
    }

    $account = az account show -o json | ConvertFrom-Json
    $script:SUBSCRIPTION_ID = $account.id
    $script:SUBSCRIPTION_NAME = $account.name
    $script:TENANT_ID = $account.tenantId

    Write-Info "Using the subscription selected by the current az login:"
    Write-Info "  Subscription: $($script:SUBSCRIPTION_NAME)"
    Write-Info "  Subscription ID: $($script:SUBSCRIPTION_ID)"
    Write-Info "  Tenant ID: $($script:TENANT_ID)"
}

function Verify-Resource-Group {
    Write-Info "Verifying resource group '$($script:RESOURCE_GROUP)' in subscription '$($script:SUBSCRIPTION_NAME)'..."
    
    $rgExists = az group exists --name $script:RESOURCE_GROUP
    if ($rgExists -eq "false") {
        Write-Error "Resource group '$($script:RESOURCE_GROUP)' does not exist in subscription '$($script:SUBSCRIPTION_NAME)' ($($script:SUBSCRIPTION_ID))."
        Write-Error "Create it first, or select the subscription that contains it with 'az account set --subscription <subscription>'."
        exit 1
    }
    
    $resourceGroupDetails = az group show --name $script:RESOURCE_GROUP --query "{name:name,location:location}" -o json | ConvertFrom-Json
    if (-not $resourceGroupDetails -or [string]::IsNullOrWhiteSpace($resourceGroupDetails.location)) {
        Write-Error "Unable to determine the region for resource group '$($script:RESOURCE_GROUP)'."
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($Location)) {
        $script:LOCATION = $resourceGroupDetails.location
        Write-Info "Resource group verified successfully: $($script:RESOURCE_GROUP)"
        Write-Info "Using resource group region: $($script:LOCATION)"
    }
    else {
        $script:LOCATION = $Location
        Write-Info "Resource group verified successfully: $($script:RESOURCE_GROUP)"
        Write-Warn "Using explicit location override '$($script:LOCATION)' instead of resource group region '$($resourceGroupDetails.location)'."
    }

    if ($script:COSMOS_RESOURCE_GROUP -ne $script:RESOURCE_GROUP) {
        Write-Info "Verifying Cosmos resource group exists: $($script:COSMOS_RESOURCE_GROUP)"
        $cosmosRgExists = az group exists --name $script:COSMOS_RESOURCE_GROUP
        if ($cosmosRgExists -eq "false") {
            Write-Error "Cosmos resource group '$($script:COSMOS_RESOURCE_GROUP)' does not exist."
            exit 1
        }
    }

}

function Deploy-Infrastructure {
    Write-Info "Applying Azure Container resources..."
    Write-Info "Existing resources will be reconciled with the Bicep template."

    if ($script:USE_EXISTING_ACR) {
        az deployment group create --resource-group $script:RESOURCE_GROUP --template-file "infrastructure/main.bicep" --parameters "containerAppName=$($script:ContainerAppName)" "cosmosEndpoint=$($script:COSMOS_ENDPOINT)" "azureAiServiceEndpoint=$($script:OPENAI_ENDPOINT)" "embeddingDeploymentName=$($script:EMBEDDING_DEPLOYMENT)" "cosmosSemanticRerankerInferenceEndpoint=$($script:COSMOS_SEMANTIC_RERANKER_INFERENCE_ENDPOINT)" "useExistingAcr=true" "existingAcrName=$($script:ACR_NAME)" "existingAcrResourceGroup=$($script:ACR_RESOURCE_GROUP)" --output table
    }
    else {
        az deployment group create --resource-group $script:RESOURCE_GROUP --template-file "infrastructure/main.bicep" --parameters "containerAppName=$($script:ContainerAppName)" "containerRegistryName=$($script:ACR_NAME)" "cosmosEndpoint=$($script:COSMOS_ENDPOINT)" "azureAiServiceEndpoint=$($script:OPENAI_ENDPOINT)" "embeddingDeploymentName=$($script:EMBEDDING_DEPLOYMENT)" "cosmosSemanticRerankerInferenceEndpoint=$($script:COSMOS_SEMANTIC_RERANKER_INFERENCE_ENDPOINT)" --output table
    }

    $deploymentExitCode = $LASTEXITCODE
    if ($deploymentExitCode -ne 0) {
        $deployedApp = az containerapp show --name $ContainerAppName --resource-group $ResourceGroup 2>$null | ConvertFrom-Json
        if (-not $deployedApp) {
            throw "Azure Container resources deployment failed with exit code $deploymentExitCode and no Container App was created."
        }

        Write-Warn "Infrastructure deployment returned exit code $deploymentExitCode, but the Container App exists. Continuing so permissions and the application image can be applied."
    }

    Write-Info "Azure Container resources deployment completed!"
}

function Get-Deployment-Outputs {
    Write-Info "Getting deployment outputs..."

    # Get ACR and Container App details
    $acrName = $script:ACR_NAME
    if ([string]::IsNullOrWhiteSpace($acrName)) {
        $acrName = az acr list --resource-group $script:ACR_RESOURCE_GROUP --query "[0].name" -o tsv
        $script:ACR_NAME = $acrName
    }
    $containerApp = az containerapp show --name $ContainerAppName --resource-group $ResourceGroup | ConvertFrom-Json
    
    $script:CONTAINER_REGISTRY = "$acrName.azurecr.io"
    $script:CONTAINER_APP_URL = "https://$($containerApp.properties.configuration.ingress.fqdn)"

    Write-Info "Container Registry: $script:CONTAINER_REGISTRY"
    Write-Info "Container App URL: $script:CONTAINER_APP_URL"
}

function Build-And-Push-Image {
    Write-Info "Building and pushing container image with Azure Container Registry..."

    # Extract ACR name from login server
    $ACR_NAME = $script:CONTAINER_REGISTRY -replace '\.azurecr\.io$', ''
    Write-Info "Logging into ACR: $ACR_NAME"

    try {
        # Build remotely in ACR so Docker Desktop is not required locally.
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $IMAGE_TAG = "$($script:CONTAINER_REGISTRY)/mcp-toolkit:$timestamp"

        # Ensure we're in the root directory
        $rootDir = Split-Path -Parent $SCRIPT_DIR
        Push-Location $rootDir
        
        try {
            Write-Info "Building image: $IMAGE_TAG"
            az acr build --registry $ACR_NAME --resource-group $script:ACR_RESOURCE_GROUP --image "mcp-toolkit:$timestamp" --file Dockerfile .
            
            if ($LASTEXITCODE -ne 0) {
                throw "Azure Container Registry build failed with exit code $LASTEXITCODE"
            }

            $script:IMAGE_TAG = $IMAGE_TAG
            Write-Info "Image pushed successfully!"
        }
        finally {
            Pop-Location
        }
    }
    catch {
        Write-Warn "Failed to build or push container image: $_"
        Write-Warn ""
        Write-Warn "TROUBLESHOOTING:"
        Write-Warn "1. Check network connectivity to ACR: az acr check-health -n $ACR_NAME --yes"
        Write-Warn "2. Verify the ACR build service is available: az acr check-health -n $ACR_NAME --yes"
        Write-Warn "3. If behind a proxy, verify Azure CLI connectivity"
        Write-Warn ""
        $script:IMAGE_TAG = $null
        throw "Container image build or push failed. Deployment cannot continue with the existing image."
    }
}

function Update-Container-App {
    Write-Info "Updating Azure Container App with MCP Toolkit image..."

    # Get current tenant ID
    $CURRENT_TENANT_ID = az account show --query "tenantId" --output tsv
    Write-Info "Current Tenant ID: $CURRENT_TENANT_ID"

    # Get the endpoint selected during resource discovery
    $cosmosEndpoint = $script:COSMOS_ENDPOINT
    if ([string]::IsNullOrWhiteSpace($cosmosEndpoint)) {
        $cosmosEndpoint = az cosmosdb show --name $script:CosmosAccountName --resource-group $script:COSMOS_RESOURCE_GROUP --query "documentEndpoint" --output tsv
    }
    Write-Info "Cosmos DB Endpoint: $cosmosEndpoint"
    
    # Get Container App to extract existing environment variables
    $containerApp = az containerapp show --name $ContainerAppName --resource-group $ResourceGroup | ConvertFrom-Json
    
    # Enable system-assigned managed identity if not already enabled
    $identityJustCreated = $false
    if ($containerApp.identity.type -ne "SystemAssigned") {
        Write-Info "Enabling SystemAssigned managed identity on Container App..."
        az containerapp identity assign --name $ContainerAppName --resource-group $ResourceGroup --system-assigned
        Write-Info "SystemAssigned managed identity enabled successfully"
        
        # Wait for the identity to propagate
        Write-Info "Waiting 15 seconds for identity to propagate..."
        Start-Sleep -Seconds 15
        
        # Refresh container app info
        $containerApp = az containerapp show --name $ContainerAppName --resource-group $ResourceGroup | ConvertFrom-Json
        $identityJustCreated = $true
    } else {
        Write-Info "Container App is already using SystemAssigned managed identity"
    }
    
    # Get existing environment variables to extract Azure AI Services endpoint and embedding settings
    $existingEnvVars = $containerApp.properties.template.containers[0].env
    $azureAiServiceEndpoint = $script:OPENAI_ENDPOINT
    $embeddingDeployment = $script:EMBEDDING_DEPLOYMENT
    
    if (-not $azureAiServiceEndpoint) {
        Write-Warn "OPENAI_ENDPOINT not found in existing container app configuration"
        Write-Warn "Please set this manually using: az containerapp update --name $ContainerAppName --resource-group $ResourceGroup --set-env-vars 'OPENAI_ENDPOINT=<your-azure-ai-services-endpoint>'"
    } else {
        Write-Info "Azure AI Services Endpoint: $azureAiServiceEndpoint"
        # Store for validation
        $script:OPENAI_ENDPOINT = $azureAiServiceEndpoint
    }
    
    if (-not $embeddingDeployment) {
        Write-Warn "OPENAI_EMBEDDING_DEPLOYMENT not found in existing container app configuration"
        Write-Warn "Please set this manually using: az containerapp update --name $ContainerAppName --resource-group $ResourceGroup --set-env-vars 'OPENAI_EMBEDDING_DEPLOYMENT=<your-deployment>'"
    } else {
        Write-Info "Embedding Deployment: $embeddingDeployment"
    }

    # Build environment variables list (no AZURE_CLIENT_ID needed for system-assigned identity)
    $envVars = @(
        "AzureAd__ClientId=$script:ENTRA_APP_CLIENT_ID"
        "AzureAd__TenantId=$CURRENT_TENANT_ID"
        "AzureAd__Audience=$script:ENTRA_APP_CLIENT_ID"
        "COSMOS_ENDPOINT=$cosmosEndpoint"
        "ASPNETCORE_ENVIRONMENT=Production"
        "ASPNETCORE_URLS=http://+:8080"
    )
    
    if ($azureAiServiceEndpoint) {
        $envVars += "OPENAI_ENDPOINT=$azureAiServiceEndpoint"
    }
    
    if ($embeddingDeployment) {
        $envVars += "OPENAI_EMBEDDING_DEPLOYMENT=$embeddingDeployment"
    }

    if ($script:COSMOS_SEMANTIC_RERANKER_INFERENCE_ENDPOINT) {
        $envVars += "AZURE_COSMOS_SEMANTIC_RERANKER_INFERENCE_ENDPOINT=$($script:COSMOS_SEMANTIC_RERANKER_INFERENCE_ENDPOINT)"
        $envVars += "COSMOS_SEMANTIC_RERANKING_ENABLED=true"
    }

    if ($script:AIF_PROJECT_RESOURCE_ID) {
        $envVars += "AIF_PROJECT_RESOURCE_ID=$($script:AIF_PROJECT_RESOURCE_ID)"
    }

    # First, ensure ingress is configured correctly for port 8080
    Write-Info "Configuring ingress to use target port 8080..."
    try {
        az containerapp ingress update --name $ContainerAppName --resource-group $ResourceGroup --target-port 8080 | Out-Null
        Write-Info "Ingress updated successfully"
    }
    catch {
        Write-Warn "Failed to update ingress configuration: $_"
    }
    
    # Configure CORS for the Container App
    Write-Info "Configuring CORS to allow all origins..."
    
    # First check if CORS is already configured
    $existingCors = az containerapp ingress cors show --name $ContainerAppName --resource-group $ResourceGroup 2>$null | ConvertFrom-Json
    
    if ($existingCors -and $existingCors.allowedOrigins -contains "*") {
        Write-Info "CORS already configured with allowed origins: $($existingCors.allowedOrigins -join ', ')"
    }
    else {
        try {
            # Wait a moment for the container app to be ready
            Start-Sleep -Seconds 2
            
            $ErrorActionPreference = "Continue"
            az containerapp ingress cors enable --name $ContainerAppName --resource-group $ResourceGroup --allowed-origins "*" --allowed-methods "GET,POST,PUT,DELETE,OPTIONS" --allowed-headers "*" --expose-headers "*" --max-age 3600 --output none 2>&1 | Out-Null
            $ErrorActionPreference = "Stop"
            
            # Verify CORS was configured by checking again
            Start-Sleep -Seconds 1
            $corsConfig = az containerapp ingress cors show --name $ContainerAppName --resource-group $ResourceGroup 2>$null | ConvertFrom-Json
            
            if ($corsConfig -and $corsConfig.allowedOrigins) {
                Write-Info "CORS configured successfully"
                Write-Info "Allowed origins: $($corsConfig.allowedOrigins -join ', ')"
            }
            else {
                Write-Warn "Could not verify CORS configuration. Please check manually in Azure Portal"
                Write-Warn "Run: az containerapp ingress cors show --name $ContainerAppName --resource-group $ResourceGroup"
            }
        }
        catch {
            Write-Warn "Exception during CORS configuration: $_"
            # Check if CORS was configured despite the error
            $corsConfig = az containerapp ingress cors show --name $ContainerAppName --resource-group $ResourceGroup 2>$null | ConvertFrom-Json
            if ($corsConfig -and $corsConfig.allowedOrigins) {
                Write-Info "CORS was configured successfully despite warning"
                Write-Info "Allowed origins: $($corsConfig.allowedOrigins -join ', ')"
            }
            else {
                Write-Warn "You may need to configure CORS manually in Azure Portal"
            }
        }
    }
    
    # ACR access is configured in Bicep with the Container App system identity.
    Write-Info "Verifying ACR managed-identity registry configuration..."
    $acrName = $script:ACR_NAME
    if ([string]::IsNullOrWhiteSpace($acrName)) {
        $acrName = az acr list --resource-group $script:ACR_RESOURCE_GROUP --query "[0].name" -o tsv
        $script:ACR_NAME = $acrName
    }
    $acrLoginServer = az acr show --name $acrName --resource-group $script:ACR_RESOURCE_GROUP --query "loginServer" -o tsv
    Write-Info "ACR Login Server: $acrLoginServer"
    
    # Only update image if a new one was built successfully
    if ($script:IMAGE_TAG) {
        Write-Info "Updating container app with new image: $script:IMAGE_TAG"
        
        try {
            az containerapp update --name $ContainerAppName --resource-group $ResourceGroup --image $script:IMAGE_TAG --set-env-vars $envVars --output none
            
            if ($LASTEXITCODE -ne 0) {
                throw "Container app update failed with exit code $LASTEXITCODE"
            }
            
            Write-Info "Container app updated successfully with new image!"
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Error "Container app update failed: $errorMessage"
            Write-Error "Check the container app logs for more details:"
            Write-Info "az containerapp logs show --name $ContainerAppName --resource-group $ResourceGroup --follow"
            exit 1
        }
    }
    else {
        Write-Warn "Skipping image update (no new image was built)"
        Write-Info "Updating only environment variables..."
        
        try {
            az containerapp update --name $ContainerAppName --resource-group $ResourceGroup --set-env-vars $envVars --output none
            
            if ($LASTEXITCODE -ne 0) {
                throw "Container app update failed with exit code $LASTEXITCODE"
            }
            
            Write-Info "Container app environment variables updated successfully!"
            Write-Info "Note: Container app is still using its existing image"
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Warn "Failed to update environment variables: $errorMessage"
            Write-Warn "Continuing with deployment..."
        }
    }

    $script:CURRENT_TENANT_ID = $CURRENT_TENANT_ID
}

function Configure-Entra-App-RedirectURIs {
    Write-Info "Configuring redirect URIs for Entra App as Single-Page Application..."
    
    # Extract FQDN from Container App URL
    $containerAppFqdn = $script:CONTAINER_APP_URL -replace '^https?://', ''
    
    $redirectUris = @(
        "https://$containerAppFqdn"
        "https://$containerAppFqdn/signin-oidc"
    )
    
    $ENTRA_APP_URL = "https://graph.microsoft.com/v1.0/applications/$($script:ENTRA_APP_OBJECT_ID)"
    
    # Create temporary file for JSON body
    $tempFile = [System.IO.Path]::GetTempFileName()
    
    # Configure as SPA (Single-Page Application) with proper token settings
    # This fixes the "Cross-origin token redemption" error and enables API access tokens
    $body = @{
        spa = @{
            redirectUris = $redirectUris
        }
        web = @{
            implicitGrantSettings = @{
                enableIdTokenIssuance = $true
                enableAccessTokenIssuance = $true
            }
        }
        # Enable the application to request access tokens (not just ID tokens)
        requiredResourceAccess = @(
            @{
                resourceAppId = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
                resourceAccess = @(
                    @{
                        id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"  # User.Read
                        type = "Scope"
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 10
    
    $body | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline
    
    try {
        az rest --method PATCH --url $ENTRA_APP_URL --headers "Content-Type=application/json" --body "@$tempFile" | Out-Null
        Write-Info "Redirect URIs configured successfully as SPA:"
        foreach ($uri in $redirectUris) {
            Write-Info "  - $uri"
        }
        Write-Info "Access token issuance enabled for SPA authentication"
    }
    catch {
        Write-Warn "Failed to configure redirect URIs automatically."
        Write-Warn "Please add these redirect URIs manually in Azure Portal as SPA redirect URIs:"
        foreach ($uri in $redirectUris) {
            Write-Warn "  - $uri"
        }
    }
    finally {
        # Clean up temp file
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force
        }
    }
}

function Assign-ACR-RBAC {
    Write-Info "Assigning AcrPull role to Container App Managed Identity..."

    $acrResourceId = az acr show --name $script:ACR_NAME --resource-group $script:RESOURCE_GROUP --query id -o tsv
    if ([string]::IsNullOrWhiteSpace($acrResourceId)) {
        Write-Error "Unable to find derived ACR '$($script:ACR_NAME)' in resource group '$($script:RESOURCE_GROUP)'."
        exit 1
    }

    $principalId = $script:ACA_MI_PRINCIPAL_ID
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        $principalId = az containerapp show --resource-group $script:RESOURCE_GROUP --name $script:ContainerAppName --query "identity.principalId" -o tsv
    }
    if ([string]::IsNullOrWhiteSpace($principalId) -or $principalId -eq "null") {
        Write-Error "Unable to find the Container App managed identity principal ID."
        exit 1
    }

    $existingAssignment = az role assignment list --assignee-object-id $principalId --scope $acrResourceId --query "[?roleDefinitionName=='AcrPull'].id" -o tsv
    if ([string]::IsNullOrWhiteSpace($existingAssignment)) {
        az role assignment create --role AcrPull --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $acrResourceId --output none
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to assign AcrPull to the Container App managed identity."
            exit 1
        }
        Write-Info "AcrPull assigned successfully to Container App MI."
    }
    else {
        Write-Info "AcrPull assignment already exists for Container App MI."
    }
}

function Assign-Cosmos-RBAC {
    Write-Info "Assigning Cosmos DB permissions to Container App Managed Identity..."

    Write-Info "Getting Container App Managed Identity Principal ID..."
    $ACA_MI_PRINCIPAL_ID = az containerapp show --resource-group $ResourceGroup --name $ContainerAppName --query "identity.principalId" --output tsv
    
    if (-not $ACA_MI_PRINCIPAL_ID -or $ACA_MI_PRINCIPAL_ID -eq "null") {
        Write-Error "Failed to get Container App Managed Identity Principal ID"
        Write-Error "Make sure the Container App has a system-assigned managed identity enabled"
        exit 1
    }
    
    $ACA_MI_DISPLAY_NAME = $ContainerAppName

    Write-Info "Container App MI Principal ID: $ACA_MI_PRINCIPAL_ID"
    
    # Assign Cosmos DB Built-in Data Reader role at Cosmos native data-plane root scope (/)
    # Native Cosmos RBAC scopes are "/", "/dbs/{db}", "/dbs/{db}/colls/{coll}" - not ARM resource IDs.
    Write-Info "Assigning Cosmos DB Data Reader role..."
    $subscriptionId = az account show --query id -o tsv
    $roleDefinitionGuid = "00000000-0000-0000-0000-000000000001"
    $roleDefinitionResourceId = "/subscriptions/$subscriptionId/resourceGroups/$($script:COSMOS_RESOURCE_GROUP)/providers/Microsoft.DocumentDB/databaseAccounts/$($script:CosmosAccountName)/sqlRoleDefinitions/$roleDefinitionGuid"
    $cosmosScope = "/"

    $existingAssignment = az cosmosdb sql role assignment list --account-name $script:CosmosAccountName --resource-group $script:COSMOS_RESOURCE_GROUP --query "[?principalId=='$ACA_MI_PRINCIPAL_ID' && scope=='$cosmosScope' && contains(roleDefinitionId, '$roleDefinitionGuid')]" | ConvertFrom-Json

    if ($existingAssignment.Count -eq 0) {
        az cosmosdb sql role assignment create --account-name $script:CosmosAccountName --resource-group $script:COSMOS_RESOURCE_GROUP --role-definition-id $roleDefinitionResourceId --principal-id $ACA_MI_PRINCIPAL_ID --scope $cosmosScope
        Write-Info "Successfully assigned Cosmos DB Data Reader role to Container App MI at scope '/'"
        Write-Info "Role assignment propagation may take a few minutes."
    } else {
        Write-Info "Cosmos DB Data Reader role assignment already exists at scope '/'"
    }
    
    # Export variables for use in deployment summary
    $script:ACA_MI_PRINCIPAL_ID = $ACA_MI_PRINCIPAL_ID
    $script:ACA_MI_DISPLAY_NAME = $ACA_MI_DISPLAY_NAME

    Write-Info "Assigning Semantic Reranker User role to Container App Managed Identity..."
    $cosmosArmScope = "/subscriptions/$subscriptionId/resourceGroups/$($script:COSMOS_RESOURCE_GROUP)/providers/Microsoft.DocumentDB/databaseAccounts/$($script:CosmosAccountName)"
    $semanticRoleId = "6c74a7c5-4a87-40f9-bb03-61e49aecbc78"
    $semanticAssignment = az role assignment list --assignee-object-id $ACA_MI_PRINCIPAL_ID --scope $cosmosArmScope --query "[?roleDefinitionId=='/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/$semanticRoleId'] | [0].id" -o tsv
    if ([string]::IsNullOrWhiteSpace($semanticAssignment)) {
        az role assignment create --role $semanticRoleId --assignee-object-id $ACA_MI_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $cosmosArmScope --output none
        Write-Info "Semantic Reranker User role assigned successfully."
    }
    else {
        Write-Info "Semantic Reranker User role assignment already exists."
    }
}

function Assign-AI-Foundry-RBAC {
    Write-Info "Assigning Azure AI Services permissions to Container App Managed Identity..."

    if ($script:EMBEDDING_ACCOUNT_ID) {
        Write-Info "Assigning Cognitive Services OpenAI User role to the selected embedding account..."
        $existingRoleAssignment = az role assignment list --assignee $script:ACA_MI_PRINCIPAL_ID --scope $script:EMBEDDING_ACCOUNT_ID --query "[?roleDefinitionName=='Cognitive Services OpenAI User'].id" -o tsv
        if (-not $existingRoleAssignment) {
            az role assignment create --role "Cognitive Services OpenAI User" --assignee-object-id $script:ACA_MI_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $script:EMBEDDING_ACCOUNT_ID
            Write-Info "Successfully assigned embedding account permission to Container App MI"
        }
        else {
            Write-Info "Embedding account permission already exists"
        }
        return
    }

    # Get Container App to extract Azure AI Services endpoint for existing deployments
    $containerApp = az containerapp show --name $ContainerAppName --resource-group $ResourceGroup | ConvertFrom-Json
    $existingEnvVars = $containerApp.properties.template.containers[0].env
    $azureAiServiceEndpoint = ($existingEnvVars | Where-Object { $_.name -eq "OPENAI_ENDPOINT" }).value
    
    if (-not $azureAiServiceEndpoint) {
        Write-Warn "OPENAI_ENDPOINT not configured. Skipping Azure AI Services RBAC assignment."
        return
    }
    
    Write-Info "Azure AI Services Endpoint: $azureAiServiceEndpoint"
    
    # Search for Cognitive Services accounts in the resource group
    Write-Info "Searching for Azure AI Services (Cognitive Services) resources in resource group..."
    $cognitiveAccounts = az cognitiveservices account list --resource-group $ResourceGroup | ConvertFrom-Json
    
    if (-not $cognitiveAccounts -or $cognitiveAccounts.Count -eq 0) {
        Write-Warn "No Cognitive Services accounts found in resource group: $ResourceGroup"
        Write-Warn "Please manually assign 'Cognitive Services OpenAI User' role to managed identity:"
        Write-Warn "  Principal ID: $($script:ACA_MI_PRINCIPAL_ID)"
        return
    }
    
    # Match endpoint to Cognitive Services account
    $matchingAccount = $null
    
    if ($azureAiServiceEndpoint -match "\.services\.ai\.azure\.com") {
        Write-Warn "ERROR: The endpoint appears to be a Microsoft Foundry project URL."
        Write-Warn "Please use the Azure AI Services account endpoint instead."
        Write-Warn "How to get the correct endpoint:"
        Write-Warn "  1. Go to Azure Portal > Cognitive Services / AI Services resource"
        Write-Warn "  2. Copy the endpoint URL from the resource's Overview page"
        Write-Warn "  3. It should look like: https://<resource-name>.cognitiveservices.azure.com/"
        return
    }
    
    if ($azureAiServiceEndpoint -match "\.cognitiveservices\.azure\.com") {
        Write-Info "Detected Azure AI Services (Cognitive Services) endpoint"
        
        # Try to find the matching Cognitive Services account
        # Prefer accounts with "openai" in the endpoint or kind
        foreach ($account in $cognitiveAccounts) {
            if ($account.kind -eq "OpenAI" -or $account.properties.endpoint -match "openai\.cognitiveservices\.azure\.com") {
                $matchingAccount = $account
                Write-Info "Found OpenAI account for Microsoft Foundry project: $($account.name)"
                break
            }
        }
        
        # If no OpenAI account found, use the first Cognitive Services account
        if (-not $matchingAccount -and $cognitiveAccounts.Count -gt 0) {
            $matchingAccount = $cognitiveAccounts[0]
            Write-Info "Using Cognitive Services account: $($matchingAccount.name)"
        }
    }
    else {
        # Direct endpoint match for Azure AI Services
        $endpointHost = ([System.Uri]$azureAiServiceEndpoint).Host
        foreach ($account in $cognitiveAccounts) {
            $accountEndpoint = $account.properties.endpoint
            if ($accountEndpoint -and ($accountEndpoint.Contains($endpointHost) -or $endpointHost.Contains($account.name))) {
                $matchingAccount = $account
                break
            }
        }
    }
    
    if (-not $matchingAccount) {
        Write-Warn "Could not automatically determine which Cognitive Services account to use"
        Write-Warn "Found these Cognitive Services accounts in resource group:"
        foreach ($account in $cognitiveAccounts) {
            Write-Warn "  - $($account.name): $($account.properties.endpoint) (Kind: $($account.kind))"
        }
        Write-Warn ""
        Write-Warn "Attempting to assign 'Cognitive Services OpenAI User' role to all OpenAI accounts..."
        
        # Try to assign to all OpenAI accounts
        $assigned = $false
        foreach ($account in $cognitiveAccounts) {
            if ($account.kind -eq "OpenAI") {
                Write-Info "Assigning role to OpenAI account: $($account.name)"
                $existingRoleAssignment = az role assignment list --assignee $script:ACA_MI_PRINCIPAL_ID --scope $account.id --query "[?roleDefinitionName=='Cognitive Services OpenAI User'].id" -o tsv
                
                if (-not $existingRoleAssignment) {
                    az role assignment create --role "Cognitive Services OpenAI User" --assignee-object-id $script:ACA_MI_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $account.id
                    Write-Info "Successfully assigned role to $($account.name)"
                    $assigned = $true
                }
                else {
                    Write-Info "Role already assigned to $($account.name)"
                    $assigned = $true
                }
            }
        }
        
        if (-not $assigned) {
            Write-Warn "No OpenAI accounts found. Please manually assign the role."
        }
        return
    }
    
    $resourceId = $matchingAccount.id
    $resourceName = $matchingAccount.name
    Write-Info "Target Cognitive Services account: $resourceName"
    
    # Check if role assignment already exists
    $existingRoleAssignment = az role assignment list --assignee $script:ACA_MI_PRINCIPAL_ID --scope $resourceId --query "[?roleDefinitionName=='Cognitive Services OpenAI User'].id" -o tsv
    
    if ($existingRoleAssignment) {
        Write-Info "'Cognitive Services OpenAI User' role already assigned to Container App MI"
    } else {
        Write-Info "Assigning 'Cognitive Services OpenAI User' role..."
        az role assignment create --role "Cognitive Services OpenAI User" --assignee-object-id $script:ACA_MI_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $resourceId
        Write-Info "Successfully assigned 'Cognitive Services OpenAI User' role to Container App MI"
    }
}

function Show-Container-Logs {
    Write-Info "Waiting 10 seconds for Azure Container App to initialize then fetching logs..."
    Start-Sleep 10

    Write-Host ""
    Write-Info "Azure Container App logs (hosting 'Azure Cosmos DB MCP Toolkit'):"
    Write-Host "Begin_Azure_Container_App_Logs ---->"
    
    try {
        az containerapp logs show --name $ContainerAppName --resource-group $ResourceGroup --tail 50 --output table
        Write-Host "<---- End_Azure_Container_App_Logs"
        Write-Host ""
    }
    catch {
        Write-Warn "Could not retrieve logs. The Azure Container App might still be starting up, use the following command to check logs later."
        Write-Info "az containerapp logs show --name $ContainerAppName --resource-group $ResourceGroup --tail 50"
    }
}

function Test-MCP-Server-Health {
    Write-Info "Verifying MCP server deployment and health..."
    Write-Info "Note: Initial container startup can take 1-3 minutes..."
    
    # First check if the revision is provisioned
    Write-Info "Checking container app revision status..."
    $revision = az containerapp revision list --name $ContainerAppName --resource-group $ResourceGroup --query "[0]" | ConvertFrom-Json
    if ($revision.properties.provisioningState -ne "Provisioned") {
        Write-Warn "Container revision is not yet provisioned. Current state: $($revision.properties.provisioningState)"
        Write-Info "Waiting 30 seconds for revision to provision..."
        Start-Sleep -Seconds 30
    }
    
    $maxRetries = 18  # 3 minutes total (10 seconds * 18)
    $retryDelay = 10
    
    for ($i = 1; $i -le $maxRetries; $i++) {
        Write-Info "Health check attempt $i of $maxRetries..."
        
        try {
            # Probe the anonymous health endpoint directly so a missing root route cannot mask app health.
            $healthResponse = Invoke-WebRequest -Uri "$($script:CONTAINER_APP_URL)/health" -UseBasicParsing -TimeoutSec 30
            Write-Info "[OK] Health endpoint responding: $($healthResponse.StatusCode)"
            Write-Info "[OK] MCP server is responding!"
            
            # Test MCP protocol endpoint
            try {
                $mcpResponse = Invoke-WebRequest -Uri "$($script:CONTAINER_APP_URL)/mcp" -UseBasicParsing -TimeoutSec 10
                Write-Info "[OK] MCP protocol endpoint responding: $($mcpResponse.StatusCode)"
            }
            catch {
                Write-Info "[INFO] MCP endpoint returned: $($_.Exception.Message)"
            }
            
            Write-Info "[SUCCESS] MCP server verification completed successfully!"
            return $true
        }
        catch {
            Write-Info "[RETRY] Attempt $i failed: $($_.Exception.Message)"
            if ($i -eq $maxRetries) {
                Write-Error "[FAILED] MCP server failed to respond after $maxRetries attempts"
                Write-Error "This might indicate a configuration issue or the application needs more time to start"
                return $false
            }
            Write-Info "Waiting $retryDelay seconds before next attempt..."
            Start-Sleep -Seconds $retryDelay
        }
    }
}

function Test-MCP-Cosmos-Query {
    Write-Info "Testing authenticated Cosmos DB query through the public MCP endpoint..."

    if ([string]::IsNullOrWhiteSpace($script:CONTAINER_APP_URL) -or
        [string]::IsNullOrWhiteSpace($script:ENTRA_APP_CLIENT_ID)) {
        Write-Error "Container App URL or Entra app client ID is unavailable for the MCP query test."
        return $false
    }

    try {
        $accessToken = (az account get-access-token --resource $script:ENTRA_APP_CLIENT_ID --query accessToken -o tsv 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
            throw "Azure CLI could not acquire an access token for the MCP API."
        }

        $requestBody = @{
            jsonrpc = "2.0"
            id = "deployment-cosmos-query"
            method = "tools/call"
            params = @{
                name = "list_databases"
                arguments = @{}
            }
        } | ConvertTo-Json -Depth 10

        $response = Invoke-WebRequest `
            -Uri "$($script:CONTAINER_APP_URL)/mcp/http" `
            -Method Post `
            -Headers @{ Authorization = "Bearer $accessToken" } `
            -ContentType "application/json" `
            -Body $requestBody `
            -UseBasicParsing `
            -TimeoutSec 60

        if ($response.StatusCode -ne 200) {
            throw "MCP endpoint returned HTTP $($response.StatusCode)."
        }

        $mcpResponse = $response.Content | ConvertFrom-Json
        if ($null -eq $mcpResponse.result -or $null -ne $mcpResponse.error) {
            $errorMessage = if ($mcpResponse.error.message) { $mcpResponse.error.message } else { "missing MCP result" }
            throw "MCP query failed: $errorMessage"
        }

        Write-Info "[OK] Authenticated MCP Cosmos query completed successfully."
        return $true
    }
    catch {
        Write-Error "[FAILED] Authenticated MCP Cosmos query failed: $($_.Exception.Message)"
        Write-Error "Verify the signed-in user has the Mcp.Tool.Executor app role and the Container App identity has Cosmos DB data-plane access."
        return $false
    }
}

function Verify-Container-App-Status {
    Write-Info "Checking Container App revision status..."
    
    # Check revision status
    $revision = az containerapp revision list --name $ContainerAppName --resource-group $ResourceGroup --query "[0]" | ConvertFrom-Json
    
    Write-Info "Revision Status:"
    Write-Info "  - Name: $($revision.name)"
    Write-Info "  - Provisioning: $($revision.properties.provisioningState)"
    Write-Info "  - Health: $($revision.properties.healthState)"
    Write-Info "  - Active: $($revision.properties.active)"
    Write-Info "  - Replicas: $($revision.properties.replicas)"
    
    if ($revision.properties.provisioningState -ne "Provisioned") {
        Write-Warning "[WARN] Container App revision is not fully provisioned: $($revision.properties.provisioningState)"
        
        # Try to restart if failed
        if ($revision.properties.provisioningState -eq "Failed") {
            Write-Info "Attempting to restart failed revision..."
            az containerapp revision restart --name $ContainerAppName --resource-group $ResourceGroup --revision $revision.name
            Write-Info "Waiting 30 seconds for restart to complete..."
            Start-Sleep -Seconds 30
        }
    }
    
    if ($revision.properties.healthState -eq "Unhealthy") {
        Write-Warning "[WARN] Container App health check is failing - this may be normal for MCP servers without health endpoints"
    }
    
    return $revision.properties.provisioningState -eq "Provisioned"
}

function Show-Deployment-Summary {
    # Validate Azure AI Services endpoint before final deployment
    Validate-AzureAiServicesEndpoint
    
    Write-Info "Deployment Summary (JSON):"
    
    # Create JSON summary (following PostgreSQL pattern exactly)
    $SUMMARY = @{
        MCP_SERVER_URI = $script:CONTAINER_APP_URL
        ENTRA_APP_CLIENT_ID = $script:ENTRA_APP_CLIENT_ID
        ENTRA_APP_OBJECT_ID = $script:ENTRA_APP_OBJECT_ID
        ENTRA_APP_SP_OBJECT_ID = $script:ENTRA_APP_SP_OBJECT_ID
        ENTRA_APP_DISPLAY_NAME = $ENTRA_APP_NAME
        ENTRA_APP_ROLE_VALUE = $script:ENTRA_APP_ROLE_VALUE
        ENTRA_APP_ROLE_ID_BY_VALUE = $script:ENTRA_APP_ROLE_ID_BY_VALUE
        ACA_MI_PRINCIPAL_ID = $script:ACA_MI_PRINCIPAL_ID
        ACA_MI_DISPLAY_NAME = $script:ACA_MI_DISPLAY_NAME
        RESOURCE_GROUP = $ResourceGroup
        COSMOS_RESOURCE_GROUP = $script:COSMOS_RESOURCE_GROUP
        ACR_RESOURCE_GROUP = $script:ACR_RESOURCE_GROUP
        ACR_NAME = $script:ACR_NAME
        SUBSCRIPTION_ID = (az account show --query id -o tsv)
        TENANT_ID = (az account show --query tenantId -o tsv)
        COSMOS_ACCOUNT_NAME = $script:CosmosAccountName
        LOCATION = $script:LOCATION
    }
    
    $SUMMARY_JSON = $SUMMARY | ConvertTo-Json
    Write-Host $SUMMARY_JSON
    
    $DEPLOYMENT_INFO_FILE = "$SCRIPT_DIR/deployment-info.json"
    $SUMMARY_JSON | Out-File -FilePath $DEPLOYMENT_INFO_FILE -Encoding UTF8
    Write-Info "Deployment information written to: $DEPLOYMENT_INFO_FILE"
}

function Update-Frontend-Config {
    Write-Info "Updating frontend configuration with deployment URLs..."
    
    # Build path incrementally for compatibility
    $projectRoot = Split-Path -Parent $SCRIPT_DIR
    $srcPath = Join-Path $projectRoot "src"
    $projectPath = Join-Path $srcPath "AzureCosmosDB.MCP.Toolkit"
    $wwwrootPath = Join-Path $projectPath "wwwroot"
    $htmlPath = Join-Path $wwwrootPath "index.html"
    
    if (-not (Test-Path $htmlPath)) {
        Write-Warn "Frontend HTML file not found at: $htmlPath"
        return
    }
    
    try {
        $htmlContent = Get-Content $htmlPath -Raw
        
        # Update the serverUrl input default value
        $htmlContent = $htmlContent -replace 'value="https://[^"]*azurecontainerapps\.io"', "value=`"$($script:CONTAINER_APP_URL)`""
        
        # Save the updated HTML
        $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8 -NoNewline
        
        Write-Info "Updated frontend default Server URL to: $($script:CONTAINER_APP_URL)"
    }
    catch {
        Write-Warn "Failed to update frontend configuration: $_"
    }
}

# Main function (following PostgreSQL pattern)
function Validate-AzureAiServicesEndpoint {
    # Validate OPENAI_ENDPOINT format. The application supports three types:
    # 1. Azure AI Services (Cognitive Services): https://<resource>.cognitiveservices.azure.com/
    # 2. OpenAI Native API: https://api.openai.com/v1
    # 3. Azure AI Foundry: https://<resource>.services.ai.azure.com/api/projects/<project-name>
    if (-not $script:OPENAI_ENDPOINT) {
        return  # No endpoint configured yet is OK
    }
    
    # If endpoint is .services.ai.azure.com, it MUST be a valid Foundry project endpoint with /api/projects/
    if ($script:OPENAI_ENDPOINT -match "\.services\.ai\.azure\.com") {
        if ($script:OPENAI_ENDPOINT -notmatch "/api/projects/") {
            Write-Error @"
ERROR: Invalid Azure AI Foundry endpoint format

The OPENAI_ENDPOINT contains '.services.ai.azure.com' but is not a valid Azure AI Foundry project endpoint.

CORRECT FORMAT (Azure AI Foundry):
  https://<resource>.services.ai.azure.com/api/projects/<project-name>

INCORRECT FORMATS:
  https://<resource>.services.ai.azure.com/
  https://<resource>.services.ai.azure.com/api/projects/

TO FIX:
  1. Go to Azure Portal > AI Foundry project
  2. Copy the full project endpoint URL (must include /api/projects/<project-name>)
  3. Update OPENAI_ENDPOINT to the complete Foundry project endpoint

ALTERNATIVE (Azure AI Services / Cognitive Services):
  https://<resource>.cognitiveservices.azure.com/

For more information, see: https://aka.ms/foundry-endpoints
"@
            exit 1
        }
        # Valid Foundry endpoint, proceed
        Write-Info "Validated Azure AI Foundry endpoint: $script:OPENAI_ENDPOINT"
    }
}

function Main {
    param($Arguments)
    
    Write-Info "Starting Azure Container Apps deployment..."

    Parse-Arguments
    Check-Prerequisites
    Login-Azure
    Verify-Resource-Group
    Auto-Detect-Resources
    Create-Entra-App
    Assign-Current-User-Role
    Deploy-Infrastructure
    Get-Deployment-Outputs
    Assign-ACR-RBAC
    Update-Frontend-Config  # Must run BEFORE Build-And-Push-Image so HTML is updated before build
    Build-And-Push-Image
    Update-Container-App
    Configure-Entra-App-RedirectURIs
    Assign-Cosmos-RBAC
    Assign-AI-Foundry-RBAC
    Show-Container-Logs

    Write-Info "Deployment completed!"
    
    # Verify deployment health
    Write-Info "`n" + "="*80
    Write-Info "DEPLOYMENT VERIFICATION"
    Write-Info "="*80
    
    $containerHealthy = Verify-Container-App-Status
    if (-not $containerHealthy) {
        Write-Warning "Container App verification had issues, but continuing with MCP server testing..."
    }
    
    $mcpHealthy = Test-MCP-Server-Health
    if (-not $mcpHealthy) {
        Write-Warning "MCP server health verification failed - please check the container logs for more details"
        $logCommand = "az containerapp logs show --name $ContainerAppName --resource-group $ResourceGroup --follow"
        Write-Info "You can check logs with: $logCommand"
    }
    
    Show-Deployment-Summary

    $cosmosQueryHealthy = Test-MCP-Cosmos-Query
    if (-not $cosmosQueryHealthy) {
        Write-Error "Deployment verification failed: the authenticated MCP Cosmos query did not complete."
        exit 1
    }
    
    # Final instructions
    Write-Info "`n" + "="*80
    Write-Info "IMPORTANT: AUTHENTICATION SETUP"
    Write-Info "="*80
    Write-Info "The Mcp.Tool.Executor role has been assigned to your user."
    Write-Info ""
    Write-Info "To use the frontend, you MUST:"
    Write-Info "  1. Sign out completely in the browser if already logged in"
    Write-Info "  2. Clear browser cache or use incognito/private window"
    Write-Info "  3. Sign in again to get a fresh token with the role claim"
    Write-Info ""
    Write-Info "Access the MCP Toolkit at:"
    Write-Info "  $($script:CONTAINER_APP_URL)"
    Write-Info ""
    Write-Info "After signing in, check the 'Roles' field shows: Mcp.Tool.Executor"
    Write-Info "="*80
}

# Run main function
Main $args
