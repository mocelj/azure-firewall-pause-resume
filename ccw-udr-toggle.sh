#!/usr/bin/env bash
set -euo pipefail

# Toggle UDR association on ccw-vnet subnets (demo convenience script)
# Usage: ./scripts/ccw-udr-toggle.sh pause   — remove UDRs from subnets
#        ./scripts/ccw-udr-toggle.sh resume  — re-attach UDRs to subnets

RG="rg-swec-ccws-modr"
VNET="ccw-vnet"
RT_NAME="rt-ccw-to-hub-fw"
SUBNETS=("ccw-cyclecloud-subnet" "ccw-compute-subnet")

ACTION="${1:-}"

if [[ -z "${ACTION}" || ( "${ACTION}" != "pause" && "${ACTION}" != "resume" ) ]]; then
    echo "Usage: $0 {pause|resume}"
    echo ""
    echo "  pause   — Remove UDR from ccw subnets (VPN direct, no firewall)"
    echo "  resume  — Re-attach UDR to ccw subnets (traffic via firewall)"
    exit 1
fi

if [[ "${ACTION}" == "pause" ]]; then
    echo "Removing UDR '${RT_NAME}' from ccw subnets..."
    for subnet in "${SUBNETS[@]}"; do
        echo "  → ${subnet}"
        az network vnet subnet update \
            --name "${subnet}" \
            --resource-group "${RG}" \
            --vnet-name "${VNET}" \
            --remove routeTable \
            -o none
    done
    echo "Done. UDRs removed — traffic bypasses firewall."
    echo "VPN access works directly. No spoke-to-spoke transit."

elif [[ "${ACTION}" == "resume" ]]; then
    echo "Re-attaching UDR '${RT_NAME}' to ccw subnets..."
    for subnet in "${SUBNETS[@]}"; do
        echo "  → ${subnet}"
        az network vnet subnet update \
            --name "${subnet}" \
            --resource-group "${RG}" \
            --vnet-name "${VNET}" \
            --route-table "${RT_NAME}" \
            -o none
    done
    echo "Done. UDRs re-attached — traffic routes via firewall (10.1.2.4)."
fi
