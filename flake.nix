{
  description = "Volkszaehler logging utility for various meters & sensors";
  inputs.nixpkgs.url = "nixpkgs/nixos-23.05";
  inputs.libsml-src = {
    type = "github";
    owner = "volkszaehler";
    repo = "libsml";
    rev = "60bc464930bf9e821b17a4efaa46b197534876cf";
    flake = false;
  };
  inputs.vzlogger-src = {
    type = "github";
    owner = "volkszaehler";
    repo = "vzlogger";
    rev = "5188375df5f0c3e261c60710aea0028eb53c1af5";
    flake = false;
  };
  outputs = { self, nixpkgs, libsml-src, vzlogger-src }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
      libsmlVer = builtins.head (builtins.match ''.*Version: ([0-9.]+).*'' (builtins.readFile (libsml-src + "/sml.pc")));
      libsml = forAllSystems
        (system: nixpkgsFor.${system}.stdenv.mkDerivation {
          pname = "libsml";
          version = "${libsmlVer}+${libsml-src.lastModifiedDate}";
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
            vzloggerCMakeLists = builtins.readFile (vzlogger-src + "/CMakeLists.txt");
            vzloggerMajorVer = builtins.head (builtins.match ''.*set\(VZLOGGER_MAJOR_VERSION ([0-9]+)\).*'' vzloggerCMakeLists);
            vzloggerMinorVer = builtins.head (builtins.match ''.*set\(VZLOGGER_MINOR_VERSION ([0-9]+)\).*'' vzloggerCMakeLists);
            vzloggerPatchVer = builtins.head (builtins.match ''.*set\(VZLOGGER_SUB_VERSION ([0-9]+)\).*'' vzloggerCMakeLists);
            pkgs = nixpkgsFor.${system};
            systemLibsml = libsml.${system};
          in
          rec {
            libsml = systemLibsml;
            default = pkgs.stdenv.mkDerivation {
              pname = "vzlogger";
              version = "${vzloggerMajorVer}.${vzloggerMinorVer}.${vzloggerPatchVer}+${vzlogger-src.lastModifiedDate}";
              src = vzlogger-src;
              nativeBuildInputs = [
                pkgs.cmake
              ];
              buildInputs = [
                systemLibsml
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
              postPatch = ''
                substituteInPlace src/gitSha1.cpp.in \
                  --replace '@GIT_SHA1@' '${vzlogger-src.rev}' \
                  --replace '@GIT_SHALONG@' '${vzlogger-src.rev}' \
                  --replace '@GIT_LAST_COMMIT_DATE@' '${vzlogger-src.lastModifiedDate}'
              '';
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

