# [NMRiH] Team Healing

Allows survivors to heal each other.

![image](https://user-images.githubusercontent.com/11559683/123883869-44b7a900-d920-11eb-821e-a109f5c0f3d0.png)

To heal another survivor, hold USE (Default: E) on them while wielding a medkit or bandages.

Healing other players is quicker than self healing by default. Players can break out of healing by crouching.

It's also possible to opt out of healing entirely by typing `!settings` and setting `Disable team healing` to `Yes`


# CVars:

- sm_team_heal_first_aid_time (Default: 8.1)
  - Seconds it takes for a first aid kit to heal a teammate.
- sm_team_heal_bandage_time (Default: 2.8)
  - Seconds it takes for bandages to heal a teammate.
- sm_team_heal_max_use_distance (Default: 50.0)
  - Maximum use range for medical items.
- sm_team_heal_cooldown (Default: 5.0)
  - Seconds after a failed team heal attempt during which a player may not initialize a new one.
