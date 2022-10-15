{
  description = "Volkszaehler logging utility for various meters & sensors";
  inputs.nixpkgs.url = "nixpkgs/nixos-22.05";
  inputs.libsml-src = {
    type = "github";
    owner = "volkszaehler";
    repo = "libsml";
    flake = false;
  };
  inputs.vzlogger-src = {
    type = "github";
    owner = "volkszaehler";
    repo = "vzlogger";
    flake = false;
  };
  outputs = { self, nixpkgs, libsml-src, vzlogger-src }:
  let
    version = builtins.substring 0 8 self.lastModifiedDate;
    supportedSystems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    nixpkgsFor = forAllSystems (system: import nixpkgs {inherit system;});
  in
  {
    packages = forAllSystems (system:
      let
        pkgs = nixpkgsFor.${system};
      in
      rec {
          libsml = pkgs.stdenv.mkDerivation {
            pname = "libsml";
            version = "1.0.0+${libsml-src.lastModifiedDate}";
            src = libsml-src;
            buildInputs = [ pkgs.libuuid ];
            installPhase = ''
              mkdir -p $out/{lib,include,lib/pkgconfig}

              cp -v sml/lib/libsml.so.1 $out/lib/
              ln -s libsml.so.1 $out/lib/libsml.so
              cp -vR sml/include/sml $out/include/
              cp -v sml.pc $out/lib/pkgconfig/
            '';
          };

          default = pkgs.stdenv.mkDerivation {
            pname = "vzlogger";
            version = "0.8.1+${vzlogger-src.lastModifiedDate}";
            src = vzlogger-src;
            nativeBuildInputs = [
              pkgs.cmake
            ];
            buildInputs = [ 
              libsml
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
            ];
            checkInputs = [ pkgs.gtest ];
            # cmakeFlags = [ "-DBUILD_TEST=off" ];
          };
      }
    );
    apps = forAllSystems (system: {
      default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/vzlogger";
      };
    });
    defaultApp = forAllSystems (system: self.packages.${system}.default);
    nixosModules.vzlogger = {config, lib, pkgs, ...}:
      with lib;
      let
        cfg = config.max-te.services.vzlogger;
        settingsFormat = pkgs.formats.json { };
        
      in {
        options.max-te.services.vzlogger = {
          enable = mkEnableOption "Enables the vzlogger daemon";
          configText = mkOption {
            type = lib.types.submodule { freeformType = settingsFormat.type; };
            default = "{}";
            description = lib.mdDoc "Contents of the vzlogger.conf file.";
          };
        };
        config = mkIf cfg.enable {
          systemd.services.vzlogger = let
            vzloggerConf = settingsFormat.generate "vzlogger.conf" cfg.configText;
          in {
            enable = true;
            wantedBy = ["multi-user.target"];
            after = ["network.target"];
            serviceConfig = {
              ExecStart = "${self.packages.${system}.vzlogger}/bin/vzlogger -f" +
                " -c ${vzloggerConf}";
              ExecReload = "";
              StandardOutput = "journal";
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