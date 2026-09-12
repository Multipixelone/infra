{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchzip,
  fetchNpmDeps,
  buildGoModule,
  buildNpmPackage,
  systemd,
  installShellFiles,
  versionCheckHook,
  nixosTests,
  nix-update-script,
  lld,
  useLLD ? stdenv.hostPlatform.isArmv7,
}:

let
  beylaVersion = "v3.28.0";
  beyla =
    {
      x86_64-linux = fetchzip {
        url = "https://github.com/grafana/beyla/releases/download/${beylaVersion}/beyla-linux-amd64-${beylaVersion}.tar.gz";
        hash = "sha256-QUDFSZ3GBUV8bcWEqQ/5yQhIW1oFeSh3GcC4QxKFx4M=";
        stripRoot = false;
      };
      aarch64-linux = fetchzip {
        url = "https://github.com/grafana/beyla/releases/download/${beylaVersion}/beyla-linux-arm64-${beylaVersion}.tar.gz";
        hash = "sha256-pkl2SBf4Vx7P6r/KjuYK4AZ6woHZdMByOjH0Sg/s/58=";
        stripRoot = false;
      };
    }
    .${stdenv.hostPlatform.system} or null;
in

buildGoModule (finalAttrs: {
  pname = "grafana-alloy";
  version = "1.19.2";

  src = fetchFromGitHub {
    owner = "grafana";
    repo = "alloy";
    tag = "v${finalAttrs.version}";
    hash = "sha256-GllAidIhgLx9ciQ/57wV1cKyzsXvEAGRgv3+8x6Uq9M=";
  };

  npmDeps = fetchNpmDeps {
    src = "${finalAttrs.src}/internal/web/ui";
    hash = "sha256-vrJUH76B0Zzuqh7Ri7B2K9YoX30xO//G0/opfYC/GTE=";
  };

  frontend = buildNpmPackage {
    pname = "alloy-frontend";
    inherit (finalAttrs) version src;

    sourceRoot = "${finalAttrs.src.name}/internal/web/ui";

    inherit (finalAttrs) npmDeps;

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -av dist $out/share

      runHook postInstall
    '';
  };

  patchPhase = ''
    cp -av ${finalAttrs.frontend}/share internal/web/ui/dist
  ''
  + lib.optionalString (beyla != null) ''
    install -Dm755 ${beyla}/beyla internal/component/beyla/ebpf/binaries/${
      if stdenv.hostPlatform.isx86_64 then "amd64" else "arm64"
    }/beyla
  '';

  modRoot = "collector";

  proxyVendor = true;
  vendorHash = "sha256-UH/D9SbMg/nb1LgjKtWptCOuIZv5MZFKI1S0MrtbRDU=";

  subPackages = [ "." ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/grafana/alloy/internal/build.Version=${finalAttrs.version}"
    "-X github.com/grafana/alloy/internal/build.Branch=v${finalAttrs.version}"
    "-X github.com/grafana/alloy/internal/build.Revision=v${finalAttrs.version}"
    "-X github.com/grafana/alloy/internal/build.BuildUser=nix@nixpkgs"
    "-X github.com/grafana/alloy/internal/build.BuildDate=1970-01-01T00:00:00Z"
  ];

  tags = [
    "embedalloyui"
    "gore2regex"
    "netgo"
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    "promtail_journal_enabled"
  ];

  env =
    lib.optionalAttrs useLLD {
      NIX_CFLAGS_LINK = "-fuse-ld=lld";
    }
    // lib.optionalAttrs stdenv.hostPlatform.isLinux {
      NIX_CFLAGS_COMPILE = "-I${lib.getDev systemd}/include";
    };

  nativeBuildInputs = [
    installShellFiles
  ]
  ++ lib.optionals useLLD [ lld ];

  postInstall =
    "mv -v $out/bin/otel_engine $out/bin/alloy"
    + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''

      installShellCompletion --cmd alloy \
        --bash <($out/bin/alloy completion bash) \
        --fish <($out/bin/alloy completion fish) \
        --zsh <($out/bin/alloy completion zsh)
    '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "-v";

  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    patchelf \
      --set-rpath "${
        lib.makeLibraryPath [ (lib.getLib systemd) ]
      }:$(patchelf --print-rpath $out/bin/alloy)" \
      $out/bin/alloy
  '';

  passthru = {
    tests = {
      inherit (nixosTests) alloy;
    };
    updateScript = nix-update-script {
      extraArgs = [
        "--version-regex"
        "v(.+)"
      ];
    };
    inherit (finalAttrs) npmDeps;
  };

  meta = {
    description = "OpenTelemetry Collector distribution with programmable pipelines";
    longDescription = ''
      Grafana Alloy is an open source OpenTelemetry Collector distribution with
      built-in Prometheus pipelines and support for metrics, logs, traces, and
      profiles.
    '';
    homepage = "https://grafana.com/oss/alloy";
    changelog = "https://github.com/grafana/alloy/blob/${finalAttrs.src.rev}/CHANGELOG.md";
    license = lib.licenses.asl20;
    platforms = lib.platforms.unix;
    maintainers = with lib.maintainers; [
      azahi
      flokli
      hbjydev
    ];
    mainProgram = "alloy";
  };
})
