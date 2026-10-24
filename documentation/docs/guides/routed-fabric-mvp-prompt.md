# Routed-fabric MVP — implementation prompt (round 15)

This page is a **self-contained copy-paste prompt**. Paste the fenced block
below, verbatim, into a fresh AI coding agent session whose working
directory is the repository root of `external-systems/clanServices`. One
session must complete the entire round-15 data-plane overhaul **across two
repos** — the artifact flake `external-systems/pkgs` (native Cilium base
re-inflation, committed there) and clanServices (implementation, tests,
SPEC amendments, documentation) — with every eval and hermetic VM gate
green. Commits are expected in both repos; clanServices should end as one
coherent commit if practical, but that is not the goal and red/partial work
is never committed. It assumes **no implementation exists**; round 15 lives
in `SPEC.md` and must be read there first.

````text
You are implementing the round-15 routed-fabric data-plane overhaul. You
work in TWO repos:
- /home/netsa/external-systems/pkgs       (artifact flake — packaging only)
- /home/netsa/external-systems/clanServices (working dir; branch main)
Commits in each repo are expected as stages land. clanServices should end
as ONE coherent commit if practical, but that is not the goal — NEVER
commit red or partial work anywhere. If you cannot reach green, STOP and
report blockers with evidence.

================================================================
0. Standing rules (a violation fails the run)
================================================================

- READ FIRST, ASSUME NOTHING. Round-15 SPEC.md is the normative contract
  AND the status authority; implementation may not exist yet.
  1. Read SPEC.md round 15 in full — decision record (D51–D55 and every
     revised entry), invariants, §6 subsystem contracts, §7 testing
     contract, §8 delivery plan.
  2. Read AGENTS.md (hard rules) and README.md in BOTH repos; the pkgs
     README documents its manifest pipeline and update commands — use
     those, do not guess.
  3. Read documentation/docs/architecture/{overview,networking,
     routed-fabric,multi-cluster}.md and skim documentation/docs/services/.
  4. Consume the latest baton-pass: read .baton-pass/LATEST.md, then every
     file in its chain (both repos). Read .baton-pass/vm-logs/summary.md
     if present. Those logs are legacy evidence only.
- Load these skills and follow them over your own defaults: frr, cilium,
  rancher-kubernetes, clan-core, clanservices, vm-tests, nix-style.
- `git add` BEFORE every Nix eval (Nix reads the git tree) — in both repos.
- NEVER run plain `nix flake check` in clanServices — it boots VM tests
  and OOMs this machine. Only ever `nix flake check --no-build
  --show-trace` there. (pkgs has no VM suites; its own `nix flake check`
  is its lint/freshness gate and is safe to run there.)
- Never weaken, skip, or delete a test or assertion to fit code. If
  reality disproves a spec assumption, amend SPEC.md FIRST and
  documentation/ in the same change, rerun the static gates, then
  implement against the amended contract. This includes correcting
  round-15 role wording if the spec still describes a default role/access
  model — see the locked MVP below.
- No IFD anywhere in clanServices eval. No day-2 scope expansion: no
  Gateway/Ingress/proxy, cert-manager, storage, or GitOps-controller
  rendering. No home or borg deployment/migration, no `clan machines`
  deploys, NO secret mutation (never run vars generate/regenerate against
  real machines) — in either repo. Never edit anything outside these two
  repos.
- VM suites run ONE AT A TIME; the sandboxed `nix build` is the
  authoritative pass/fail. Interactive/driver mode is debug-only, and any
  fix proven under the driver is re-proven with a sandboxed rerun before
  it counts. Tee every VM log to .baton-pass/vm-logs/<suite>.log (durable;
  /tmp is wiped on reboot).

================================================================
1. Entry checks (before anything else)
================================================================

1. BOTH repos clean: `git status` in clanServices and in
   /home/netsa/external-systems/pkgs. Record both HEADs. If either tree is
   dirty or staged, STOP and report — another agent may be mid-flight.
