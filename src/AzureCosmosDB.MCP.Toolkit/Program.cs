// Program.cs
using ModelContextProtocol.Server;
using System.ComponentModel;
using Microsoft.Azure.Cosmos;
using System.Text.Json;
using Azure.Identity;
using System.Text.RegularExpressions;
using Azure.AI.OpenAI;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;
using System.Text;
using System.Collections.Concurrent;
using AzureCosmosDB.MCP.Toolkit.Services;

var builder = WebApplication.CreateBuilder(args);

// Add controllers
builder.Services.AddControllers();

// Disable default claim mapping for cleaner token handling
JwtSecurityTokenHandler.DefaultMapInboundClaims = false;

// Configure for container environment
builder.WebHost.ConfigureKestrel(options =>
{
    // Container Apps expects port 8080
    options.ListenAnyIP(8080);
});

// Get Azure AD configuration from appsettings
var azureAd = builder.Configuration.GetSection("AzureAd");
var tenantId = azureAd["TenantId"];
var clientId = azureAd["ClientId"];
var audienceConfig = azureAd["Audience"];
var isDevelopment = builder.Environment.IsDevelopment();

// Check if authentication should be bypassed for development
var devBypassAuth = isDevelopment && (Environment.GetEnvironmentVariable("DEV_BYPASS_AUTH") == "true" ||
                   builder.Configuration.GetValue<bool>("DevelopmentMode:BypassAuthentication"));

if (!isDevelopment && (string.IsNullOrEmpty(tenantId) || string.IsNullOrEmpty(clientId)))
{
    throw new InvalidOperationException("AzureAd:TenantId and AzureAd:ClientId must be configured outside Development.");
}

if (!devBypassAuth && !string.IsNullOrEmpty(tenantId) && !string.IsNullOrEmpty(clientId))
{
    // Build list of valid audiences
    var validAudiences = new List<string> { clientId, $"api://{clientId}" };
    
    // Add audiences from configuration (supports comma-separated values)
    if (!string.IsNullOrEmpty(audienceConfig))
    {
        var configuredAudiences = audienceConfig.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (var aud in configuredAudiences)
        {
            if (!validAudiences.Contains(aud))
            {
                validAudiences.Add(aud);
            }
        }
    }
    
    // Add JWT Bearer authentication only if configuration is available
    builder.Services
        .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddJwtBearer(options =>
        {
            options.Authority = $"https://login.microsoftonline.com/{tenantId}/v2.0";

            options.TokenValidationParameters = new TokenValidationParameters
            {
                // Multi-tenant support: Accept tokens from any Azure AD tenant
                ValidateIssuer = true,
                // Accept both v1.0 and v2.0 tokens from any tenant
                IssuerValidator = (issuer, securityToken, validationParameters) =>
                {
                    // Accept issuers matching either pattern from any tenant:
                    // v2.0: https://login.microsoftonline.com/{tenantId}/v2.0
                    // v1.0: https://sts.windows.net/{tenantId}/
                    if (issuer.StartsWith("https://login.microsoftonline.com/") && issuer.EndsWith("/v2.0") ||
                        issuer.StartsWith("https://sts.windows.net/") && issuer.EndsWith("/"))
                    {
                        return issuer;
                    }
                    throw new SecurityTokenInvalidIssuerException($"Invalid issuer: {issuer}");
                },

                ValidateAudience = true,
                ValidAudiences = validAudiences,

                ValidateLifetime = true,
                ValidateIssuerSigningKey = true,
                ClockSkew = TimeSpan.FromMinutes(2),
                RoleClaimType = "roles",
            };

            options.MapInboundClaims = false;
            options.RefreshOnIssuerKeyNotFound = true;

            // Add detailed logging for authentication events
            options.Events = new JwtBearerEvents
            {
                OnMessageReceived = context =>
                {
                    var logger = context.HttpContext.RequestServices.GetRequiredService<ILogger<Program>>();
                    
                    // Check query parameter first (Container Apps doesn't strip this)
                    if (string.IsNullOrEmpty(context.Token))
                    {
                        var accessToken = context.Request.Query["access_token"].FirstOrDefault();
                        if (!string.IsNullOrEmpty(accessToken))
                        {
                            context.Token = accessToken;
                            logger.LogInformation("Token retrieved from query parameter");
                        }
                    }
                    
                    // Workaround: Azure Container Apps ingress may strip Authorization header
                    // Check for custom header as fallback
                    if (string.IsNullOrEmpty(context.Token))
                    {
                        // Try multiple header names since Azure Container Apps may strip some
                        if (context.Request.Headers.TryGetValue("X-MS-TOKEN-AAD-ACCESS-TOKEN", out var tokenValue))
                        {
                            context.Token = tokenValue;
                            logger.LogInformation("Token retrieved from X-MS-TOKEN-AAD-ACCESS-TOKEN header");
                        }
                        else if (context.Request.Headers.TryGetValue("X-Access-Token", out var customTokenValue))
                        {
                            context.Token = customTokenValue;
                            logger.LogInformation("Token retrieved from X-Access-Token header");
                        }
                        else if (context.Request.Headers.TryGetValue("X-Auth-Token", out var authTokenValue))
                        {
                            context.Token = authTokenValue;
                            logger.LogInformation("Token retrieved from X-Auth-Token header");
                        }
                    }
                    
                    var hasAuth = context.Request.Headers.ContainsKey("Authorization");
                    var hasCustom = context.Request.Headers.ContainsKey("X-MS-TOKEN-AAD-ACCESS-TOKEN");
                    var hasQuery = !string.IsNullOrEmpty(context.Request.Query["access_token"].FirstOrDefault());
                    logger.LogInformation("Message received. Has Authorization header: {HasAuth}, Has X-MS-TOKEN-AAD-ACCESS-TOKEN: {HasCustom}, Has Query Token: {HasQuery}", hasAuth, hasCustom, hasQuery);
                    
                    return Task.CompletedTask;
                },
                OnAuthenticationFailed = context =>
                {
                    var logger = context.HttpContext.RequestServices.GetRequiredService<ILogger<Program>>();
                    logger.LogError("Authentication failed: {Error}", context.Exception.Message);
                    logger.LogError("Exception details: {Details}", context.Exception.ToString());
                    return Task.CompletedTask;
                },
                OnTokenValidated = context =>
                {
                    var logger = context.HttpContext.RequestServices.GetRequiredService<ILogger<Program>>();
                    logger.LogInformation("Token validated successfully for user: {User}", context.Principal?.Identity?.Name ?? "Unknown");
                    logger.LogInformation(
                        "Validated token identity: oid={ObjectId}, appid={AppId}, azp={AuthorizedParty}, roles={Roles}, scopes={Scopes}",
                        context.Principal?.FindFirst("oid")?.Value ?? "none",
                        context.Principal?.FindFirst("appid")?.Value ?? "none",
                        context.Principal?.FindFirst("azp")?.Value ?? "none",
                        string.Join(",", context.Principal?.FindAll("roles").Select(claim => claim.Value) ?? Enumerable.Empty<string>()),
                        string.Join(",", context.Principal?.FindAll("scp").Select(claim => claim.Value) ?? Enumerable.Empty<string>()));
                    return Task.CompletedTask;
                },
                OnChallenge = context =>
                {
                    var logger = context.HttpContext.RequestServices.GetRequiredService<ILogger<Program>>();
                    logger.LogWarning("Authentication challenge: {Error}, {ErrorDescription}", context.Error, context.ErrorDescription);
                    
                    // Log ALL headers to debug
                    logger.LogWarning("All request headers:");
                    foreach (var header in context.Request.Headers)
                    {
                        logger.LogWarning("  {Key}: {Value}", header.Key, header.Value);
                    }
                    return Task.CompletedTask;
                }
            };
        });

    var trustedPrincipalIds = builder.Configuration["AzureAd:TrustedPrincipalObjectIds"]?
        .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .ToHashSet(StringComparer.OrdinalIgnoreCase) ?? new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    // Foundry project-managed-identity tokens may omit app-role claims. Keep the role requirement
    // for normal callers, with an explicit object-id allow-list for the configured Foundry identity.
    builder.Services.AddAuthorization(options =>
    {
        options.AddPolicy("McpToolExecutor", policy => policy.RequireAssertion(context =>
            context.User.IsInRole("Mcp.Tool.Executor") ||
            trustedPrincipalIds.Contains(context.User.FindFirst("oid")?.Value ?? string.Empty)));

        options.DefaultPolicy = new AuthorizationPolicyBuilder()
            .RequireAuthenticatedUser()
            .Build();
    });
}
else
{
    // Development mode - bypass authentication
    builder.Services.AddAuthorization(options =>
    {
        options.AddPolicy("McpToolExecutor", policy => policy.RequireAssertion(_ => true));
        options.DefaultPolicy = new AuthorizationPolicyBuilder()
            .RequireAssertion(_ => true)
            .Build();
    });
}

