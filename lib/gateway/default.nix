# lib/gateway: the private shared implementation of the `nat-gateway`
# and `router` services (specs/gateway.md G1). Not a clan service. The
# services set `clanServices.gateway.*`; a VM suite may import this
# module directly.
{
  key = "clanServices:lib/gateway";
  imports = [
    ./nat64.nix
    ./clat.nix
    ./router.nix
  ];
}
