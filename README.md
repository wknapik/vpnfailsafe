# What is vpnfailsafe ?

`vpnfailsafe` prevents a VPN user's ISP-assigned IP address from being exposed
on the internet, both while the VPN connection is active and when it goes down.

`vpnfailsafe` doesn't affect traffic to/from private networks, or disrupt existing
firewall rules beyond its intended function.

# How does it work ?

`vpnfailsafe` ensures that all traffic to/from the internet goes through the VPN.
It is meant to be executed by OpenVPN when the tunnel is established (--up), or
torn down (--down). 

On --up:
* All configured VPN server domains are resolved and saved in /etc/hosts.
* Routes are set up, so that all traffic to the internet goes over the tunnel.
  The original default route is preserved and two more specific ones are added
  (mimicking --redirect-gateway def1) + routes to all configured VPN servers
  are added.
* /etc/resolv.conf is updated, so only the DNS pushed by the VPN server is used.
* iptables rules are inserted at the beginning of INPUT, OUTPUT and FORWARD
  chains to ensure that the only traffic to/from the internet is between the
  VPN client and the VPN server.

On --down:
* The /etc/hosts entries for VPN servers remain in place, so the VPN connection
  can be re-established without allowing traffic to DNS servers outside the VPN.
* Previously added routes are removed.
* Previous /etc/resolv.conf is restored.
* Firewall rules remain in place, allowing only the re-establishment of the vpn
  tunnel.

# How do I install/use it ?

Save vpnfailsafe&#46;sh in /etc/openvpn, make it executable and add the
following lines to /etc/openvpn/\<your_provider\>.conf:

```
script-security 2
up /etc/openvpn/vpnfailsafe.sh
down /etc/openvpn/vpnfailsafe.sh
```

That's it.

Since `vpnfailsafe` contains the functionality of the popular
update-resolv-conf&#46;sh script, the two don't need to be combined.

A complete configuration example is included as example.conf.

Arch Linux users may choose to install the
[vpnfailsafe-git](https://aur.archlinux.org/packages/vpnfailsafe-git/) package
from AUR instead.

If you want to use --user/--group to drop root priveleges, or otherwise run as
an unprivileged user, prepare for an uphill battle. OpenVPN will not make it
easy and the changes to get full functionality as non-root are likely to be
invasive. Perhaps a working example will be added in the future.

# What are the requirements/assumptions/limitations ?

Dependencies are minimal (listed in the PKGBUILD file). One assumption is that
the VPN server will push at least one DNS to the client.

`vpnfailsafe` has been tested on Linux, with both tun and tap devices, in all
topologies supported by OpenVPN.

There is no ipv6 support.

"RTNETLINK answers: File exists" errors can be ignored safely. They appear when
OpenVPN tries to set up a route, that's already been created by `vpnfailsafe`.
Adding the "route-noexec" option will tell OpenVPN to leave routing to
`vpnfailsafe` and prevent those errors from appearing.

The /etc/hosts entries may eventually become stale and require removal. Because
some VPN providers assign hundreds of IPs to their VPN server domains and
return different subsets of that pool in subsequent queries, updating these
entries automatically becomes very problematic. It makes determining whether a
previously valid IP is still valid impossible, so automated updates would
require constantly changing hosts entries, routes and firewall rules and almost
always to no benefit. In the interest of keeping this script small and simple,
such updates are now considered out of scope, unless github issues show popular
demand for the feature.

# How do I restore my system to the state from before running vpnfailsafe ?

`vpnfailsafe` will revert all changes when the tunnel is closed, except for the
firewall rules. You can restore those using the init script that set the
iptables rules on boot, or by otherwise removing the VPNFAILSAFE_INPUT,
VPNFAILSAFE_OUTPUT and VPNFAILSAFE_FORWARD chains.

Also, the entries in /etc/hosts for the VPN servers might get stale and require
removal.

# Will vpnfailsafe protect me against DNS leaks ?

Yes. See "How does it work ?" for more details.

That being said, if your life, job, or whatever you care about depend on your
IP not leaking, consider that this script has been tested by only a handful of
people. YMMV.

# Will vpnfailsafe protect me against all forms of IP leaks ?

No. Application level leaks can still happen, via protocols like WebRTC, or
BitTorrent. The user can also announce their identity to the world and no
script will stop them.

# Do I still need to configure a firewall ?

Yes. `vpnfailsafe` limits what kind of traffic is allowed, but only to achieve
its goals. Otherwise everything is passed through to pre-existing firewall
rules.

# Aren't there already scripts that do all that ?

One would think so, but then one would be wrong.

What is out there are mostly "applications", with non-optional GUIs and
thousands of lines of code behind them, often VPN-provider specific.

