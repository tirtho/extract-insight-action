# Mailbox to Queue Function

An Azure Function that polls a Microsoft 365 email mailbox using Microsoft Graph API and sends email metadata to Azure Service Bus for processing.

## Features

- **Timer-triggered polling**: Runs on a configurable schedule (default: every 5 minutes)
- **Microsoft Graph API integration**: Connects securely to Microsoft 365 mailboxes
- **Service Bus integration**: Sends email metadata to Azure Service Bus topics
- **Key Vault support**: Securely retrieves credentials from Azure Key Vault
- **Configurable time windows**: Processes emails from a specified time interval
- **Multi-tenant support**: Can access different mailboxes within the tenant

## Prerequisites

- Java 21
- Maven 3.6+
- Azure Functions Core Tools 4.x
- An Azure subscription with:
  - Azure Functions app
  - Azure Service Bus namespace and topic
  - Azure Key Vault (optional for secure credential storage)
  - Azure AD App Registration with Mail.Read permissions
  
## Configuration

Configure the following settings in your `local.settings.json` or Azure Functions app settings:

### Required Settings

```json
{
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "java",
    "FUNCTIONS_EXTENSION_VERSION": "~4",
    "AZURE_SERVICE_BUS_URL": "https://your-servicebus-namespace.servicebus.windows.net/",
    "AZURE_SERVICE_BUS_TOPIC": "email-processing",
    "AZURE_CLIENT_ID": "your-app-registration-client-id",
    "AZURE_CLIENT_SECRET": "your-app-registration-client-secret",
    "AZURE_TENANT_ID": "your-azure-tenant-id"
  }
}
```

### Optional Settings

```json
{
  "Values": {
    "AZURE_KEY_VAULT_URL": "https://your-keyvault-name.vault.azure.net/",
    "PAST_EMAIL_READ_INTERVAL_SECONDS": "3600",
    "TARGET_MAILBOX": "me"
  }
}
```

### Azure AD App Registration

Create an Azure AD App Registration with the following API permissions:
- **Microsoft Graph API**:
  - `Mail.Read` (Application permission) - to read emails from mailboxes
  - `User.Read.All` (Application permission) - if accessing other users' mailboxes

Generate a client secret and use the Application (client) ID, client secret, and tenant ID in your configuration.

### Key Vault Secrets (Recommended)

Store sensitive information in Azure Key Vault:
- `AZURE-CLIENT-ID`: Azure AD App Registration client ID
- `AZURE-CLIENT-SECRET`: Azure AD App Registration client secret
- `AZURE-TENANT-ID`: Azure tenant ID
- `TARGET-MAILBOX`: Target mailbox (use "me" for the app's mailbox or a user principal name)

## Authentication

The function uses Azure Managed Identity for authentication with Azure services:
- **Service Bus**: Uses DefaultAzureCredential
- **Key Vault**: Uses DefaultAzureCredential
- **Microsoft Graph**: Uses Client Credentials flow with Azure AD App Registration

For local development, you can use Azure CLI authentication:
```bash
az login
```

Ensure your Azure AD App Registration has the necessary Microsoft Graph permissions granted by an administrator.

## Building and Running

### Local Development

1. Install dependencies:
   ```bash
   mvn clean install
   ```

2. Start the function locally:
   ```bash
   mvn azure-functions:run
   ```

### Testing

Run unit tests:
```bash
mvn test
```

### Deployment

Deploy to Azure:
```bash
mvn azure-functions:deploy
```

## Email Processing

The function:

1. Connects to Microsoft Graph API using Azure AD App Registration credentials
2. Queries for emails received within the specified time interval using OData filters
3. Extracts metadata from each email:
   - Internet Message ID and Graph Message ID
   - Subject
   - Sender (address and name)
   - Recipients (To, CC, BCC)
   - Received date and sent date
   - Body preview
   - Attachment indicator
4. Sends the metadata as JSON to the configured Service Bus topic
5. Handles pagination for large result sets

### Message Format

The Service Bus messages contain email metadata in JSON format:

```json
{
  "messageId": "unique-internet-message-id",
  "graphMessageId": "graph-api-message-id",
  "subject": "Email subject",
  "from": "sender@domain.com",
  "fromName": "Sender Display Name",
  "toRecipients": "recipient1@domain.com;recipient2@domain.com",
  "ccRecipients": "cc1@domain.com;cc2@domain.com",
  "bccRecipients": "bcc1@domain.com",
  "allRecipients": "recipient1@domain.com;recipient2@domain.com;cc1@domain.com;cc2@domain.com;bcc1@domain.com",
  "receivedDate": "2026-02-24T21:05:53.000Z",
  "sentDate": "2026-02-24T20:55:43.000Z",
  "bodyPreview": "First 255 characters of email body...",
  "hasAttachments": true,
  "processedAt": "2026-02-24T21:05:53.123",
  "functionName": "PollMailbox",
  "source": "MicrosoftGraph"
}
```

## Monitoring

- View function execution logs in Azure Monitor
- Monitor Service Bus message processing
- Set up alerts for function failures or processing delays

## Troubleshooting

### Common Issues

1. **Authentication errors**: Ensure Azure AD App Registration is properly configured with correct permissions
2. **Graph API connection failures**: Verify client ID, client secret, and tenant ID are correct
3. **Service Bus errors**: Check Service Bus connection string and topic permissions
4. **Permission errors**: Ensure the app registration has Mail.Read permissions and admin consent is granted
5. **Mailbox access errors**: Verify the target mailbox exists and the app has access

### Logging

The function logs important events:
- Function start/completion
- Number of emails processed
- Errors during email processing or Service Bus operations

Check the Azure Functions logs or use Application Insights for detailed monitoring.

## Project Structure

```
src/
├── main/
│   └── java/
│       └── com/
│           └── microsoft/
│               └── azure/
│                   └── functions/
│                       └── PollMailbox.java
└── test/
    └── java/
        └── com/
            └── microsoft/
                └── azure/
                    └── functions/
                        └── PollMailboxTest.java
```

## License

This project is licensed under the MIT License.