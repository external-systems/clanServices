{ifstateOverlay}: {
  config,
  lib,
  ...
}: {
  assertions = [
    {
      assertion = !config.systemd.network.enable;
      message = "clanServices networking is IfState-only; systemd-networkd must stay disabled";
    }
    {
      assertion = !config.networking.useDHCP;
      message = "clanServices networking is IfState-only; use per-link IfState DHCP hooks instead of networking.useDHCP";
    }
    {
      assertion = lib.versionAtLeast config.networking.ifstate.package.version "2.5";
      message = "clanServices requires IfState >= 2.5; apply inputs.pkgs.overlays.ifstate or provide an equivalent newer package";
    }
  ];

  nixpkgs.overlays = lib.mkAfter [ifstateOverlay];

  networking = {
    ifstate = {
      enable = true;
      settings = {
        parameters.ignore = {
          ifname = [
            "^cilium"
            "^lxc"
            "^tap"
            "^vnet"
          ];
          routes = [
            {dev = "^cilium";}
            {dev = "^lxc";}
          ];
          rules = [{table = 200;}];
        };
      };
    };

    interfaces = lib.mkForce {};
    networkmanager.enable = lib.mkForce false;
    useDHCP = lib.mkForce false;
    useNetworkd = lib.mkForce false;
  };

  systemd = {
    network.enable = lib.mkForce false;
    services.ifstate.serviceConfig.KillMode = "process";
  };
}
