{ lib }:
let
  inherit (builtins)
    attrNames
    hasAttr
    head
    isAttrs
    isList
    isString
    length
    ;

  serviceName =
    service:
    if isString service then
      service
    else if isAttrs service then
      let
        names = attrNames service;
      in
      if length names == 1 then head names else null
    else
      null;

  servicePayload =
    service: name: if isAttrs service && hasAttr name service then service.${name} else { };

  servicesList =
    services:
    if services == null then
      [ ]
    else if isList services then
      services
    else
      throw "horizon.node.services must be a vector of service variants";
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
