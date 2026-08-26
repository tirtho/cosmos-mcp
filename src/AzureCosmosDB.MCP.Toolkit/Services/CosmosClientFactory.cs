using Azure.Identity;
using Microsoft.Azure.Cosmos;
using System.Net.Http;

namespace AzureCosmosDB.MCP.Toolkit.Services;

/// <summary>
/// Factory for creating CosmosClient instances with managed identity in Azure and
/// an emulator connection string only when no Azure endpoint is configured.
/// </summary>
public static class CosmosClientFactory
{
    private static CosmosClientOptions BuildClientOptions(IConfiguration configuration, ILogger logger, bool useGatewayMode)
    {
        var options = new CosmosClientOptions
        {
            ApplicationName = "AzureCosmosDBMCP",
            EnableContentResponseOnWrite = false,
            RequestTimeout = TimeSpan.FromSeconds(60)
        };

        if (useGatewayMode)
        {
            // Emulator/local scenarios are more reliable over HTTPS gateway mode.
            options.ConnectionMode = ConnectionMode.Gateway;
        }

        var sslVerifySetting = configuration["COSMOS_EMULATOR_SSL_VERIFY"]
            ?? Environment.GetEnvironmentVariable("COSMOS_EMULATOR_SSL_VERIFY");

        if (!string.IsNullOrWhiteSpace(sslVerifySetting)
            && bool.TryParse(sslVerifySetting, out var sslVerify)
            && !sslVerify)
        {
            logger.LogWarning("COSMOS_EMULATOR_SSL_VERIFY=false detected. TLS certificate validation is disabled for Cosmos DB emulator connections.");
            options.HttpClientFactory = () => new HttpClient(new HttpClientHandler
            {
                ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
            });
        }

        return options;
    }

    /// <summary>
    /// Create a CosmosClient using managed identity for Azure endpoints.
    /// 
    /// Priority order:
    /// 1. COSMOS_ENDPOINT with DefaultAzureCredential - for cloud production
    /// 2. COSMOS_CONNECTION_STRING - for emulator or local development
    /// </summary>
    public static CosmosClient CreateCosmosClient(IConfiguration configuration, ILogger logger)
    {
        var endpoint = configuration["COSMOS_ENDPOINT"] 
            ?? Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");

        if (!string.IsNullOrWhiteSpace(endpoint))
        {
            logger.LogInformation("Creating CosmosClient using DefaultAzureCredential (managed identity in Azure)");
            var credential = new DefaultAzureCredential();
            return new CosmosClient(endpoint, credential, BuildClientOptions(configuration, logger, useGatewayMode: false));
        }

        var connectionString = configuration["COSMOS_CONNECTION_STRING"]
            ?? Environment.GetEnvironmentVariable("COSMOS_CONNECTION_STRING");
        if (!string.IsNullOrWhiteSpace(connectionString))
        {
            logger.LogInformation("Creating CosmosClient using connection string (emulator/local mode)");
            return new CosmosClient(connectionString, BuildClientOptions(configuration, logger, useGatewayMode: true));
        }

        throw new InvalidOperationException(
            "COSMOS_ENDPOINT must be set for Azure managed identity access. " +
            "For local emulator development only, use COSMOS_CONNECTION_STRING.");
    }
}