2. No in-flight VM: check for qemu processes; no background build tasks.
   If one is running, do not start work; report.
3. Baseline gates on the clean trees, recorded verbatim for the report:
   - pkgs: `nix fmt .` ; `nix flake check --show-trace`
     (lint + k8s-version parity + manifest freshness + airgap completeness;
     must pass before you touch anything)
   - clanServices: `nix fmt .` ;
     `nix build .#checks.x86_64-linux.treefmt` ;
     `nix flake check --no-build --show-trace` (zero warnings) ;
     `nix build .#checks.x86_64-linux.nix-unit -L` (record the count)
4. Existing clanServices VM suites at baseline (each built individually,
   one at a time, `nix build --no-link .#checks.x86_64-linux.<suite>`):
   k3s-single, k3s-join, k3s-ha, k3s-data-plane, k3s-bgp-ecmp,
   rke2-single, rke2-join, rke2-ha, rke2-data-plane, rke2-bgp-ecmp,
   fleet-routing, wireguard-mesh.
   Run them only when you need a pre-change baseline; they are slow.
   The required single/join/HA suites must be green again at the end.

================================================================
2. Locked MVP (from SPEC round 15 — do not redesign)
================================================================

- `netif`: multi-instance, multi-link host networking (links, addressing,
  gateways, routes, policy routing, MTU, DNS, firewall trust, deploy
  targets). Provider-MAC netif bridges only; KubeVirt bridges are day-2.
  Underlay MTU is explicit in netif; WireGuard and pod-path MTU derive
  from it rather than being repeated per fabric interface.
- The legacy `fleet-routing` service is RENAMED to `routed-fabric`.
  `routed-fabric` has EXACTLY FOUR canonical roles — `member` (the base
  role), `client`, `admin`, `router` (each a specialization of member).
  There is NO default role and NO per-machine access setting; every
  machine takes exactly one of the four roles per instance.
- Fabric topology is routed-hub ONLY: explicit hubs, eBGP + BFD + Zebra.
  NO iBGP, NO route reflectors, NO full mesh. Every instance has >= 1
  reachable hub; hub HA = 2 (two active hubs); hubs send next-hop-self;
  spokes are non-transit (a spoke never forwards fabric traffic between
  other members). Hub is a topology marker, ORTHOGONAL to the `router`
  role (upstream-prefix ownership) — neither implies the other, and
  Kubernetes manager nodes are NOT hubs by default.
- Multiple `routed-fabric` instances = multiple trust domains.
- ClusterMesh: FULL PEERING BY DEFAULT within one fabric; explicit
  symmetric selective peers within that fabric. Unpeered clusters
  share no state and install no pod routes for each other (leaf route
  isolation) — in the canonical A-B-C shape, B peers with A and C while
  A and C share nothing.
- Cilium: native routing with multi-pool IPAM on BOTH k3s and rke2; no
  official overlays (no VXLAN/Geneve); local `::1` FRR peering in BOTH
  address families; Node IPAM at fabric scope; `node-bgp` and
  `shared-bgp` deliveries; kube-proxy off and Cilium
  `installIptablesRules=false` with nftables.
- WireGuard `AllowedIPs` are the transit/source ACL. An external-transit
  0.0.0.0/0 and ::/0 is allowed ONLY as the WireGuard crypto ACL; it must
  NEVER appear as an installed, accepted, or leaked IP default route —
  the RIB/FIB carries no default route unless an explicit policy table
  requires it. Return path for Internet-sourced traffic is enforced by
  source policy, not by a default route.

================================================================
3. Stage 0 — probes, then spec pre-amendment
================================================================

Before implementing anything, run SMALL throwaway probes (nix eval,
short-lived scratch nixosTest, or `nix build` of a scratch config —
never committed) for:

1. FRR config validation: integrated-config syntax, `frr-reload.py
   --test` preview semantics, and the fact that enabling a daemon needs
   a one-time frr restart (reload alone does not start new daemons).
