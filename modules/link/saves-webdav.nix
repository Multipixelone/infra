# The server half of the RetroArch save authority: `rclone serve webdav` on
# link, published as saves.finnrut.is through impa. The policy, the client
# projections and the runbook are elsewhere (modules/gaming/saves/policy.nix,
# docs/retroarch-save-authority-runbook.md); this file is the endpoint and the
# things that go wrong at it.
#
# Four of those things are invisible from the option names below.
#
# rclone's DEFAULT --vfs-cache-mode is `off`, and `off` streams a PUT straight
# to the FINAL filename: the target is truncated the moment the request starts
# and refilled only as bytes arrive. A handheld that walks out of wifi
# mid-upload therefore leaves a truncated save at the real path, and the next
# client to sync fetches that truncation as the newest version of the game.
# `writes` writes into the cache and rename(2)s the finished file into place, so
# the visible file is only ever a whole one. Its costs are stated at the flag.
#
# DynamicUser would be worse than wrong here, it would be quietly wrong. A
# transient UID is allocated per boot, so every file already in the data
# directory would be owned by a number that no longer means anything the first
# time the host reboots -- on a service whose entire content is the only copy of
# somebody's save history. The user below is static and boring on purpose.
#
# The listener cannot be loopback. Site "nyc" publishes through impa
# (192.168.6.50), so nginx and cloudflared are on a DIFFERENT machine than this
# service and a 127.0.0.1 bind would be unreachable from the proxy. What makes
# the endpoint equivalently private is the generated nixos-service-publication
# chain: modules/service-publication/nixos.nix jumps to it from position 1 of
# nixos-fw, accepts this port only from the proxy's /32, and ends in
# nixos-fw-refuse. The declarative firewall opening below is the same one
# modules/link/copyparty.nix makes, and for the same reason: it states the
# listener's LAN reachability where the listener is declared instead of leaving
# it as an emergent property of a chain in another module. It widens nothing
# while the rollout is on, because the chain is matched first and refuses.
#
# And the data directory is an operator-created Btrfs SUBVOLUME. A tmpfiles `d`
# rule would happily manufacture a plain directory in its place; rclone would
# serve it, everything would look healthy, and btrbk would have nothing to
# snapshot -- which is a fact you would discover during a recovery. The tmpfiles
# rule here is `z`, which adjusts ownership and never creates, and the unit
# refuses to start with the exact `btrfs subvolume create` line in its journal.
{
  config,
  inputs,
  ...
}:
let
  inventory = config.flake.saveSyncInventory;
  inherit (inventory) webdav;

  serviceName = "retroarch-saves-webdav";
  serviceUser = "retroarch-dav";
  cacheDir = "/var/cache/${serviceName}";

  # LoadCredential materialises the htpasswd at $CREDENTIALS_DIRECTORY/<id> on
  # ramfs, mode 0400. `%d` is systemd's specifier for that directory, so the
  # path never has to be spelled out or expanded through a shell.
  credentialId = "htpasswd";
  # Written as a literal for the same reason modules/service-publication/nixos.nix
  # writes runtimeAcmeSecret as one: the unit has to name this file in a
  # ConditionPathExists even in the evaluation where the age.secrets declaration
  # is gated off and config.age.secrets holds no such attribute.
  htpasswdRuntimePath = "/run/agenix/retroarch-saves-htpasswd";
  htpasswdAgeFile = "${inputs.secrets}/games/retroarch-saves-htpasswd.age";

  # The proxy's own copy of the same htpasswd. A separate agenix name because it
  # is decrypted on a different host with different ownership (nginx, not root),
  # and a literal runtime path for the same reason as htpasswdRuntimePath above:
  # nginx.extraConfig is resolved at flake level, where the proxy's
  # config.age.secrets is out of scope entirely.
  proxyCredentialName = "retroarch-saves-htpasswd-proxy";
  proxyHtpasswdRuntimePath = "/run/agenix/${proxyCredentialName}";

  # ONE source of truth for both host modules. The NixOS option below still
  # exists and still carries the explanation, but its VALUE comes from here:
  # link gates its rclone unit on it, and impa gates nginx's copy of the same
  # htpasswd on it, and impa cannot read an option declared inside link's
  # module. Two hosts consuming one credential need one switch, not two that
  # can disagree -- a proxy that decrypted the file while link had not would
  # 401 every request with no way to tell why from either host.
  credentialIsDeployed = true;

  # The Basic-auth realm nginx presents. rclone passes no --realm and so uses
  # its own default; the two need not agree, because nginx challenges first and
  # is the only realm a client ever sees. Kept as a plain hostname so the prompt
  # a browser shows names the service rather than leaking anything about it.
  realm = "saves.finnrut.is";

  # `config.hosts` is the flake-parts host registry; it is not on any nixos
  # config, so both addresses are captured out here (the same move
  # modules/link/roomieorder.nix makes).
  linkLanAddress = config.hosts.link.homeAddress;

  # The vhost for this application is GENERATED ON THE PROXY, so everything
  # nginx-shaped in this file lands on impa, not on link.
  proxySite = "nyc";
  proxyHostName = "impa";
  proxyLanAddress = config.servicePublication.hosts.${proxyHostName}.addresses.lan;
  # Captured out here because the module below shadows `config` with the NixOS
  # one, which carries no servicePublication registry.
  declaredIngressHost = config.servicePublication.sites.${proxySite}.publicIngressHost;
  declaredProxyHosts = config.servicePublication.sites.${proxySite}.defaultProxyHosts;

  # Deliberately not "*.log": the nginx module's own logrotate stanza claims
  # /var/log/nginx/*.log, and a second stanza naming a file that glob already
  # covers is a duplicate log entry, which logrotate rejects outright (and
  # services.logrotate.checkConfig would fail the build). The stock stanza is
  # mkDefault weekly/rotate=26 and belongs to every other vhost on this box, so
  # it is left alone and this file simply sits outside its glob while staying
  # inside nginx's LogsDirectory, which is the only place under ProtectSystem
  # =strict that nginx can write.
  davAccessLog = "/var/log/nginx/saves-dav.access";
  logFormatName = "saves_dav";
  requestZone = "saves_dav_req";
  connectionZone = "saves_dav_conn";
  # The rate-limit and logging key. NOT ngx_http_realip: see the maps in
  # commonHttpConfig below for why this vhost cannot rewrite $remote_addr. Both
  # carry their own leading `$` so the nginx text below can interpolate them
  # directly; the alternative renders the same bytes and reads far worse.
  clientVariable = "$saves_dav_client";
  cfIpVariable = "$saves_dav_cf_ip";

  backend = {
    host = "link";
    inherit (webdav) port;
  };
