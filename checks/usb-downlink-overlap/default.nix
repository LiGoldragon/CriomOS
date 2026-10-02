# Negative fixture for a proposed policy, pending the living's ruling.
# Expected to fail until a separately approved runtime guard is implemented.
args: import ../usb-downlink-chain (args // { overlapContract = true; })
