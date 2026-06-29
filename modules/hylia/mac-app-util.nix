{ inputs, ... }:
{
  # mac-app-util keeps Spotlight/Dock/Launchpad aliases in sync for apps Nix
  # installs (incl. home-manager "Nix Apps"), which otherwise don't get indexed.
  # NOTE: do NOT make mac-app-util's nixpkgs follow ours. Upstream pins nixpkgs
  # to a commit with SBCL 2.4.10 because newer SBCL (>=2.5.10) crashes building
  # its Common Lisp deps via named-readtables ("Bug in readtable iterators",
  # SBCL bug #2134500). Following our unstable nixpkgs reintroduces that break.
  flake-file.inputs.mac-app-util = {
    url = "github:hraban/mac-app-util";
    inputs.flake-utils.follows = "flake-utils";
  };

  configurations.darwin.hylia.module = {
    imports = [ inputs.mac-app-util.darwinModules.default ];
    # Also trampoline home-manager-installed GUI apps into ~/Applications.
    home-manager.sharedModules = [ inputs.mac-app-util.homeManagerModules.default ];
  };
}
