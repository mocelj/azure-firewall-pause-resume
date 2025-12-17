#!/bin/bash
# ==============================================================================
# Azure Firewall Pause/Resume Script
# ==============================================================================
# This script allows you to pause (deallocate) and resume (allocate) an Azure
# Firewall while preserving its IP configuration. If the original private IP
# cannot be preserved during resume, it can optionally update specified UDRs.
# ==============================================================================

set -e

# Suppress Python deprecation warnings from Azure CLI
export PYTHONWARNINGS="ignore::UserWarning"

# ==============================================================================
# Configuration Variables (can be overridden by environment or azfw.env file)
# ==============================================================================
RG="${RG:-}"                           # Resource Group of the Firewall
FW="${FW:-}"                           # Firewall Name
VNET_RG="${VNET_RG:-}"                 # Resource Group of the VNet (if different)
VNET_NAME="${VNET_NAME:-}"             # VNet Name
FW_SUBNET_NAME="${FW_SUBNET_NAME:-AzureFirewallSubnet}"  # Firewall Subnet Name
CONFIG_FILE="${CONFIG_FILE:-firewall_config.json}"       # Local config file path
UDR_CSV_FILE="${UDR_CSV_FILE:-}"       # CSV file with UDR definitions
STORAGE_MODE="${STORAGE_MODE:-local}"  # Storage mode: local or azure
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-}" # Azure Storage Account name (for azure mode)
STORAGE_CONTAINER="${STORAGE_CONTAINER:-firewall-config}" # Azure Storage container name

# ==============================================================================
# Script Variables
# ==============================================================================
DRY_RUN=false
VERBOSE=false
ACTION=""

# ==============================================================================
# Color Output
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==============================================================================
# Logging Functions
# ==============================================================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

log_dry_run() {
    echo -e "${YELLOW}[DRY-RUN]${NC} $1" >&2
}

# ==============================================================================
# Help Function
# ==============================================================================
show_help() {
    cat << EOF
Azure Firewall Pause/Resume Script
===================================

USAGE:
    $(basename "$0") <action> [options]

ACTIONS:
    pause       Deallocate the firewall and save IP configuration
    resume      Allocate the firewall using saved IP configuration
    status      Show current firewall status
    help        Show this help message

OPTIONS:
    --rg <name>              Resource Group of the Firewall
    --fw <name>              Firewall Name
    --vnet-rg <name>         Resource Group of the VNet (if different from --rg)
    --vnet <name>            VNet Name
    --subnet <name>          Firewall Subnet Name (default: AzureFirewallSubnet)
    --config <path>          Path to local config file (default: firewall_config.json)
    --udr-csv <path>         Path to CSV file with UDR definitions
    --storage-mode <mode>    Storage mode: local or azure (default: local)
    --storage-account <name> Azure Storage Account name (required for azure mode)
    --storage-container <n>  Azure Storage container name (default: firewall-config)
    --dry-run                Show what would be done without making changes
    --verbose                Enable verbose output
    --help                   Show this help message

ENVIRONMENT VARIABLES:
    RG                  Resource Group of the Firewall
    FW                  Firewall Name
    VNET_RG             Resource Group of the VNet
    VNET_NAME           VNet Name
    FW_SUBNET_NAME      Firewall Subnet Name
    CONFIG_FILE         Path to local config file
    UDR_CSV_FILE        Path to CSV file with UDR definitions
    STORAGE_MODE        Storage mode: local or azure
    STORAGE_ACCOUNT     Azure Storage Account name
    STORAGE_CONTAINER   Azure Storage container name

STORAGE MODES:
    local               Store configuration in a local JSON file (default)
    azure               Store configuration in Azure Blob Storage
                        Requires: --storage-account or STORAGE_ACCOUNT env var

UDR CSV FORMAT:
    resource_group,route_table_name,route_name
    rg-spoke1,rt-spoke1,route-to-firewall
    rg-spoke2,rt-spoke2,default-route

EXAMPLES:
    # Pause firewall (local storage - default)
    $(basename "$0") pause --rg myRG --fw myFirewall --vnet myVNet

    # Pause firewall (Azure storage)
    $(basename "$0") pause --rg myRG --fw myFirewall --vnet myVNet \\
        --storage-mode azure --storage-account mystorageaccount

    # Resume firewall with UDR updates if needed (local storage)
    $(basename "$0") resume --rg myRG --fw myFirewall --vnet myVNet --udr-csv udrs.csv

    # Resume firewall from Azure storage
    $(basename "$0") resume --rg myRG --fw myFirewall --vnet myVNet \\
        --storage-mode azure --storage-account mystorageaccount --udr-csv udrs.csv

    # Dry run to see what would happen
    $(basename "$0") pause --rg myRG --fw myFirewall --vnet myVNet --dry-run

    # Check firewall status
    $(basename "$0") status --rg myRG --fw myFirewall

    # Using environment file
    source azfw.env && $(basename "$0") pause

EOF
}