// Add HTTP context accessor for authentication
builder.Services.AddHttpContextAccessor();

// Add CORS for external MCP access
builder.Services.AddCors(options =>
{
    options.AddPolicy("MCPPolicy", policy =>
    {
        policy.AllowAnyOrigin()
              .AllowAnyMethod()
              .AllowAnyHeader()
              .WithExposedHeaders("Cross-Origin-Opener-Policy", "Cross-Origin-Embedder-Policy");
    });
});

// Add health checks for Azure Container Apps
builder.Services.AddHealthChecks();

// Register Cosmos DB Client as a singleton for dependency injection
builder.Services.AddSingleton(sp =>
{
    var logger = sp.GetRequiredService<ILogger<Program>>();
    var configuration = sp.GetRequiredService<IConfiguration>();
    
    return CosmosClientFactory.CreateCosmosClient(configuration, logger);
});

// Register services for dependency injection
builder.Services.AddScoped<AzureCosmosDB.MCP.Toolkit.Services.CosmosDbToolsService>();
builder.Services.AddScoped<AzureCosmosDB.MCP.Toolkit.Services.AuthenticationService>();
builder.Services.AddSingleton<AzureCosmosDB.MCP.Toolkit.Services.McpToolRequestValidator>();

// Register MCP server with SDK transport (SSE + Streamable HTTP) for AI Foundry and other MCP clients.
// Tools are defined below using [McpServerTool] attributes on CosmosDbMcpTools class.
builder.Services.AddMcpServer()
    .WithHttpTransport()
    .WithToolsFromAssembly();

// Configure forwarded headers for proxy scenarios
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();
});

var app = builder.Build();

// Store configuration in static state for access by static tool methods
AppState.Configuration = builder.Configuration;

// Add security headers middleware to allow MSAL authentication
app.Use(async (context, next) =>
{
    // Fix COOP policy to allow MSAL popup authentication
    context.Response.Headers["Cross-Origin-Opener-Policy"] = "unsafe-none";
    context.Response.Headers["Cross-Origin-Embedder-Policy"] = "unsafe-none";
    
    await next();
});

// Add request logging middleware with User-Agent tracking
app.Use(async (context, next) =>
{
    var logger = context.RequestServices.GetRequiredService<ILogger<Program>>();
    var path = context.Request.Path.Value ?? "";
    var method = context.Request.Method;
    var rawUserAgent = context.Request.Headers["User-Agent"].ToString();
    var userAgent = Program.NormalizeUserAgentForTelemetry(
        rawUserAgent,
        out var userAgentOriginalLength,
        out var userAgentWasTruncated,
        out var userAgentControlCharsRemoved);
    var clientIp = context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
    
    // Log a normalized, bounded User-Agent value to reduce telemetry/dashboard abuse risk.
    logger.LogInformation(
        "Request: {Method} {Path} | User-Agent: {UserAgent} | UA-Original-Length: {UserAgentOriginalLength} | UA-Truncated: {UserAgentWasTruncated} | UA-ControlChars-Removed: {UserAgentControlCharsRemoved} | Client-IP: {ClientIp}", 
        method, path, userAgent, userAgentOriginalLength, userAgentWasTruncated, userAgentControlCharsRemoved, clientIp);
    
    // Detailed logging for MCP endpoints
    if (path.StartsWith("/mcp", StringComparison.OrdinalIgnoreCase))
    {
        logger.LogInformation("=== MCP REQUEST DETAILS ===");
        logger.LogInformation("Method: {Method}, Path: {Path}", method, path);
        logger.LogInformation("User-Agent: {UserAgent}", userAgent);
        logger.LogInformation("Client-IP: {ClientIp}", clientIp);
        
        // Log other relevant headers (excluding sensitive data)
        if (context.Request.Headers.ContainsKey("Content-Type"))
            logger.LogInformation("Content-Type: {ContentType}", context.Request.Headers["Content-Type"].ToString());
        if (context.Request.Headers.ContainsKey("Accept"))
            logger.LogInformation("Accept: {Accept}", context.Request.Headers["Accept"].ToString());
        if (context.Request.Headers.ContainsKey("Referer"))
            logger.LogInformation("Referer: {Referer}", context.Request.Headers["Referer"].ToString());
        
        logger.LogInformation("=== END MCP REQUEST ===");
    }
    
    await next();
});

