let
  pkgs = import <nixpkgs> { };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zls
    zig
    linphone
    pjsip
    libreoffice
    python3
  ];

  LD_LIBRARY_PATH = "${pkgs.wayland}/lib";
}
