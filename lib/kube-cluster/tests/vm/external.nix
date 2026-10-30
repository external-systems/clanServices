{
  lib,
  inputs,
  distro,
  profile,
}: let
  native = profile == "native";
  k3s = distro == "k3s";
  clusterA = "${distro}-a";
  clusterB = "${distro}-b";
  dnsA = "mesh-${clusterA}.test.clan";
  dnsB = "mesh-${clusterB}.test.clan";
  dnsServerIp = stableIp "dns";
  ipA = "192.168.77.1";
  ipB = "192.168.77.3";
  runtimeUnit =
    if k3s
    then "k3s.service"
    else "rke2-server.service";
  kubeconfig = "/etc/rancher/${distro}/${distro}.yaml";
  marker = "${distro}-clustermesh-external-${profile}-ok";
  transportModule =
    if native
    then "routed-fabric"
    else "wireguard-mesh";
  underlayIp = name: "192.168.1.${
    toString
    {
      alpha = 1;
      beta = 2;
      gamma = 3;
      delta = 4;
      dns = 254;
    }
        .${
      name
    }
  }";
  stableIp = name: "192.168.77.${
    toString
    {
      alpha = 1;
      beta = 2;
      gamma = 3;
      delta = 4;
      dns = 5;
    }
        .${
      name
    }
  }";
  stableIp6 = name: "${
    if native
    then "fd77"
    else "fd00:77"
  }::${
    toString
    {
      alpha = 1;
      beta = 2;
      gamma = 3;
      delta = 4;
      dns = 5;
    }
        .${
      name
    }
  }";
  clusterSettings = id: dns: {
    network.fabric = {
      service = transportModule;
      instance = "mesh";
    };
    cilium.id = id;
    mesh = {
      exposure = "external-load-balancer";
      external = {
        loadBalancerClass = "cloud.fake/mesh-lb";
        dnsName = dns;
        annotations."external-dns.alpha.kubernetes.io/hostname" = dns;
      };
    };
  };
  mkNode = name: {pkgs, ...}: {
    imports = [
      (import ../../../../tests/ifstate-vm.nix {
        ifstateOverlay = inputs.pkgs.overlays.ifstate;
        addresses = ["${underlayIp name}/24"];
      })
    ];
    virtualisation = {
      cores = 2;
      memorySize = 3584;
      diskSize = 8192;
    };
    environment.sessionVariables.KUBECONFIG = kubeconfig;
    environment.systemPackages = [
      pkgs.kubectl
      pkgs.cilium-cli
      pkgs.openssl
      pkgs.socat
    ];
    networking.nameservers = lib.mkForce [dnsServerIp];
    services.resolved.enable = false;
    systemd.services = lib.optionalAttrs (name == "alpha" || name == "gamma") (
      let
        cluster =
          if name == "alpha"
          then clusterA
          else clusterB;
        ip =
          if name == "alpha"
          then ipA
          else ipB;
      in {
        "fake-external-lb-${cluster}" = {
          description = "Hermetic external LoadBalancer controller for ${cluster}";
          wantedBy = [];
          after = [runtimeUnit];
          path = [
            pkgs.kubectl
            pkgs.coreutils
            pkgs.jq
          ];
          environment.KUBECONFIG = kubeconfig;
          script = ''
            until kubectl get --raw=/readyz >/dev/null 2>&1; do
              sleep 2
            done
            while true; do
              if kubectl get service -n kube-system clustermesh-apiserver >/dev/null 2>&1; then
                kubectl patch service -n kube-system clustermesh-apiserver --type merge \
                  -p '{"spec":{"externalIPs":["${ip}"]}}'
                kubectl patch service -n kube-system clustermesh-apiserver --subresource status --type merge \
                  -p "$(jq -nc --arg ip '${ip}' '{status:{loadBalancer:{ingress:[{ip:$ip}]}}}')"
              fi
              sleep 2
            done
          '';
          serviceConfig = {
            Restart = "always";
            RestartSec = 5;
          };
        };
      }
    );
  };