in
{
  # Whole-application bypass, not a per-route one. RetroArch's Cloud Sync client
  # speaks HTTP Basic against rclone and has no browser, no redirect handling
  # and no way to complete a Cloudflare Access identity challenge -- the same
  # constraint Grout has in modules/link/romm.nix, arrived at from the same
  # direction. Unlike RomM there is no second surface to keep gated: every path
  # under this hostname is the sync protocol, so narrowing the bypass to a
  # prefix would buy nothing and would leave the parts a client actually needs
  # behind a challenge it cannot answer.
  #
  # lib/service-publication.nix only accepts this shape when it is declared
  # whole: public, bypassAccess, a justification, and no Access policy, no
  # service tokens and no route-level access override anywhere. Everything that
  # would normally protect the endpoint therefore has to be somewhere else --
  # HTTP Basic at rclone, the rate limits below, and the Cloudflare WAF rules
  # the runbook makes an operator precondition.
  servicePublication.applications.saves = {
    site = proxySite;
    public = true;
    publicHostname = "saves.finnrut.is";
    access = {
      bypassAccess = true;
      bypassJustification = "RetroArch's Cloud Sync client authenticates with HTTP Basic against rclone and cannot complete a Cloudflare Access identity challenge";
    };
    # Nothing to link to. With --disable-dir-list an authenticated GET / answers
    # 405 and an unauthenticated one answers 401 (both observed against rclone
    # 1.75.0), so a Homepage tile could only ever render an error next to a
    # hostname nobody is meant to open in a browser.
    homepage.enable = false;

    # Server level, so it covers every generated location without touching any
    # route's generated ACL. Read modules/service-publication/nixos.nix:125 for
    # where this lands.
    #
    # Nothing here sets `proxy_set_header Host`: recommendedProxySettings
    # already emits one, and nixpkgs writes extraConfig BEFORE the include, so a
    # second Host header would duplicate rather than override.
    #
    # There is deliberately no rewrite, no try_files, no trailing-slash handling
    # and no dav_methods:
    #   * a rewrite changes the URI the origin resolves, and a WebDAV client
    #     builds its Destination headers and PROPFIND hrefs out of the exact URI
    #     it sent, so rewriting desynchronises the client's map of the
    #     collection from the server's;
    #   * a trailing-slash redirect would invent behaviour the origin does not
    #     have -- rclone issues no redirects at all, and GET /dir without a
    #     slash is a hard 405 -- and would hide that from anyone reading a
    #     scanner report;
    #   * try_files resolves against nginx's own root, which on the proxy holds
    #     none of this and would 404 every request before proxy_pass ran;
    #   * dav_methods would make nginx ANSWER PUT/MKCOL/COPY/MOVE itself against
    #     a local root instead of proxying them, which is how you end up with
    #     two half-populated save trees and no way to tell which is authoritative.
    nginx.extraConfig = ''
      # Basic auth AT THE PROXY, not only at rclone.
      #
      # This is load-bearing, not defence in depth. rclone's own auth middleware
      # short-circuits CORS preflight BEFORE checking the htpasswd:
      #
      #     // skip auth for CORS preflight
      #     if r.Method == "OPTIONS" { next.ServeHTTP(w, r); return }
      #
      # and golang.org/x/net/webdav's handleOptions then Stat()s the request
      # path and builds the Allow header from the result. On a hostname with a
      # whole-application Access bypass that made unauthenticated OPTIONS a
      # three-way existence oracle -- file, directory, or absent -- readable off
      # Allow, and on THIS service the path is a save file name, which is a game
      # title. Measured against rclone 1.75.0 with this unit's exact flags:
      # every other method 401s, OPTIONS alone answers 200. It was also silent:
      # a 200 never emits rclone's "Unauthorized request from" line, so the
      # metrics exporter below and both auth alert rules stayed flat throughout.
      #
      # nginx's auth_basic has no such exemption -- verified: unauthenticated
      # OPTIONS is 401, authenticated OPTIONS reaches the handler -- and it
      # validates the bcrypt hashes directly through crypt_r(), which libxcrypt
      # supports on NixOS (verified against a real $2y$ htpasswd).
      #
      # Deliberately NOT `if ($request_method = OPTIONS) { return 405; }`:
      # RetroArch's WebDAV driver probes with OPTIONS at sync_begin, so blanket
      # rejection would break the one client this bypass exists for. Requiring
      # credentials keeps OPTIONS working for anyone who has them.
      #
      # nginx does not strip Authorization, so the same credentials still reach
      # rclone and its htpasswd remains a second, independent check. The route's
      # health contract stays expectedStatuses = [ 401 ] because nginx now
      # issues that 401 itself for an unauthenticated GET /.
      auth_basic           "${realm}";
      auth_basic_user_file ${proxyHtpasswdRuntimePath};

      # There is deliberately NO set_real_ip_from / real_ip_header here, even
      # though CF-Connecting-IP is exactly the address the rate limits below
      # want to key on. ngx_http_realip rewrites $remote_addr in the POST_READ
      # phase, which is BEFORE the ACCESS phase where ngx_http_access evaluates
      # the allow/deny list that modules/service-publication/nixos.nix generates
      # into every public route. That list allows the site's trusted CIDRs plus
      # cloudflared's own LAN address and denies the rest, so a restored
      # $remote_addr made the generated ACL compare against the INTERNET
      # client's address, which is in none of those ranges: every tunnelled
      # request was refused with nginx's own 403 before auth_basic could issue
      # the 401 this route's health contract expects. Observed as
      # `saves/root: bypassed external health returned 403` from the
      # service-publication smoke, and reproduced on the proxy itself -- an
      # otherwise identical request 401s without the header and 403s with it.
      #
      # The client address is recovered as a plain variable instead, by the two
      # maps in commonHttpConfig, and used for the limit zones and the log. It
      # carries the same trust set the realip directives had (the header counts
      # only when the peer is impa's own LAN address, which is what cloudflared
      # connects FROM, because lib/service-publication.nix builds the Tunnel
      # ingress as https://<proxy lanAddress>:443) and the same residual risk:
      # any local process on impa can open a connection to this vhost and forge
      # CF-Connecting-IP, forging both the rate-limit key and the logged
      # address. That is why the rate limits here are a fairness and
      # brute-force control and never an authentication one. What it no longer
      # does is move $remote_addr out from under the generated ACL.

      # Save files are kilobytes; the largest object this authority will ever
      # hold is a PS2 memory card image or a save state, single-digit MiB. 64m
      # is roughly eight times the largest plausible upload and still inside
      # Cloudflare's 100 MB request-body cap, so a runaway PUT is refused at the
      # proxy instead of being written into the subvolume. client_body_timeout
      # is per read operation, not per request, so 60s is generous for a phone
      # on a bad uplink without leaving a stalled body open forever.
      client_max_body_size 64m;
      client_body_timeout 60s;

      # A Cloud Sync lifecycle is not one request, it is a burst of many small
      # ones: a PROPFIND per directory plus a GET or PUT per changed file, fired
      # back to back with no pacing. link's live save tree alone is 131 files,
      # so a first sync is comfortably 150-300 requests in a few seconds. The
      # textbook rate=1r/s burst=5 would reject request six and the client would
      # simply never see those saves, because RetroArch has no retry, no backoff
      # and no durable queue -- a rejected leg is skipped until the next
      # startup, core unload or manual "Sync Now". So: a high sustained rate, a
      # burst deep enough to swallow a whole first sync, and `nodelay` so the
      # burst is served immediately instead of being smoothed out into a
      # multi-minute trickle. Sustained abuse still converges on 30r/s per
      # client address.
      limit_req zone=${requestZone} burst=200 nodelay;
      limit_req_status 429;
      # Generous on purpose: under HTTP/2 every concurrent REQUEST counts
      # against limit_conn, not every connection, so a client that pipelines its
      # PROPFINDs over one connection can trivially show up as dozens.
      limit_conn ${connectionZone} 64;
      limit_conn_status 429;

      # 429 rather than the 503 default: it is the accurate status, and it is
      # the one a client can distinguish from the origin being broken.

      # Metadata only. $request, $uri and $args are deliberately absent: on this
      # hostname the path IS a save file name, which is a game title, and an
      # access log is not the place to accumulate a reading list. Authorization
      # is likewise never logged.
      access_log ${davAccessLog} ${logFormatName};

      # WebDAV is a streaming protocol in both directions and the proxy has no
      # business holding a copy. Buffering a PUT would also defer the upstream
      # write past the client's own timeout, and proxy_max_temp_file_size 0
      # makes sure a large response can never be spooled to the edge box's disk.
      proxy_request_buffering off;
      proxy_buffering off;
      proxy_max_temp_file_size 0;
      # rclone's --vfs-cache-mode writes finishes a PUT with a rename(2) and an
      # fsync on a busy 4 TB filesystem; nginx's 60s default is close enough to
      # that to matter, and a proxy timeout mid-PUT is precisely the truncated
      # save the cache mode exists to prevent.
      proxy_read_timeout 120s;
      proxy_send_timeout 120s;
    '';

    routes.root = {
      inherit backend;
      health = {
        path = "/";
        # 401 and nothing else -- now issued by NGINX's auth_basic rather than
        # by rclone. The status is unchanged, but the reason matters: rclone's
        # htpasswd check does NOT run before routing for every method. Its auth
        # middleware exempts OPTIONS for CORS preflight, which on an
        # Access-bypassed hostname made unauthenticated OPTIONS a path-existence
        # oracle until auth_basic was added at the proxy (see nginx.extraConfig
        # above). Every other method 401s at rclone; OPTIONS answered 200.
        #
        # That single status is still what proves the bypass is real: an Access
        # challenge would be a 302 to cloudflareaccess.com, and a 200 would mean
        # something is answering without credentials.
        expectedStatuses = [ 401 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      credentialDeployed = config.infra.saveSync.webdav.credentialDeployed;
      yaml = pkgs.formats.yaml { };

      # Refuse loudly, and print the fix rather than the fault. This runs as the
      # service user before rclone binds anything, so a missing subvolume is a
      # failed unit with a copy-pasteable command in its journal instead of a
      # healthy-looking server writing into a directory btrbk cannot snapshot.
      preflight = pkgs.writeShellApplication {
        name = "${serviceName}-preflight";
        runtimeInputs = [ pkgs.coreutils ];
        meta.description = "Refuse to serve the RetroArch save authority unless its Btrfs subvolume is present and writable";
        text = ''
          data_dir=${lib.escapeShellArg webdav.dataDir}

          if [ ! -d "$data_dir" ]; then
            cat >&2 <<EOF
          $data_dir does not exist.

          The save authority serves a dedicated Btrfs subvolume and nothing in this
          repository creates it: a tmpfiles rule would create a plain directory, rclone
          would serve it happily, and btrbk would have nothing to snapshot. Create it on
          link, through one of the two mount points of that subvolume:

            sudo btrfs subvolume create $data_dir
            sudo chown ${serviceUser}:${serviceUser} $data_dir
            sudo chmod 0750 $data_dir
          EOF
            exit 1
          fi

          # A Btrfs subvolume root is always inode 256; a plain directory on the
          # same filesystem is not. Both checks are ordinary stat(2) calls, so
          # they work under an empty CapabilityBoundingSet -- `btrfs subvolume
          # show` would not.
          fstype=$(stat -f -c %T "$data_dir")
          inode=$(stat -c %i "$data_dir")
          if [ "$fstype" != btrfs ] || [ "$inode" != 256 ]; then
            cat >&2 <<EOF
          $data_dir is not a Btrfs subvolume root (filesystem $fstype, inode $inode).

          It is almost certainly a plain directory that something created for you. Nothing
          here will fail until a recovery does. Move it aside and create the subvolume:

            sudo mv $data_dir $data_dir.plaindir
            sudo btrfs subvolume create $data_dir
            sudo chown ${serviceUser}:${serviceUser} $data_dir
            sudo cp -a $data_dir.plaindir/. $data_dir/
          EOF
            exit 1
          fi

          if [ ! -w "$data_dir" ]; then
            cat >&2 <<EOF
          $data_dir is not writable by ${serviceUser}.

            sudo chown ${serviceUser}:${serviceUser} $data_dir
            sudo chmod 0750 $data_dir
          EOF
            exit 1
          fi
        '';
      };

      # Counts, and nothing but counts. There is no nginx exporter and no Loki
      # ruler on this stack, so the node-exporter textfile collector is the only
      # hook that exists for authentication failures; this is modelled on the
      # openclaw-service-metrics timer in modules/link/observability.nix and
      # writes into the directory that module already owns.
      authMetrics = pkgs.writeShellApplication {
        name = "${serviceName}-metrics";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.systemd
        ];
        meta.description = "Export a WebDAV authentication-failure count for the RetroArch save authority, with no request detail";
        text = ''
          metrics_dir=/var/lib/prometheus-node-exporter-text-files
          metrics_tmp="$metrics_dir/${serviceName}.prom.tmp"
          metrics_out="$metrics_dir/${serviceName}.prom"

          # The line this matches is, verbatim from rclone 1.75.0:
          #   INFO  : <path>: <address>: Unauthorized request from <user>
          # It carries the requested path -- which on this service is a save
          # file name, which is a game title -- and the rejected username.
          # Neither leaves this pipeline: grep -c yields a number and the number
          # is the only thing written. INFO is also the lowest level at which
          # the line exists at all, so the journal itself does hold those paths;
          # this exporter is the boundary they do not cross.
          #
          # --boot makes the counter reset on reboot, which Prometheus already
          # understands as a counter reset. A journal vacuum mid-boot looks like
          # the same thing and undercounts rather than overcounts.
          unauthorized=$(journalctl --boot --unit=${serviceName}.service --output=cat --no-pager 2>/dev/null \
            | grep -c 'Unauthorized request from' || true)
          case "$unauthorized" in (*[!0-9]*|"") unauthorized=0;; esac

          {
            echo '# HELP retroarch_saves_webdav_unauthorized_requests_total WebDAV requests rejected by HTTP Basic authentication since boot.'
            echo '# TYPE retroarch_saves_webdav_unauthorized_requests_total counter'
            echo "retroarch_saves_webdav_unauthorized_requests_total $unauthorized"
          } > "$metrics_tmp"
          chmod 0644 "$metrics_tmp"
          mv "$metrics_tmp" "$metrics_out"
        '';
      };

      saveAuthorityRules = yaml.generate "retroarch-save-authority-rules.yaml" {
        groups = [
          {
            name = "retroarch-save-authority";
            interval = "1m";
            rules = [
              {
                # The generic SystemdUnitFailed rule in
                # modules/link/observability.nix already sees this unit, at
                # warning. This one is critical because the thing that stopped
                # is the only writable copy of every client's save history, and
                # because every client fails SILENTLY when it is gone: a failed
                # sync's only trace in RetroArch is the word "failures" appended
                # to a task title.
                alert = "SaveAuthorityUnitFailed";
                expr = ''node_systemd_unit_state{instance="link",name="${serviceName}.service",state="failed"} == 1'';
                for = "2m";
                labels.severity = "critical";
                annotations.summary = "RetroArch save authority unit has failed on link";
              }
              {
                alert = "SaveAuthorityNotServing";
                expr = ''node_systemd_unit_state{instance="link",name="${serviceName}.service",state="active"} == 0'';
                for = "10m";
                labels.severity = "critical";
                annotations.summary = "RetroArch save authority is not running on link";
              }
              {
                # Rising, not present: a wrong password on one client produces a
                # handful of rejections per sync trigger and fixes itself the
                # moment somebody retypes it, so a threshold of zero would page
                # on ordinary human error. Twenty in fifteen minutes is past
                # what a misconfigured client can produce on its own.
                alert = "SaveAuthorityAuthFailuresRising";
                expr = ''increase(retroarch_saves_webdav_unauthorized_requests_total{instance="link"}[15m]) > 20'';
                for = "10m";
                labels.severity = "warning";
                annotations.summary = "WebDAV authentication failures are rising on the RetroArch save authority";
              }
              {
                # HTTP Basic is the only authentication in front of a WebDAV
                # server that implements DELETE and MOVE. Sustained failures are
                # somebody working through a list.
                alert = "SaveAuthorityAuthFailureFlood";
                expr = ''increase(retroarch_saves_webdav_unauthorized_requests_total{instance="link"}[1h]) > 200'';
                for = "10m";
                labels.severity = "critical";
                annotations.summary = "Sustained WebDAV authentication failures against the RetroArch save authority";
              }
              {
                # Without this, the two rules above degrade to silence rather
                # than to noise: increase() over an absent series returns
                # nothing and an alert that returns nothing never fires. The
                # exporter writes a 0 every minute precisely so that its absence
                # is itself a signal.
                alert = "SaveAuthorityAuthMetricsMissing";
                expr = ''absent(retroarch_saves_webdav_unauthorized_requests_total{instance="link"})'';
                for = "15m";
                labels.severity = "warning";
                annotations.summary = "RetroArch save authority authentication-failure counter is no longer being exported";
              }
            ];
          }
        ];
      };
    in
    {
      options.infra.saveSync.webdav.credentialDeployed = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the htpasswd agenix secret for the save authority exists in
          the private secrets repository yet.

          Defaults false because an `age.secrets.<name>.file` pointing at a
          `.age` that has not been created BREAKS EVALUATION for the whole
          flake, not just for this host. The declaration below is otherwise
          complete: create the file, flip this, deploy.

          It also gates the alert rules and the metrics timer. Every rule in
          that group describes a service that is expected to be running, and
          until the credential exists the unit is deliberately held inactive by
          its ConditionPathExists -- a group that fires critical from the moment
          it merges only teaches its reader to ignore the next one.
        '';
      };

      config = {
        # Released 2026-09-07: games/retroarch-saves-htpasswd.age exists in the
        # secrets repository as of rev 465292e, carrying three bcrypt entries
        # (link, ios, rg-slide), each verified against the password its client
        # credential file actually holds. Until that was true this had to stay
        # false -- see the option description; a missing .age breaks evaluation
        # for every host, and the alert group would have fired critical from the
        # moment it merged.
        infra.saveSync.webdav.credentialDeployed = credentialIsDeployed;

        users.users.${serviceUser} = {
          isSystemUser = true;
          group = serviceUser;
          description = "RetroArch save authority WebDAV server";
        };
        users.groups.${serviceUser} = { };

        # The operator reads this tree constantly and writes it almost never:
        # every diagnosis of a forked save prefix or a blanked cartridge is
        # `blank-scan`, `md5sum` and `ls` over the live data and the btrbk
        # snapshots, and routing all of that through sudo is how a read turns
        # into an accidental write. Group membership grants exactly the read.
        #
        # It cannot grant more: the tmpfiles rule below holds the subvolume at
        # 0750 and rclone's umask 0027 makes every file inside 0640, so the
        # group bit is r-x on directories and r-- on files. Restoring a save
        # still needs sudo, deliberately -- that asymmetry is the point, not an
        # oversight to be fixed later by widening the mode to 0770.
        #
        # Supplementary groups are resolved when a process STARTS, so an
        # already-running login session keeps the old set: this takes effect at
        # the operator's next login, not at switch time. See the same trap
        # documented against the romm group in modules/link/syncthing.nix.
        users.users.tunnel.extraGroups = [ serviceUser ];

        # `z`, never `d`. See the header: `d` would create a plain directory
        # where an operator-created Btrfs subvolume belongs, rclone would serve
        # it, and the failure would surface as an impossible restore. `z`
        # adjusts an existing path's ownership and mode and creates nothing;
        # when the subvolume is missing the preflight refuses instead.
        systemd.tmpfiles.rules = [
          "z ${webdav.dataDir} 0750 ${serviceUser} ${serviceUser} -"
        ];

        # See the header for why this is not loopback and why this opening does
        # not widen anything: the generated nixos-service-publication chain is
        # matched first and narrows the port to the proxy's /32.
        networking.firewall.allowedTCPPorts = [ webdav.port ];

        age.secrets = lib.mkIf credentialDeployed {
          "retroarch-saves-htpasswd" = {
            file = htpasswdAgeFile;
            mode = "400";
            owner = "root";
            group = "root";
          };
        };

        systemd.services.${serviceName} = {
          description = "RetroArch save authority (rclone WebDAV)";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          onFailure = [ "notify-telegram@%n.service" ];

          # Not a failure: before the operator has staged the htpasswd there is
          # nothing to authenticate against, and a unit that crash-loops on a
          # missing credential would send a Telegram alert every ten seconds
          # about a state the repository already knows it is in. Same pattern as
          # the acme-order-renew condition in
          # modules/service-publication/nixos.nix.
          unitConfig.ConditionPathExists = htpasswdRuntimePath;

          serviceConfig = {
            Type = "exec";
            User = serviceUser;
            Group = serviceUser;
            Restart = "on-failure";
            RestartSec = "10s";

            # Never --user/--pass: both land in argv, where every local process
            # can read them out of /proc, and rclone hashes --pass with
            # MD5-crypt against a published default salt. The htpasswd holds
            # bcrypt, which rclone's own documentation recommends, and reaches
            # the process through ramfs at %d.
            LoadCredential = [ "${credentialId}:${htpasswdRuntimePath}" ];

            CacheDirectory = baseNameOf cacheDir;
            CacheDirectoryMode = "0700";

            # --file-perms and --dir-perms are presentation only: they change
            # what rclone REPORTS over the wire, not what lands on disk. The
            # on-disk mode comes from here. 0027 gives 0640 files inside 0750
            # directories, owned by the service user, which is what btrbk's
            # snapshots and restic's backup both read back.
            UMask = "0027";

            ExecStartPre = lib.getExe preflight;
            ExecStart = lib.concatStringsSep " " [
              (lib.getExe pkgs.rclone)
              "serve"
              "webdav"
              webdav.dataDir
              "--addr ${linkLanAddress}:${toString webdav.port}"
              "--htpasswd %d/${credentialId}"
              # Write to a .partial in the cache and rename(2) it into place. The
              # costs, stated rather than discovered: a PUT is acknowledged up to
              # --vfs-write-back (5s by default) before the bytes reach the data
              # directory, so a crash inside that window loses an acknowledged
              # write; and every written file exists twice for that window, once
              # in /var/cache on the root filesystem and once in the subvolume.
              # Save files are kilobytes, so the second copy is noise against
              # RootDiskPressure. Never add --inplace: it defeats the rename and
              # puts the truncation back.
              "--vfs-cache-mode writes"
              "--cache-dir ${cacheDir}"
              # The VFS caches directory listings for 5 minutes by default.
              # rclone invalidates its own writes, but a restore -- from a btrbk
              # snapshot or from restic, which is the entire recovery story for
              # this service -- happens underneath it, and a client that syncs
              # into a stale listing undoes the restore. One minute is short
              # enough that a restore is visible before anyone gets that far.
              "--dir-cache-time 1m"
              "--disable-dir-list"
              # Deliberately absent: -L / --copy-links / --links. rclone skips
              # symlinks by default, and that default is a containment property
              # -- it is what keeps a symlink dropped into the subvolume from
              # publishing something outside it.
              #
              # Also absent: --etag-hash. The local backend is a SlowHash, so
              # every PROPFIND would read every file end to end to answer it.
              #
              # INFO is required, not cosmetic: "Unauthorized request from" does
              # not exist at NOTICE, and that line is the only authentication
              # signal this stack has.
              "--log-level INFO"
            ];

            NoNewPrivileges = true;
            # The port is above 1024, so the server needs nothing at all.
            CapabilityBoundingSet = [ ];
            AmbientCapabilities = [ ];
            ProtectSystem = "strict";
            ReadWritePaths = [ webdav.dataDir ];
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            ProtectClock = true;
            ProtectHostname = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            RemoveIPC = true;
            LockPersonality = true;
            # rclone is Go and never maps writable-executable memory.
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
              "~@resources"
            ];
          };
        };

        systemd.services."${serviceName}-metrics" = lib.mkIf credentialDeployed {
          description = "Export save-authority authentication-failure counts without request detail";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe authMetrics;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            # The collector directory itself is created and owned by
            # modules/link/observability.nix; re-declaring the tmpfiles rule
            # here would only give systemd-tmpfiles a duplicate line to warn
            # about.
            ReadWritePaths = [ "/var/lib/prometheus-node-exporter-text-files" ];
          };
        };

        systemd.timers."${serviceName}-metrics" = lib.mkIf credentialDeployed {
          description = "Refresh save-authority authentication-failure counts";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = "1m";
            Unit = "${serviceName}-metrics.service";
          };
        };

        services.prometheus.ruleFiles = lib.mkIf credentialDeployed (lib.mkAfter [ saveAuthorityRules ]);
      };
    };

  # The vhost for saves.finnrut.is is generated on the PROXY, and everything
  # below is http-context only: map, limit_req_zone, limit_conn_zone and
  # log_format cannot appear in a server block, so they cannot ride along in the
  # application's nginx.extraConfig above and have to be contributed to impa's
  # own commonHttpConfig from here. Splitting them across two files is not an
  # accident of layout, it is the only arrangement nginx accepts.
  configurations.nixos.${proxyHostName}.module =
    { config, lib, ... }:
    {
      assertions = [
        {
          assertion = declaredIngressHost == proxyHostName;
          message = "modules/link/saves-webdav.nix contributes nginx http-context config and a CF-Connecting-IP trust set to ${proxyHostName}, but site ${proxySite} now publishes through ${declaredIngressHost}; move both to that host.";
        }
        {
          assertion = declaredProxyHosts == [ proxyHostName ];
          message = "modules/link/saves-webdav.nix assumes site ${proxySite} proxies through ${proxyHostName} alone; the saves vhost is generated wherever defaultProxyHosts points, and its limit zones and log format must be defined on that host.";
        }
      ];

      # The SAME htpasswd the rclone unit on link uses, decrypted a second time
      # here so nginx can validate Basic auth itself. Two copies of one
      # credential is deliberate and is not a weakening: the alternative is
      # nginx forwarding every request to link before anything checks it, which
      # is exactly the hole this closes. Owned by nginx because the worker reads
      # it on every request; 0400 because nothing else on impa has any business
      # with it.
      #
      # Recipients already cover impa (users ++ systems in the secrets repo), so
      # no rekey was needed to add this consumer.
      age.secrets = lib.mkIf credentialIsDeployed {
        ${proxyCredentialName} = {
          file = htpasswdAgeFile;
          mode = "0400";
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
        };
      };

      services.nginx.commonHttpConfig = ''
        # Metadata only, and one line per request. $request, $uri, $args and the
        # Authorization header are all deliberately missing: on saves.finnrut.is
        # the path is a save file name, which is a game title.
        log_format ${logFormatName} '$time_iso8601 client=${clientVariable} method=$request_method '
                                    'status=$status bytes=$body_bytes_sent reqlen=$request_length '
                                    'rt=$request_time ustatus=$upstream_status urt=$upstream_response_time';

        # The client address, recovered WITHOUT ngx_http_realip. The vhost
        # cannot rewrite $remote_addr, because the generated public-route ACL
        # evaluates against it one phase later and would then 403 every
        # tunnelled request (the long note in nginx.extraConfig above has the
        # phase ordering and the observed failure). A variable is the whole
        # difference: it feeds the limit zones and the log and is invisible to
        # ngx_http_access.
        #
        # Two maps because one cannot express "trust this header only from this
        # peer". The first yields the header only when the connection actually
        # came from cloudflared on this proxy -- exactly the set_real_ip_from
        # trust set -- and an empty string for every other peer, including any
        # LAN client that sets the header itself. The second falls back to the
        # real peer address whenever the first produced nothing, so a direct LAN
        # request is still keyed and logged as itself rather than as "".
        #
        # Keyed as a string rather than $binary_remote_addr: the value is a
        # variable, so the binary form is not available. A textual IPv4 key is a
        # few bytes wider per entry, which a 10m zone absorbs without noticing.
        map $remote_addr ${cfIpVariable} {
          default "";
          ${proxyLanAddress} $http_cf_connecting_ip;
        }
        map ${cfIpVariable} ${clientVariable} {
          default ${cfIpVariable};
          "" $remote_addr;
        }

        # Both modules evaluate in PREACCESS, after the maps resolve, so the key
        # is the real client. Keying on $remote_addr instead would put every
        # internet request in the world onto cloudflared's single source address
        # and rate-limit the whole world as one client.
        limit_req_zone ${clientVariable} zone=${requestZone}:10m rate=30r/s;
        limit_conn_zone ${clientVariable} zone=${connectionZone}:10m;
      '';

      # 30 days, and a stanza of its own. The nginx module's stock stanza is
      # weekly/rotate=26 through mkDefault and belongs to every other vhost on
      # this host, so it is not overridden; the DAV log simply sits outside its
      # /var/log/nginx/*.log glob (see davAccessLog above) so that logrotate
      # gets one stanza per file instead of a duplicate-entry error.
      services.logrotate.settings.saves-dav = {
        files = [ davAccessLog ];
        frequency = "daily";
        rotate = 30;
        missingok = true;
        notifempty = true;
        compress = true;
        delaycompress = true;
        # /var/log/nginx is 0750 nginx:nginx, so logrotate has to drop to the
        # same user to rotate inside it.
        su = "${config.services.nginx.user} ${config.services.nginx.group}";
        sharedscripts = true;
        postrotate = "[ ! -f /var/run/nginx/nginx.pid ] || kill -USR1 `cat /var/run/nginx/nginx.pid`";
      };
    };
}
