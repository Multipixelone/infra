# An absent score also handles players predating installation or changing names.
execute unless score @s ijt_leave matches 0.. run return run function infra:join_tips/initial
execute if score @s ijt_leave matches 1.. run function infra:join_tips/returning
