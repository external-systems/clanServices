# Wi-Fi

iwd owns Wi-Fi in every mode. IfState never configures a Wi-Fi link.

| Mode | Who joins networks | How you join a new one |
|---|---|---|
| gaming (NetworkManager) | NetworkManager, with iwd as its Wi-Fi backend | Steam's network settings, or the KDE applet |
| developer, kubernetes (IfState) | iwd alone, which also runs DHCP and sends DNS to systemd-resolved | `iwctl`, or an iwd front end such as iwgtk |

## Networks follow you between modes

Known networks live in `/var/lib/iwd`, which every mode shares:

- NetworkManager writes a copy of each Wi-Fi profile there. That is its
  default `iwd-config-path = auto` setting.
- In developer mode, iwd joins those networks on its own.
- A network you join with `iwctl` in developer mode shows up in
  NetworkManager, and so in Steam's network list, after you reboot into
  gaming.

So a café you joined from Steam's UI works after you reboot into developer
mode, and the other way round.

## Networks you have never seen

Join them on the spot: from Steam's UI or KDE in gaming mode, or with `iwctl`
in developer mode:

```bash
iwctl station wlan0 scan
iwctl station wlan0 get-networks
iwctl station wlan0 connect "Cafe Wi-Fi"
```

You can also declare networks in the inventory, with the password as a
prompted clan var. That is optional, and only useful for a network that must
work on the very first boot.

## Wired and Wi-Fi together

When a cable and Wi-Fi are both up, the cable wins: netif's default route
has metric 100, iwd's starts at 300, and NetworkManager's Wi-Fi uses 600.
Wi-Fi stays connected as a fallback, so unplugging needs no
reconfiguration (planned, phases P3b and P2).

A probe on 2026-11-16 confirmed it for IPv4 and IPv6. iwd put both of
its default routes at metric 307. With a wired default at 100, traffic
left through the cable. With the cable down, it left through Wi-Fi, and
nothing was reconfigured.

## Limits

- netif does not run access points. A machine is always a Wi-Fi client.
- A Wi-Fi link never carries a static core address, a literal endpoint or
  the deploy target. Roaming machines deploy through a name: LAN DNS or
  Tailscale MagicDNS.
- Steam itself cannot run in a VM test. Steam talks to NetworkManager's
  backend-neutral D-Bus API, and SteamOS uses NetworkManager with iwd too.
  One check on the real Deck confirms Steam's Wi-Fi settings with the iwd
  backend (phase P2).
- A dock's Ethernet plugged in while in developer mode is handled by a
  separate hot-plug owner (planned, phase P2). NetworkManager handles it in
  gaming mode.