# ==============================================================================
# Validation Functions
# ==============================================================================
validate_required_params() {
    local missing=()
    
    [[ -z "$RG" ]] && missing+=("RG (--rg)")
    [[ -z "$FW" ]] && missing+=("FW (--fw)")
    [[ -z "$VNET_NAME" ]] && missing+=("VNET_NAME (--vnet)")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required parameters:"
        for param in "${missing[@]}"; do
            echo "  - $param"
        done
        echo ""
        echo "Use --help for usage information"
        exit 1
    fi
    
    # Default VNET_RG to RG if not specified
    VNET_RG="${VNET_RG:-$RG}"
}

validate_storage_config() {
    if [[ "$STORAGE_MODE" == "azure" ]]; then
        if [[ -z "$STORAGE_ACCOUNT" ]]; then
            log_error "Azure storage mode requires --storage-account or STORAGE_ACCOUNT env var"
            exit 1
        fi
        log_debug "Using Azure Blob Storage: account=$STORAGE_ACCOUNT, container=$STORAGE_CONTAINER"
    else
        log_debug "Using local file storage: $CONFIG_FILE"
    fi
}

# ==============================================================================
# Azure Blob Storage Functions
# ==============================================================================
get_blob_name() {
    # Generate blob name based on firewall identity
    echo "${RG}/${FW}/config.json"
}

ensure_storage_container() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would ensure storage container '$STORAGE_CONTAINER' exists in account '$STORAGE_ACCOUNT'"
        return 0
    fi
    
    log_debug "Ensuring storage container '$STORAGE_CONTAINER' exists..."
    
    # Check if container exists, create if not
    if ! az storage container show \
        --name "$STORAGE_CONTAINER" \
        --account-name "$STORAGE_ACCOUNT" \
        --auth-mode login \
        --output none 2>/dev/null; then
        
        log_info "Creating storage container '$STORAGE_CONTAINER'..."
        az storage container create \
            --name "$STORAGE_CONTAINER" \
            --account-name "$STORAGE_ACCOUNT" \
            --auth-mode login \
            --output none
    fi
}

upload_config_to_blob() {
    local config_content="$1"
    local blob_name=$(get_blob_name)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would upload configuration to blob '$blob_name' in container '$STORAGE_CONTAINER'"
        return 0
    fi
    
    ensure_storage_container
    
    log_info "Uploading configuration to Azure Blob Storage..."
    log_debug "Blob path: $STORAGE_ACCOUNT/$STORAGE_CONTAINER/$blob_name"
    
    # Write to temp file and upload
    local temp_file=$(mktemp)
    echo "$config_content" > "$temp_file"
    
    az storage blob upload \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$STORAGE_CONTAINER" \
        --name "$blob_name" \
        --file "$temp_file" \
        --auth-mode login \
        --overwrite \
        --output none
    
    rm -f "$temp_file"
    log_info "Configuration uploaded to Azure Blob Storage"
}

download_config_from_blob() {
    local blob_name=$(get_blob_name)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would download configuration from blob '$blob_name'"
        return 0
    fi
    
    log_info "Downloading configuration from Azure Blob Storage..."
    log_debug "Blob path: $STORAGE_ACCOUNT/$STORAGE_CONTAINER/$blob_name"
    
    local temp_file=$(mktemp)
    
    if ! az storage blob download \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$STORAGE_CONTAINER" \
        --name "$blob_name" \
        --file "$temp_file" \
        --auth-mode login \
        --output none 2>/dev/null; then
        
        log_error "Failed to download configuration from Azure Blob Storage"
        log_error "Blob '$blob_name' may not exist in container '$STORAGE_CONTAINER'"
        rm -f "$temp_file"
        exit 1
    fi
    
    cat "$temp_file"
    rm -f "$temp_file"
}

