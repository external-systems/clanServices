# Docs site and deck (org-pkgs flakeModules.docs): only what differs from
# the org defaults.
_: {
  perSystem.docs = {
    repo = "clanServices";
    settings = {
      site_name = "External Systems — Kubernetes cluster clanServices";
      site_description = "Declare machines in one inventory file and get secure, interconnected Kubernetes clusters.";
      nav = [
        {Home = "index.md";}
        {Presentation = "presentation.md";}
        {
          Architecture = [
            {Overview = "architecture/overview.md";}
            {Networking = "architecture/networking.md";}
            {Multi-cluster = "architecture/multi-cluster.md";}
            {"Routed fabric" = "architecture/routed-fabric.md";}
            {"Network diagrams" = "architecture/network-diagrams.md";}
            {GitOps = "architecture/gitops.md";}
            {Security = "architecture/security.md";}
          ];
        }
        {
          "Host networking (netif)" = [
            {Overview = "netif/index.md";}
            {"What netif is responsible for" = "netif/responsibility.md";}
            {"Use cases" = "netif/use-cases.md";}
            {"Modes and reboots" = "netif/modes.md";}
            {Wi-Fi = "netif/wifi.md";}
            {"Ownership and VPNs" = "netif/ownership.md";}
            {"Home router" = "netif/router.md";}
            {"Plan and evidence" = "netif/plan.md";}
            {"Retrospective and hardening" = "netif/hardening.md";}
            {Glossary = "netif/glossary.md";}
          ];
        }
        {
          "Router and NAT gateway" = [
            {Overview = "gateway/index.md";}
            {"Home and on-prem router" = "gateway/router.md";}
            {"Cloud NAT gateway" = "gateway/nat-gateway.md";}
            {"Exposing services" = "gateway/exposure.md";}
            {"Plan and probes" = "gateway/plan.md";}
            {Retrospective = "gateway/retrospective.md";}
          ];
        }
        {Decisions = [{"Decision record" = "decisions/index.md";}];}
        {
          Services = [
            {Overview = "services/index.md";}
            {rke2 = "services/rke2.md";}
            {k3s = "services/k3s.md";}
            {"kubernetes (upstream, reserved)" = "services/kubernetes.md";}
            {netif = "services/netif.md";}
            {routed-fabric = "services/routed-fabric.md";}
            {wireguard-mesh = "services/wireguard-mesh.md";}
            {remote-builder = "services/remote-builder.md";}
          ];
        }
        {
          Guides = [
            {"Day-2 GitOps" = "guides/day-2-gitops.md";}
            {"Airgap operation" = "guides/airgap.md";}
            {Upgrades = "guides/upgrades.md";}
            {Secrets = "guides/secrets.md";}
            {"Routed-fabric MVP (implementation prompt)" = "guides/routed-fabric-mvp-prompt.md";}
            {"Stage-0 probe lessons" = "guides/stage0-probe-lessons.md";}
          ];
        }
        {
          Plans = [
            {"Data-plane hardening" = "plans/data-plane-hardening.md";}
            {"Agent brief" = "plans/agent-brief.md";}
            {
              "Phase prompts" = [
                {"1. Tooling and flake inputs" = "plans/phase-1-tooling/prompt.md";}
                {"2. Correctness and stability" = "plans/phase-2-correctness/prompt.md";}
                {"3. Allocation with clan vars" = "plans/phase-3-allocation/prompt.md";}
                {"4. netif underlay" = "plans/phase-4-netif-underlay/prompt.md";}
                {"5. Facts and synthetic clans" = "plans/phase-5-facts-and-clans/prompt.md";}
                {"6. VM harness" = "plans/phase-6-vm-harness/prompt.md";}
                {"7. Gateway and floating IPs" = "plans/phase-7-gateway/prompt.md";}
                {"8. terranix + OpenTofu" = "plans/phase-8-opentofu/prompt.md";}
                {"9. Proxmox and breadth" = "plans/phase-9-proxmox-and-breadth/prompt.md";}
              ];
            }
          ];
        }
        {
          Reference = [
            {Glossary = "reference/glossary.md";}
            {Testing = "reference/testing.md";}
            {"Upstream references" = "reference/upstream.md";}
          ];
        }
      ];
    };
    slides = {
      title = "Kubernetes cluster clanServices";
      # This deck's own blocks (kinds, levels, cols), after the org style.
      extraHead = ''<link rel="stylesheet" href="custom.css" />'';
    };
  };
}
