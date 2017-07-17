#!/usr/bin/env bash

set -euo pipefail

# Clear all existing firewall rules.
iptables -F
iptables -X
for table in nat mangle raw security; do
    for opt in -F -X; do
        iptables -t "$table" "$opt"
    done
done

# Only allow inbound traffic we requested.
iptables -P INPUT DROP
iptables -P OUTPUT ACCEPT
iptables -P FORWARD DROP
iptables -I INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