# ==============================================================================
# Firewall Functions
# ==============================================================================
get_firewall_status() {
    log_debug "Getting firewall status..."
    
    local fw_info
    # Capture only stdout, discard stderr (Azure CLI warnings)
    fw_info=$(az network firewall show \
        --resource-group "$RG" \
        --name "$FW" \
        --output json 2>/dev/null)
    
    local exit_code=$?
    
    # If the command failed, try again with stderr to get error message
    if [[ $exit_code -ne 0 ]] || [[ -z "$fw_info" ]]; then
        local error_msg
        error_msg=$(az network firewall show \
            --resource-group "$RG" \
            --name "$FW" \
            --output json 2>&1)
        log_error "Failed to get firewall information. Please check:"
        log_error "  - Resource group '$RG' exists"
        log_error "  - Firewall '$FW' exists"
        log_error "  - You have proper permissions"
        log_debug "Error: $error_msg"
        exit 1
    fi
    
    # Extract JSON by finding the first { and keeping everything from there
    fw_info=$(echo "$fw_info" | sed -n '/^{/,$p')
    
    # Validate it's valid JSON
    if ! echo "$fw_info" | jq empty 2>/dev/null; then
        log_error "Failed to parse firewall status as JSON"
        exit 1
    fi
    
    echo "$fw_info"
}

get_ip_config_count() {
    local fw_info="$1"
    echo "$fw_info" | jq '.ipConfigurations | length'
}

save_ip_configuration() {
    local fw_info="$1"
    
    log_info "Extracting IP configuration..."
    
    local ip_configs
    ip_configs=$(echo "$fw_info" | jq '{
        ipConfigurations: .ipConfigurations,
        managementIpConfiguration: .managementIpConfiguration,
        firewallName: .name,
        resourceGroup: .resourceGroup,
        savedAt: now | todate
    }')
    
    if [[ "$STORAGE_MODE" == "azure" ]]; then
        upload_config_to_blob "$ip_configs"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry_run "Would save IP configuration to $CONFIG_FILE"
            log_debug "Configuration content:"
            echo "$ip_configs" | jq '.'
        else
            echo "$ip_configs" > "$CONFIG_FILE"
            log_info "IP configuration saved to $CONFIG_FILE"
        fi
    fi
    
    # Display saved configuration
    local ip_count
    ip_count=$(echo "$ip_configs" | jq '.ipConfigurations | length')
    log_info "Saved $ip_count IP configuration(s)"
    
    echo "$ip_configs" | jq -r '.ipConfigurations[] | "  - \(.name): Private IP: \(.privateIPAddress // .privateIpAddress // "N/A")"'
}

load_ip_configuration() {
    local config_content
    
    if [[ "$STORAGE_MODE" == "azure" ]]; then
        config_content=$(download_config_from_blob)
    else
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_error "Configuration file not found: $CONFIG_FILE"
            log_error "Please run 'pause' first to save the configuration, or check the file path"
            exit 1
        fi
        config_content=$(cat "$CONFIG_FILE")
    fi
    
    echo "$config_content"
}

deallocate_firewall() {
    log_info "Deallocating firewall '$FW'..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would deallocate firewall '$FW' in resource group '$RG'"
        return 0
    fi
    
    # Get list of all IP configuration names
    local ip_config_names
    ip_config_names=$(az network firewall show \
        --resource-group "$RG" \
        --name "$FW" \
        --query "ipConfigurations[].name" \
        --output tsv)
    
    if [[ -z "$ip_config_names" ]]; then
        log_warn "No IP configurations found to remove"
        return 0
    fi
    
    # Delete each IP configuration explicitly
    for config_name in $ip_config_names; do
        log_info "Removing IP configuration: $config_name"
        az network firewall ip-config delete \
            --resource-group "$RG" \
            --firewall-name "$FW" \
            --name "$config_name" \
            --output none
    done
    
    log_info "Firewall deallocation initiated, waiting for completion..."
    
    # Wait for deallocation to complete by checking IP configuration count
    local max_wait=600  # 10 minutes max
    local wait_time=0
    local check_interval=15
    
    while [[ $wait_time -lt $max_wait ]]; do
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
        
        local current_status
        current_status=$(az network firewall show \
            --resource-group "$RG" \
            --name "$FW" \
            --output json 2>/dev/null)
        
        local ip_count
        ip_count=$(echo "$current_status" | jq '.ipConfigurations | length')
        
        if [[ "$ip_count" -eq 0 ]]; then
            log_info "Firewall deallocated successfully"
            return 0
        fi
        
        log_debug "Still waiting for deallocation... (${wait_time}s elapsed, IP configs: $ip_count)"
    done
    
    log_warn "Deallocation is taking longer than expected. The firewall may still be deallocating."
}

