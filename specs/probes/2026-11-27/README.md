# Probe round of 2026-11-27 (SPEC.md round 61)

One findings file per area. Each is the probe engineer's record for the
design file of that area: one row per probe or assumption, with the
suite and the log lines.

| File | Design |
|---|---|
| `fabric.md` | `specs/design-routed-fabric.md` |
| `kube.md` | `specs/design-kube.md` |
| `gateway.md` | `specs/design-gateway.md` |
| `netif.md` | `specs/design-netif.md` |

How to read them:

- **VERIFIED-VM**: a NixOS VM suite on the remote builder showed it, on
  a prototype applied to `main` at `deeaba4`.
- **REFUTED**: a probe disagreed with the design. The design file
  already follows the probe.
- **NOT-RUN**: designed, not booted. The step that builds it must prove
  it.

What is here and what is not:

- These files are in the repo. The design files cite them.
- The prototypes (`prototype.patch` per area), the saved run lines
  (`runs/`) and the kube manifests are session evidence. They are not
  in the repo. The session handoff maps them. Where a findings or
  design file names `prototype.patch`, `runs/`, `manifests/`,
  `reviews/` or `patches/`, it means that evidence folder.
- A prototype is evidence, not the implementation. Each ran without
  `check`; some nix-unit tests fail on them. Build each step from the
  design file's §8 and use the prototype as a worked example.
- Probe suites named `*-probe-*` or `probe-*` were throwaway. They are
  not on `main`.
