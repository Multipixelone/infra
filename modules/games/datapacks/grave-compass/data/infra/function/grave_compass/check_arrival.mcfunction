# Calls are synchronous; replace the entire scratch object for every player.
data modify storage infra:grave_compass death set from entity @s LastDeathLocation
data modify storage infra:grave_compass death.x set from entity @s LastDeathLocation.pos[0]
data modify storage infra:grave_compass death.y set from entity @s LastDeathLocation.pos[1]
data modify storage infra:grave_compass death.z set from entity @s LastDeathLocation.pos[2]
function infra:grave_compass/arrive with storage infra:grave_compass death