allocate_firewall() {
    local saved_config="$1"
    
    log_info "Allocating firewall '$FW'..."
    
    # Get the first IP configuration (primary)
    local primary_config
    primary_config=$(echo "$saved_config" | jq '.ipConfigurations[0]')
    
    local config_name
    config_name=$(echo "$primary_config" | jq -r '.name')
    
    # Handle both formats: publicIPAddress.id (capital IP), publicIpAddress.id, or publicIPAddressId (legacy)
    local public_ip_id
    public_ip_id=$(echo "$primary_config" | jq -r '.publicIPAddress.id // .publicIpAddress.id // .publicIPAddressId // empty')
    
    # Handle both formats: privateIPAddress (capital IP) or privateIpAddress
    local original_private_ip
    original_private_ip=$(echo "$primary_config" | jq -r '.privateIPAddress // .privateIpAddress // empty')
    
    if [[ -z "$public_ip_id" || "$public_ip_id" == "null" ]]; then
        log_error "Could not extract public IP address ID from saved configuration"
        log_error "Please check the configuration file format"
        exit 1
    fi
    
    log_debug "Primary config name: $config_name"
    log_debug "Public IP ID: $public_ip_id"
    log_debug "Original private IP: $original_private_ip"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would allocate firewall with:"
        log_dry_run "  Config name: $config_name"
        log_dry_run "  VNet: $VNET_NAME (RG: $VNET_RG)"
        log_dry_run "  Subnet: $FW_SUBNET_NAME"
        log_dry_run "  Public IP: $public_ip_id"
        return 0
    fi
    
    # Extract public IP name from the resource ID
    local public_ip_name
    public_ip_name=$(echo "$public_ip_id" | awk -F'/' '{print $NF}')
    
    log_debug "Public IP name: $public_ip_name"
    log_debug "VNet: $VNET_NAME (RG: $VNET_RG)"
    
    # Use ip-config create with --vnet-name (automatically uses AzureFirewallSubnet)
    log_info "Adding IP configuration to firewall..."
    if ! az network firewall ip-config create \
        --resource-group "$RG" \
        --firewall-name "$FW" \
        --name "$config_name" \
        --vnet-name "$VNET_NAME" \
        --public-ip-address "$public_ip_name" \
        --output none 2>&1 | grep -v "UserWarning"; then
        
        log_error "Failed to add firewall IP configuration"
        log_error "Please check:"
        log_error "  - VNet '$VNET_NAME' exists in resource group '$VNET_RG'"
        log_error "  - Public IP '$public_ip_name' exists"
        log_error "  - AzureFirewallSubnet exists in the VNet"
        log_error "  - You have proper permissions"
        exit 1
    fi
    
    log_info "Firewall allocation initiated, waiting for completion..."
    
    # Wait for allocation and check private IP
    sleep 30  # Initial wait for allocation to start
    
    local max_wait=300
    local wait_time=30
    local check_interval=15
    local new_private_ip=""
    
    while [[ $wait_time -lt $max_wait ]]; do
        local current_status
        current_status=$(az network firewall show \
            --resource-group "$RG" \
            --name "$FW" \
            --output json 2>/dev/null)
        
        # Handle both formats: privateIPAddress (capital IP) or privateIpAddress
        new_private_ip=$(echo "$current_status" | jq -r '.ipConfigurations[0].privateIPAddress // .ipConfigurations[0].privateIpAddress // empty')
        
        if [[ -n "$new_private_ip" ]]; then
            break
        fi
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
        log_debug "Waiting for allocation... (${wait_time}s elapsed)"
    done
    
    if [[ -z "$new_private_ip" ]]; then
        log_error "Failed to get new private IP after allocation"
        exit 1
    fi
    
    log_info "Firewall allocated successfully"
    log_info "New private IP: $new_private_ip"
    
    # Check if private IP changed
    if [[ -n "$original_private_ip" && "$original_private_ip" != "$new_private_ip" ]]; then
        log_warn "Private IP changed from $original_private_ip to $new_private_ip"
        echo "$new_private_ip"
    else
        log_info "Private IP preserved: $new_private_ip"
        echo ""
    fi
}

