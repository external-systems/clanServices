{
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: let
    vmTest = pkgs.writeShellApplication {
      name = "vm-test";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.git
        pkgs.gnugrep
      ];
      text = ''
        suites=(${lib.escapeShellArgs (builtins.attrNames config.legacyPackages.vmTests)})

        expected_marker() {
          printf '%s' "$1" | tr 'a-z-' 'A-Z_'
          printf '_OK\n'
        }

        if [[ $# -eq 1 && $1 == --list ]]; then
          for suite in "''${suites[@]}"; do
            printf '%s %s\n' "$suite" "$(expected_marker "$suite")"
          done
          exit 0
        fi

        rebuild=0
        if [[ $# -eq 2 && $1 == --rebuild ]]; then
          rebuild=1
          shift
        fi
        if [[ $# -ne 1 ]]; then
          printf 'usage: vm-test [--list | [--rebuild] <suite>]\n' >&2
          exit 2
        fi

        suite=$1
        valid=0
        for candidate in "''${suites[@]}"; do
          if [[ $candidate == "$suite" ]]; then
            valid=1
            break
          fi
        done
        if [[ $valid -eq 0 ]]; then
          printf 'unknown VM suite: %s\nuse --list to see available suites\n' "$suite" >&2
          exit 2
        fi

        repo_root=$(git rev-parse --show-toplevel)
        cd "$repo_root"
        log_dir=".baton-pass/vm-logs/$suite"
        mkdir -p "$log_dir"
        n=0
        log="$log_dir/logs-$n"
        set -o noclobber
        while ! : 2>/dev/null > "$log"; do
          if [[ ! -e $log ]]; then
            printf 'cannot create VM log: %s\n' "$log" >&2
            exit 1
          fi
          ((n += 1))
          log="$log_dir/logs-$n"
        done
        set +o noclobber

        target=.#legacyPackages.${pkgs.stdenv.hostPlatform.system}.vmTests.$suite
        build_args=("$target" --no-link -L --print-out-paths)
        if [[ $rebuild -eq 1 ]] && nix path-info "$target" > /dev/null 2>&1; then
          build_args+=(--rebuild)
        fi
        set +e
        nix build "''${build_args[@]}" 2>&1 | tee -a "$log"
        status=''${PIPESTATUS[0]}
        set -e
        if [[ $status -eq 0 ]]; then
          marker=$(expected_marker "$suite")
          if ! grep -F -- "$marker" "$log" > /dev/null; then
            printf 'suite %s exited 0 but did not print %s\n' "$suite" "$marker" >&2
            status=1
          fi
        fi
        printf 'VM build log: %s\n' "$log"
        exit "$status"
      '';
    };
  in {
    apps.vm-test = {
      type = "app";
      program = lib.getExe vmTest;
      meta.description = "Build one VM suite and save its numbered log";
    };
  };
}
