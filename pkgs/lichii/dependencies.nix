{
  lib,
  fetchurl,
  runCommand,
  gnutar,
  gzip,
  zstd,
  patch,
  src,
}:
let
  manifest = builtins.fromJSON (builtins.readFile "${src}/cpmfile.json");
  # These sources must match upstream: forced bundled codecs/data and the
  # coupled Vulkan/SPIR-V toolchain. Others use the locked nixpkgs packages.
  names = [
    "zstd"
    "opus"
    "zbic"
    "reshade"
    "vulkan-headers"
    "vulkan-utility-libraries"
    "spirv-headers"
    "vulkan-memory-allocator"
    "sirit"
    "xbyak"
    # Header-only, consumed via xxhash_SOURCE_DIR (DOWNLOAD_ONLY).
    "xxhash"
  ];
  sourceFor =
    name:
    let
      dep = manifest.${name};
      archive = fetchurl {
        url = "https://${dep.git_host or "github.com"}/${dep.repo}/archive/${dep.version}.tar.gz";
        hash = "sha512-${
          builtins.convertHash {
            inherit (dep) hash;
            hashAlgo = "sha512";
            toHashFormat = "base64";
          }
        }";
      };
    in
    {
      package = dep.package or name;
      source =
        runCommand "lichii-${name}-${dep.version}"
          {
            nativeBuildInputs = [
              gnutar
              gzip
              zstd
              patch
            ];
          }
          ''
            mkdir -p $out
            tar xf ${archive} --strip-components=1 -C $out
            chmod -R u+w $out
            ${lib.concatMapStringsSep "\n" (file: ''
              patch -d $out -p1 < ${src}/.patch/${name}/${file}
            '') (dep.patches or [ ])}
          '';
    };
in
map sourceFor names