in {
  name = "${distro}-clustermesh-external-${profile}";

  clan = {
    directory = ./.;
    test.useContainers = false;

    modules =
      lib.optionalAttrs native {
        routed-fabric = lib.modules.importApply ../../../../services/routed-fabric/default.nix {
          ifstateOverlay = inputs.pkgs.overlays.ifstate;
        };
      }
      // lib.optionalAttrs (!native) {
        wireguard-mesh = lib.modules.importApply ../../../../services/wireguard-mesh/default.nix {
          ifstateOverlay = inputs.pkgs.overlays.ifstate;
        };
      };
    exportInterfaces =
      {
        node_transport = ../../../../lib/node-transport-interface.nix;
      }
      // lib.optionalAttrs native {
        routed_fabric = ../../../../services/routed-fabric/routed-fabric-interface.nix;
      };

    inventory = {
      meta.domain = "test.clan";
      machines = {
        alpha = {};
        beta = {};
        gamma = {};
        delta = {};
        dns = {};
      };
      instances = {
        mesh = {
          module.name = transportModule;
          module.input = "self";
          roles =
            if native
            then {
              spine.machines = {
                alpha.settings = {
                  ipv4 = stableIp "alpha";
                  ipv6 = stableIp6 "alpha";
                  endpoint = underlayIp "alpha";
                };
                gamma.settings = {
                  ipv4 = stableIp "gamma";
                  ipv6 = stableIp6 "gamma";
                  endpoint = underlayIp "gamma";
                };
              };
              leaf.machines = {
                beta.settings = {
                  ipv4 = stableIp "beta";
                  ipv6 = stableIp6 "beta";
                  endpoint = underlayIp "beta";
                };
                delta.settings = {
                  ipv4 = stableIp "delta";
                  ipv6 = stableIp6 "delta";
                  endpoint = underlayIp "delta";
                };
                dns.settings = {
                  ipv4 = stableIp "dns";
                  ipv6 = stableIp6 "dns";
                  endpoint = underlayIp "dns";
                  access = "admin";
                };
              };
            }
            else {
              peer.machines = lib.genAttrs ["alpha" "beta" "gamma" "delta" "dns"] (name: {
                settings = {
                  ipv4 = stableIp name;
                  ipv6 = stableIp6 name;
                  endpoint = underlayIp name;
                };
              });
            };
        };
        ${clusterA} = {
          module.name = distro;
          module.input = "self";
          roles.server = {
            settings = clusterSettings 1 dnsA;
            machines = {
              alpha.settings.clusterInit = true;
              beta.settings.clusterInit = false;
            };
          };
        };
        ${clusterB} = {
          module.name = distro;
          module.input = "self";
          roles.server = {
            settings = clusterSettings 2 dnsB;
            machines = {
              gamma.settings.clusterInit = true;
              delta.settings.clusterInit = false;
            };
          };
        };
      };
    };
  };

  nodes =
    (lib.genAttrs ["alpha" "beta" "gamma" "delta"] mkNode)
    // {
      dns = {
        imports = [
          (import ../../../../tests/ifstate-vm.nix {
            ifstateOverlay = inputs.pkgs.overlays.ifstate;
            addresses = ["${underlayIp "dns"}/24"];
            routes = [
              {
                to = "10.1.0.0/16";
                via = underlayIp "alpha";
                dev = "eth1";
              }
              {
                to = "10.3.0.0/16";
                via = underlayIp "gamma";
                dev = "eth1";
              }
            ];
          })
        ];
        networking = {
          nameservers = lib.mkForce [dnsServerIp];
          firewall = {
            allowedTCPPorts = [53];
            allowedUDPPorts = [53];
          };
        };
        # The DNS VM is outside both clusters, so tunnel-profile pod return
        # traffic uses each cluster's init node. Native admin routes also exist.
        services.dnsmasq = {
          enable = true;
          settings = {
            listen-address = dnsServerIp;
            bind-dynamic = true;
            no-resolv = true;
            log-queries = true;
            address = [
              "/${dnsA}/${ipA}"
              "/${dnsB}/${ipB}"
            ];
          };
        };
      };
    };

  testScript = ''
    def fail_dump(m):
        for cmd in [
            "ip -br addr >&2",
            "ip route >&2; ip -6 route >&2",
            "wg show all >&2 || true",
            "journalctl -u ${runtimeUnit} --no-pager -l | tail -n 60 >&2 || true",
            "journalctl -u '${distro}-${clusterA}-clustermesh-secrets' --no-pager -l | tail -n 40 >&2 || true",
            "journalctl -u 'fake-external-lb-${clusterA}' --no-pager -l | tail -n 40 >&2 || true",
            "kubectl get nodes,pods -A -o wide >&2 || true",
            "kubectl get service -n kube-system clustermesh-apiserver -o yaml >&2 || true",
            "kubectl describe pod -n kube-system -l k8s-app=clustermesh-apiserver --request-timeout=10s >&2 || true",
            "timeout 20 cilium status >&2 || true",
            "timeout 20 cilium clustermesh status >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=cilium --all-containers=true --tail=80 >&2 || true",
            "kubectl logs -n kube-system -l k8s-app=clustermesh-apiserver --all-containers=true --tail=80 >&2 || true",
            "kubectl logs -n kube-system deployment/coredns --all-containers=true --tail=60 >&2 || true",
        ]:
            m.execute(cmd)

    try:
        start_all()
        dns.wait_for_unit("dnsmasq.service", timeout=120)
        machines = [alpha, beta, gamma, delta]
        for m in machines:
            m.wait_until_succeeds("systemctl show -p Result --value ifstate.service | grep -q '^success$'", timeout=120)
            m.wait_until_succeeds(
                "wg show all latest-handshakes | awk 'NF > 0 {n++; if ($3 == 0) bad=1} END {exit !(n > 0 && !bad)}'",
                timeout=120,
            )
            m.wait_for_unit("haproxy.service", timeout=240)
            m.wait_for_unit("${runtimeUnit}", timeout=600)

        for m, cluster in [(alpha, "${clusterA}"), (gamma, "${clusterB}")]:
            m.wait_until_succeeds(
                f"systemctl show -p Result --value ${distro}-{cluster}-bootstrap-apply | grep -q '^success$'",
                timeout=900,
            )
            m.wait_until_succeeds(
                f"systemctl show -p Result --value ${distro}-{cluster}-clustermesh-secrets | grep -q '^success$'",
                timeout=300,
            )

        alpha.wait_until_succeeds("kubectl wait --for=condition=Ready node/alpha node/beta --timeout=120s", timeout=300)
        gamma.wait_until_succeeds("kubectl wait --for=condition=Ready node/gamma node/delta --timeout=120s", timeout=300)
        alpha.wait_until_succeeds("cilium status", timeout=180)
        gamma.wait_until_succeeds("cilium status", timeout=180)

        if ${
      if native
      then "False"
      else "True"
    }:
            for m in [alpha, gamma]:
                m.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.routing-mode}' | grep -qx tunnel")
                m.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.tunnel-protocol}' | grep -qx vxlan")
                m.succeed("kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.mtu}' | grep -qx 1370")

        for m, cluster in [(alpha, "${clusterA}"), (gamma, "${clusterB}")]:
            m.succeed(f"systemctl start fake-external-lb-{cluster}.service")

        for m in [alpha, gamma]:
            m.wait_until_succeeds(
                "kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=clustermesh-apiserver --timeout=180s",
                timeout=300,
            )
            m.succeed("kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.type}' | grep -q '^LoadBalancer$'")
            m.succeed("kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.loadBalancerClass}' | grep -q '^cloud.fake/mesh-lb$'")
            m.succeed("kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.spec.externalTrafficPolicy}' | grep -q '^Local$'")
            m.succeed("test -z \"$(kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{.metadata.annotations.lbipam\\.cilium\\.io/ips}')\"")

        for m, fqdn, ip in [(alpha, "${dnsA}", "${ipA}"), (gamma, "${dnsB}", "${ipB}")]:
            m.wait_until_succeeds(
                f"kubectl -n kube-system get service clustermesh-apiserver -o jsonpath='{{.status.loadBalancer.ingress[0].ip}}' | grep -q '^{ip}$'",
                timeout=240,
            )
            m.wait_until_succeeds(
                f"kubectl get secret -n kube-system clustermesh-apiserver-server-cert -o jsonpath='{{.data.tls\\.crt}}' | base64 -d | openssl x509 -noout -text | grep -q 'DNS:{fqdn}'",
                timeout=120,
            )

        # Real DNS resolution and data-plane traffic through the fake
        # provider's DNS-published external LoadBalancer address.
        for source in machines:
            source.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.ca\\.crt}' | base64 -d > /tmp/clustermesh-ca.crt")
            source.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\\.crt}' | base64 -d > /tmp/clustermesh-client.crt")
            source.succeed("kubectl -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\\.key}' | base64 -d > /tmp/clustermesh-client.key")
            source.wait_until_succeeds("ping -c 2 -W 3 ${dnsServerIp}", timeout=120)
            for fqdn, ip in [("${dnsA}", "${ipA}"), ("${dnsB}", "${ipB}")]:
                source.succeed(f"getent ahostsv4 {fqdn} | grep -q '^{ip} '")
                source.wait_until_succeeds(
                    f"curl -s --cacert /tmp/clustermesh-ca.crt --cert /tmp/clustermesh-client.crt --key /tmp/clustermesh-client.key --max-time 5 https://{fqdn}:2379/health -o /dev/null -w '%{{http_code}}' | grep -qx 200",
                    timeout=240,
                )

        alpha.wait_until_succeeds("cilium clustermesh status | grep -q '${clusterB}'", timeout=300)
        gamma.wait_until_succeeds("cilium clustermesh status | grep -q '${clusterA}'", timeout=300)
        print("${marker}")
    except Exception:
        for cmd in [
            "ip -br addr >&2",
            "ip route >&2",
            "ss -lntup >&2",
            "journalctl -u dnsmasq --no-pager -l | tail -n 100 >&2 || true",
        ]:
            dns.execute(cmd)
        for m in [alpha, beta, gamma, delta]:
            try:
                fail_dump(m)
            except Exception:
                pass
        raise
  '';
}
