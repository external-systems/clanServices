{inputs, ...}: {
  imports = [
    inputs.treefmt-nix.flakeModule
  ];

  perSystem = {
    treefmt.programs = {
      alejandra.enable = true;
      deadnix = {
        enable = true;
        no-lambda-pattern-names = true;
      };
      nixf-diagnose = {
        enable = true;
        autoFix = false;
        only = "sema-primop-removed-prefix";
      };
      shellcheck.enable = true;
      sizelint.enable = true;
      statix.enable = true;
    };
  };
}
