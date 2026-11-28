# The sysctl baseline of every link of a machine (specs/netif.md N47,
# N48; specs/design-netif.md §3.4). One source, three sinks:
#
# 1. `boot.kernel.sysctl` (lib/ifstate.nix): `everyLink4` and
#    `everyLink6` with `all`, `default` and the glob `*`, so every link
#    in every mode, also another owner's and one that appears later;
#    `raOff6` with `default` only (a glob would switch router
#    advertisements off on hot-plug links at every sysctl reload);
# 2. IfState's per-interface `sysctl` (services/netif/default.nix):
#    declared links, restored on every apply and seen by `netif-drift`;
# 3. `hotplugUp` (services/netif/host.nix): the RA keys a hot-plug
#    link turns on.
#
# The ARP keys (design step 8) join this file with their step.
{
  everyLink4 = {
    accept_redirects = 0;
    secure_redirects = 0;
    send_redirects = 0;
    accept_source_route = 0;
  };
  everyLink6 = {
    accept_redirects = 0;
    accept_source_route = 0;
  };
  # Router advertisements off (N48): a link takes them only where
  # declared (`ra = true`), and even then no route-information route,
  # no MTU and no hop limit below 64 (I8).
  raOff6 = {
    accept_ra = 0;
    autoconf = 0;
    accept_ra_defrtr = 0;
    accept_ra_pinfo = 0;
    accept_ra_rt_info_max_plen = 0;
    accept_ra_mtu = 0;
    accept_ra_min_hop_limit = 64;
  };
}
