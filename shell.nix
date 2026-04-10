let
  pkgs = import <nixpkgs> { };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zls
    zig
    linphone
    pjsip
  ];

  LD_LIBRARY_PATH = "${pkgs.wayland}/lib";
}