update_udrs() {
    local new_private_ip="$1"
    
    if [[ -z "$UDR_CSV_FILE" ]]; then
        log_warn "No UDR CSV file specified. Skipping UDR updates."
        log_warn "You may need to manually update routes pointing to the firewall."
        return 0
    fi
    
    if [[ ! -f "$UDR_CSV_FILE" ]]; then
        log_error "UDR CSV file not found: $UDR_CSV_FILE"
        return 1
    fi
    
    log_info "Updating UDRs with new private IP: $new_private_ip"
    
    # Skip header line and process each UDR
    local line_num=0
    while IFS=',' read -r udr_rg route_table route_name || [[ -n "$udr_rg" ]]; do
        line_num=$((line_num + 1))
        
        # Skip header
        if [[ $line_num -eq 1 && "$udr_rg" == "resource_group" ]]; then
            continue
        fi
        
        # Skip empty lines
        [[ -z "$udr_rg" ]] && continue
        
        # Trim whitespace
        udr_rg=$(echo "$udr_rg" | xargs)
        route_table=$(echo "$route_table" | xargs)
        route_name=$(echo "$route_name" | xargs)
        
        log_info "Updating route: $route_table/$route_name in $udr_rg"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry_run "Would update route '$route_name' in table '$route_table' (RG: $udr_rg) with next-hop $new_private_ip"
            continue
        fi
        
        az network route-table route update \
            --resource-group "$udr_rg" \
            --route-table-name "$route_table" \
            --name "$route_name" \
            --next-hop-ip-address "$new_private_ip" \
            --output none || {
            log_warn "Failed to update route $route_name in $route_table"
        }
        
    done < "$UDR_CSV_FILE"
    
    log_info "UDR updates completed"
}

# ==============================================================================
# Action Functions
# ==============================================================================
pause_firewall() {
    log_info "=== Pausing Azure Firewall ==="
    log_info "Firewall: $FW"
    log_info "Resource Group: $RG"
    log_info "Storage Mode: $STORAGE_MODE"
    [[ "$STORAGE_MODE" == "azure" ]] && log_info "Storage Account: $STORAGE_ACCOUNT"
    echo ""
    
    # Get current firewall status
    local fw_info
    fw_info=$(get_firewall_status)
    
    # Check if already deallocated
    local ip_count
    ip_count=$(get_ip_config_count "$fw_info")
    
    if [[ "$ip_count" -eq 0 ]]; then
        log_warn "Firewall is already deallocated (no IP configurations)"
        exit 0
    fi
    
    log_info "Current IP configurations: $ip_count"
    
    # Save IP configuration
    save_ip_configuration "$fw_info"
    
    # Deallocate firewall
    deallocate_firewall
    
    echo ""
    log_info "=== Firewall Paused Successfully ==="
}

resume_firewall() {
    log_info "=== Resuming Azure Firewall ==="
    log_info "Firewall: $FW"
    log_info "Resource Group: $RG"
    log_info "Storage Mode: $STORAGE_MODE"
    [[ "$STORAGE_MODE" == "azure" ]] && log_info "Storage Account: $STORAGE_ACCOUNT"
    echo ""
    
    # Get current firewall status
    local fw_info
    fw_info=$(get_firewall_status)
    
    # Check if already allocated
    local ip_count
    ip_count=$(get_ip_config_count "$fw_info")
    
    if [[ "$ip_count" -gt 0 ]]; then
        log_warn "Firewall already has $ip_count IP configuration(s)"
        log_warn "It appears to be already allocated"
        exit 0
    fi
    
    # Load saved configuration
    local saved_config
    saved_config=$(load_ip_configuration)
    
    log_debug "Raw config content:"
    log_debug "$saved_config"
    
    log_info "Loaded saved configuration:"
    echo "$saved_config" | jq -r '.ipConfigurations[] | "  - \(.name): Private IP: \(.privateIpAddress // .privateIPAddress // "N/A")"'
    echo ""
    
    # Allocate firewall
    local ip_changed
    ip_changed=$(allocate_firewall "$saved_config")
    
    # Update UDRs if IP changed
    if [[ -n "$ip_changed" ]]; then
        update_udrs "$ip_changed"
    fi
    
    echo ""
    log_info "=== Firewall Resumed Successfully ==="
}

