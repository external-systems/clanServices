{
  module,
  clanLib,
  lib,
  ...
}: let
  machines =
    lib.genAttrs ["builder" "laptop" "desk"]
    (_: {nixpkgs.hostPlatform = "x86_64-linux";});

  evaled = clanLib.clan {
    self = {};
    # No vars here: the state every machine is in before
    # `clan vars generate`.
    directory = ./.;
    inherit machines;
    modules.remote-builder = module;
    inventory.instances = {
      remote-builder = {
        module = {
          name = "remote-builder";
          input = "self";
        };
        roles = {
          server.machines.builder.settings.address = "192.0.2.10";
          client.machines.laptop = {};
        };
      };
      # A second instance: every global is namespaced by instance name.
      ci-builders = {
        module = {
          name = "remote-builder";
          input = "self";
        };
        roles = {
          server.machines.builder.settings.ciKey.enabled = false;
          client.machines.desk = {};
        };
      };
    };
  };

  cfg = name: evaled.config.nixosConfigurations.${name}.config;
  builder = cfg "builder";
  laptop = cfg "laptop";
  desk = cfg "desk";
  generatorNames = c: lib.sort lib.lessThan (lib.attrNames c.clan.core.vars.generators);
in {
  server = {
    test_generatorsNamespacedByInstance = {
      expr = lib.filter (n: lib.hasPrefix "remote-builder" n || lib.hasPrefix "ci-builders" n) (generatorNames builder);
      expected = ["ci-builders-host-key" "remote-builder-ci" "remote-builder-host-key"];
    };
    test_sshServe = {
      expr = {
        inherit (builder.nix.sshServe) enable protocol write trusted;
        # No client key or CI key generated yet.
        inherit (builder.nix.sshServe) keys;
      };
      expected = {
        enable = true;
        protocol = "ssh-ng";
        write = true;
        trusted = true;
        keys = [];
      };
    };
    # Both instances serve from builder; list options merge, so compare
    # the distinct values.
    test_systemFeatures = {
      expr = lib.sort lib.lessThan (lib.unique builder.nix.settings.system-features);
      expected = ["benchmark" "big-parallel" "kvm" "nixos-test"];
    };
    test_aarch64ByBinfmt = {
      expr = lib.attrNames builder.boot.binfmt.registrations;
      expected = ["aarch64-linux"];
    };
  };

  client = {
    test_buildMachine = {
      expr = map (m: {inherit (m) hostName protocol sshUser systems maxJobs speedFactor;}) laptop.nix.buildMachines;
      expected = [
        {
          hostName = "builder";
          protocol = "ssh-ng";
          sshUser = "nix-ssh";
          systems = ["x86_64-linux" "aarch64-linux"];
          maxJobs = 16;
          speedFactor = 10;
        }
      ];
    };
    test_distributedBuilds = {
      expr = {inherit (laptop.nix) distributedBuilds;};
      expected = {distributedBuilds = true;};
    };
    test_sshAliasFailsFast = {
      expr = map (s: lib.hasInfix s laptop.programs.ssh.extraConfig) [
        "Host builder"
        "HostName 192.0.2.10"
        "User nix-ssh"
        "ConnectTimeout 5"
        "ServerAliveCountMax 3"
      ];
      expected = [true true true true true];
    };
    test_addressDefaultsToMachineName = {
      expr = lib.hasInfix "HostName builder" desk.programs.ssh.extraConfig;
      expected = true;
    };
    test_clientGeneratorPerInstance = {
      expr = {
        laptop = laptop.clan.core.vars.generators ? remote-builder-client;
        desk = desk.clan.core.vars.generators ? ci-builders-client;
        deskOther = desk.clan.core.vars.generators ? remote-builder-client;
      };
      expected = {
        laptop = true;
        desk = true;
        deskOther = false;
      };
    };
    test_noKnownHostBeforeGeneration = {
      expr = laptop.programs.ssh.knownHosts ? remote-builder-builder;
      expected = false;
    };
  };
}
