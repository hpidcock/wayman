# wayman

A small Wi-Fi tray tool for sway and other wlroots compositors, written in
Zig 0.17. It puts a signal-strength icon in the bar's tray and opens a popup
for switching networks, joining new ones and disconnecting.

![tray icon with popup listing networks](docs/popup.png)

## How it works

- **Tray icon**: a `StatusNotifierItem` on the session bus. Any bar with a
  StatusNotifier host (waybar's `tray` module, for example) shows it. The
  icon is drawn with cairo and updated as the signal changes; the tooltip
  shows the connected network and strength.
- **Popup**: a `wlr-layer-shell` surface anchored below the bar at the top
  right, drawn with cairo and pango. Click the tray icon to open it. Click a
  network to join it, type the password when asked, press Escape or click
  anywhere outside to close it.
- **Networking**: NetworkManager over its D-Bus API, using libdbus-1. New
  networks are added with `AddAndActivateConnection`; on Ubuntu,
  NetworkManager's netplan integration persists them as
  `/etc/netplan/90-NM-*.yaml`. Wrong passwords remove the half-made profile
  again so the next attempt prompts afresh.

- **VPN**: every NetworkManager profile of type `vpn` (OpenVPN, PPTP, ...)
  or `wireguard` is listed in a VPN section of the popup with a switch.
  Several can be on at once. While any VPN is up the tray icon carries a
  small padlock and the tooltip names it.
- **Secrets**: wayman registers as a NetworkManager secret agent. When a
  profile needs a password, certificate password or one-time code (OpenVPN
  challenge/response), or a Wi-Fi password was rejected, the popup opens
  with a prompt and hands the answer back to NetworkManager. Answers are
  kept in memory for the session so a reconnect does not ask again;
  one-time codes are never reused. Nothing is written to disk.

Supported networks: open, WPA2/WPA3 personal, OWE. Enterprise (802.1X) and
WEP networks are listed but need a profile created with netplan or `nmcli`
first; once one exists wayman can activate it.

## Building

```
nix develop      # or provide zig 0.17, pkg-config, wayland-scanner and the libs below
zig build
./zig-out/bin/wayman
```

Dependencies: wayland-client, wayland-cursor, wayland-protocols,
libxkbcommon, cairo, pango, dbus-1. The protocol XML files wayman needs are
vendored in `protocols/`.

`zig build test` runs the unit tests. `nix build` produces the package.

## Running

Start it from your sway config:

```
exec wayman
```

and make sure your bar has a tray, e.g. `"modules-right": ["tray", ...]` in
waybar. Logs go to stderr; debug builds are more verbose.

## Theming

By default wayman reads waybar's `style.css` (from `$XDG_CONFIG_HOME/waybar`,
`~/.config/waybar`, `~/waybar` or `/etc/xdg/waybar`) and derives its look
from it:

| Popup element            | Taken from                                                   |
| ------------------------ | ------------------------------------------------------------ |
| background               | `window#waybar` background (made at least 90% opaque)        |
| text, tray icon          | `window#waybar` color                                        |
| accent                   | first of `#workspaces button.focused` background/border, `#mode` background, `#clock` background that contrasts with the bar |
| error text               | `#battery.critical` colour, if any                            |
| font                     | `font-family` / `font-size` from `window#waybar` or `*`      |

Muted text, hover, borders and the empty signal bars are shades of the text
colour. `@define-color`, `@import`, hex, `rgb()`/`rgba()`, named colours and
GTK's `alpha()`, `shade()` and `mix()` are understood; anything else falls
back to the built-in dark theme.

Options:

```
wayman --style PATH        # use this CSS file (same rules as above) instead of waybar's
wayman --no-waybar-theme   # built-in theme
```

## Layout

| File           | Role                                                        |
| -------------- | ----------------------------------------------------------- |
| `src/main.zig` | Wires everything together and runs the poll loop           |
| `src/nm.zig`   | NetworkManager client and the network model                 |
| `src/sni.zig`  | StatusNotifierItem D-Bus object                             |
| `src/wl.zig`   | Wayland connection, input, shm buffers, layer-shell popup   |
| `src/ui.zig`   | Popup layout, drawing and interaction                       |
| `src/icon.zig` | Cairo drawing helpers and tray pixmap rendering             |
| `src/agent.zig`| NetworkManager secret agent (VPN and Wi-Fi credential prompts) |
| `src/dbus.zig` | Thin helpers over libdbus-1                                 |
| `src/theme.zig`| CSS subset parser and the waybar-to-popup theme mapping     |
| `src/c.h`      | The C headers translated into the `c` module at build time  |
