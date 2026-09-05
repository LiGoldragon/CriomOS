{ lib }:
let
  inherit (builtins)
    head
    isAttrs
    isList
    isString
    ;

  serviceName =
    service:
    if isAttrs service then
      service.kind or null
    else if isString service then
      service
    else
      null;

  servicePayload =
    service: name:
    if isAttrs service && (service.kind or null) == name then
      builtins.removeAttrs service [ "kind" ]
    else
      { };

  servicesList =
    services:
    if services == null then
      [ ]
    else if isList services then
      services
    else
      throw "horizon.node.capabilities must be a vector of tagged capabilities";
in
rec {
  has = services: name: builtins.any (service: serviceName service == name) (servicesList services);

  payload =
    services: name:
    let
      matches = builtins.filter (service: serviceName service == name) (servicesList services);
    in
    if matches == [ ] then { } else servicePayload (head matches) name;

  personaDevelopmentHas =
    services: capabilityName:
    let
      personaDevelopment = payload services "PersonaDevelopment";
      capabilities = servicesList (personaDevelopment.capabilities or [ ]);
    in
    has capabilities capabilityName;
}
