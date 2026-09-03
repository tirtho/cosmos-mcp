using System.ComponentModel;
using Microsoft.Azure.Cosmos;
using ModelContextProtocol.Server;

namespace AzureCosmosDB.MCP.Toolkit.Services;

[McpServerToolType]
public sealed class CosmosDbMcpTools
{
    private readonly CosmosDbToolsService _tools;
    private readonly CosmosClient _cosmosClient;

    public CosmosDbMcpTools(CosmosDbToolsService tools, CosmosClient cosmosClient)
    {
        _tools = tools ?? throw new ArgumentNullException(nameof(tools));
        _cosmosClient = cosmosClient ?? throw new ArgumentNullException(nameof(cosmosClient));
    }

    [McpServerTool, Description("Lists the databases available to the configured Cosmos DB account.")]
    public Task<object> ListDatabases(CancellationToken cancellationToken = default)
        => _tools.ListDatabases(cancellationToken);

    [McpServerTool, Description("Lists the containers in a Cosmos DB database.")]
    public Task<object> ListCollections(string databaseId, CancellationToken cancellationToken = default)
        => _tools.ListCollections(databaseId, cancellationToken);

    [McpServerTool, Description("Returns the most recent documents from a Cosmos DB container.")]
    public Task<object> GetRecentDocuments(string databaseId, string containerId, int n, CancellationToken cancellationToken = default)
        => _tools.GetRecentDocuments(databaseId, containerId, n, cancellationToken);

    [McpServerTool, Description("Searches a string property using case-insensitive text matching.")]
    public Task<object> TextSearch(string databaseId, string containerId, string property, string searchPhrase, int n = 10, CancellationToken cancellationToken = default)
        => _tools.TextSearch(databaseId, containerId, property, searchPhrase, n, cancellationToken);

    [McpServerTool, Description("Finds a document by its id.")]
    public Task<object> FindDocumentByID(string databaseId, string containerId, string id, CancellationToken cancellationToken = default)
        => _tools.FindDocumentByID(databaseId, containerId, id, cancellationToken);

    [McpServerTool, Description("Infers a schema from sampled documents in a Cosmos DB container.")]
    public Task<object> GetApproximateSchema(string databaseId, string containerId, CancellationToken cancellationToken = default)
        => _tools.GetApproximateSchema(databaseId, containerId, cancellationToken);

    [McpServerTool, Description("Runs vector similarity search with explicit field projection.")]
    public Task<object> VectorSearch(string databaseId, string containerId, string searchText, string vectorProperty, string selectProperties, int topN = 10, CancellationToken cancellationToken = default)
        => _tools.VectorSearch(databaseId, containerId, searchText, vectorProperty, selectProperties, topN, cancellationToken);

    [McpServerTool, Description("Runs hybrid text and vector search with explicit field projection.")]
    public Task<object> HybridSearch(string databaseId, string containerId, string searchText, string textProperty, string vectorProperty, string selectProperties, int topN = 10, CancellationToken cancellationToken = default)
        => _tools.HybridSearch(databaseId, containerId, searchText, textProperty, vectorProperty, selectProperties, topN, cancellationToken);

    [McpServerTool, Description("Searches using the first successful strategy in the requested priority order.")]
    public Task<string> Search(
        string databaseId,
        string containerId,
        string searchText,
        string selectProperties = "",
        int n = 5,
        string searchTypes = "hybrid,vector,text")
        => CosmosDbTools.Search(_cosmosClient, databaseId, containerId, searchText, selectProperties, n, searchTypes);
}
