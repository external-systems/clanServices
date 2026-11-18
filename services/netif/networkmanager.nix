# netif's NetworkManager renderer (specs/netif.md N2, N5): what a
# `networkmanager` mode gets instead of IfState. It renders one profile
# per plain wired link, static or DHCP, and sets iwd as the Wi-Fi
# backend. Everything else (VLANs, bonds, bridges, tunnels, policy
# routing) needs an IfState mode; the shared base rejects it here.
#
# Links netif does not declare stay NetworkManager's own: a dock or a
# USB adapter gets its default DHCP profile, Wi-Fi is joined from the
# desktop or Steam.
{
  config,
  lib,
  ...
}: let
  cfg = config.clanServices.netif;
  inherit (config.clanServices.networking) mode;
  isV6 = lib.hasInfix ":";
  yes = value:
    if value
    then "true"
    else "false";

  # address1, address2, …; the gateway rides on the first address.
  numbered = prefix: values:
    lib.listToAttrs (lib.imap1 (i: value: lib.nameValuePair "${prefix}${toString i}" value) values);

  family = {
    l,
    v6,
    dhcp,
    gateway,
    ownsDefault,
  }: let
    addresses = builtins.filter (address: isV6 address == v6) l.addresses;
    dns = builtins.filter (server: isV6 server == v6) l.nameservers;
    routes = builtins.filter (route: isV6 route.destination == v6) l.routes;
  in
    {
      method =
        if dhcp || (v6 && l.ra && addresses == [])
        then "auto"
        else if addresses != []
        then "manual"
        else if v6
        then "link-local"
        else "disabled";
      route-metric = toString cfg.routeMetric;
      never-default = yes (!ownsDefault);
    }
    // numbered "address" (
      lib.imap0 (
        i: address:
          if i == 0 && gateway != null && ownsDefault
          then "${address},${gateway}"
          else address
      )
      addresses
    )
    // numbered "route" (
      map (
        route:
          route.destination
          + lib.optionalString (route.gateway != null) ",${route.gateway}"
      )
      routes
    )
    // lib.optionalAttrs (dns != []) {dns = lib.concatStringsSep ";" dns + ";";};

  profile = interface: l: {
    connection = {
      id = "netif-${interface}";
      type = "ethernet";
      interface-name = interface;
      autoconnect = "true";
      # above NetworkManager's own "Wired connection" default
      autoconnect-priority = "10";
    };
    ethernet = lib.optionalAttrs (l.mtu != null) {mtu = toString l.mtu;};
    ipv4 = family {
      inherit l;
      v6 = false;
      dhcp = l.dhcp4;
      gateway = l.gateway4;
      ownsDefault = l.default4;
    };
    ipv6 = family {
      inherit l;
      v6 = true;
      dhcp = l.dhcp6;
      gateway = l.gateway6;
      ownsDefault = l.default6;
    };
  };
in {
  config = lib.mkIf (mode.manager == "networkmanager") {
    networking.networkmanager = {
      # iwd owns Wi-Fi in every mode (N5); known networks are shared
      # with the IfState modes through /var/lib/iwd.
      wifi.backend = "iwd";
      dns = "systemd-resolved";
      # NetworkManager creates a DHCP profile for every wired device it
      # sees, before netif's profile exists. Not on the links netif
      # declares: there the declared profile is the only one.
      settings = {
        main.no-auto-default = lib.concatStringsSep "," (builtins.attrNames cfg.links);
        # A wired link netif does not declare (a dock, an unknown LAN)
        # sits behind netif's own links and ahead of Wi-Fi (N18): the
        # same order as the 'wired-hotplug' owner in an IfState mode.
        # netif's profiles set their metric themselves.
        connection-netif-adhoc-wired = {
          match-device = "type:ethernet";
          "ipv4.route-metric" = cfg.routeMetric + 100;
          "ipv6.route-metric" = cfg.routeMetric + 100;
        };
      };
      # A NIC that belongs to another mode of this machine is nobody's
      # here (N4). Links netif never declares, such as a dock, stay
      # NetworkManager's own.
      unmanaged = map (interface: "interface-name:${interface}") cfg.otherModeInterfaces;
      ensureProfiles.profiles = lib.mapAttrs' (
        interface: l: lib.nameValuePair "netif-${interface}" (profile interface l)
      ) (lib.filterAttrs (_: l: l.kind == "physical") cfg.links);
    };

    # In an IfState mode IfState renames a NIC found by its MAC. Here
    # udev does, so the link has the same name in every mode (N15).
    systemd.network.links = lib.mapAttrs' (
      interface: l:
        lib.nameValuePair "10-netif-${interface}" {
          matchConfig.PermanentMACAddress = l.matchMac;
          linkConfig.Name = interface;
        }
    ) (lib.filterAttrs (_: l: l.matchMac != null) cfg.links);
  };
}
