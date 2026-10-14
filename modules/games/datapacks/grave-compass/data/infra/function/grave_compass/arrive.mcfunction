# Keep the player's dimension; changing it would make @s distance checks unsafe.
$execute if dimension $(dimension) positioned $(x) $(y) $(z) if entity @s[distance=..3] run clear @s minecraft:recovery_compass[minecraft:custom_data~{infra_grave_compass:1b}]
