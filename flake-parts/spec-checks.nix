# Static checks on the spec files and on what the specs depend on
# (specs/gateway.md §12.2, §12.5).
{lib, ...}: {
  perSystem = {pkgs, ...}: {
    # Section numbers of a spec ascend: `## N.` by one or more, `### N.M`
    # inside its own section. A section that sits out of order is found
    # by neither readers nor agents.
    checks.spec-headings =
      pkgs.runCommand "spec-headings" {
        specs = lib.fileset.toSource {
          root = ../.;
          fileset = lib.fileset.union ../SPEC.md (lib.fileset.fileFilter (file: file.hasExt "md") ../specs);
        };
      } ''
        for file in "$specs"/SPEC.md "$specs"/specs/*.md; do
          awk -v file="$(basename "$file")" '
            /^```/ { code = !code }
            code { next }
            /^## [0-9]+\. / {
              split($2, n, ".")
              if (n[1] + 0 <= section + 0 && seen) { printf "%s: section %s follows section %s\n", file, n[1], section; bad = 1 }
              section = n[1]; minor = 0; seen = 1; next
            }
            /^### [0-9]+\.[0-9]+ / {
              split($2, n, ".")
              if (n[1] != section) { printf "%s: heading %s sits in section %s\n", file, $2, section; bad = 1 }
              if (n[2] + 0 <= minor + 0) { printf "%s: heading %s follows %s.%s\n", file, $2, section, minor; bad = 1 }
              minor = n[2]
            }
            END { exit bad }
          ' "$file"
        done
        touch $out
      '';

    # Jool is an out-of-tree kernel module and the only translator of
    # the NAT64 gateways and the CLATs (specs/gateway.md G2, G23). This
    # fails at evaluation when nixpkgs marks it broken or unavailable
    # for a kernel the fleet may run; the `nat-gateway` suite proves it
    # loads and translates.
    checks.jool-available = let
      kernels = {
        default = pkgs.linuxPackages;
        latest = pkgs.linuxPackages_latest;
      };
      unusable = lib.filterAttrs (_: kernel: kernel.jool.meta.broken || !(lib.meta.availableOn pkgs.stdenv.hostPlatform kernel.jool)) kernels;
    in
      if unusable != {}
      then throw "Jool is broken or unavailable for the kernel packages: ${lib.concatStringsSep ", " (builtins.attrNames unusable)}"
      else
        pkgs.runCommand "jool-available" {
          versions = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: kernel: "${name}: kernel ${kernel.kernel.version}, jool ${kernel.jool.version}") kernels);
        } ''
          echo "$versions"
          touch $out
        '';
  };
}
