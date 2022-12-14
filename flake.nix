{
  description = "Volkszaehler logging utility for various meters & sensors";
  inputs.nixpkgs.url = "nixpkgs/nixos-22.11";
  inputs.libsml-src = {
    type = "github";
    owner = "volkszaehler";
    repo = "libsml";
    rev = "559ca1e3ff8de7645fc4372f632e42b64cec780f";
    flake = false;
  };
  inputs.vzlogger-src = {
    type = "github";
    owner = "maxberger";
    repo = "vzlogger";
    rev = "ec7839332cdb94240b2e78111813dd73054fb69a";
    flake = false;
  };
  outputs = { self, nixpkgs, libsml-src, vzlogger-src }:
    let
      version = builtins.substring 0 8 self.lastModifiedDate;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
      libsml = forAllSystems
        (system: nixpkgsFor.${system}.stdenv.mkDerivation {
          pname = "libsml";
          version = "1.0.0+${libsml-src.lastModifiedDate}";
          src = libsml-src;
          buildInputs = [ nixpkgsFor.${system}.libuuid ];
          installPhase = ''
            mkdir -p $out/{lib,include,lib/pkgconfig}

            cp -v sml/lib/libsml.so.1 $out/lib/
            ln -s libsml.so.1 $out/lib/libsml.so
            cp -vR sml/include/sml $out/include/
            cp -v sml.pc $out/lib/pkgconfig/
          '';
        });
    in
    {
      packages = forAllSystems
        (system:
          let
            pkgs = nixpkgsFor.${system};
          in
          rec {
            default = pkgs.stdenv.mkDerivation {
              pname = "vzlogger";
              version = "0.8.1+${vzlogger-src.lastModifiedDate}";
              src = vzlogger-src;
              nativeBuildInputs = [
                pkgs.cmake
              ];
              buildInputs = [
                libsml.${system}
                pkgs.curl
                pkgs.cyrus_sasl
                pkgs.gnutls
                pkgs.json_c
                pkgs.libgcrypt
                pkgs.libmicrohttpd
                pkgs.libunistring
                pkgs.libuuid
                pkgs.mosquitto
                pkgs.openssl
                pkgs.git
              ];
              checkInputs = [ pkgs.gtest ];
              cmakeFlags = [ "-DBUILD_TEST=off" ];
            };
            docker = pkgs.dockerTools.buildLayeredImage
              {
                name = "vzlogger";
                config.Entrypoint = [ "${default}/bin/vzlogger" "-f" ];
                contents = with pkgs.dockerTools; [
                  caCertificates
                  fakeNss
                ];
              };
          }
        );
      apps = forAllSystems (system: rec {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/vzlogger";
        };
      });
      nixosModules.default = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.services.vzlogger;
          settingsFormat = pkgs.formats.json { };
        in
        {
          options.services.vzlogger = {
            enable = mkEnableOption "Enables the vzlogger daemon";
            settings = mkOption {
              type = lib.types.submodule { freeformType = settingsFormat.type; };
              default = { };
              description = lib.mdDoc ''
                vzlogger configuration. Refer to
                <https://github.com/volkszaehler/vzlogger/tree/${libsml-src.rev}/etc> for examples.
              '';
            };
          };
          config = mkIf cfg.enable {
            systemd.services.vzlogger =
              let
                vzloggerConf = settingsFormat.generate "vzlogger.conf" cfg.settings;
              in
              {
                enable = true;
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                serviceConfig = {
                  ExecStart = "${self.packages.${pkgs.system}.default}/bin/vzlogger -f" +
                    " -c ${vzloggerConf}";
                  ExecReload = "";
                  StandardOutput = "journal+console";
                  Restart = "on-failure";
                  RestartPreventExitStatus = 78;
                  StartLimitIntervalSec = 0;
                  RestartSec = 30;
                };
              };
          };
        };
    };
}
