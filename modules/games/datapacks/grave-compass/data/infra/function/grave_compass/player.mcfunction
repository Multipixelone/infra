# AxGraves captures drops during the death event; never give while dead.
execute if entity @s[nbt={Health:0.0f}] run return 0
# The statistic advances only while alive. Pending deaths also survive reconnects.
execute if score @s igc_deaths matches 1.. if score @s igc_time matches 1.. run function infra:grave_compass/respawn
execute store result score @s igc_items run clear @s minecraft:recovery_compass[minecraft:custom_data~{infra_grave_compass:1b}] 0
execute if score @s igc_items matches 1.. if data entity @s LastDeathLocation run function infra:grave_compass/check_arrival
