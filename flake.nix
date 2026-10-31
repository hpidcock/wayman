# Copyright (C) 2026 by Harry Pidcock
# Licensed under 0BSD, see LICENCE file for details.
{
  description = "wayman - a sway/wayland tray utility for connecting to and switching wifi networks";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        wayman = pkgs.stdenv.mkDerivation {
          pname = "wayman";
          version = "0.1.0";

          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./build.zig
              ./build.zig.zon
              ./src
              ./protocols
              ./README.md
            ];
          };

          nativeBuildInputs = with pkgs; [
            zig.hook
            pkg-config
            wayland-scanner
          ];

          buildInputs = with pkgs; [
            wayland
            wayland-protocols
            libxkbcommon
            cairo
            pango
            dbus
          ];

          zigBuildFlags = [ "-Doptimize=ReleaseSafe" ];

          meta = {
            description = "Wi-Fi tray icon and popup for sway/wlroots compositors";
            mainProgram = "wayman";
            platforms = pkgs.lib.platforms.linux;
          };
        };
        default = wayman;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "wayman";

          packages = with pkgs; [
            # Zig toolchain
            zig
            zls

            # Build helpers
            pkg-config
            wayland-scanner

            # Wayland client stack
            wayland
            wayland-protocols
            libxkbcommon

            # Rendering (text/vector) for the GUI
            cairo
            pango
            fontconfig
            freetype

            # D-Bus, for talking to NetworkManager / iwd
            dbus
          ];

          shellHook = ''
            # Keep Zig's global cache out of $HOME and inside the project.
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
            echo "wayman devshell: zig $(zig version), zls $(zls --version)"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
