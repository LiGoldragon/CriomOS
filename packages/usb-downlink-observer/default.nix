{ rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "usb-downlink-observer";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
}
