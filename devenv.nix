{ pkgs, ... }:

{
  cachix.pull = [ "sagikazarmark-dev" ];

  dotenv.enable = true;

  packages = with pkgs; [
    cargo-release
    cargo-watch
    cargo-expand
    dagger
  ];

  languages = {
    rust = {
      enable = true;
    };
  };
}
