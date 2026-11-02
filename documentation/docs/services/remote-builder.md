# remote-builder

A fleet utility, outside the Kubernetes contracts (D65): nix builds offloaded
to a build machine over `ssh-ng`, nixbuild.net style. The service code and
its eval tests live in `services/remote-builder/`.

Remote nix builds in the style of [nixbuild.net](https://docs.nixbuild.net/getting-started/),
on machines of a clan. Generators are named after the instance, shown here
for an instance called `remote-builder`.

```nix
inventory.instances.remote-builder = {
  module = {
    input = "clanServices";
    name = "remote-builder";
  };
  roles = {
    server.machines.builder.settings.address = "builder.example.com";
    client.tags.pc = {};
  };
};
```

- **server** serves its nix store over `ssh-ng` to the restricted `nix-ssh`
  user (`nix.sshServe`: no shell, no forwarding, `nix-daemon --stdio`). It
  advertises `benchmark`, `big-parallel`, `kvm` and `nixos-test`, and builds
  `aarch64-linux` through binfmt emulation. Its host key is a clan var
  (`remote-builder-host-key`), so clients trust it without a prompt.
- **client** gets its own keypair (`remote-builder-client`, readable by root
  for nix-daemon), a `nix.buildMachines` entry per server,
  `builders-use-substitutes`, an ssh alias that fails fast when the server
  is down (`ConnectTimeout 5`, dead connections dropped after about 45s), and
  the server's host key in `/etc/ssh/ssh_known_hosts`.
- **CI**: with `ciKey.enabled` (default), the server also authorizes a shared
  key whose private half is never deployed. Hand it to CI:

  ```sh
  clan vars get <server> remote-builder-ci/id_ed25519
  ```

  and point the runner at the server (`ssh-ng://nix-ssh@<address>`), either
  as a builder (`--builders`) or as a remote store
  (`--store ssh-ng://nix-ssh@<address> --eval-store auto`).

Every authorized key can write to the server's store as a trusted user. Only
list keys you would give root on that store.

## Order of operations

Server and clients read each other's public vars, so generate before
deploying:

```sh
clan vars generate <server> <client>...   # keys and host key
clan machines update <server>             # authorizes the client keys
clan machines update <client>...          # buildMachines + known_hosts
```

A client added later needs `clan vars generate <client>` and a server
redeploy before its builds are accepted.

## Try it

On a client:

```sh
sudo nix store info --store ssh-ng://<server>    # as root, like nix-daemon
nix build --max-jobs 0 --rebuild nixpkgs#hello   # local jobs off: must build remotely
```
