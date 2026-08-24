{
  gitleaks,
  gitMinimal,
  nix,
  writeShellApplication,
}:
writeShellApplication {
  name = "service-publication-validate";
  runtimeInputs = [
    gitleaks
    gitMinimal
    nix
  ];
  text = ''
    repo_root=$(git rev-parse --show-toplevel)
    cd "$repo_root"

    stage() { printf '\n==> %s\n' "$1"; }

    system=$(nix eval --impure --raw --expr builtins.currentSystem)

    stage "build focused registry, generated-file, formatting, OpenTofu, and fail-closed checks"
    nix build --no-link ".#checks.$system.service-publication-validation"

    stage "scan service-publication files and history for secrets"
    scan_paths=(
      Justfile
      docs/service-publication-runbook.md
      docs/split-dns-service-publication.md
      infra/service-publication
      lib/service-publication.nix
      modules/service-publication
      pkgs/service-publication-deploy
      pkgs/service-publication-smoke
      pkgs/service-publication-tofu
      pkgs/service-publication-validate
    )
    for path in "''${scan_paths[@]}"; do
      gitleaks dir --redact --verbose "$path"
    done
    gitleaks git --redact --verbose \
      --log-opts="--all -- ''${scan_paths[*]}" \
      "$repo_root"

    stage "service-publication validation passed"
  '';
  meta.description = "Run focused, provider-safe service publication validation";
}
