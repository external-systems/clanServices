{
  ifstateOverlay,
  addresses,
  routes ? [],
  withBase ? false,
  nameservers ? ["192.168.1.254"],
}: {lib, ...}: {
  imports = lib.optional withBase (import ../lib/ifstate.nix {inherit ifstateOverlay;});

  networking = {
    inherit nameservers;
    ifstate.settings = {
      interfaces.eth1 = {
        inherit addresses;
        link = {
          kind = "physical";
          state = "up";
        };
      };
      routing.routes = routes;
    };
  };
}
