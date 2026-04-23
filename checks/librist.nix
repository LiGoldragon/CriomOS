{
  librist,
  writeScriptBin,
  mksh,
}:
let
  senderPort = 8192;
  senderInputUrl = "udp://127.0.0.1:${toString senderPort}";

  receiverPort = 8200;
  receiverIpAndPort = "123.123.123.123:${toString receiverPort}";

  senderCName = "senderCName";
  senderBandwidth = 2560000;
  senderMinBuffer = 245;
  senderMaxBuffer = 1000;
  senderMinRtt = 40;
  senderMaxRtt = 500;
  senderReorderBuffer = 60;
  senderCongestionControl = 1;
  senderStreamID = 1000;
  senderOutputUrl = "rist:${receiverIpAndPort}//?cname=${senderCName}&bandwidth=${toString senderBandwidth}&buffer-min=${toString senderMinBuffer}&buffer-max=${toString senderMaxBuffer}&rtt-min=${toString senderMinRtt}&rtt-max=${toString senderMaxRtt}&reorder-buffer=${toString senderReorderBuffer}&congestion-control${senderCongestionControl}=?stream-id=${senderStreamID}";

  receiverCName = "receiverCName";
  receiverBandwidth = 2560000;
  receiverMinBuffer = 245;
  receiverMaxBuffer = 1000;
  receiverMinRtt = 40;
  receiverMaxRtt = 500;
  receiverReorderBuffer = 60;
  receiverCongestionControl = 1;
  receiverStreamID = 1000;
  receiverInputUrl = "rist:$receiverIpAndPort//?cname=${receiverCName}&bandwidth=${toString receiverBandwidth}&buffer-min=${toString receiverMinBuffer}&buffer-max=${toString receiverMaxBuffer}&rtt-min=${toString receiverMinRtt}&rtt-max=${toString receiverMaxRtt}&reorder-buffer=${toString receiverReorderBuffer}&congestion-control${receiverCongestionControl}=?stream-id=${receiverStreamID}";

  receiverOutputUrl = "udp://192.168.x.x:8192?stream-id=1000";

in
{
  simpleSender = writeScriptBin "simpleRistReceiverTest" ''
    #!${mksh}/bin/mksh
    ristsender --inputurl '${senderInputUrl}' --outputurl '${senderOutputUrl}' \
    --profile 1 --verbose-level 4
  '';

  simpleReceiver = writeScriptBin "" ''
    #!${mksh}/bin/mksh

    receiverIpAndPort="$1"
    SwitchFlag=''${3:-"switch"}

    ristreceiver --inputurl "${receiverInputUrl}" --outputurl '${receiverOutputUrl}' \
    --profile 1 --verbose-level 4
  '';

}
