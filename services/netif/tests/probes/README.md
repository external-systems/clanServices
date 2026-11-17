# netif probes

Probes are small NixOS VM tests that showed a fact the netif contract
relies on, before a suite asserts it (`specs/netif.md` N40, evidence in
§8). They are not in `checks` or `vmTests`, and CI never runs them.

| Probe | What it showed | Suite that takes it over |
|---|---|---|
| `wifi` | iwd's route metric in both families beside IfState (N18) | `netif-wifi` (P2) |
| `modes-eval` | modes as specialisations with a read-only mode option (N24); evaluation only | `netif-modes` (P4) |

Run one on a machine with KVM:

```sh
nix build .#netifProbes.wifi
nix eval --json .#netifProbes.modes-eval
```

Delete a probe in the change that makes its suite assert the same thing.
