#!/usr/bin/env bash

set -euo pipefail

# Clear all existing ipv6 firewall rules.
ip6tables -F
ip6tables -X
for table in nat mangle raw security; do
    for opt in -F -X; do
        ip6tables -t "$table" "$opt"
    done
done

# Drop all ipv6 traffic.
for chain in INPUT OUTPUT FORWARD; do
    ip6tables -P "$chain" DROP
done
