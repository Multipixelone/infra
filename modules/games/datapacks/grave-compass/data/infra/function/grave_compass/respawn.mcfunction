# clear with a zero limit counts inventory and offhand without removing anything.
execute store result score @s igc_items run clear @s minecraft:recovery_compass[minecraft:custom_data~{infra_grave_compass:1b}] 0
execute if score @s igc_items matches 0 if data entity @s LastDeathLocation run give @s minecraft:recovery_compass[minecraft:custom_data={infra_grave_compass:1b},minecraft:custom_name={text:"Grave Compass",italic:false},minecraft:lore=[{text:"Points to your last death.",italic:false}]] 1
scoreboard players set @s igc_deaths 0
