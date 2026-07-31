{
  boot.kernelPatches = [
    {
      name = "uvcvideo-ms2130-restrict-frame-aspect-16-9";
      patch = ./linux-7.0.1.patch;
    }
  ];
}
