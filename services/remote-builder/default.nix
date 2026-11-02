# Remote nix builders in the style of nixbuild.net: a build server
# serves its store over ssh-ng to a restricted `nix-ssh` user (no shell,
# no forwarding, ForceCommand nix-daemon --stdio), every client machine
# authenticates with its own clan-generated key, and one shared CI key
# (operator-only private half) lets CI runners build there too.
#
# Multi-instance safe: every generator, ssh alias and known-hosts entry is
# named after the instance (`<instance>-client`, `<instance>-host-key`,
# `<instance>-ci`), so an instance called "remote-builder" keeps the
# generator names it had in external-systems/home.
{clanLib, ...}: {
  _class = "clan.service";
  manifest = {
    name = "remote-builder";
    description = "nixbuild.net-style remote nix builders over ssh-ng, with per-machine client keys and a CI key";
    readme = builtins.readFile ./README.md;
    categories = ["System"];
  };

  roles = {
    server = {
      description = "Build machine: serves its nix store over ssh-ng to the clients' keys and the CI key";
      interface = {lib, ...}: {
        options = {
          address = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Address clients connect to (IP or DNS name). null: the machine name.";
          };
          systems = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["x86_64-linux" "aarch64-linux"];
            description = "Systems offered to clients. Systems other than the server's own are emulated with binfmt (qemu-user), like nixbuild.net's aarch64 builds.";
          };
          maxJobs = lib.mkOption {
            type = lib.types.ints.positive;
            default = 16;
            description = "Builds a client may run on the server at once (buildMachines maxJobs).";
          };
          speedFactor = lib.mkOption {
            type = lib.types.ints.positive;
            default = 10;
            description = "Preference relative to other builders, the local machine counting 1.";
          };
          supportedFeatures = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["benchmark" "big-parallel" "kvm" "nixos-test"];
            description = "Nix system features the server advertises and clients route by (kvm/nixos-test: VM tests).";
          };
          ciKey.enabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Generate a shared CI keypair (clan var <instance>-ci,
              private half never deployed) and authorize it. Put the
              private half into the CI system's secrets:
              clan vars get <server> <instance>-ci/id_ed25519
            '';
          };
          authorizedKeys = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Extra public keys allowed to build (keys not managed by clan).";
          };
        };
      };

      perInstance = {
        instanceName,
        roles,
        settings,
        ...
      }: {
        nixosModule = {
          config,
          lib,
          pkgs,
          ...
        }: let
          inherit (config.clan.core.vars) generators;
          hostKeyGen = "${instanceName}-host-key";
          ciGen = "${instanceName}-ci";
          ciPub = generators.${ciGen}.files."id_ed25519.pub";

          # Each client's public key, once `clan vars generate <client>`
          # has created it; clients without one yet are skipped.
          clientKeys = lib.filter (key: key != null) (map (machine:
            clanLib.getPublicValue {
              flake = config.clan.core.settings.directory;
              inherit machine;
              generator = "${instanceName}-client";
              file = "id_ed25519.pub";
              default = null;
            })
          (lib.attrNames (roles.client.machines or {})));

          hostSystem = pkgs.stdenv.hostPlatform.system;
        in {
          clan.core.vars.generators = {
            # Pinned host key, so clients can trust the server without a
            # TOFU prompt (nix-daemon's ssh cannot answer one).
            ${hostKeyGen} = {
              files = {
                ssh_host_ed25519_key = {};
                "ssh_host_ed25519_key.pub".secret = false;
              };
              runtimeInputs = [pkgs.openssh];
              script = ''
                ssh-keygen -t ed25519 -N "" -C "" -f "$out"/ssh_host_ed25519_key
              '';
            };

            ${ciGen} = lib.mkIf settings.ciKey.enabled {
              share = true;
              files = {
                # Operator-only: handed to CI, never uploaded anywhere.
                id_ed25519.deploy = false;
                "id_ed25519.pub".secret = false;
              };
              runtimeInputs = [pkgs.openssh];
              script = ''
                ssh-keygen -t ed25519 -N "" -C "${ciGen}" -f "$out"/id_ed25519
              '';
            };
          };

          services.openssh = {
            enable = true;
            hostKeys = [
              {
                inherit (generators.${hostKeyGen}.files.ssh_host_ed25519_key) path;
                type = "ed25519";
              }
            ];
          };

          # The store over ssh-ng for the restricted nix-ssh user. trusted
          # is what lets clients upload build inputs and run builds, and it
          # makes every authorized key store-root on this machine: only
          # fleet keys and the CI key are listed.
          nix = {
            sshServe = {
              enable = true;
              protocol = "ssh-ng";
              write = true;
              trusted = true;
              keys =
                clientKeys
                ++ lib.optional (settings.ciKey.enabled && ciPub.exists) ciPub.value
                ++ settings.authorizedKeys;
            };

            settings = {
              system-features = settings.supportedFeatures;
              max-jobs = "auto";
              cores = 0;
              # Fetch dependencies from caches here instead of streaming
              # them from the client.
              builders-use-substitutes = true;
              # Keep room for builds: collect garbage when the store disk
              # runs low.
              min-free = 20 * 1024 * 1024 * 1024;
              max-free = 100 * 1024 * 1024 * 1024;
            };

            gc = {
              automatic = lib.mkDefault true;
              dates = lib.mkDefault "weekly";
              options = lib.mkDefault "--delete-older-than 14d";
            };
          };

          # Non-native systems via qemu-user (sets extra-platforms).
          boot.binfmt.emulatedSystems = lib.filter (system: system != hostSystem) settings.systems;
        };
      };
    };

    client = {
      description = "Machine that sends its builds to every server of the instance";
      perInstance = {
        instanceName,
        roles,
        ...
      }: {
        nixosModule = {
          config,
          lib,
          pkgs,
          ...
        }: let
          clientGen = "${instanceName}-client";
          keyFile = config.clan.core.vars.generators.${clientGen}.files.id_ed25519.path;

          servers =
            lib.mapAttrsToList (name: machine: let
              inherit (machine) settings;
            in {
              inherit name settings;
              address =
                if settings.address != null
                then settings.address
                else name;
              hostKey = clanLib.getPublicValue {
                flake = config.clan.core.settings.directory;
                machine = name;
                generator = "${instanceName}-host-key";
                file = "ssh_host_ed25519_key.pub";
                default = null;
              };
            })
            (roles.server.machines or {});
        in {
          clan.core.vars.generators.${clientGen} = {
            files = {
              # Read by nix-daemon (root) when it opens the ssh connection.
              id_ed25519 = {};
              "id_ed25519.pub".secret = false;
            };
            runtimeInputs = [pkgs.openssh];
            script = ''
              ssh-keygen -t ed25519 -N "" -C "${instanceName}@${config.clan.core.settings.machine.name}" -f "$out"/id_ed25519
            '';
          };

          nix = {
            distributedBuilds = true;
            settings.builders-use-substitutes = true;
            buildMachines =
              map (server: {
                # The ssh alias below carries the real address.
                hostName = server.name;
                protocol = "ssh-ng";
                sshUser = "nix-ssh";
                sshKey = keyFile;
                inherit (server.settings) systems maxJobs speedFactor supportedFeatures;
              })
              servers;
          };

          programs.ssh = {
            extraConfig =
              lib.concatMapStrings (server: ''
                Host ${server.name}
                  HostName ${server.address}
                  User nix-ssh
                  IdentityFile ${keyFile}
                  # Fail fast when the builder is down so nix falls back
                  # to the next machine or a local build instead of
                  # waiting on the kernel's ~2 min TCP SYN retries, and
                  # drop a dead mid-build connection after ~45s.
                  ConnectTimeout 5
                  ConnectionAttempts 1
                  ServerAliveInterval 15
                  ServerAliveCountMax 3
              '')
              servers;

            knownHosts = lib.listToAttrs (map (server: {
              name = "${instanceName}-${server.name}";
              value = {
                hostNames = lib.unique [server.name server.address];
                publicKey = server.hostKey;
              };
            }) (lib.filter (server: server.hostKey != null) servers));
          };
        };
      };
    };
  };
}
