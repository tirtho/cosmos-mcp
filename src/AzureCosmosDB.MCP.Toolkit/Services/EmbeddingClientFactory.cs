using Azure.AI.OpenAI;
using Azure.Identity;
using OpenAI;

namespace AzureCosmosDB.MCP.Toolkit.Services;

/// <summary>
/// Abstraction for embedding client operations supporting multiple endpoints.
/// Supports: Azure AI Services, OpenAI native API, and Azure AI Foundry projects.
/// </summary>
public interface IEmbeddingClient
{
    /// <summary>
    /// Generate embeddings for the given text.
    /// </summary>
    Task<float[]> GenerateEmbeddingAsync(string text, string deploymentName, CancellationToken cancellationToken = default);
    
    /// <summary>
    /// Get the endpoint type for diagnostics and logging.
    /// </summary>
    string EndpointType { get; }
}

/// <summary>
/// Azure OpenAI (Azure AI Services / Cognitive Services) embedding client adapter.
/// Supports: https://<resource>.cognitiveservices.azure.com/
/// </summary>
internal class AzureOpenAIEmbeddingClient : IEmbeddingClient
{
    private readonly AzureOpenAIClient _client;

    public string EndpointType => "Azure AI Services (Cognitive Services)";

    public AzureOpenAIEmbeddingClient(AzureOpenAIClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    public async Task<float[]> GenerateEmbeddingAsync(string text, string deploymentName, CancellationToken cancellationToken = default)
    {
        var embeddingClient = _client.GetEmbeddingClient(deploymentName);
        var embeddingResponse = await embeddingClient.GenerateEmbeddingAsync(text);
        return embeddingResponse.Value.ToFloats().ToArray();
    }
}

/// <summary>
/// OpenAI native API embedding client adapter.
/// Supports: https://api.openai.com/v1
/// </summary>
internal class OpenAINativeEmbeddingClient : IEmbeddingClient
{
    private readonly OpenAIClient _client;

    public string EndpointType => "OpenAI Native API";

    public OpenAINativeEmbeddingClient(OpenAIClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    public async Task<float[]> GenerateEmbeddingAsync(string text, string deploymentName, CancellationToken cancellationToken = default)
    {
        // OpenAI SDK v2.0.0 - Get embedding client with model name (not deployment name)
        var embeddingClient = _client.GetEmbeddingClient(deploymentName);
        // Call GenerateEmbeddingAsync with text only, cancellation token is handled separately
        var embeddingResponse = await embeddingClient.GenerateEmbeddingAsync(text);
        return embeddingResponse.Value.ToFloats().ToArray();
    }
}

/// <summary>
/// Azure AI Foundry embedding client adapter.
/// Supports: https://<resource>.services.ai.azure.com/api/projects/<project-name>
/// </summary>
internal class AzureAIFoundryEmbeddingClient : IEmbeddingClient
{
    private readonly AzureOpenAIClient _client;

    public string EndpointType => "Azure AI Foundry";

    public AzureAIFoundryEmbeddingClient(AzureOpenAIClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    public async Task<float[]> GenerateEmbeddingAsync(string text, string deploymentName, CancellationToken cancellationToken = default)
    {
        var embeddingClient = _client.GetEmbeddingClient(deploymentName);
        var embeddingResponse = await embeddingClient.GenerateEmbeddingAsync(text);
        return embeddingResponse.Value.ToFloats().ToArray();
    }
}

/// <summary>
/// Factory for creating embedding clients with support for multiple endpoint types.
/// Automatically detects endpoint type and creates appropriate client.
/// 
/// Supported endpoints:
/// 1. Azure AI Services (Cognitive Services): https://<resource>.cognitiveservices.azure.com/
/// 2. OpenAI Native API: https://api.openai.com/v1
/// 3. Azure AI Foundry Project: https://<resource>.services.ai.azure.com/api/projects/<project-name>
/// </summary>
public static class EmbeddingClientFactory
{
    /// <summary>
    /// Detect the endpoint type based on the URL pattern.
    /// </summary>
    private static EndpointType DetectEndpointType(string endpoint)
    {
        if (string.IsNullOrWhiteSpace(endpoint))
            throw new ArgumentException("Endpoint cannot be null or empty.", nameof(endpoint));

        endpoint = endpoint.Trim().ToLowerInvariant();

        if (endpoint.Contains("api.openai.com", StringComparison.OrdinalIgnoreCase))
        {
            return EndpointType.OpenAINative;
        }

        if (endpoint.Contains(".services.ai.azure.com", StringComparison.OrdinalIgnoreCase))
        {
            if (endpoint.Contains("/api/projects/", StringComparison.OrdinalIgnoreCase))
            {
                return EndpointType.AzureAIFoundry;
            }
            throw new InvalidOperationException(
                $"Azure AI Foundry endpoint detected but URL does not contain '/api/projects/'. " +
                "Expected format: https://<resource>.services.ai.azure.com/api/projects/<project-name> " +
                $"Got: {endpoint}");
        }

        if (endpoint.Contains(".cognitiveservices.azure.com", StringComparison.OrdinalIgnoreCase))
        {
            return EndpointType.AzureAIServices;
        }

        // Default to Azure AI Services if pattern matches standard Azure structure
        if (endpoint.Contains(".azure.com", StringComparison.OrdinalIgnoreCase))
        {
            return EndpointType.AzureAIServices;
        }

        throw new InvalidOperationException(
            $"Unable to determine endpoint type for: {endpoint}. " +
            "Supported endpoints:\n" +
            "  - Azure AI Services: https://<resource>.cognitiveservices.azure.com/\n" +
            "  - OpenAI Native: https://api.openai.com/v1\n" +
            "  - Azure AI Foundry: https://<resource>.services.ai.azure.com/api/projects/<project-name>");
    }

