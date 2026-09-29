{ rustPlatform, iproute2, makeWrapper }:
rustPlatform.buildRustPackage {
  pname = "usb-downlink-observer";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [ makeWrapper ];
  postFixup = ''
    wrapProgram $out/bin/usb-downlink-observer --prefix PATH : ${iproute2}/bin
  '';
}
