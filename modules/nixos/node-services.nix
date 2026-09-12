{ lib }:
let
  inherit (builtins)
    isAttrs
    isList
    isString
    removeAttrs
    ;

  serviceName =
    service: if isAttrs service && service ? kind && isString service.kind then service.kind else null;

  servicePayload = service: removeAttrs service [ "kind" ];

  servicesList =
    services:
    if services == null then
      [ ]
    else if isList services then
      services
    else
      throw "horizon.node.capabilities must be a vector of capability records";
in
rec {
  has = services: name: builtins.any (service: serviceName service == name) (servicesList services);

  payload =
    services: name:
    let
      matches = builtins.filter (service: serviceName service == name) (servicesList services);
    in
    if matches == [ ] then { } else servicePayload (builtins.head matches);

  personaDevelopmentHas =
    services: capabilityName:
    let
      personaDevelopment = payload services "personaDevelopment";
      capabilities = personaDevelopment.capabilities or [ ];
    in
    builtins.elem capabilityName capabilities;
}
