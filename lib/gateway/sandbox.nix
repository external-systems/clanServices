# The systemd sandbox of lib/gateway's long-running helpers (the health
# check, the CLAT follower; specs/gateway.md §17, G14). They stay root:
# `systemctl` and `ip netns exec` need it. Each unit adds the
# capabilities it uses as `CapabilityBoundingSet`.
{
  NoNewPrivileges = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  ProtectKernelModules = true;
  ProtectKernelLogs = true;
  ProtectControlGroups = true;
  ProtectClock = true;
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  LockPersonality = true;
  SystemCallArchitectures = "native";
  RestrictAddressFamilies = ["AF_UNIX" "AF_NETLINK" "AF_INET" "AF_INET6"];
}
