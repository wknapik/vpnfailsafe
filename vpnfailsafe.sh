#!/usr/bin/env bash

set -eEuo pipefail

readonly prog="$(basename "$0")"
readonly private_nets="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
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

# $@ := ""
error() {
    exit 1
}

# $@ := "up" | "down"
update_hosts() {
    pkill -P1 -f "$prog" || true
    if [[ "$@" == up ]]; then
        uh() {
            local -r beg="# VPNFAILSAFE BEGIN" end="# VPNFAILSAFE END"
            local -ar remotes=($(env|grep -oP 'remote_[0-9]+=.*'|cut -d= -f2))
            local -r maybe_inplace="$([[ "$PPID" -eq 1 ]] && echo -i || echo)"
            {
                sed $maybe_inplace /etc/hosts -e "/^$beg/,/^$end/d" 
                echo "$beg"
                getent hosts "${remotes[@]}"|grep -v :
                echo "$end"
            } >/etc/hosts.vpnfailsafe
            chmod --reference=/etc/hosts /etc/hosts.vpnfailsafe
            mv /etc/hosts.vpnfailsafe /etc/hosts
        }
        uh
        while true; do sleep 5m; uh; done& 
    fi
}

# $@ := "up" | "down"
update_routes() {
    if [[ "$@" == up ]]; then
        if [[ -z $(ip route show "$trusted_ip") ]]; then
            ip route add "$trusted_ip/32" via "$route_net_gateway"
        fi
        for net in 0.0.0.0/1 128.0.0.0/1; do
            [[ -z $(ip route show "$net") ]] && ip route add "$net" via "$route_vpn_gateway"
        done
    elif [[ "$@" == down ]]; then
        for route in "$trusted_ip/32" 0.0.0.0/1 128.0.0.0/1; do
            [[ -n $(ip route show "$route") ]] && ip route del "$route"
        done
        if [[ -n $(ip addr show dev "$dev" 2>/dev/null) ]]; then
            ip addr del "$ifconfig_local/$ifconfig_netmask" dev "$dev"
        fi
    else
        error
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
        *) error;;
    esac
}

# $@ := ""
update_firewall() {
    local -r public_nic="$(ip route show "$trusted_ip"|cut -d' ' -f5)"

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
            *) error;;
        esac
        for remote in ${!remote_*}; do
            if [[ "$remote" =~ ^remote_[0-9]+$ ]]; then
                local port="remote_port_${remote##*_}"
                local proto="proto_${remote##*_}"
                iptables -A "VPNFAILSAFE_$*" -p "${!proto}" -"$sd" "${!remote}" --"$sd"port "${!port}" \
                    -m conntrack --ctstate "$states"RELATED,ESTABLISHED -"$io" "$public_nic" -j ACCEPT
            fi
        done
    }

    # $@ := "INPUT" | "OUTPUT" | "FORWARD"
    pass_private_nets() { 
        case "$@" in
            INPUT) local -r sd=s io=i;;
            OUTPUT|FORWARD) local -r sd=d io=o;;
            *) error;;
        esac
        if [[ "$@" != FORWARD ]]; then
            iptables -A "VPNFAILSAFE_$*" -"$sd" "$ifconfig_local/$ifconfig_netmask" -"$io" "$dev" -j RETURN
        fi
        iptables -A "VPNFAILSAFE_$*" -"$sd" "$private_nets" ! -"$io" "$dev" -j RETURN
    }

    # $@ := "INPUT" | "OUTPUT" | "FORWARD"
    pass_vpn() {
        case "$@" in
            INPUT)
                iptables -A "VPNFAILSAFE_$*" -s "$private_nets" -i "$dev" -j DROP
                local -r io=i;;
            OUTPUT|FORWARD)
                local -r io=o;;
            *) error;;
        esac
        iptables -A "VPNFAILSAFE_$*" -"$io" "$dev" -j RETURN
    }

    # $@ := "INPUT" | "OUTPUT" | "FORWARD"
    drop_other() {
        iptables -A "VPNFAILSAFE_$*" -j DROP
    }

    for chain in INPUT OUTPUT FORWARD; do
        insert_chain "$chain"
        [[ "$chain" != FORWARD ]] && accept_remotes "$chain"
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
    if [[ "${st}" == up ]]; then
        update_firewall
    fi
}

main
