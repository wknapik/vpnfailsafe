#!/usr/bin/env bash

set -eEuo pipefail

readonly dev
readonly ${!foreign_option_*}
readonly ifconfig_local
readonly ifconfig_netmask
readonly ${!proto_*}
readonly ${!remote_*}
readonly ${!remote_port_*}
readonly route_net_gateway
readonly route_vpn_gateway
readonly script_type
readonly trusted_ip

readonly prog="$(basename "$0")"
readonly private_nets="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
readonly -a remotes=($(env|grep -oP 'remote_[0-9]+=.*'|sort -g|cut -d= -f2))

# $@ := "up" | "down"
update_hosts() {
    pkill -P1 -f "bash $0" || true
    if [[ $@ == up ]]; then
        uh() {
            if remote_entries="$(getent -s dns hosts "${remotes[@]}"|grep -v :)"; then
                local -r beg="# VPNFAILSAFE BEGIN" end="# VPNFAILSAFE END"
                {
                    sed -e "/^$beg/,/^$end/d" /etc/hosts
                    echo -e "$beg\n$remote_entries\n$end"
                } >/etc/hosts.vpnfailsafe
                chmod --reference=/etc/hosts /etc/hosts.vpnfailsafe
                sync /etc/hosts.vpnfailsafe
                mv /etc/hosts.vpnfailsafe /etc/hosts
            fi
        }
        uh
        while true; do sleep 5m; uh; done& 
    fi
}

# $@ := "up" | "down"
update_routes() {
    remote_ips="$(getent -s files hosts "${remotes[@]}"|cut -d' ' -f1)"
    if [[ $@ == up ]]; then
        for remote_ip in $remote_ips; do
            if [[ -z $(ip route show "$remote_ip") ]]; then
                ip route add "$remote_ip" via "$route_net_gateway"
            fi
        done
        for net in 0.0.0.0/1 128.0.0.0/1; do
            [[ -z $(ip route show "$net") ]] && ip route add "$net" via "$route_vpn_gateway"
        done
    elif [[ $@ == down ]]; then
        for route in $remote_ips 0.0.0.0/1 128.0.0.0/1; do
            [[ -n $(ip route show "$route") ]] && ip route del "$route"
        done
        if [[ -n $(ip addr show dev "$dev" 2>/dev/null) ]]; then
            ip addr del "$ifconfig_local/$ifconfig_netmask" dev "$dev"
        fi
    fi
}

# $@ := "up" | "down"
update_resolv() {
    case "$@" in
        up) local domains="" ns=""
            for opt in "${!foreign_option_*}"; do
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
        local -r public_nic="$(ip route show "$trusted_ip"|cut -d' ' -f5)"
        local i=1; for remote in "${remotes[@]}"; do
            local port="remote_port_$i"
            local proto="proto_$i"
            iptables -A "VPNFAILSAFE_$*" -p "${!proto}" -"$sd" "$remote" --"$sd"port "${!port}" \
                -m conntrack --ctstate "$states"RELATED,ESTABLISHED -"$io" "${public_nic:?}" -j ACCEPT
            i=$((i + 1))
        done
    }

    # $@ := "INPUT" | "OUTPUT" | "FORWARD"
    pass_private_nets() { 
        case "$@" in
            INPUT) local -r sd=s io=i;;
            OUTPUT|FORWARD) local -r sd=d io=o;;
        esac
        if [[ $@ != FORWARD ]]; then
            iptables -A "VPNFAILSAFE_$*" -"$sd" "$ifconfig_local/$ifconfig_netmask" -"$io" "$dev" -j RETURN
        fi
        iptables -A "VPNFAILSAFE_$*" -"$sd" "$private_nets" ! -"$io" "$dev" -j RETURN
    }

    # $@ := "INPUT" | "OUTPUT" | "FORWARD"
    pass_vpn() {
        case "$@" in
            INPUT) local -r io=i
                   iptables -A "VPNFAILSAFE_$*" -s "$private_nets" -i "$dev" -j DROP;;
            OUTPUT|FORWARD) local -r io=o;;
        esac
        iptables -A "VPNFAILSAFE_$*" -"$io" "$dev" -j RETURN
    }

    # $@ := "INPUT" | "OUTPUT" | "FORWARD"
    drop_other() {
        iptables -A "VPNFAILSAFE_$*" -j DROP
    }

    for chain in INPUT OUTPUT FORWARD; do
        insert_chain "$chain"
        [[ $chain != FORWARD ]] && accept_remotes "$chain"
        pass_private_nets "$chain"
        pass_vpn "$chain"
        drop_other "$chain"
    done
}

# $@ := ""
cleanup() {
    update_resolv down
    update_routes down
    update_hosts down
}
trap cleanup INT TERM

# $@ := line_number exit_code
err_msg() {
    echo "$0:$1: \`$(sed -n "$1,+0{s/^\s*//;p}" "$0")\` returned $2" >&2
    cleanup
}
trap 'err_msg "$LINENO" "$?"' ERR

# $@ := ""
main() {
    local -r st="${script_type:-down}"
    update_hosts "$st"
    update_routes "$st"
    update_resolv "$st"
    if [[ $st == up ]]; then
        update_firewall
    fi
}

main