2. Dual-AF Cilium -> local FRR at `::1`: BGP session in both families,
   Cilium's loopback next hop accepted and rewritten to the stable
   transport address, and Zebra installing the routes into the kernel
   FIB in both families.
3. Internet-SOURCED INBOUND traffic: an external host sourcing traffic
   INTO the fabric through a router/hub to a published VIP — with 0/0
   and ::/0 present ONLY in the WireGuard crypto ACL — plus the
   source-policy RETURN path. Verify no IP default route is installed or
   accepted unless an explicit policy table requires it.
4. MTU derivation end to end (link -> WG interface -> pod path), with
   PMTU behavior.

If a probe disproves a round-15 assumption: amend SPEC.md round 15 AND
documentation/ together, rerun the static gates, and only then implement.
Otherwise record probe findings in your report and proceed. Stage 0 must
stay small — it is validation, not implementation.

================================================================
4. Stage 1 — pkgs: re-inflate the Cilium base manifest (native)
================================================================

The clanServices Cilium stage (Stage 3) consumes the committed base, so
the native base lands FIRST, in pkgs, committed there:

1. In /home/netsa/external-systems/pkgs, edit pkgs/cilium/values.nix
   (the canonical fleet-uniform profile; rendered into
   manifests/cilium/<chartVersion>.yaml at update time): switch
   routingMode to "native"; remove the tunnel/VXLAN settings entirely;
   keep ipv4/ipv6NativeRoutingCIDR active; add autoDirectNodeRoutes =
   false and installIptablesRules = false (kube-proxy stays replaced;
   multi-pool IPAM, dual-stack, BPF masquerade+tproxy, maglev, pmtu,
   clustermesh-apiserver, Gateway/Ingress off all stay).
2. `git add` the values edit, then re-inflate with the repo's own
   updater: `nix run .#update-manifests` (re-renders every committed
   manifest from pins into manifests/; chartVersion stays 1.20.3 so the
   file is manifests/cilium/1.20.3.yaml with new bytes). Review with
   `git diff` — the diff must show native routing and no tunnel devices.
   If the fresh render references a different image set than
   pkgs/cilium/versions.nix pins, update versions.nix per the README
   (`nix store prefetch-file --json <url>` hashes); the
   cilium-airgap-completeness check will tell you.
3. pkgs gates: `nix fmt .` ; `nix flake check --show-trace` (lint +
   k8s-version parity + manifest-cilium-freshness [committed ≡ fresh
   render, byte-identical] + cilium-airgap-completeness). Zero warnings.
4. Commit pkgs (message records the native-profile re-inflation). Record
   the commit SHA. Do NOT push on your own initiative: remote pushes were
   not pre-authorized. STOP and ASK THE USER to authorize pushing pkgs;
   continue only after the user authorizes it and you have verified that
   the exact recorded SHA is visible on the remote (e.g.
   `git ls-remote origin main` contains it). clanServices must pin a
   shareable revision, not a local-only commit or path.
5. Only with the SHA visible remotely: back in clanServices, move the
   pin: `nix flake lock --update-input pkgs` (equivalently
   `nix flake update pkgs`), verify flake.lock now records your new pkgs
   commit, `git add flake.lock`, and re-run the clanServices static gates
   before continuing. If push is NOT authorized, STOP here before any pin
   change and report (do not substitute a local path, a path: input, or
   a local-only pin — that is a failure of this run).

================================================================
5. Stage 2 — netif + routed-fabric (transport plane)
================================================================

Implement in the shared lib (`lib/kube-cluster/`) first, with the thin
service layers on top (fix once, not twice — AGENTS rule 4):

