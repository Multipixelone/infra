# Discord chat source mark

`discord.png` is a 12×9 RGBA rendering of Discord's official white Clyde symbol:

- [Official SVG](https://cdn.prod.website-files.com/6257adef93867e50d84d30e2/66e3d7f4ef6498ac018f2c55_Symbol.svg)
- SVG SHA-256: `eb3bf5a2e8b9f9aa39c1b1d38aeaa7c2997084567634c55f4141aa39cf426cec`
- PNG SHA-256: `faabe947d72a45358b27ee03ed87024b52be50da418b3033b0c5e78490103a89`

Retrieved from [Discord's brand assets](https://discord.com/branding) on
2026-10-14. The symbol belongs to Discord Inc.; it is not an original project
asset or covered by the repository's license. Discord's published guidelines
permit white marks, require the brand to be established elsewhere when using
the standalone symbol, and prohibit altering the design. The server's resource
pack prompt and the glyph's tooltip identify Discord. This mark identifies
messages arriving from Discord and implies no endorsement.

The original SVG has a 64×48 view box. It was rasterized with librsvg 2.62.3
(`rsvg-convert --width 12 --height 9 --keep-aspect-ratio`), preserving its 4:3
proportions and white fill. ImageMagick 7.1.2-29 extracted 8-bit RGBA pixels;
the PNG was encoded with unfiltered rows and no timestamps or ancillary chunks.
The vendored PNG is copied directly into the deterministic pack, with no build
or runtime download. Its font height is 9 and ascent is 8, matching staff glyphs.
