# Vein mining on link

Veinminer by MiraculixxT, [Paper 2.12.3](https://modrinth.com/mod/veinminer/version/O12m3jOR),
was published September 30, 2026 and lists Paper/Purpur/Folia support for 26.3.
The CDN jar is pinned by SHA-256. Its actual `paper-plugin.yml` names it
`Veinminer`, version `2.12.3`, API `1.21`, with a Paper library loader and Folia
support. The project is [AGPL-3.0-only](https://github.com/MiraculixxT/Veinminer).

## For players

Sneak while mining ore, diorite or andesite with a suitable pickaxe to mine up
to 64 connected blocks of the same type. Fortune and Silk Touch still work,
and each extra block uses normal tool durability plus 0.1 exhaustion for a
small hunger cost. The client addon is allowed but optional.
Client addon users can vein-mine any block; the groups below apply to mining
without the addon.

All vanilla ores are included: coal, copper, iron, gold, redstone, lapis,
diamond and emerald, including deepslate variants; nether gold, nether quartz
and ancient debris. Logs, stems, granite, tuff, calcite, stone and deepslate
terrain are excluded. A vein contains only the starting material, so normal
and deepslate ore variants are separate operations. Diagonal neighbors count.

The 64-block cap includes the original block. This covers normal ore veins
and limits each click on a large diorite or andesite deposit to one stack.
A one-second cooldown bounds repeated operations. Creative mode does not
activate vein mining. Wrong tools or insufficient tiers fall back to ordinary
mining without extra drops. Extra blocks use the actual held pickaxe's drops
and damage operation, preserving enchantments and Unbreaking. Extra-block
processing stops at one remaining durability; the original, ordinary block
break can still break a worn tool.

Vanilla Java clients need no addon. The pinned Geyser 2.11.3 build 1249 forwards
Bedrock sneak input as Java shift input; Veinminer checks Paper's
`Player.isSneaking()`. If the server sees no sneak state, the block is mined
normally. Client-addon registration and all-block access are enabled, with no
client requirement or settings overrides. These are jar/config checks, not a
claim of a live Bedrock test.

## Configuration and compatibility

`minecraft-veinminer.nix` generates `settings.json`, `groups.json` and
`blocks.json` under each Paper backend's `plugins/Veinminer` directory. The
explicit groups require the vanilla pickaxe tag. Standalone blocks and settings
overrides are empty. Kotlin/KPaper dependencies and their Maven metadata are
pinned and preseeded in Paper's library cache; the release needs no relocation.

FAWE's breeze-rod wand is outside the pickaxe rule; Veinminer also ignores
creative players. Grave heads are outside the block lists, so AxGraves is not
a mining target. The initial break listener runs at `MONITOR` and respects
cancellation. Each extra block fires a cancellable subclass of `BlockBreakEvent`
before removal or drops. No claims or CoreProtect plugin is configured here.

Future block logging needs verification: extra blocks are set to air by the
plugin after its synthetic break event, and drops use a custom event rather
than vanilla `BlockDropItemEvent`. A logger that excludes synthetic events or
depends on vanilla drop events may miss extra blocks; do not assume complete
CoreProtect-style logging or rollback from these checks alone.

There are no bStats classes in the Veinminer or KPaper jars. The existing shared
`plugins/bStats/config.yml` remains disabled. The published updater ignores
`autoUpdate=false` when checking and downloading newer jars to
`plugins/Veinminer/update`; the long-named hide-updates option suppresses join
messages only. Finn explicitly accepted this upstream behavior. Downloaded jars
are not linked into the installed plugin set, which remains Nix-pinned.

## Activation and validation

A Paper restart is required after the separately approved deploy to load the
new jar. Do not hot-load it. Updating the declarative LuckPerms bootstrap does
not modify the existing database. During the approved activation gate, grant
use and apply the declared command restrictions additively:

```fish
sudo games-console survival 'lp group default permission set veinminer.use true'
sudo games-console survival 'lp group default permission set veinminer.toggle false'
sudo games-console survival 'lp group default permission set veinminer.blocks false'
sudo games-console survival 'lp group default permission set veinminer.groups false'
sudo games-console survival 'lp group default permission set veinminer.settings false'
sudo games-console survival 'lp group default permission set veinminer.reload false'
sudo games-console survival 'lp sync'
sudo games-console velocity 'lpv sync'
sudo games-logs survival
sudo games-logs velocity
```

Run commands individually and verify asynchronous completion in logs. Existing
builder, mod and admin inheritance carries `veinminer.use` from default. Ordinary
players receive no configuration commands; console and op command behavior is
upstream. The generated `chat-inventory.commands` also includes these grants
and restrictions. Fresh databases can use the existing bootstrap import flow.

`games-minecraft-veinminer` checks fixtures with and without LuckPerms credentials,
an additional Paper backend and no Paper backends. It runs the release's strict
JSON serializers and real traversal against a value-only Identifier fixture,
including oversized deposits, preview isolation and a failed-break abort.
It exercises the actual Paper library loader with transfers rejected, and
checks published bytecode for drop/tool, durability and cancellation guards
and the pinned Geyser sneak-input path. These checks do not start a live server.

After approved activation, smoke-test ordinary versus sneaking Java and Bedrock
mining, wrong tiers, Fortune/Silk Touch, a worn tool, a deposit over 64 blocks,
the FAWE wand and grave interactions. No deployment or live tests are part of
the configuration change.
