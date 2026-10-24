# Network diagrams

How fleet network diagrams get their data. Round 16, D57: clanServices
exposes **network facts** as a neutral NixOS-option seam; anything that
draws diagrams — `nix-topology` included — is **consumer-owned** and lives
outside this flake.

## The seam: `clan.networkFacts`

ClanServices will expose a **dependency-free, versioned, JSON-serializable,
non-secret, per-node network-facts NixOS interface** at
`clan.networkFacts`. The exact option schema is **planned, not
implemented**; option leaves carry defaults so deep evaluation never
breaks.

The contract:

- **Producer-owned, actually read-only.** Leaves use NixOS
  `readOnly = true`. The service owning each fact populates it from the
  **same resolved configuration** used for functional networking and
  exports — `netif` writes underlay/link facts, `routed-fabric` writes
  fabric facts, the distro services write k8s cluster facts. Wrappers and
  consumers only read; they never define or override the values. This
  complements the exports system; there is no second source of truth.
- **Complete build-time-declared topology and policy.** Node identity;
  `netif` links/interfaces/networks/addresses/gateways/routes/policy
  routes/MTU/DNS/firewall trust; fabric member/hub/access/border, stable
  loopbacks, per-adjacency WireGuard links, transfer prefixes, MTU,
  public endpoints, AllowedIPs, ASNs, upstreams, FRR prefix policy, and
  NAT/source-return intent; and k8s cluster identity, node membership,
  distros, CIDRs, pools, Node-IPAM facts, private DNS, and API/mirror
  endpoints — as independent underlay, fabric, ClusterMesh, and
  control-domain graph facts.
- **Non-secret.** No private keys, certificates, tokens, kubeconfigs, or
  other secrets ever appear.
- **Declared configuration, not runtime state.** Dynamic DHCP/RA addresses,
  BGP-learned routes, live handshakes, reachability, and failures are not
  build-time certainties: the interface represents declared mode/intent and
  never invents values. The contract is 100% accurate for declared
  build-time configuration — nothing more.

## What clanServices does not do

ClanServices must **not** depend on `nix-topology`, import its modules, set
its `topology.*` options, render icons/SVGs, or own diagram packages.
Diagram generation is a consumer concern; this flake stops at the facts.

## The consumer-owned wrapper

A consumer that wants diagrams supplies its own wrapper:

- it adds the `nix-topology` input/overlay/flake module/NixOS module
  itself;
- it translates `clan.networkFacts` into `topology.*` settings;
- it may expose `packages.<diagram>` or `topology.<system>.config.output`
  from its own flake.

Nothing in that wrapper feeds back into functional networking — it is a
rendering of facts, one direction only.

## Status

**Planned (D57).** There is no implementation or VM evidence yet: no
`clan.networkFacts` options exist, no consumer wrapper ships in this repo,
and the schema above is the design contract, not an API reference.
