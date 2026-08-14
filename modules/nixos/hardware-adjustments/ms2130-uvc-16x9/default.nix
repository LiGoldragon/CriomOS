{
  boot.kernelPatches = [
    {
      name = "uvcvideo-ms2130-restrict-frame-aspect-16-9";
      patch = ./linux-7.1.8.patch;
    }
  ];
}