// Configure forwarded headers
app.UseForwardedHeaders();

// Add health check endpoint for container orchestrators
app.MapHealthChecks("/health");

// Enable CORS
app.UseCors("MCPPolicy");

// Configure static files with more explicit options
app.UseDefaultFiles(); // This will serve index.html as default
app.UseStaticFiles();

// Add routing first
app.UseRouting();

// Then authentication and authorization middleware (MUST be after UseRouting and before MapControllers)
app.UseAuthentication();
app.UseAuthorization();

// Development mode logging
if (isDevelopment || devBypassAuth)
{
    app.Logger.LogInformation("Running in development mode with authentication bypass");
}

// Map controllers last
app.MapControllers();

// Map MCP SDK endpoint at /mcp — provides SSE transport (GET /mcp) and Streamable HTTP (POST /mcp).
// This is what AI Foundry, Claude Desktop, and other standard MCP clients connect to.
// The custom /mcp/http controller endpoint is retained for the built-in web UI tester.
if (!devBypassAuth)
{
    app.MapMcp("/mcp").RequireAuthorization("McpToolExecutor");
}
else
{
    app.MapMcp("/mcp");
}

// Add a simple root endpoint as fallback
app.MapGet("/", () => Results.Redirect("/index.html"));

app.Run();

// Static configuration holder for access in static tool methods
internal static class AppState
{
    public static IConfiguration? Configuration { get; set; }
}

public partial class Program
{
    private const int MaxUserAgentLength = 256;

    public static string NormalizeUserAgentForTelemetry(string? userAgent, out int originalLength, out bool wasTruncated, out int controlCharsRemoved)
    {
        originalLength = userAgent?.Length ?? 0;
        wasTruncated = false;
        controlCharsRemoved = 0;

        if (string.IsNullOrWhiteSpace(userAgent))
        {
            return "Not-Specified";
        }

        var normalized = userAgent.Normalize(NormalizationForm.FormKC);
        var sb = new StringBuilder(normalized.Length);

        foreach (var ch in normalized)
        {
            if (char.IsControl(ch))
            {
                controlCharsRemoved++;
                continue;
            }

            sb.Append(ch);
        }

        var sanitized = sb.ToString().Trim();
        if (sanitized.Length == 0)
        {
            return "Not-Specified";
        }

        if (sanitized.Length > MaxUserAgentLength)
        {
            wasTruncated = true;
            sanitized = sanitized[..MaxUserAgentLength];
        }

        return sanitized;
    }
}

public static class CosmosDbTools
{
    private sealed record SearchProfile(string TextProperty, string? VectorProperty, string SelectProperties, bool HasFullTextIndex, bool HasVectorIndex, bool SemanticRerankingEnabled);
    private static readonly ConcurrentDictionary<string, Lazy<Task<SearchProfile>>> SearchProfiles = new(StringComparer.OrdinalIgnoreCase);

    private static bool IsVectorProperty(string propertyName)
        => propertyName.Contains("embedding", StringComparison.OrdinalIgnoreCase)
            || propertyName.Contains("vector", StringComparison.OrdinalIgnoreCase);

