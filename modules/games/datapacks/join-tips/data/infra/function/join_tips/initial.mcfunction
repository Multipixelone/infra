# Predicates read persisted statistics, unlike a newly created scoreboard.
# This runs before this session's first player tick increments play_time.
execute if entity @s[tag=infra.join_tips.seen] run return run function infra:join_tips/returning
execute if predicate infra:join_tips/returning run return run function infra:join_tips/returning
function infra:join_tips/first
