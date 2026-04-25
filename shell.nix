let
  pkgs = import <nixpkgs> { };
  unstable = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/b12141ef619e0a9c1c84dc8c684040326f27cdcc.tar.gz") {};
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    unstable.zls
    unstable.zig
    linphone
    pjsip
    libreoffice
    python3
  ];

  LD_LIBRARY_PATH = "${pkgs.wayland}/lib";
}
