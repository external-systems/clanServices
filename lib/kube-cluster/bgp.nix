# BGP v2 resource rendering (D9) and the private fleet fabric (D10).
#
# Topology (D9): Cilium's GoBGP originates VIP routes and dials OUT to the
# node-local BIRD over a node-local BGP link; BIRD listens only on that
# link's loopback alias (169.254.179.1/32 on `lo`, strict-bind — no :179
# listener on any non-loopback interface). BIRD refuses 127/8 neighbor
# addresses ("Invalid remote address", verified against BIRD 2.20), hence
# the link-local alias. BIRD imports ONLY the exact /32+/128 VIPs of the
# cluster's shared-bgp pools (prefix filters + per-family import limits)
# and re-exports exactly those to the configured upstream peer(s); it
# installs nothing into the cluster node's kernel (no kernel protocol).
# Cilium agents never peer with each other and listen on no port.
#
# Upstream sessions are dialed out by the node (active) and split per
# address family (a v4 session carries the ipv4 channel, a v6 session the
# ipv6 channel — no cross-family next-hop games). `next hop self` makes the
# router see the node's own session address as the VIP next hop, which is
# what the upstream ECMPs across.
#
# Determinism (D9): two private 32-bit ASNs per cluster (RFC 6996 range
# 4200000000–4294967294) hashed from the instance name; the Cilium-side and
# BIRD-side ASNs use different hash salts (and a deterministic +1 fallback
# on the astronomically unlikely salt collision). Router ids: Cilium's
# default allocation (the node's IPv4 address — its mesh/transport address
# under the tested transport); BIRD's `router id` is set to the same node
# IPv4 via the vendored fragment renderer (bird.nix).
{ lib }:
let
  cidrLib = import ./cidr.nix { inherit lib; };

  # First 8 hex chars of sha256(s) as a 32-bit int (same scheme as the
  # cilium id hash in default.nix; pure Nix, no IFD).
  hash32 =
    s:
    let
      hexVal =
        c:
        let
          digits = lib.stringToCharacters "0123456789abcdef";
          idx = lib.findFirst (i: builtins.elemAt digits i == c) (-1) (lib.genList (x: x) 16);
        in
        if idx == -1 then throw "kube-cluster/bgp: bad hex digit '${c}' in hash" else idx;
    in
    lib.foldl' (acc: c: acc * 16 + hexVal c) 0 (
      lib.stringToCharacters (lib.substring 0 8 (builtins.hashString "sha256" s))
    );

  asnBase = 4200000000;
  asnSpan = 4294967294 - asnBase; # 94967294 values

  # BIRD symbols may not contain '-' or '.'; instance names are DNS-style.
  birdSym = s: lib.replaceStrings [ "-" "." ] [ "_" "_" ] s;

  # Per-family block capacity (for the BIRD import limit), capped: the
  # prefix filter already pins the exact /32+/128 shape, the limit is the
  # second belt against surprises.
  cap4 =
    block:
    let
      prefix = builtins.fromJSON (builtins.elemAt (lib.splitString "/" block) 1);
    in
    if prefix >= 16 then lib.foldl' (acc: _: acc * 2) 1 (lib.genList (x: x) (32 - prefix)) else 4096;
  cap6 =
    block:
    let
      prefix = builtins.fromJSON (builtins.elemAt (lib.splitString "/" block) 1);
    in
    if prefix >= 120 then lib.foldl' (acc: _: acc * 2) 1 (lib.genList (x: x) (128 - prefix)) else 4096;

  importLimit =
    blocks: capFn:
    let
      total = lib.foldl' (acc: b: acc + capFn b) 0 blocks;
    in
    lib.max 1 (lib.min 4096 total);

  byFamily = blocks: {
    v4 = builtins.filter (b: !(lib.hasInfix ":" b)) blocks;
    v6 = builtins.filter (lib.hasInfix ":") blocks;
  };

  # A BIRD prefix-set pattern list: exact /32s (or /128s) within the blocks.
  exactSet =
    blocks: len:
    "[ ${lib.concatMapStringsSep ", " (b: "${b}{${toString len},${toString len}}") blocks} ]";

  importFilter =
    name: blocks': len:
    if blocks' == [ ] then
      ''
        filter ${name} {
          reject;
        }
      ''
    else
      ''
        filter ${name} {
          if net ~ ${exactSet blocks' len} then accept;
          else reject;
        }
      '';
in
rec {
  # D9: two deterministic private 32-bit ASNs per cluster. Derivation:
  # sha256("kube-cluster-bgp-cilium:<instance>") / ("...-bird:<instance>"),
  # first 8 hex chars as u32, mapped into 4200000000..4294967293 by modulo
  # (the top of the RFC 6996 range is excluded so the collision fallback
  # +1 stays in range).
  hashBgpAsns =
    instanceName:
    let
      cilium = asnBase + lib.mod (hash32 "kube-cluster-bgp-cilium:${instanceName}") asnSpan;
      bird0 = asnBase + lib.mod (hash32 "kube-cluster-bgp-bird:${instanceName}") asnSpan;
      bird = if bird0 == cilium then bird0 + 1 else bird0;
    in
    {
      inherit cilium bird;
    };

  # Resolved ASNs: explicit pins (bgp.ciliumASN/bgp.birdASN) win over the
  # hashed defaults — the escape hatch for a fleet-wide ASN collision
  # (fleet-asserted), parallel to the cilium.id pin (§6.2).
  resolveBgpAsns =
    { instanceName, settings }:
    let
      hashed = hashBgpAsns instanceName;
    in
    {
      cilium = if settings.bgp.ciliumASN != null then settings.bgp.ciliumASN else hashed.cilium;
      bird = if settings.bgp.birdASN != null then settings.bgp.birdASN else hashed.bird;
    };

  # The node-local BGP link address (D9): a /32 alias on `lo` that BIRD
  # strict-binds its :179 listener to and Cilium dials out to. One constant
  # per host is safe: one cluster per node (D16). Link-local = never
  # forwarded, never routed, never advertised (BIRD imports only the
  # shared-bgp pool VIPs).
  bgpLinkV4 = "169.254.179.1";

  # Fabric pool blocks (D10): RFC1918 + ULA derived from the resolved
  # cilium id (overridable). 172.16.<id>.0/24 sits inside 172.16.0.0/12 for
  # every legal id (1–255) and is disjoint from the id-derived pod/service
  # space (10/8 + fd10::/16) and the mesh hash space (192.168/16 +
  # fd77::/16); non-overlap with explicit pod/service CIDR overrides is
  # eval-asserted (assertions.nix reservedCidrs).
  fabricBlocks =
    { ciliumId, settings }:
    {
      v4 =
        if settings.fabric.ipv4Block != null then
          settings.fabric.ipv4Block
        else
          "172.16.${toString ciliumId}.0/24";
      v6 =
        if settings.fabric.ipv6Block != null then
          settings.fabric.ipv6Block
        else
          "fd11:${toString ciliumId}::/64";
    };

  # Well-known core VIPs inside the fabric blocks: offset 53 (the DNS
  # port) is the private CoreDNS VIP (D22 substrate).
  fabricCoreDNSVips =
    { ciliumId, settings }:
    let
      blocks = fabricBlocks { inherit ciliumId settings; };
    in
    {
      ipv4 = cidrLib.addressAt blocks.v4 53;
      ipv6 = cidrLib.addressAtV6 blocks.v6 83; # 0x53
    };

  # The default private fabric pool (D10): one cluster-global shared-bgp
  # pool per cluster, on by default. Returns null when fabric.enable=false.
  mkFabricPool =
    {
      instanceName,
      ciliumId,
      settings,
    }:
    if !settings.fabric.enable then
      null
    else
      let
        blocks = fabricBlocks { inherit ciliumId settings; };
      in
      {
        name = "${instanceName}-fabric";
        blocks = [
          blocks.v4
          blocks.v6
        ];
        serviceSelector."clan.lol/pool" = "${instanceName}-fabric";
        delivery = "shared-bgp";
        candidates = [ ];
      };

  # The BGP v2 resource set (D9), rendered iff shared-bgp pools exist.
  # Returns kubenix typed-tree fragments (custom types registered in
  # bundle.nix).
  mkBgpResources =
    {
      instanceName,
      asns,
      # [ machineName ] — one CiliumBGPClusterConfig per node (overlapping
      # node selectors are rejected by Cilium, so we never share one).
      members,
      # names of the cluster's shared-bgp pools (advertised VIP sources)
      sharedBgpPoolNames,
      advertisePodCIDRs ? false,
      advertiseClusterIPs ? false,
      manifestLabels,
    }:
    let
      advertLabel."clan.lol/bgp-advertisement" = instanceName;
    in
    {
      ciliumBGPPeerConfigs."${instanceName}-bird" = {
        metadata.labels = manifestLabels;
        spec = {
          # D9 timers: fast datacenter failure detection (no BFD in 1.20).
          timers = {
            holdTimeSeconds = 9;
            keepAliveTimeSeconds = 3;
            connectRetryTimeSeconds = 5;
          };
          families = [
            {
              afi = "ipv4";
              safi = "unicast";
              advertisements.matchLabels = advertLabel;
            }
            {
              afi = "ipv6";
              safi = "unicast";
              advertisements.matchLabels = advertLabel;
            }
          ];
        };
      };

      ciliumBGPClusterConfigs = lib.listToAttrs (
        map (m: {
          name = "${instanceName}-${m}";
          value = {
            metadata.labels = manifestLabels;
            spec = {
              nodeSelector.matchLabels."kubernetes.io/hostname" = m;
              bgpInstances = [
                {
                  name = "${instanceName}-bird";
                  localASN = asns.cilium;
                  # NO localPort: the Cilium side listens on no :179 — it
                  # only dials out to the node-local BIRD (D9).
                  peers = [
                    {
                      name = "bird";
                      peerASN = asns.bird;
                      peerAddress = bgpLinkV4;
                      peerConfigRef.name = "${instanceName}-bird";
                    }
                  ];
                }
              ];
            };
          };
        }) members
      );

      ciliumBGPAdvertisements = {
        # Exact /32+/128 VIPs of the shared-bgp pools (ETP-Local
        # withdrawal semantics come from the Services' ETP).
        "${instanceName}-service-vips" = {
          metadata.labels = manifestLabels // advertLabel;
          spec.advertisements = [
            {
              advertisementType = "Service";
              service.addresses = [ "LoadBalancerIP" ];
              selector.matchExpressions = [
                {
                  key = "clan.lol/pool";
                  operator = "In";
                  values = sharedBgpPoolNames;
                }
              ];
            }
          ];
        };
      }
      # D13 opt-ins (default off): pod CIDRs (multi-pool IPAM ⇒
      # CiliumPodIPPool type selecting the cluster's pod pool by its
      # manifest labels) and ClusterIPs (all Services).
      // lib.optionalAttrs advertisePodCIDRs {
        "${instanceName}-pod-cidrs" = {
          metadata.labels = manifestLabels // advertLabel;
          spec.advertisements = [
            {
              advertisementType = "CiliumPodIPPool";
              selector.matchLabels."clan.lol/cluster" = instanceName;
            }
          ];
        };
      }
      // lib.optionalAttrs advertiseClusterIPs {
        "${instanceName}-cluster-ips" = {
          metadata.labels = manifestLabels // advertLabel;
          spec.advertisements = [
            {
              advertisementType = "Service";
              service.addresses = [ "ClusterIP" ];
              # match-all: NotIn with a dummy value (upstream-documented
              # idiom).
              selector.matchExpressions = [
                {
                  key = "clan.lol/cluster";
                  operator = "NotIn";
                  values = [ "never" ];
                }
              ];
            }
          ];
        };
      };
    };

  # The cluster-node BIRD fragment (D9/D19): the text one cluster
  # contributes to the host's single BIRD via the vendored fragment
  # renderer. `blocks` = the cluster's shared-bgp pool blocks (the ONLY
  # prefixes BIRD may ever import from Cilium or export upstream).
  mkBirdFragment =
    {
      instanceName,
      asns,
      blocks,
      upstreamPeers ? [ ],
    }:
    let
      ns = birdSym instanceName;
      fam = byFamily blocks;

      upstreams4 = builtins.filter (p: !(lib.hasInfix ":" p.address)) upstreamPeers;
      upstreams6 = builtins.filter (p: lib.hasInfix ":" p.address) upstreamPeers;

      mkUpstream = i: peer: channel: ''
        protocol bgp ${ns}_upstream_${toString i} {
          local port 4179 as ${toString asns.bird};
          neighbor ${peer.address} as ${toString peer.asn};
          hold time 9;
          keepalive time 3;
          connect retry time 5;
          ${channel} {
            import none;
            export filter ${ns}_cilium_in${if channel == "ipv4" then "4" else "6"};
            next hop self;
          };
        }
      '';
    in
    ''
      # kube-cluster/${instanceName} (D9): Cilium GoBGP dials out to this
      # node-local BIRD over the loopback BGP link (${bgpLinkV4}, an alias on
      # lo); BIRD re-exports approved VIPs to configured upstreams only and
      # installs nothing into the kernel.
      protocol device {
        scan time 10;
      }

      ${importFilter "${ns}_cilium_in4" fam.v4 32}
      ${importFilter "${ns}_cilium_in6" fam.v6 128}
      protocol bgp ${ns}_cilium {
        local ${bgpLinkV4} port 179 as ${toString asns.bird};
        neighbor ${bgpLinkV4} as ${toString asns.cilium};
        passive on;
        strict bind on;
        free bind on;
        hold time 9;
        keepalive time 3;
        connect retry time 5;
        ipv4 {
          import filter ${ns}_cilium_in4;
          import limit ${toString (importLimit fam.v4 cap4)} action block;
          export none;
        };
        ipv6 {
          import filter ${ns}_cilium_in6;
          import limit ${toString (importLimit fam.v6 cap6)} action block;
          export none;
        };
      }
      ${lib.concatStringsSep "\n" (lib.imap1 (i: p: mkUpstream i p "ipv4") upstreams4)}
      ${lib.concatStringsSep "\n" (
        lib.imap1 (i: p: mkUpstream (i + builtins.length upstreams4) p "ipv6") upstreams6
      )}
    '';
}
