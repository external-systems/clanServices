# The fixed names of lib/gateway's kernel objects and units. A machine
# runs at most one NAT64 translator and one CLAT (the services assert
# it), so the names need no instance part; interface names must also
# fit 15 characters. Consumers (the kube services' Cilium `devices`,
# SPEC.md D71) read the CLAT link from here or from the export.
{
  nat64 = {
    netns = "nat64";
    host = "jool0";
    inside = "jool1";
    table = "nat64";
    jool = "nat64-jool";
    health = "nat64-health";
    beacon = "nat64-beacon";
    runtime = "nat64-gateway";
  };
  clat = {
    netns = "clat";
    host = "clat0";
    inside = "clat1";
    jool = "clat";
    follow = "clat-follow";
    instance = "clat";
  };
}