    private static JsonElement RemoveVectorProperties(JsonElement value)
    {
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(value));
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            WriteWithoutVectorProperties(writer, document.RootElement);
        }

        return JsonDocument.Parse(stream.ToArray()).RootElement.Clone();
    }

    private static void WriteWithoutVectorProperties(Utf8JsonWriter writer, JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in value.EnumerateObject())
                {
                    if (IsVectorProperty(property.Name)) continue;
                    writer.WritePropertyName(property.Name);
                    WriteWithoutVectorProperties(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in value.EnumerateArray())
                    WriteWithoutVectorProperties(writer, item);
                writer.WriteEndArray();
                break;
            default:
                value.WriteTo(writer);
                break;
        }
    }

    private static string BuildSearchResponse(string searchType, string query, object parameters, IEnumerable<JsonElement> results)
        => JsonSerializer.Serialize(new
        {
            searchType,
            query,
            parameters = RemoveVectorProperties(JsonSerializer.SerializeToElement(parameters)),
            results = results.Select(RemoveVectorProperties)
        });

    private static bool TryGetResults(string json, out JsonElement results)
    {
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind == JsonValueKind.Array)
        {
            results = document.RootElement.Clone();
            return true;
        }

        if (document.RootElement.TryGetProperty("results", out var wrappedResults) && wrappedResults.ValueKind == JsonValueKind.Array)
        {
            results = wrappedResults.Clone();
            return true;
        }

        results = default;
        return false;
    }

    private static string NormalizeSearchType(string value)
        => value.Trim().ToLowerInvariant().Replace('-', '_').Replace(' ', '_');

    private static async Task<SearchProfile> GetSearchProfileAsync(CosmosClient client, string databaseId, string containerId)
    {
        var key = $"{databaseId}/{containerId}";
        var lazy = SearchProfiles.GetOrAdd(key, _ => new Lazy<Task<SearchProfile>>(
            () => LoadSearchProfileAsync(client, databaseId, containerId), LazyThreadSafetyMode.ExecutionAndPublication));
        return await lazy.Value;
    }

    private static async Task<SearchProfile> LoadSearchProfileAsync(CosmosClient client, string databaseId, string containerId)
    {
        var container = client.GetContainer(databaseId, containerId);
        var response = await container.ReadContainerAsync();
        var policyJson = JsonSerializer.SerializeToElement(response.Resource.IndexingPolicy);
        var policyText = policyJson.GetRawText();

        var sampleIterator = container.GetItemQueryIterator<JsonElement>(new QueryDefinition("SELECT TOP 10 * FROM c"), requestOptions: new QueryRequestOptions { MaxItemCount = 10 });
        var stringProperties = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var documentProperties = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var vectorCandidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (sampleIterator.HasMoreResults)
        {
            foreach (var document in await sampleIterator.ReadNextAsync())
            {
                if (document.ValueKind != JsonValueKind.Object) continue;
                foreach (var property in document.EnumerateObject())
                {
                    documentProperties.Add(property.Name);
                    if (property.Value.ValueKind == JsonValueKind.String)
                        stringProperties[property.Name] = stringProperties.GetValueOrDefault(property.Name) + 1;
                    if (property.Value.ValueKind == JsonValueKind.Array &&
                        (property.Name.Contains("vector", StringComparison.OrdinalIgnoreCase) || property.Name.Contains("embedding", StringComparison.OrdinalIgnoreCase)))
                        vectorCandidates.Add(property.Name);
                }
            }
            break;
        }

        var textProperty = stringProperties.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key).Select(pair => pair.Key).FirstOrDefault() ?? "content";
        var vectorProperty = vectorCandidates.FirstOrDefault();
        var selectProperties = string.Join(",", documentProperties.Where(property => !vectorCandidates.Contains(property)));
        if (string.IsNullOrWhiteSpace(selectProperties)) selectProperties = "id";
        return new SearchProfile(
            textProperty,
            vectorProperty,
            selectProperties,
            policyText.Contains("fullText", StringComparison.OrdinalIgnoreCase),
            vectorProperty is not null && policyText.Contains("vector", StringComparison.OrdinalIgnoreCase),
            string.Equals(Environment.GetEnvironmentVariable("COSMOS_SEMANTIC_RERANKING_ENABLED"), "true", StringComparison.OrdinalIgnoreCase));
    }

    [McpServerTool, Description("Searches a Cosmos DB container using the first search type in searchTypes that returns results. Supported types are hybrid, vector, and text; default priority is hybrid,vector,text. Use selectProperties to return only requested fields. The response includes the selected search type, parameterized Cosmos query, and results. Embedding/vector fields are excluded by default.")]
    internal static async Task<string> Search(
        CosmosClient client,
        [Description("Database id containing the container")] string databaseId,
        [Description("Container id to query")] string containerId,
        [Description("Natural-language search text")] string searchText,
        [Description("Comma-separated fields to return, or empty to return complete documents")] string selectProperties = "",
        [Description("Maximum number of results, default 5")] int n = 5,
        [Description("Comma-separated search types in priority order: hybrid, vector, text. Default: hybrid,vector,text.")] string searchTypes = "hybrid,vector,text")
    {
        if (string.IsNullOrWhiteSpace(databaseId) || string.IsNullOrWhiteSpace(containerId) || string.IsNullOrWhiteSpace(searchText))
            return JsonSerializer.Serialize(new { error = "Parameters 'databaseId', 'containerId', and 'searchText' are required." });
        if (n < 1 || n > 50)
            return JsonSerializer.Serialize(new { error = "Parameter 'n' must be between 1 and 50." });

        var profile = await GetSearchProfileAsync(client, databaseId, containerId);
        var properties = string.IsNullOrWhiteSpace(selectProperties) ? profile.SelectProperties : selectProperties;
        var requestedTypes = searchTypes.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(NormalizeSearchType)
            .Where(type => type is "hybrid" or "vector" or "text")
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (requestedTypes.Count == 0)
            return JsonSerializer.Serialize(new { error = "searchTypes must contain at least one of: hybrid, vector, text." });

        foreach (var searchType in requestedTypes)
        {
            var candidateCount = Math.Min(50, Math.Max(n, 20));
            string candidateJson;
            if (searchType == "hybrid" && profile.VectorProperty is not null && profile.HasVectorIndex)
                candidateJson = await HybridSearch(databaseId, containerId, searchText, profile.TextProperty, profile.VectorProperty, properties, candidateCount);
            else if (searchType == "vector" && profile.VectorProperty is not null && profile.HasVectorIndex)
                candidateJson = await VectorSearch(databaseId, containerId, searchText, profile.VectorProperty, properties, candidateCount);
            else if (searchType == "text")
                candidateJson = await TextSearch(databaseId, containerId, profile.TextProperty, searchText, n: Math.Min(20, Math.Max(n, 10)), selectProperties: properties);
            else
                continue;

            if (!TryGetResults(candidateJson, out var candidateResults) || candidateResults.GetArrayLength() == 0)
                continue;
            if (profile.SemanticRerankingEnabled)
                return await SemanticRerankAsync(client, databaseId, containerId, searchText, candidateJson, n, profile.TextProperty);
            return candidateJson;
        }

        return JsonSerializer.Serialize(new { searchTypes = requestedTypes, results = Array.Empty<object>(), message = "No search type returned results." });
    }

    private static async Task<string> SemanticRerankAsync(CosmosClient client, string databaseId, string containerId, string context, string candidateJson, int topN, string targetPath)
    {
        using var candidateDocument = JsonDocument.Parse(candidateJson);
        var candidateRoot = candidateDocument.RootElement;
        var candidatesElement = candidateRoot.ValueKind == JsonValueKind.Array
            ? candidateRoot
            : candidateRoot.TryGetProperty("results", out var wrappedResults) ? wrappedResults : default;
        if (candidatesElement.ValueKind != JsonValueKind.Array)
            return candidateJson;

        var candidates = candidatesElement.EnumerateArray().ToList();
        if (candidates.Count == 0) return candidateJson;

        var documents = candidates.Select(document => JsonSerializer.Serialize(document)).ToList();
        SemanticRerankResult result;
        try
        {
            result = await client.GetContainer(databaseId, containerId).SemanticRerankAsync(
                rerankContext: context,
                documents: documents,
                options: new Dictionary<string, dynamic>
                {
                    ["return_documents"] = true,
                    ["top_k"] = topN,
                    ["sort"] = true,
                    ["document_type"] = "json",
                    ["target_paths"] = targetPath
                });
        }
        catch (CosmosException)
        {
            return candidateJson;
        }

        var reranked = result.RerankScores
            .Take(topN)
            .Select(score => new
            {
                score = score.Score,
                document = score.Document is null ? null : (object?)RemoveVectorProperties(JsonSerializer.Deserialize<JsonElement>(score.Document))
            });
        return JsonSerializer.Serialize(new
        {
            searchType = "semantic_reranked",
            baseSearch = candidateRoot.ValueKind == JsonValueKind.Object && candidateRoot.TryGetProperty("searchType", out var baseType) ? baseType.GetString() : "unknown",
            query = candidateRoot.ValueKind == JsonValueKind.Object && candidateRoot.TryGetProperty("query", out var query) ? query.GetString() : null,
            parameters = candidateRoot.ValueKind == JsonValueKind.Object && candidateRoot.TryGetProperty("parameters", out var parameters)
                ? RemoveVectorProperties(parameters)
                : default,
            results = reranked
        });
    }

    // Environment variables used:
    // COSMOS_ENDPOINT - Cosmos DB account endpoint
    // OPENAI_ENDPOINT - Azure AI Services account endpoint, e.g. https://<resource>.cognitiveservices.azure.com/
    //                   Do NOT use Foundry project URLs (https://*.services.ai.azure.com/api/projects/...)
    // OPENAI_EMBEDDING_DEPLOYMENT - Embedding model deployment name (e.g. text-embedding-3-small)
    // Auth uses Entra ID via DefaultAzureCredential (supports Managed Identity and service principals).

    [McpServerTool, Description("Lists databases available in the Cosmos DB account.")]
    public static async Task<string> ListDatabases()
    {
        try
        {
            var endpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
            if (string.IsNullOrWhiteSpace(endpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable COSMOS_ENDPOINT." });
            }

            var credential = new DefaultAzureCredential();
            using var client = new CosmosClient(endpoint, credential, new CosmosClientOptions
            {
                ApplicationName = "AzureCosmosDBMCP"
            });

            var results = new List<string>();
            var iterator = client.GetDatabaseQueryIterator<DatabaseProperties>();
            while (iterator.HasMoreResults)
            {
                var page = await iterator.ReadNextAsync();
                foreach (var db in page)
                {
                    results.Add(db.Id);
                }
            }

            return JsonSerializer.Serialize(results);
        }
        catch (CosmosException cex)
        {
            return JsonSerializer.Serialize(new { error = cex.Message, statusCode = (int)cex.StatusCode });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }

    [McpServerTool, Description("Lists containers (collections) for the specified database.")]
    public static async Task<string> ListCollections(
        [Description("Database id to list containers from")] string databaseId)
    {
        try
        {
            var endpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
            if (string.IsNullOrWhiteSpace(endpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable COSMOS_ENDPOINT." });
            }

            if (string.IsNullOrWhiteSpace(databaseId))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'databaseId' is required." });
            }

            var credential = new DefaultAzureCredential();
            using var client = new CosmosClient(endpoint, credential, new CosmosClientOptions
            {
                ApplicationName = "AzureCosmosDBMCP"
            });

            var db = client.GetDatabase(databaseId);
            var results = new List<string>();
            var iterator = db.GetContainerQueryIterator<ContainerProperties>();
            while (iterator.HasMoreResults)
            {
                var page = await iterator.ReadNextAsync();
                foreach (var c in page)
                {
                    results.Add(c.Id);
                }
            }

            return JsonSerializer.Serialize(results);
        }
        catch (CosmosException cex)
        {
            return JsonSerializer.Serialize(new { error = cex.Message, statusCode = (int)cex.StatusCode });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }

    [McpServerTool, Description("Gets the most recent N documents ordered by timestamp (_ts DESC) from the specified database/container. N must be between 1 and 20.")]
    public static async Task<string> GetRecentDocuments(
        [Description("Database id containing the container")] string databaseId,
        [Description("Container id to query")] string containerId,
        [Description("Number of documents to return (1-20)")] int n)
    {
        try
        {
            var endpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
            if (string.IsNullOrWhiteSpace(endpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable COSMOS_ENDPOINT." });
            }
            if (string.IsNullOrWhiteSpace(databaseId) || string.IsNullOrWhiteSpace(containerId))
            {
                return JsonSerializer.Serialize(new { error = "Parameters 'databaseId' and 'containerId' are required." });
            }
            if (n < 1 || n > 20)
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'n' must be a whole number between 1 and 20." });
            }

            var credential = new DefaultAzureCredential();
            using var client = new CosmosClient(endpoint, credential, new CosmosClientOptions
            {
                ApplicationName = "AzureCosmosDBMCP"
            });

            var container = client.GetContainer(databaseId, containerId);
            var queryText = $"SELECT TOP {n} * FROM c ORDER BY c._ts DESC";
            var iterator = container.GetItemQueryIterator<dynamic>(
                new QueryDefinition(queryText),
                requestOptions: new QueryRequestOptions { MaxItemCount = n }
            );

            var jsonDocs = new List<string>();
            while (iterator.HasMoreResults && jsonDocs.Count < n)
            {
                var page = await iterator.ReadNextAsync();
                foreach (var doc in page)
                {
                    jsonDocs.Add(doc?.ToString() ?? "{}");
                    if (jsonDocs.Count >= n) break;
                }
            }

            var jsonArray = "[" + string.Join(",", jsonDocs) + "]";
            return jsonArray;
        }
        catch (CosmosException cex)
        {
            return JsonSerializer.Serialize(new { error = cex.Message, statusCode = (int)cex.StatusCode });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }

    [McpServerTool, Description("Select TOP N documents whose specified string property contains the search phrase, case-insensitive, without requiring a full-text index. Use selectProperties to return only requested fields; id is returned by default and embeddings are excluded. Call get_approximate_schema first when the property name is unknown. N must be between 1 and 20.")]
    public static async Task<string> TextSearch(
        [Description("Database id containing the container")] string databaseId,
        [Description("Container id to query")] string containerId,
        [Description("Exact string property path to search, e.g. name, subject, content, or profile.name. Derive it from get_approximate_schema; do not invent it.")] string property,
        [Description("Search term to look for within the property")] string searchPhrase,
        [Description("Number of documents to return (1-20, default 10)")] int n = 10,
        [Description("Comma-separated fields to return, or empty to return id only")] string selectProperties = "")
    {
        try
        {
            var endpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
            if (string.IsNullOrWhiteSpace(endpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable COSMOS_ENDPOINT." });
            }
            if (string.IsNullOrWhiteSpace(databaseId) || string.IsNullOrWhiteSpace(containerId))
            {
                return JsonSerializer.Serialize(new { error = "Parameters 'databaseId' and 'containerId' are required." });
            }
            if (string.IsNullOrWhiteSpace(property))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'property' is required." });
            }
            if (n < 1 || n > 20)
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'n' must be a whole number between 1 and 20." });
            }

            var properties = string.IsNullOrWhiteSpace(selectProperties) ? "id" : selectProperties;
            if (properties.Trim() == "*" || properties.Contains("*"))
                return JsonSerializer.Serialize(new { error = "Parameter 'selectProperties' cannot contain '*' wildcard." });
            var propertyPattern = new Regex(@"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$");
            if (properties.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Any(p => !propertyPattern.IsMatch(p)))
                return JsonSerializer.Serialize(new { error = "Invalid property name in selectProperties." });

            // Basic validation to avoid injection in the property path: allow letters, digits, underscore and dot segments.
            var propPattern = new Regex(@"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$");
            if (!propPattern.IsMatch(property))
            {
                return JsonSerializer.Serialize(new { error = "Invalid property name. Use dot notation with letters, digits, and underscores only (e.g., name or profile.name)." });
            }

            var credential = new DefaultAzureCredential();
            using var client = new CosmosClient(endpoint, credential, new CosmosClientOptions
            {
                ApplicationName = "AzureCosmosDBMCP"
            });

            var container = client.GetContainer(databaseId, containerId);
            var projection = string.Join(", ", properties.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(p => $"c.{p}"));
            var queryText = $"SELECT TOP {n} {projection}, 1 AS score FROM c WHERE IS_STRING(c.{property}) AND CONTAINS(c.{property}, @searchPhrase, true) ORDER BY score DESC";
            var query = new QueryDefinition(queryText).WithParameter("@searchPhrase", searchPhrase);

            var iterator = container.GetItemQueryIterator<dynamic>(query, requestOptions: new QueryRequestOptions { MaxItemCount = n });

            var jsonDocs = new List<string>();
            while (iterator.HasMoreResults && jsonDocs.Count < n)
            {
                var page = await iterator.ReadNextAsync();
                foreach (var doc in page)
                {
                    jsonDocs.Add(doc?.ToString() ?? "{}");
                    if (jsonDocs.Count >= n) break;
                }
            }

            using var resultDocument = JsonDocument.Parse("[" + string.Join(",", jsonDocs) + "]");
            return BuildSearchResponse("text", queryText, new { searchPhrase, property, selectProperties = properties, n }, resultDocument.RootElement.EnumerateArray());
        }
        catch (CosmosException cex)
        {
            return JsonSerializer.Serialize(new { error = cex.Message, statusCode = (int)cex.StatusCode });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }

    [McpServerTool, Description("Find a document by its id in the specified database/container.")]
    public static async Task<string> FindDocumentByID(
        [Description("Database id containing the container")] string databaseId,
        [Description("Container id to query")] string containerId,
        [Description("The id of the document to find")] string id)
    {
        try
        {
            var endpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
            if (string.IsNullOrWhiteSpace(endpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable COSMOS_ENDPOINT." });
            }
            if (string.IsNullOrWhiteSpace(databaseId) || string.IsNullOrWhiteSpace(containerId))
            {
                return JsonSerializer.Serialize(new { error = "Parameters 'databaseId' and 'containerId' are required." });
            }
            if (string.IsNullOrWhiteSpace(id))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'id' is required." });
            }

            var credential = new DefaultAzureCredential();
            using var client = new CosmosClient(endpoint, credential, new CosmosClientOptions
            {
                ApplicationName = "AzureCosmosDBMCP"
            });

            var container = client.GetContainer(databaseId, containerId);
            var queryText = "SELECT * FROM c WHERE c.id = @id";
            var query = new QueryDefinition(queryText).WithParameter("@id", id);

            var iterator = container.GetItemQueryIterator<dynamic>(query, requestOptions: new QueryRequestOptions { MaxItemCount = 1 });

            while (iterator.HasMoreResults)
            {
                var page = await iterator.ReadNextAsync();
                foreach (var doc in page)
                {
                    var json = doc?.ToString() ?? "{}";
                    return JsonSerializer.Serialize(RemoveVectorProperties(JsonSerializer.Deserialize<JsonElement>(json)));
                }
            }

            return JsonSerializer.Serialize(new { message = "No document found with the specified id." });
        }
        catch (CosmosException cex)
        {
            return JsonSerializer.Serialize(new { error = cex.Message, statusCode = (int)cex.StatusCode });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }

    [McpServerTool, Description("Approximates a container schema by sampling up to 10 documents and returning a union of top-level properties with inferred types and brief descriptions.")]
    public static async Task<string> GetApproximateSchema(
        [Description("Database id containing the container")] string databaseId,
        [Description("Container id to inspect")] string containerId)
    {
        try
        {
            var endpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
            if (string.IsNullOrWhiteSpace(endpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable COSMOS_ENDPOINT." });
            }
            if (string.IsNullOrWhiteSpace(databaseId) || string.IsNullOrWhiteSpace(containerId))
            {
                return JsonSerializer.Serialize(new { error = "Parameters 'databaseId' and 'containerId' are required." });
            }

            var credential = new DefaultAzureCredential();
            using var client = new CosmosClient(endpoint, credential, new CosmosClientOptions
            {
                ApplicationName = "AzureCosmosDBMCP"
            });

            var container = client.GetContainer(databaseId, containerId);
            var queryText = "SELECT TOP 10 * FROM c";
            var iterator = container.GetItemQueryIterator<dynamic>(
                new QueryDefinition(queryText),
                requestOptions: new QueryRequestOptions { MaxItemCount = 10 }
            );

            var typeMap = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
            var countMap = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            int sampleCount = 0;

            while (iterator.HasMoreResults && sampleCount < 10)
            {
                var page = await iterator.ReadNextAsync();
                foreach (var doc in page)
                {
                    var json = doc?.ToString();
                    if (string.IsNullOrWhiteSpace(json)) continue;

                    try
                    {
                        using var parsed = JsonDocument.Parse(json);
                        if (parsed.RootElement.ValueKind != JsonValueKind.Object) continue;
                        sampleCount++;
                        
                        foreach (var prop in parsed.RootElement.EnumerateObject())
                        {
                            var name = prop.Name;
                            var kind = prop.Value.ValueKind;
                            string type = kind switch
                            {
                                JsonValueKind.String => "string",
                                JsonValueKind.Number => "number",
                                JsonValueKind.True => "boolean",
                                JsonValueKind.False => "boolean",
                                JsonValueKind.Object => "object",
                                JsonValueKind.Array => "array",
                                JsonValueKind.Null => "null",
                                _ => "unknown"
                            };

                            if (!typeMap.TryGetValue(name, out HashSet<string>? set))
                            {
                                set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                                typeMap[name] = set;
                            }
                            set!.Add(type);

                            countMap.TryGetValue(name, out int current);
                            countMap[name] = current + 1;
                        }
                    }
                    catch
                    {
                        // Ignore malformed JSON rows
                    }

                    if (sampleCount >= 10) break;
                }
            }

            if (sampleCount == 0)
            {
                return JsonSerializer.Serialize(new { message = "No documents found to infer schema." });
            }

            var properties = new List<object>();
            foreach (var kvp in typeMap.OrderBy(k => k.Key, StringComparer.OrdinalIgnoreCase))
            {
                var name = kvp.Key;
                var types = kvp.Value.OrderBy(t => t).ToArray();
                var typeStr = string.Join(" | ", types);
                countMap.TryGetValue(name, out int appearCount);
                var description = $"Appears in {appearCount}/{sampleCount} sampled documents.";
                properties.Add(new { name, type = typeStr, description });
            }

            var result = new { sampleSize = sampleCount, properties };
            return JsonSerializer.Serialize(result);
        }
        catch (CosmosException cex)
        {
            return JsonSerializer.Serialize(new { error = cex.Message, statusCode = (int)cex.StatusCode });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }

    [McpServerTool, Description("Performs vector search on Cosmos DB using Azure OpenAI embeddings. Searches for semantically similar documents based on text input.")]
    public static async Task<string> VectorSearch(
        [Description("Database id containing the container")] string databaseId,
        [Description("Container id to query")] string containerId,
        [Description("Text to search for semantically similar content")] string searchText,
        [Description("Property name where vector embeddings are stored, e.g. 'vector' or 'embeddings'")] string vectorProperty,
        [Description("Comma-separated list of specific properties to project in results, e.g. 'id,title,content'. Cannot use '*' wildcard.")] string selectProperties,
        [Description("Number of documents to return (1-50, default 10)")] int topN = 10)
    {
        try
        {
            // Validate environment variables
            var cosmosEndpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
            // OPENAI_ENDPOINT must be the Azure AI Services account endpoint, not a Foundry project URL
            // Microsoft Foundry projects expose OpenAI-compatible endpoints (recommended)
            var openaiEndpoint = Environment.GetEnvironmentVariable("OPENAI_ENDPOINT");
            var embeddingDeployment = Environment.GetEnvironmentVariable("OPENAI_EMBEDDING_DEPLOYMENT");

            if (string.IsNullOrWhiteSpace(cosmosEndpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable COSMOS_ENDPOINT." });
            }
            if (string.IsNullOrWhiteSpace(openaiEndpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable OPENAI_ENDPOINT." });
            }
            if (string.IsNullOrWhiteSpace(embeddingDeployment))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable OPENAI_EMBEDDING_DEPLOYMENT." });
            }

            // Validate parameters
            if (string.IsNullOrWhiteSpace(databaseId) || string.IsNullOrWhiteSpace(containerId))
            {
                return JsonSerializer.Serialize(new { error = "Parameters 'databaseId' and 'containerId' are required." });
            }
            if (string.IsNullOrWhiteSpace(searchText))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'searchText' is required." });
            }
            if (string.IsNullOrWhiteSpace(vectorProperty))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'vectorProperty' is required." });
            }
            if (string.IsNullOrWhiteSpace(selectProperties))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'selectProperties' is required." });
            }
            if (topN < 1 || topN > 50)
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'topN' must be a whole number between 1 and 50." });
            }

            // Validate that selectProperties doesn't contain wildcard
            if (selectProperties.Trim() == "*" || selectProperties.Contains("*"))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'selectProperties' cannot contain '*' wildcard. Please specify explicit property names separated by commas." });
            }

            // Validate property names (without c. prefix - we'll add it later)
            var propPattern = new Regex(@"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$");
            
            // Validate vectorProperty
            if (!propPattern.IsMatch(vectorProperty))
            {
                return JsonSerializer.Serialize(new { error = "Invalid vectorProperty name. Use dot notation with letters, digits, and underscores only (e.g., 'vector' or 'embeddings')." });
            }

            // Validate selectProperties format - each property should be valid
            var properties = selectProperties.Split(',', StringSplitOptions.RemoveEmptyEntries)
                .Select(p => p.Trim())
                .ToArray();
            
            foreach (var prop in properties)
            {
                if (!propPattern.IsMatch(prop))
                {
                    return JsonSerializer.Serialize(new { error = $"Invalid property name '{prop}' in selectProperties. Use dot notation with letters, digits, and underscores only (e.g., 'id', 'title', 'metadata.author')." });
                }
            }

            var credential = new DefaultAzureCredential();

            // Generate embedding using the appropriate embedding service
            // (Azure AI Services, OpenAI native, or Azure AI Foundry)
            float[] embedding;
            try
            {
                if (AppState.Configuration == null)
                {
                    return JsonSerializer.Serialize(new { error = "Application configuration not initialized." });
                }
                
                var embeddingClient = EmbeddingClientFactory.CreateEmbeddingClient(AppState.Configuration);
                embedding = await embeddingClient.GenerateEmbeddingAsync(searchText, embeddingDeployment);
            }
            catch (Exception ex)
            {
                return JsonSerializer.Serialize(new { error = $"Failed to generate embedding: {ex.Message}" });
            }

            // Perform vector search in Cosmos DB
            using var cosmosClient = new CosmosClient(cosmosEndpoint, credential, new CosmosClientOptions
            {
                ApplicationName = "AzureCosmosDBMCP"
            });

            var container = cosmosClient.GetContainer(databaseId, containerId);

            // Build SELECT clause by prepending "c." to each property
            var selectClause = string.Join(", ", properties.Select(p => $"c.{p}"));

            // Build vector search query - prepend "c." to vectorProperty as well
            var queryText = $@"
                SELECT TOP @topN {selectClause}, 1 - VectorDistance(c.{vectorProperty}, @embedding) as score
                FROM c
                ORDER BY VectorDistance(c.{vectorProperty}, @embedding)";

            var queryDefinition = new QueryDefinition(queryText)
                .WithParameter("@topN", topN)
                .WithParameter("@embedding", embedding);

            var iterator = container.GetItemQueryIterator<dynamic>(
                queryDefinition,
                requestOptions: new QueryRequestOptions { MaxItemCount = topN }
            );

            var results = new List<string>();
            while (iterator.HasMoreResults && results.Count < topN)
            {
                var page = await iterator.ReadNextAsync();
                foreach (var doc in page)
                {
                    results.Add(doc?.ToString() ?? "{}");
                    if (results.Count >= topN) break;
                }
            }

            var jsonArray = "[" + string.Join(",", results) + "]";
            using var resultDocument = JsonDocument.Parse(jsonArray);
            return BuildSearchResponse("vector", queryText, new { searchText, vectorProperty, selectProperties, topN, embedding = "@embedding" }, resultDocument.RootElement.EnumerateArray());
        }
        catch (CosmosException cex)
        {
            return JsonSerializer.Serialize(new { error = cex.Message, statusCode = (int)cex.StatusCode });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }

    [McpServerTool, Description("Performs hybrid search combining vector similarity and full-text keyword search using Reciprocal Rank Fusion (RRF). Requires both a vector index and a full-text index on the container.")]
    public static async Task<string> HybridSearch(
        [Description("Database id containing the container")] string databaseId,
        [Description("Container id to query")] string containerId,
        [Description("Text to search for using both semantic similarity and keyword matching")] string searchText,
        [Description("Property name that has a full-text index for keyword search, e.g. 'text' or 'content'")] string textProperty,
        [Description("Property name where vector embeddings are stored, e.g. 'vector' or 'embeddings'")] string vectorProperty,
        [Description("Comma-separated list of specific properties to project in results, e.g. 'id,title,content'. Cannot use '*' wildcard.")] string selectProperties,
        [Description("Number of documents to return (1-50, default 10)")] int topN = 10)
    {
        try
        {
            // Validate environment variables
            var cosmosEndpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
            var openaiEndpoint = Environment.GetEnvironmentVariable("OPENAI_ENDPOINT");
            var embeddingDeployment = Environment.GetEnvironmentVariable("OPENAI_EMBEDDING_DEPLOYMENT");

            if (string.IsNullOrWhiteSpace(cosmosEndpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable COSMOS_ENDPOINT." });
            }
            if (string.IsNullOrWhiteSpace(openaiEndpoint))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable OPENAI_ENDPOINT." });
            }
            if (string.IsNullOrWhiteSpace(embeddingDeployment))
            {
                return JsonSerializer.Serialize(new { error = "Missing required environment variable OPENAI_EMBEDDING_DEPLOYMENT." });
            }

            // Validate parameters
            if (string.IsNullOrWhiteSpace(databaseId) || string.IsNullOrWhiteSpace(containerId))
            {
                return JsonSerializer.Serialize(new { error = "Parameters 'databaseId' and 'containerId' are required." });
            }
            if (string.IsNullOrWhiteSpace(searchText))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'searchText' is required." });
            }
            if (string.IsNullOrWhiteSpace(textProperty))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'textProperty' is required." });
            }
            if (string.IsNullOrWhiteSpace(vectorProperty))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'vectorProperty' is required." });
            }
            if (string.IsNullOrWhiteSpace(selectProperties))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'selectProperties' is required." });
            }
            if (topN < 1 || topN > 50)
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'topN' must be a whole number between 1 and 50." });
            }

            // Validate that selectProperties doesn't contain wildcard
            if (selectProperties.Trim() == "*" || selectProperties.Contains("*"))
            {
                return JsonSerializer.Serialize(new { error = "Parameter 'selectProperties' cannot contain '*' wildcard. Please specify explicit property names separated by commas." });
            }

            // Validate property names
            var propPattern = new Regex(@"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$");
            
            if (!propPattern.IsMatch(vectorProperty))
            {
                return JsonSerializer.Serialize(new { error = "Invalid vectorProperty name. Use dot notation with letters, digits, and underscores only (e.g., 'vector' or 'embeddings')." });
            }

            if (!propPattern.IsMatch(textProperty))
            {
                return JsonSerializer.Serialize(new { error = "Invalid textProperty name. Use dot notation with letters, digits, and underscores only (e.g., 'text' or 'content')." });
            }

            var properties = selectProperties.Split(',', StringSplitOptions.RemoveEmptyEntries)
                .Select(p => p.Trim())
                .ToArray();
            
            foreach (var prop in properties)
            {
                if (!propPattern.IsMatch(prop))
                {
                    return JsonSerializer.Serialize(new { error = $"Invalid property name '{prop}' in selectProperties. Use dot notation with letters, digits, and underscores only (e.g., 'id', 'title', 'metadata.author')." });
                }
            }

            var credential = new DefaultAzureCredential();

            // Generate embedding using the configured embedding service
            float[] embedding;
            try
            {
                if (AppState.Configuration == null)
                {
                    return JsonSerializer.Serialize(new { error = "Application configuration not initialized." });
                }
                
                var embeddingClient = EmbeddingClientFactory.CreateEmbeddingClient(AppState.Configuration);
                embedding = await embeddingClient.GenerateEmbeddingAsync(searchText, embeddingDeployment);
            }
            catch (Exception ex)
            {
                return JsonSerializer.Serialize(new { error = $"Failed to generate embedding: {ex.Message}" });
            }

            // Perform hybrid search in Cosmos DB
            using var cosmosClient = new CosmosClient(cosmosEndpoint, credential, new CosmosClientOptions
            {
                ApplicationName = "AzureCosmosDBMCP"
            });

            var container = cosmosClient.GetContainer(databaseId, containerId);

            var selectClause = string.Join(", ", properties.Select(p => $"c.{p}"));

            // Hybrid search query using RRF to combine vector and full-text scores
            var queryText = $@"
                SELECT TOP @topN {selectClause}, RANK RRF(VectorDistance(c.{vectorProperty}, @embedding), FullTextScore(c.{textProperty}, @searchText)) AS score
                FROM c
                ORDER BY RANK RRF(VectorDistance(c.{vectorProperty}, @embedding), FullTextScore(c.{textProperty}, @searchText))";

            var queryDefinition = new QueryDefinition(queryText)
                .WithParameter("@topN", topN)
                .WithParameter("@embedding", embedding)
                .WithParameter("@searchText", searchText);

            var iterator = container.GetItemQueryIterator<dynamic>(
                queryDefinition,
                requestOptions: new QueryRequestOptions { MaxItemCount = topN }
            );

            var results = new List<string>();
            while (iterator.HasMoreResults && results.Count < topN)
            {
                var page = await iterator.ReadNextAsync();
                foreach (var doc in page)
                {
                    results.Add(doc?.ToString() ?? "{}");
                    if (results.Count >= topN) break;
                }
            }

            var jsonArray = "[" + string.Join(",", results) + "]";
            using var resultDocument = JsonDocument.Parse(jsonArray);
            return BuildSearchResponse("hybrid", queryText, new { searchText, textProperty, vectorProperty, selectProperties, topN, embedding = "@embedding" }, resultDocument.RootElement.EnumerateArray());
        }
        catch (CosmosException cex)
        {
            return JsonSerializer.Serialize(new { error = cex.Message, statusCode = (int)cex.StatusCode });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }
}
