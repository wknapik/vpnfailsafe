#!/usr/bin/env bash

# After the OpenVPN connection is closed and vpnfailsafe has been called
# (--down), firewall rules remain in place to prevent IP leaks.
# This script completely disables vpnfailsafe and restores the system to the
# previous state.

set -euo pipefail

# Remove /etc/hosts entries.
sed -i /etc/hosts -e '/^# VPNFAILSAFE BEGIN/,/^# VPNFAILSAFE END/d'

# Remove firewall rules.
for chain in INPUT OUTPUT FORWARD; do
    if iptables -C "$chain" -j "VPNFAILSAFE_$chain" 2>/dev/null; then
        iptables -D "$chain" -j "VPNFAILSAFE_$chain"
        iptables -F "VPNFAILSAFE_$chain"
        iptables -X "VPNFAILSAFE_$chain"
    fi
done