show_status() {
    log_info "=== Azure Firewall Status ==="
    log_info "Firewall: $FW"
    log_info "Resource Group: $RG"
    echo ""
    
    local fw_info
    fw_info=$(get_firewall_status)
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_debug "Firewall info length: ${#fw_info}"
        log_debug "First 200 chars: ${fw_info:0:200}"
    fi
    
    local provisioning_state
    provisioning_state=$(echo "$fw_info" | jq -r '.provisioningState')
    
    local ip_count
    ip_count=$(get_ip_config_count "$fw_info")
    
    echo "Provisioning State: $provisioning_state"
    echo "IP Configurations: $ip_count"
    echo ""
    
    if [[ "$ip_count" -gt 0 ]]; then
        echo "IP Configuration Details:"
        # Debug: Show the first IP configuration raw data
        if [[ "$VERBOSE" == "true" ]]; then
            log_debug "Raw IP Configuration:"
            echo "$fw_info" | jq '.ipConfigurations[0]' >&2
        fi
        echo "$fw_info" | jq -r '.ipConfigurations[] | "  - " + .name + ":\n      Private IP: " + (.privateIpAddress // .privateIPAddress // "N/A") + "\n      Public IP: " + ((.publicIpAddress.id // .publicIPAddress.id // .publicIPAddressId // null) | if . != null then (split("/") | .[-1]) else "N/A" end)'
        echo ""
        log_info "Firewall Status: ALLOCATED (Running)"
    else
        log_info "Firewall Status: DEALLOCATED (Paused)"
    fi
    
    # Check for saved configuration
    echo ""
    if [[ "$STORAGE_MODE" == "azure" ]]; then
        if [[ -n "$STORAGE_ACCOUNT" ]]; then
            log_info "Storage Mode: Azure Blob Storage"
            log_info "Storage Account: $STORAGE_ACCOUNT"
            log_info "Container: $STORAGE_CONTAINER"
        else
            log_info "Storage Mode: Azure (not configured)"
        fi
    else
        if [[ -f "$CONFIG_FILE" ]]; then
            log_info "Saved configuration found: $CONFIG_FILE"
            log_debug "Saved at: $(jq -r '.savedAt' "$CONFIG_FILE" 2>/dev/null || echo 'unknown')"
        else
            log_info "No saved local configuration found"
        fi
    fi
}

# ==============================================================================
# Argument Parsing
# ==============================================================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            pause|resume|status|help)
                ACTION="$1"
                shift
                ;;
            --rg)
                RG="$2"
                shift 2
                ;;
            --fw)
                FW="$2"
                shift 2
                ;;
            --vnet-rg)
                VNET_RG="$2"
                shift 2
                ;;
            --vnet)
                VNET_NAME="$2"
                shift 2
                ;;
            --subnet)
                FW_SUBNET_NAME="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --udr-csv)
                UDR_CSV_FILE="$2"
                shift 2
                ;;
            --storage-mode)
                STORAGE_MODE="$2"
                if [[ "$STORAGE_MODE" != "local" && "$STORAGE_MODE" != "azure" ]]; then
                    log_error "Invalid storage mode: $STORAGE_MODE (must be 'local' or 'azure')"
                    exit 1
                fi
                shift 2
                ;;
            --storage-account)
                STORAGE_ACCOUNT="$2"
                shift 2
                ;;
            --storage-container)
                STORAGE_CONTAINER="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    parse_arguments "$@"
    
    # Show help if no action specified
    if [[ -z "$ACTION" ]]; then
        show_help
        exit 0
    fi
    
    # Handle help action
    if [[ "$ACTION" == "help" ]]; then
        show_help
        exit 0
    fi
    
    # Validate parameters for actions that need them
    if [[ "$ACTION" != "help" ]]; then
        validate_required_params
        validate_storage_config
    fi
    
    # Show dry-run notice
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi
    
    # Execute action
    case $ACTION in
        pause)
            pause_firewall
            ;;
        resume)
            resume_firewall
            ;;
        status)
            show_status
            ;;
        *)
            log_error "Unknown action: $ACTION"
            exit 1
            ;;
    esac
}

main "$@"
