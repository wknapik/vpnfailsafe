#!/usr/bin/env bash

set -eEuo pipefail

readonly dev
readonly ${!foreign_option_*}
readonly ifconfig_local
readonly ifconfig_netmask # either (subnet)
readonly ifconfig_remote # or (p2p/net30)
readonly ${!proto_*}
readonly ${!remote_*}
readonly ${!remote_port_*}
readonly route_net_gateway
readonly route_vpn_gateway
readonly script_type
readonly trusted_ip
readonly trusted_port
readonly untrusted_ip
readonly untrusted_port

readonly prog="$(basename "$0")"
readonly private_nets="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
readonly -a remotes=($(env|grep -oP 'remote_[0-9]+=.*'|sort -n|cut -d= -f2))
readonly -a cnf_remote_domains=(${remotes[@]%%*[0-9]})
readonly -a cnf_remote_ips=(${remotes[@]##*[!0-9.]*})
readonly cur_remote_ip="${trusted_ip:-$untrusted_ip}"
readonly cur_port="${trusted_port:-$untrusted_port}"

# $@ := ""
update_hosts() {
    if remote_entries="$(getent -s dns hosts "${cnf_remote_domains[@]:-}"|grep -v :)"; then
        local -r beg="# VPNFAILSAFE BEGIN" end="# VPNFAILSAFE END"
        {
            sed -e "/^$beg/,/^$end/d" /etc/hosts
            echo -e "$beg\n$remote_entries\n$end"
        } >/etc/hosts.vpnfailsafe
        chmod --reference=/etc/hosts /etc/hosts.vpnfailsafe
        mv /etc/hosts.vpnfailsafe /etc/hosts
    fi
}

# $@ := "up" | "down"
update_routes() {
    local -ar resolved_ips=($(getent -s files hosts "${cnf_remote_domains[@]:-nonexistent}"|cut -d' ' -f1 || true))
    local -ar remote_ips=("${resolved_ips[@]:-}" "${cnf_remote_ips[@]:-}")
    if [[ $@ == up ]]; then
        for remote_ip in "$cur_remote_ip" "${remote_ips[@]:-}"; do
            if [[ -n $remote_ip && -z $(ip route show "$remote_ip") ]]; then
                ip route add "$remote_ip" via "$route_net_gateway"
            fi
        done
        for net in 0.0.0.0/1 128.0.0.0/1; do
            if [[ -z $(ip route show "$net") ]]; then
                ip route add "$net" via "$route_vpn_gateway"
            fi
        done
    elif [[ $@ == down ]]; then
        for route in "$cur_remote_ip" "${remote_ips[@]:-}" 0.0.0.0/1 128.0.0.0/1; do
            if [[ -n $route && -n $(ip route show "$route") ]]; then
                ip route del "$route"
            fi
        done
    fi
}

# $@ := "up" | "down"
update_resolv() {
    case "$@" in
        up) local domains="" ns=""
            for opt in ${!foreign_option_*}; do
                case "${!opt}" in
                    dhcp-option\ DOMAIN*) domains+="${!opt##* }";;
                    dhcp-option\ DNS\ *) ns+=" ${!opt##* }";;
                    *) ;;
                esac
            done
            echo -e "${domains/ /search }\n${ns// /$'\n'nameserver }"|resolvconf -a "$dev";;
        down) resolvconf -d "$dev" 2>/dev/null || true;;
    esac
}

# $@ := ""
update_firewall() {
    # $@ := "INPUT" | "OUTPUT" | "FORWARD"
    insert_chain() {
        if iptables -C "$*" -j "VPNFAILSAFE_$*" 2>/dev/null; then
            iptables -D "$*" -j "VPNFAILSAFE_$*"
            for opt in F X; do
                iptables -"$opt" "VPNFAILSAFE_$*"
            done
        fi
        iptables -N "VPNFAILSAFE_$*"
        iptables -I "$*" -j "VPNFAILSAFE_$*"
    }

    # $@ := "INPUT" | "OUTPUT"
    accept_remotes() {
        case "$@" in
            INPUT)  local -r sd=s states=""   io=i;;
            OUTPUT) local -r sd=d states=NEW, io=o;;
        esac
        local -r public_nic="$(ip route show "$cur_remote_ip"|cut -d' ' -f5)"
        local -ar suf=(-m conntrack --ctstate "$states"RELATED,ESTABLISHED -"$io" "${public_nic:?}" -j ACCEPT)
        for ((i=1; i <= ${#remotes[*]}; ++i)); do
            local port="remote_port_$i"
            local proto="proto_$i"
            iptables -A "VPNFAILSAFE_$*" -p "${!proto%-client}" -"$sd" "${remotes[i-1]}" --"$sd"port "${!port}" "${suf[@]}"
        done
        if ! iptables -S|grep -q -- "^-A VPNFAILSAFE_$* .*-$sd $cur_remote_ip/32 .*-j ACCEPT$"; then
            for p in tcp udp; do
                iptables -A "VPNFAILSAFE_$*" -p "$p" -"$sd" "$cur_remote_ip" --"$sd"port "${cur_port}" "${suf[@]}"
            done
        fi
    }

    # $@ := "INPUT" | "OUTPUT" | "FORWARD"
    pass_private_nets() { 
        case "$@" in
            INPUT) local -r sd=s io=i;;&
            OUTPUT|FORWARD) local -r sd=d io=o;;&
            INPUT|OUTPUT) local -r vpn="${ifconfig_remote:-$ifconfig_local}/${ifconfig_netmask:-32}"
               iptables -A "VPNFAILSAFE_$*" -"$sd" "$vpn" -"$io" "$dev" -j RETURN;;&
            *) iptables -A "VPNFAILSAFE_$*" -"$sd" "$private_nets" ! -"$io" "$dev" -j RETURN;;&
            INPUT) iptables -A "VPNFAILSAFE_$*" -s "$private_nets" -i "$dev" -j DROP;;&
            *) iptables -A "VPNFAILSAFE_$*" -"$io" "$dev" -j RETURN;;
        esac
    }

    # $@ := "INPUT" | "OUTPUT" | "FORWARD"
    drop_other() {
        iptables -A "VPNFAILSAFE_$*" -j DROP
    }

    for chain in INPUT OUTPUT FORWARD; do
        insert_chain "$chain"
        [[ $chain != FORWARD ]] && accept_remotes "$chain"
        pass_private_nets "$chain"
        drop_other "$chain"
    done
}

# $@ := ""
cleanup() {
    update_resolv down
    update_routes down
}
trap cleanup INT TERM

# $@ := line_number exit_code
err_msg() {
    echo "$0:$1: \`$(sed -n "$1,+0{s/^\s*//;p}" "$0")' returned $2" >&2
    cleanup
}
trap 'err_msg "$LINENO" "$?"' ERR

# $@ := ""
main() {
    case "${script_type:-down}" in
        up) for f in hosts routes resolv firewall; do "update_$f" up; done;;
        down) update_routes down
              update_resolv down;;
    esac
}

main
