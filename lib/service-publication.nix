{ lib }:
let
  inherit (builtins)
    attrNames
    attrValues
    concatLists
    filter
    foldl'
    head
    length

    match
    ;

  concatMap = f: xs: concatLists (map f xs);
  optional = condition: value: if condition then [ value ] else [ ];
  unique = values: length values == length (lib.unique values);
  isNonEmpty = value: value != null && match ".*[^[:space:]].*" value != null;
  validHostname = value: match "([a-z0-9][a-z0-9-]*\\.)+[a-z0-9][a-z0-9-]*" value != null;
  validPath = value: match "/.*" value != null;
  pathContains = parent: child: parent == "/" || lib.hasPrefix parent child;
  routeKey = application: route: "${application}/${route}";

  sortRoutes =
    routes:
    lib.sort (
      left: right:
      let
        leftLength = builtins.stringLength left.pathPrefix;
        rightLength = builtins.stringLength right.pathPrefix;
      in
      if leftLength == rightLength then left.key < right.key else leftLength > rightLength
    ) routes;

  resolve =
    registry:
    let
      inherit (registry) sites;
      inherit (registry) hosts;
      inherit (registry) applications;
      inherit (registry) accessPolicies;

      hostSite = hostName: (hosts.${hostName} or { site = null; }).site;
      hostLan = hostName: ((hosts.${hostName} or { addresses.lan = null; }).addresses.lan or null);
      isProxy =
        hostName:
        ((hosts.${hostName} or { capabilities.reverseProxy = false; }).capabilities.reverseProxy or false);
      internalDnsHosts =
        siteName:
        filter (
          hostName: hostSite hostName == siteName && (hosts.${hostName}.capabilities.internalDns or false)
        ) (attrNames hosts);
      internalDnsAddress =
        siteName:
        let
          candidates = internalDnsHosts siteName;
        in
        if length candidates == 1 then hostLan (head candidates) else null;

      canonicalFor =
        applicationName: application:
        if application.public then
          if application.publicHostname != null then
            application.publicHostname
          else
            "${applicationName}.apps.finnrut.is"
        else
          "${applicationName}.${(sites.${application.site} or { internalZone = "invalid"; }).internalZone}";

      aliasFor =
        applicationName: application:
        if application.public then
          "${applicationName}.${(sites.${application.site} or { internalZone = "invalid"; }).internalZone}"
        else
          null;

      fallbackCandidates =
        siteName:
        let
          site = sites.${siteName} or { defaultProxyHosts = [ ]; };
        in
        filter (
          hostName: builtins.hasAttr hostName hosts && hostSite hostName == siteName && isProxy hostName
        ) site.defaultProxyHosts;

      effectiveProxy =
        application: route:
        if route.proxy.host != null then
          route.proxy.host
        else if isProxy route.backend.host then
          route.backend.host
        else
          let
            candidates = fallbackCandidates application.site;
          in
          if length candidates == 1 then head candidates else null;

      effectiveAccess =
        application: route:
        let
          routeAccess = route.access;
        in
        {
          policy = if routeAccess.policy != null then routeAccess.policy else application.access.policy;
          serviceTokens = lib.unique (application.access.serviceTokens ++ routeAccess.serviceTokens);
          bypassAccess = routeAccess.bypassAccess || application.access.bypassAccess;
          bypassJustification =
            if routeAccess.bypassJustification != null then
              routeAccess.bypassJustification
            else
              application.access.bypassJustification;
        };

      mkRoute =
        applicationName: application: routeName: route:
        let
          proxyHost = effectiveProxy application route;
          canonical = canonicalFor applicationName application;
          alias = aliasFor applicationName application;
          public = application.public && route.public != false;
          access = effectiveAccess application route;
          backendAddress =
            if proxyHost == route.backend.host then "127.0.0.1" else hostLan route.backend.host;
        in
        {
          key = routeKey applicationName routeName;
          application = applicationName;
          inherit
            canonical
            alias
            public
            access
            backendAddress
            ;
          route = routeName;
          inherit (application) site;
          pathPrefix = route.match.pathPrefix;
          inherit (route) backend;
          proxy = {
            host = proxyHost;
            lanAddress = if proxyHost == null then null else hostLan proxyHost;
          };
          inherit (route) health;
        };

      routes = lib.concatMapAttrs (
        applicationName: application:
        lib.mapAttrs' (
          routeName: route:
          lib.nameValuePair (routeKey applicationName routeName) (
            mkRoute applicationName application routeName route
          )
        ) application.routes
      ) applications;

      routeList = attrValues routes;
      applicationList = lib.mapAttrsToList (applicationName: application: {
        name = applicationName;
        inherit (application) site public;
        canonical = canonicalFor applicationName application;
        alias = aliasFor applicationName application;
        routes = filter (route: route.application == applicationName) routeList;
      }) applications;

      hostAdminRecords = lib.mapAttrs' (
        hostName: host:
        lib.nameValuePair "${hostName}.hosts.${(sites.${host.site} or { internalZone = "invalid"; }).internalZone}" host.addresses.lan
      ) (lib.filterAttrs (_: host: host.addresses.lan != null) hosts);

      applicationRecords = foldl' (
        records: application:
        let
          applicationRoutes = application.routes;
          proxyAddresses = lib.unique (map (route: route.proxy.lanAddress) applicationRoutes);
          address = if length proxyAddresses == 1 then head proxyAddresses else null;
        in
        records
        // {
          ${application.canonical} = address;
        }
        // lib.optionalAttrs (application.alias != null) {
          ${application.alias} = address;
        }
      ) { } applicationList;

      blockyRecords = hostAdminRecords // applicationRecords;

      routesByProxy = lib.groupBy (route: route.proxy.host) (
        filter (route: route.proxy.host != null) routeList
      );
      nginxByHost = lib.mapAttrs (
        proxyHost: proxyRoutes:
        let
          applicationsOnHost = lib.unique (map (route: route.application) proxyRoutes);
          vhosts = concatMap (
            applicationName:
            let
              application = applications.${applicationName};
              canonical = canonicalFor applicationName application;
              alias = aliasFor applicationName application;
              appRoutes = sortRoutes (filter (route: route.application == applicationName) proxyRoutes);
            in
            [
              {
                name = canonical;
                kind = "proxy";
                routes = appRoutes;
              }
            ]
            ++ optional (alias != null) {
              name = alias;
              kind = "redirect";
              redirectTo = canonical;
              routes = [ ];
            }
          ) applicationsOnHost;
        in
        {
          certificateNames = lib.unique (map (vhost: vhost.name) vhosts);
          inherit vhosts;
          lanAddress = hostLan proxyHost;
          sites = lib.unique (map (route: route.site) proxyRoutes);
        }
      ) routesByProxy;

      publicApplications = filter (application: application.public) applicationList;
      readyPolicies = lib.filterAttrs (
        _: policy: policy.cloudflareImportKey != null && policy.include != [ ]
      ) accessPolicies;

      accessApplicationFor =
        application:
        let
          advancedRoutes = filter (
            route:
            route.public
            && (
              route.access.policy != applications.${application.name}.access.policy
              || route.access.serviceTokens != [ ]
              || route.access.bypassAccess
            )
          ) application.routes;
          mkAccess = suffix: domain: access: {
            key = "${application.name}${suffix}";
            application = application.name;
            inherit domain access;
          };
        in
        map (
          route: mkAccess "/${route.route}" "${application.canonical}${route.pathPrefix}" route.access
        ) advancedRoutes
        ++ [ (mkAccess "" application.canonical applications.${application.name}.access) ];

      accessApplications = concatMap accessApplicationFor publicApplications;
      accessApplicationsByKey = lib.listToAttrs (
        map (application: lib.nameValuePair application.key application) accessApplications
      );

      publicDns = lib.listToAttrs (
        map (
          application:
          lib.nameValuePair application.name {
            hostname = application.canonical;
            accessDependency = application.name;
          }
        ) publicApplications
      );

      tunnelApplications = map (
        application:
        let
          orderedRoutes = sortRoutes application.routes;
        in
        {
          key = application.name;
          hostname = application.canonical;
          accessDependency = application.name;
          ingress = map (
            route:
            if route.public then
              {
                inherit (route) key;
                inherit (route) pathPrefix;
                service = "https://${route.proxy.lanAddress}:443";
                originServerName = route.canonical;
                httpHostHeader = route.canonical;
                noTlsVerify = false;
                accessDependency = application.name;
              }
            else
              {
                inherit (route) key;
                inherit (route) pathPrefix;
                service = "http_status:404";
                originServerName = null;
                httpHostHeader = null;
                noTlsVerify = false;
                accessDependency = application.name;
              }
          ) orderedRoutes;
        }
      ) publicApplications;

      internalProbes = map (route: {
        inherit (route) key;
        scope = "internal";
        hostname = route.canonical;
        inherit (route) canonical alias;
        resolverAddress = internalDnsAddress route.site;
        proxyAddress = route.proxy.lanAddress;
        path = route.health.path;
        expectedStatuses = route.health.expectedStatuses;
        timeoutSeconds = route.health.timeoutSeconds;
      }) routeList;

      externalProbes = map (route: {
        inherit (route) key;
        scope = "external";
        hostname = route.canonical;
        path = route.health.path;
        expectedStatuses = route.health.expectedStatuses;
        timeoutSeconds = route.health.timeoutSeconds;
        inherit (route) access;
        denied = false;
      }) (filter (route: route.public) routeList);

      externalDeniedProbes = map (route: {
        inherit (route) key;
        scope = "external";
        hostname = route.canonical;
        path = route.health.path;
        expectedStatuses = [ 404 ];
        timeoutSeconds = route.health.timeoutSeconds;
        inherit (route) access;
        denied = true;
      }) (filter (route: applications.${route.application}.public && !route.public) routeList);

      errorsForApplication =
        application:
        let
          original = applications.${application.name};
          appRoutes = application.routes;
          publicRoutes = filter (route: route.public) appRoutes;
          prefixes = map (route: route.pathPrefix) appRoutes;
          routePairs = concatMap (
            outer: map (inner: { inherit outer inner; }) (filter (inner: inner.key != outer.key) appRoutes)
          ) appRoutes;
          conflictingPairs = filter (
            pair:
            pathContains pair.outer.pathPrefix pair.inner.pathPrefix
            && pair.outer.pathPrefix != pair.inner.pathPrefix
            && (
              (!pair.outer.public && pair.inner.public)
              || (!pair.outer.access.bypassAccess && pair.inner.access.bypassAccess)
            )
          ) routePairs;
          policyKeys = lib.unique (map (route: route.access.policy) publicRoutes);
        in
        optional (
          !validHostname application.canonical
        ) "application ${application.name}: invalid canonical hostname ${application.canonical}"
        ++ optional (appRoutes == [ ]) "application ${application.name}: at least one route is required"
        ++ optional (
          original.publicHostname != null && !original.public
        ) "application ${application.name}: publicHostname requires public = true"
        ++ optional (
          original.public && publicRoutes == [ ]
        ) "application ${application.name}: public application has no effective public route"
        ++ optional (
          !original.public && lib.any (route: route.public == true) (attrValues original.routes)
        ) "application ${application.name}: a private application route cannot opt into publication"
        ++ optional (!unique prefixes) "application ${application.name}: duplicate route path prefixes"
        ++ optional (
          conflictingPairs != [ ]
        ) "application ${application.name}: invalid nested path exposure or bypass precedence"
        ++ concatMap (
          route:
          optional (!validPath route.pathPrefix) "route ${route.key}: pathPrefix must begin with /"
          ++ optional (!validPath route.health.path) "route ${route.key}: health path must begin with /"
          ++ optional (
            route.health.expectedStatuses == [ ]
          ) "route ${route.key}: expectedStatuses must not be empty"
          ++ optional (lib.any (
            status: status < 100 || status > 599
          ) route.health.expectedStatuses) "route ${route.key}: expected status is outside 100..599"
          ++ optional (
            !(builtins.hasAttr route.backend.host hosts)
          ) "route ${route.key}: unknown backend host ${route.backend.host}"
          ++ optional (
            route.proxy.host == null
          ) "route ${route.key}: implicit proxy selection requires exactly one capable fallback"
          ++ optional (
            route.proxy.host != null && !(builtins.hasAttr route.proxy.host hosts)
          ) "route ${route.key}: unknown proxy host ${toString route.proxy.host}"
          ++ optional (
            route.proxy.host != null && !isProxy route.proxy.host
          ) "route ${route.key}: selected proxy lacks reverseProxy capability"
          ++ optional (
            route.backendAddress == null
          ) "route ${route.key}: backend has no address reachable from the proxy"
          ++
            optional
              (
                route.backend.host != route.proxy.host
                && builtins.hasAttr route.backend.host hosts
                && !lib.elem route.proxy.host hosts.${route.backend.host}.reachableFromProxyHosts
              )
              "route ${route.key}: backend does not declare reachability from proxy ${toString route.proxy.host}"
          ++ optional (route.proxy.lanAddress == null) "route ${route.key}: proxy has no site LAN address"
          ++ optional (
            route.backend.host != route.proxy.host && hostSite route.backend.host != route.site
          ) "route ${route.key}: cross-site backend routing is not enabled"
          ++ optional (
            route.proxy.host != null && hostSite route.proxy.host != route.site
          ) "route ${route.key}: cross-site proxy routing is not enabled"
          ++ optional (
            route.access.bypassAccess && !isNonEmpty route.access.bypassJustification
          ) "route ${route.key}: bypassAccess requires a non-empty justification"
          ++ optional (
            route.public
            && (
              route.access.policy == null || !(builtins.hasAttr (toString route.access.policy) accessPolicies)
            )
          ) "route ${route.key}: public route has no known Access policy"
          ++ optional (
            route.public && route.access.policy != null && !(builtins.hasAttr route.access.policy readyPolicies)
          ) "route ${route.key}: Access policy ${toString route.access.policy} is not import-ready"
        ) appRoutes
        ++ concatMap (
          policy:
          optional (
            policy != null && !(builtins.hasAttr policy accessPolicies)
          ) "application ${application.name}: unknown Access policy ${toString policy}"
        ) policyKeys;

      siteErrors = concatMap (
        siteName:
        let
          site = sites.${siteName};
          ingress = hosts.${site.publicIngressHost} or null;
          fallbacks = fallbackCandidates siteName;
        in
        optional (ingress == null) "site ${siteName}: unknown publicIngressHost ${site.publicIngressHost}"
        ++ optional (
          ingress != null && ingress.site != siteName
        ) "site ${siteName}: publicIngressHost belongs to another site"
        ++ optional (
          ingress != null && !ingress.capabilities.publicConnector
        ) "site ${siteName}: publicIngressHost lacks publicConnector capability"
        ++ optional (!unique site.routedLanCidrs) "site ${siteName}: duplicate routed LAN CIDR"
        ++ optional (
          site.networkInventoryConfirmed && site.routedLanCidrs == [ ]
        ) "site ${siteName}: confirmed network inventory has no routed LAN CIDRs"
        ++ optional (
          length fallbacks != 1
        ) "site ${siteName}: exactly one capable default proxy is required"
        ++ optional (
          length (internalDnsHosts siteName) != 1
        ) "site ${siteName}: exactly one internal DNS host is required"
      ) (attrNames sites);

      hostErrors = concatMap (
        hostName:
        let
          host = hosts.${hostName};
        in
        optional (!(builtins.hasAttr host.site sites)) "host ${hostName}: unknown site ${host.site}"
        ++ optional (host.addresses.lan == null) "host ${hostName}: missing site LAN address"
      ) (attrNames hosts);

      canonicalNames = map (application: application.canonical) applicationList;
      aliasNames = filter (name: name != null) (map (application: application.alias) applicationList);
      adminNames = attrNames hostAdminRecords;
      allNames = canonicalNames ++ aliasNames ++ adminNames;
      vhostNames = concatMap (host: host.certificateNames) (attrValues nginxByHost);
      certNames = concatMap (host: host.certificateNames) (attrValues nginxByHost);

      projectionErrors =
        optional (
          !unique allNames
        ) "service publication: canonical, alias, or host administration hostname collision"
        ++ optional (lib.any (name: lib.hasSuffix ".home.finnrut.is" name) (
          allNames ++ vhostNames ++ certNames
        )) "service publication: legacy home.finnrut.is name escaped into a target projection"
        ++ concatMap (
          route:
          optional (
            (blockyRecords.${route.canonical} or null) != route.proxy.lanAddress
          ) "route ${route.key}: Blocky canonical does not resolve to the selected proxy"
          ++ optional (
            route.alias != null && (blockyRecords.${route.alias} or null) != route.proxy.lanAddress
          ) "route ${route.key}: Blocky alias does not resolve to the selected proxy"
          ++ optional (
            !(lib.elem route.canonical certNames)
          ) "route ${route.key}: canonical vhost is missing from its proxy certificate"
          ++ optional (
            route.public
            && route.proxy.lanAddress != null
            && !lib.hasPrefix "https://${route.proxy.lanAddress}:443" (
              head (
                map (item: item.service) (
                  filter (item: item.key == route.key) (concatMap (item: item.ingress) tunnelApplications)
                )
                ++ [ "" ]
              )
            )
          ) "route ${route.key}: Tunnel origin is not direct HTTPS to the selected proxy"
        ) routeList
        ++ concatMap (
          name:
          optional (
            !(builtins.hasAttr name accessApplicationsByKey)
          ) "public DNS ${name}: missing Access application dependency"
        ) (attrNames publicDns);

      errors =
        siteErrors ++ hostErrors ++ concatMap errorsForApplication applicationList ++ projectionErrors;
    in
    {
      inherit
        errors
        routes
        blockyRecords
        nginxByHost
        internalProbes
        ;
      externalProbes = externalProbes ++ externalDeniedProbes;
      cloudflare = {
        accessPolicies = readyPolicies;
        accessApplications = accessApplicationsByKey;
        dnsRecords = publicDns;
        tunnel = {
          ingressHost = lib.mapAttrs (_: site: site.publicIngressHost) sites;
          applications = tunnelApplications;
          catchAll = "http_status:404";
        };
      };
      metadata = {
        schemaVersion = 1;
        generatedFrom = "servicePublication";
        containsSecrets = false;
      };
      inherit (registry) sites;
      inherit (registry) hosts;
      applications = lib.mapAttrs (applicationName: application: {
        inherit (application) site public;
        canonical = canonicalFor applicationName application;
        alias = aliasFor applicationName application;
      }) applications;
    };
in
{
  inherit resolve;
}