- `services/netif/` (new clanService, auto-discovered via
  services/*/flake-module.nix; no central registration list). Multi-
  instance, multi-link; deterministic names including SFP+-shaped
  physical names; eval errors for conflicting link ownership and
  duplicate default routes; MTU derivation; provider-MAC bridges only;
  versioned `peer`/`netif` exports feeding routed-fabric endpoint
  selection. NOTE: `checks.coverage` throws unless
  `nix-unit.tests.netif` exists — register eval tests in the same change.
- Rename `services/fleet-routing/` -> `services/routed-fabric/`
  (directory, `clan.modules` name, exports interface, flake-module keys,
  docs pages). Exactly the four canonical roles member/client/admin/
  router — member is the base; client/admin/router specialize it; NO
  default role; NO access setting; one membership and exactly one role
  per machine per instance. Amend SPEC D52/D33 wording first if it
  still describes a default-role/access model.
- Fabric: explicit routed hubs only (eBGP + BFD + Zebra; no iBGP/RR/
  full mesh); >= 1 reachable hub per instance (eval error otherwise);
  hub HA = 2; next-hop-self from hubs; spokes non-transit; NAT sites
  without a direct link work through reachable hubs. AllowedIPs =
  transit/source ACL rendered from the SAME route policy as the FRR
  filters (no cryptokey/routing drift); external-transit 0/0 and ::/0
  ONLY in the WG crypto ACL — never an installed/accepted IP default
  route unless an explicit policy table requires it; source-policy
  return path for Internet-sourced inbound traffic. One integrated
  `services.frr.config` per host (bgpd + bfdd + Zebra from the first
  render); Zebra owns kernel installation.
- Stage-2 done means: eval tests green AND the netif + routed-fabric
  (transport/FRR) VM suites pass, sandboxed, one at a time.

================================================================
6. Stage 3 — native Cilium + pools on both distros (k3s + rke2)
================================================================

Consume the Stage-1 RE-INFLATED committed base through the kubenix
layer-2 merge over the pkgs input pin (zero IFD; cluster name/id,
devices, MTU, Node IPAM, pod-pool CIDRs, and mesh peers are layer-2):

- Native routing, multi-pool pod IPAM, no tunnel/overlay,
  `auto-direct-node-routes=false` on BOTH k3s and rke2; Cilium devices
  cover every fabric interface; nftables with Cilium
  `installIptablesRules=false`; kube-proxy off.
- Local Cilium -> FRR at `::1` in both address families; next-hop
  rewrite to the stable transport address; FRR/Zebra distributes remote
  pod-pool routes.
- Node IPAM at fabric scope; `node-bgp` (owner-only advertisement) and
  `shared-bgp` (ECMP + ETP-Local withdrawal) deliveries.
- Per-distro data-plane VM suites (k3s + rke2) must pass.

================================================================
7. Stage 4 — selective mesh, DNS, roles, failure, migration
================================================================

- ClusterMesh: full peering by default within one fabric; explicit
  symmetric selective peers rendered from exports within that fabric
  (canonical shape A-B-C: B peers with A and C; A and C share no state
  and install no pod routes — leaf isolation). Separate routed-fabric
  instances = separate trust domains (negative test: no cross-domain
  routes).
- Role-scoped DNS and route consumption per SPEC (client VIP-only,
  admin +svc/pod zones + pod/ClusterIP routes, router upstream policy).
- Failure suites: hub withdrawal, node-bgp withdrawal, shared-bgp
  single-path withdrawal.
- Migration: once the routed-fabric replacement suites are green,
  DELETE the legacy implementation OUTRIGHT — the BIRD modules/lib
  files (e.g. lib/kube-cluster/bird*.nix and BIRD-specific renderers/
  options/tests), VXLAN remnants, the `wireguard-mesh` service, and the
  old fleet-routing code. No archived copies, no commented-out code.
  Historical documentation may remain. Every deletion removes the
  module AND its nix-unit/VM registrations in the same change so
  `checks.coverage` and eval stay coherent.

================================================================
8. Mandatory test matrix (every row green; eval or VM as appropriate)
================================================================

1. netif: multi-NIC and multi-instance, SFP+-shaped interface names,
   conflicting-ownership and duplicate-default-route eval negatives,
   MTU derivation.
2. One reachable hub: baseline fabric works with a single hub.
3. Two NAT sites with NO direct link: reachability via the hub(s).
4. Two hubs active-active: multi-flow ECMP; single-hub withdrawal
   converges without blackholing.
5. Router-not-hub: a router role is not a transit hub.
6. Stable host RIB/FIB: Zebra-installed routes, NO `r` (reject) routes,
   and NO IP default route unless an explicit policy table requires it.
7. External-transit crypto ACL: Internet-SOURCED inbound traffic via
   hub/router to a VIP with the source-policy return path; 0/0 and ::/0
   exist ONLY in the WG AllowedIPs; any installed/accepted default
   route is a negative.
8. MTU/PMTU on the fabric and pod paths.
9. Native dual-stack pod routes on both distros.
10. Local Cilium dual-AF advertisements to `::1` FRR with correct next
    hops, Zebra FIB installation in both families.
11. Classless LoadBalancer Services get Node IPAM (fabric scope).
12. `node-bgp` owner-only advertisement; `shared-bgp` ECMP and
    withdrawal.
13. member/client/admin/router isolation (what each role can and cannot
    reach); hub vs router orthogonality.
14. k3s + rke2 full data plane suites.
15. Selective ClusterMesh A-B-C: full peering is the default within one
    fabric; with the selective override, B peers with A and C while A
    and C share NO state and install NO pod routes for each other.
16. Separate routed-fabric trust domain: cross-domain route/pod negative.
17. kamrui-h1 shape: single-node k3s + admin dual-role, local Cilium
    intact.
18. No Cilium tunnel/iptables negatives (no VXLAN/Geneve, no
    Cilium-installed iptables rules, kube-proxy off).
19. Firewall positive AND negative exposure assertions (nftables).
20. Existing k3s/rke2 single/join/HA suites stay green.

================================================================
9. Final gates — all green IN THIS ORDER
================================================================

pkgs (already committed in Stage 1 — verify, don't redo):
- pkgs tree clean at your recorded SHA; `nix fmt .` ;
  `nix flake check --show-trace` green.

clanServices:
1. `git add -A` (new files staged before eval).
2. `nix fmt .`; restage anything it rewrote.
3. `nix build .#checks.x86_64-linux.treefmt`.
4. `nix flake check --no-build --show-trace` — read the output; zero
   eval warnings (including zero NEW deprecation warnings).
5. `nix build .#checks.x86_64-linux.nix-unit -L` — record the count.
6. Every VM suite, one at a time, sandboxed, log teed to
   .baton-pass/vm-logs/<suite>.log:
   `nix build --no-link .#checks.x86_64-linux.<suite>`
   Cover at minimum: netif, routed-fabric, k3s-single, k3s-join, k3s-ha,
   k3s-data-plane, rke2-single, rke2-join, rke2-ha, rke2-data-plane,
   plus every suite you added or touched.
7. `nix build .#packages.x86_64-linux.documentation` and
   `nix build .#packages.x86_64-linux.slides`.
8. `git diff --check` and `git diff --cached --check` clean.
9. Commit clanServices — aim for ONE coherent commit (message records
   round-15 MVP, the pkgs base SHA it pins, the full suite list with
   green status, and nix-unit counts). Do NOT commit red or partial
   work. If any gate is red: STOP, report the blocker with the failing
   command and log excerpts, and leave the tree staged.

================================================================
10. Final report (after the commits, or in place of them if blocked)
================================================================

- Commit SHA of BOTH repos (pkgs native-base commit + clanServices
  commit), or "blocked, not committed" + evidence for whichever failed.
- What was implemented, per stage; which SPEC.md decisions were amended
  and why.
- nix-unit count, full VM suite list with pass/fail, and every SPEC/
  documentation file updated.
- Probe findings from Stage 0.
- Say plainly if anything above was not verified.
````
