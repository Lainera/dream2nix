{
  lib,
  config,
  dream2nix,
  ...
}: {
  imports = [
    dream2nix.modules.dream2nix.nodejs-package-lock
    dream2nix.modules.dream2nix.nodejs-granular
  ];

  mkDerivation = {
    src = config.deps.fetchFromGitHub {
      owner = "davhau";
      repo = "prettier";
      rev = "2.8.7-package-lock";
      sha256 = "sha256-zo+WRV3VHja8/noC+iPydtbte93s5GGc3cYaQgNhlEY=";
    };
  };

  deps = {nixpkgs, ...}: {
    inherit
      (nixpkgs)
      fetchFromGitHub
      stdenv
      ;
  };

  name = lib.mkForce "prettier";
  version = lib.mkForce "2.8.7";
}