    /// <summary>
    /// Create an embedding client for the specified endpoint.
    /// 
    /// Priority order for authentication:
    /// 1. OPENAI_API_KEY - for local development or scenarios where API key is available
    /// 2. Azure credentials (DefaultAzureCredential) - for cloud production with Azure authentication
    /// </summary>
    public static IEmbeddingClient CreateEmbeddingClient(IConfiguration configuration, ILogger? logger = null)
    {
        var endpoint = (configuration["OPENAI_ENDPOINT"]
            ?? Environment.GetEnvironmentVariable("OPENAI_ENDPOINT") ?? string.Empty).Trim();

        if (string.IsNullOrWhiteSpace(endpoint))
        {
            throw new InvalidOperationException(
                "OPENAI_ENDPOINT environment variable must be set. " +
                "Supported formats:\n" +
                "  - Azure AI Services: https://<resource>.cognitiveservices.azure.com/\n" +
                "  - OpenAI Native: https://api.openai.com/v1\n" +
                "  - Azure AI Foundry: https://<resource>.services.ai.azure.com/api/projects/<project-name>");
        }

        var endpointType = DetectEndpointType(endpoint);
        var apiKey = (configuration["OPENAI_API_KEY"]
            ?? Environment.GetEnvironmentVariable("OPENAI_API_KEY") ?? string.Empty).Trim();

        if (string.Equals(configuration["ASPNETCORE_ENVIRONMENT"], "Production", StringComparison.OrdinalIgnoreCase) &&
            !string.IsNullOrWhiteSpace(apiKey))
        {
            throw new InvalidOperationException("OPENAI_API_KEY is not permitted in Production. Configure an Azure endpoint and use Managed Identity.");
        }

        switch (endpointType)
        {
            case EndpointType.OpenAINative:
                return CreateOpenAINativeClient(endpoint, apiKey, logger);
            
            case EndpointType.AzureAIFoundry:
                return CreateAzureAIFoundryClient(endpoint, apiKey, logger);
            
            case EndpointType.AzureAIServices:
            default:
                return CreateAzureAIServicesClient(endpoint, apiKey, logger);
        }
    }

    /// <summary>
    /// Create Azure AI Services (Cognitive Services) embedding client.
    /// </summary>
    private static IEmbeddingClient CreateAzureAIServicesClient(string endpoint, string apiKey, ILogger? logger)
    {
        logger?.LogInformation("Creating embedding client for Azure AI Services (Cognitive Services)");

        AzureOpenAIClient client;
        if (!string.IsNullOrWhiteSpace(apiKey))
        {
            logger?.LogInformation("  Using API key authentication");
            client = new AzureOpenAIClient(new Uri(endpoint), new Azure.AzureKeyCredential(apiKey));
        }
        else
        {
            logger?.LogInformation("  Using Azure credentials (DefaultAzureCredential)");
            var credential = new DefaultAzureCredential();
            client = new AzureOpenAIClient(new Uri(endpoint), credential);
        }

        return new AzureOpenAIEmbeddingClient(client);
    }

    /// <summary>
    /// Create OpenAI native API embedding client.
    /// </summary>
    private static IEmbeddingClient CreateOpenAINativeClient(string endpoint, string apiKey, ILogger? logger)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            throw new InvalidOperationException(
                "OpenAI native API requires OPENAI_API_KEY. " +
                "Azure credentials (DefaultAzureCredential) are not supported for OpenAI native API. " +
                "Set OPENAI_API_KEY environment variable with your OpenAI API key.");
        }

        logger?.LogInformation("Creating embedding client for OpenAI native API");
        logger?.LogInformation("  Using API key authentication");

        var client = new OpenAIClient(apiKey);
        return new OpenAINativeEmbeddingClient(client);
    }

    /// <summary>
    /// Create Azure AI Foundry embedding client.
    /// </summary>
    private static IEmbeddingClient CreateAzureAIFoundryClient(string endpoint, string apiKey, ILogger? logger)
    {
        logger?.LogInformation("Creating embedding client for Azure AI Foundry");

        AzureOpenAIClient client;
        if (!string.IsNullOrWhiteSpace(apiKey))
        {
            logger?.LogInformation("  Using API key authentication");
            client = new AzureOpenAIClient(new Uri(endpoint), new Azure.AzureKeyCredential(apiKey));
        }
        else
        {
            logger?.LogInformation("  Using Azure credentials (DefaultAzureCredential)");
            var credential = new DefaultAzureCredential();
            client = new AzureOpenAIClient(new Uri(endpoint), credential);
        }

        return new AzureAIFoundryEmbeddingClient(client);
    }
}

/// <summary>
/// Enumeration of supported endpoint types.
/// </summary>
internal enum EndpointType
{
    AzureAIServices,
    OpenAINative,
    AzureAIFoundry
}
