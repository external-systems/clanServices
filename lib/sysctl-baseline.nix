# The sysctl baseline of every link of a machine (specs/netif.md N47,
# specs/design-netif.md §3.4). One source, two sinks today:
#
# 1. `boot.kernel.sysctl` with `all`, `default` and the glob `*`
#    (lib/ifstate.nix): every link in every mode, also another owner's
#    and one that appears later;
# 2. IfState's per-interface `sysctl` (services/netif/default.nix):
#    declared links, restored on every apply and seen by `netif-drift`.
#
# The router-advertisement keys (design step 2) and the ARP keys
# (design step 8) join this file with their steps.
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
}
