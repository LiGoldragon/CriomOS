{ horizon, lib, ... }:

{
  imports = lib.optionals (horizon.node.behavesAs.bareMetal && horizon.node.behavesAs.edge) [
    ./ms2130-uvc-16x9
  ];
}
