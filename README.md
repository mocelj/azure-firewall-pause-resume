# Azure Firewall Pause/Resume Management Script

A bash script to manage Azure Firewall deallocate/allocate operations while preserving IP configurations and automatically updating User Defined Routes (UDRs) when the private IP changes.

## Features

- **Pause (deallocate)** - Stop the firewall and save IP configuration
- **Resume (allocate)** - Start the firewall with preserved IP configuration
- **Flexible storage** - Store configuration locally or in Azure Blob Storage for cross-machine access
- **Automatic UDR updates** - Update route tables when the firewall's private IP changes
- **Dry run mode** - Preview changes without executing them
- **Status check** - View current firewall status and IP configuration

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in (`az login`)
- [jq](https://stedolan.github.io/jq/) installed for JSON processing
- Bash shell (Linux, macOS, WSL, or Git Bash on Windows)

## Files

| File | Description |
|------|-------------|
| `azfw.sh` | Main script |
| `azfw.env` | Environment variables configuration |
| `udrs_sample.csv` | Sample UDR CSV file |
| `firewall_config.json` | Generated IP configuration (created by pause command) |

## Quick Start

### 1. Configure Environment Variables

Copy the template file and edit it with your Azure Firewall details:

```bash
cp azfw.env.template azfw.env
nano azfw.env
```

Example configuration:
```bash
# Firewall Resource Group
export RG="my-resource-group"

# Firewall Name
export FW="my-firewall"

# Virtual Network Resource Group
export VNET_RG="my-vnet-rg"

# Virtual Network Name
export VNET_NAME="my-vnet"

# Firewall Subnet Name
export FW_SUBNET_NAME="AzureFirewallSubnet"

# Path to save/load IP configuration JSON (used when STORAGE_MODE=local)
export CONFIG_FILE="./firewall_config.json"

# Path to UDR CSV file (optional)
export UDR_CSV_FILE="./udrs.csv"

# Storage mode: "local" (default) or "azure"
export STORAGE_MODE="local"

# Azure Storage Account (required when STORAGE_MODE=azure)
# export STORAGE_ACCOUNT="mystorageaccount"

# Azure Storage Container (default: firewall-config)
# export STORAGE_CONTAINER="firewall-config"
```

### 2. Source the Environment File

```bash
source ./azfw.env
```

### 3. Make the Script Executable

```bash
chmod +x azfw.sh
```

### 4. Run the Script

```bash
# Check firewall status
./azfw.sh status

# Pause firewall (dry run first)
./azfw.sh pause --dry-run

# Pause firewall (local storage - default)
./azfw.sh pause

# Resume firewall
./azfw.sh resume

# Pause firewall with Azure Blob Storage
./azfw.sh pause --storage-mode azure --storage-account mystorageaccount

# Resume firewall from Azure Blob Storage (from any machine)
./azfw.sh resume --storage-mode azure --storage-account mystorageaccount
```

## Commands

### `status`

Display the current firewall status and IP configuration.

```bash
./azfw.sh status
```

### `pause`

Deallocate the firewall and save the current IP configuration to a JSON file.

```bash
# Dry run (preview changes)
./azfw.sh pause --dry-run

# Execute pause
./azfw.sh pause

# With custom config file path
./azfw.sh pause -c /path/to/config.json
```

### `resume`

Allocate the firewall using the saved IP configuration.

```bash
# Dry run (preview changes)
./azfw.sh resume --dry-run

# Execute resume
./azfw.sh resume

# Resume with automatic UDR updates
./azfw.sh resume -u ./udrs.csv
```

### `help`

Display help information and usage examples.

```bash
./azfw.sh help
```

## Options

| Option | Description |
|--------|-------------|
| `--rg <name>` | Firewall resource group |
| `--fw <name>` | Firewall name |
| `--vnet-rg <name>` | Virtual network resource group |
| `--vnet <name>` | Virtual network name |
| `--subnet <name>` | Firewall subnet name (default: AzureFirewallSubnet) |
| `--config <path>` | Path to save/load IP configuration JSON (local mode) |
| `--udr-csv <path>` | CSV file with UDRs to update if private IP changes |
| `--storage-mode <mode>` | Storage mode: `local` (default) or `azure` |
| `--storage-account <name>` | Azure Storage Account name (required for azure mode) |
| `--storage-container <name>` | Azure Storage container name (default: firewall-config) |
| `--dry-run` | Preview changes without executing |
| `--verbose` | Enable detailed logging |
| `--help` | Show help message |

## Storage Modes

The script supports two storage modes for saving and loading firewall IP configuration:

### Local Storage (Default)

Stores configuration in a local JSON file. Best for single-machine usage.

```bash
# Uses local file (default behavior)
./azfw.sh pause --config ./firewall_config.json
./azfw.sh resume --config ./firewall_config.json
```

### Azure Blob Storage

Stores configuration in Azure Blob Storage. **Recommended for:**
- Resuming firewall from a different machine
- Team environments where multiple people may need to manage the firewall
- Centralized configuration management
- Disaster recovery scenarios

```bash
# Pause and store config in Azure Blob Storage
./azfw.sh pause --storage-mode azure --storage-account mystorageaccount

# Resume from any machine with Azure CLI access
./azfw.sh resume --storage-mode azure --storage-account mystorageaccount
```

**Requirements for Azure Storage mode:**
- Azure Storage Account with blob access
- Azure CLI logged in with permissions to:
  - `Microsoft.Storage/storageAccounts/blobServices/containers/read`
  - `Microsoft.Storage/storageAccounts/blobServices/containers/write`
  - `Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read`
  - `Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write`

The script uses `--auth-mode login` so no storage account keys are required.

**Blob naming convention:**
```
<container>/<resource-group>/<firewall-name>/config.json
```

## UDR CSV File Format

The CSV file should contain UDR definitions with the following columns:

```csv
resource_group,route_table_name,route_name
rg-spoke-01,rt-spoke-01,route-to-firewall
rg-spoke-02,rt-spoke-02,default-route
```

### Columns

| Column | Description |
|--------|-------------|
| `resource_group` | Resource group containing the route table |
| `route_table_name` | Name of the route table |
| `route_name` | Name of the route to update |

## IP Configuration File

The pause command generates a JSON file (`firewall_config.json`) with the following structure:

```json
{
  "timestamp": "2025-12-16T21:30:00+00:00",
  "firewall": {
    "name": "afw-dev-hub-s74ecrt7u",
    "resourceGroup": "rg-dev-hub-s74ecrt7u"
  },
  "virtualNetwork": {
    "name": "vn-dev-hub-s74ecrt7u-hub-01",
    "resourceGroup": "rg-dev-hub-s74ecrt7u",
    "firewallSubnet": "AzureFirewallSubnet"
  },
  "ipConfigurations": [
    {
      "name": "AzureFirewallIpConfiguration",
      "privateIPAddress": "10.1.2.4",
      "publicIPAddressId": "/subscriptions/.../pip-dev-hub-s74ecrt7u-azfw",
      "subnetId": "/subscriptions/.../AzureFirewallSubnet"
    }
  ]
}
```

## Important Notes

### Private IP Address Changes

> âš ï¸ **Warning**: When you deallocate and reallocate an Azure Firewall, the private IP address **may change**. This can break routing if your UDRs point to the old IP.

The script handles this by:
1. Saving the original private IP during pause
2. Comparing the new IP after resume
3. Automatically updating specified UDRs if the IP changes

### Billing

- Azure Firewall billing **stops** when deallocated
- Billing **resumes** when allocated
- Public IP addresses continue to incur charges

### Permissions Required

The executing user/service principal needs:
- `Microsoft.Network/azureFirewalls/read`
- `Microsoft.Network/azureFirewalls/write`
- `Microsoft.Network/publicIPAddresses/read`
- `Microsoft.Network/virtualNetworks/subnets/read`
- `Microsoft.Network/routeTables/routes/write` (for UDR updates)

**Additional permissions for Azure Storage mode:**
- `Storage Blob Data Contributor` role on the storage account, or:
  - `Microsoft.Storage/storageAccounts/blobServices/containers/read`
  - `Microsoft.Storage/storageAccounts/blobServices/containers/write`
  - `Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read`
  - `Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write`

## Examples

### Pause and Resume Workflow

```bash
# Source environment
source ./azfw.env

# Check current status
./azfw.sh status

# Preview pause operation
./azfw.sh pause --dry-run --verbose

# Execute pause (saves config to firewall_config.json)
./azfw.sh pause

# ... firewall is deallocated, no charges ...

# Preview resume operation
./azfw.sh resume --dry-run --verbose

# Execute resume with UDR updates
./azfw.sh resume -u ./udrs.csv
```

### Using Command Line Options

```bash
# Override default values
./azfw.sh status \
    --rg my-resource-group \
    --fw my-firewall \
    --vnet-rg my-vnet-rg \
    --vnet my-vnet

# Use custom local config file
./azfw.sh pause --config /backups/fw-config-$(date +%Y%m%d).json
```

### Cross-Machine Resume with Azure Storage

```bash
# On Machine A: Pause firewall and save to Azure Storage
./azfw.sh pause \
    --rg my-resource-group \
    --fw my-firewall \
    --vnet my-vnet \
    --storage-mode azure \
    --storage-account centralconfigstorage

# On Machine B: Resume firewall using config from Azure Storage
./azfw.sh resume \
    --rg my-resource-group \
    --fw my-firewall \
    --vnet my-vnet \
    --storage-mode azure \
    --storage-account centralconfigstorage \
    --udr-csv ./udrs.csv
```

## Troubleshooting

### "command not found" errors

The script has Windows line endings (CRLF). Convert to Unix format:

```bash
sed -i 's/\r$//' azfw.sh azfw.env
```

### "Firewall is already deallocated" when it's not

Run with `--verbose` to see debug output:

```bash
./azfw.sh pause --verbose
```

### Permission errors

Ensure you're logged in to Azure CLI with appropriate permissions:

```bash
az login
az account show
```

### jq not found

Install jq:

```bash
# Ubuntu/Debian
sudo apt-get install jq

# RHEL/CentOS
sudo yum install jq

# macOS
brew install jq
```

## License

MIT License
