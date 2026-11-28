{
  instances = {
    # A one-machine fabric: routed-fabric is the only transport (D72),
    # and the cluster takes its node addresses from it.
    fabric = {
      module.name = "routed-fabric";
      module.input = "self";
      roles.spine.machines.alpha = {};
    };
    kube = {
      module.name = "rke2";
      module.input = "self";
      roles.server = {
        settings.network.fabric = {
          service = "routed-fabric";
          instance = "fabric";
        };
        machines.alpha.settings.clusterInit = true;
      };
    };
  };
}
