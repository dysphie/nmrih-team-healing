/* TODO:
 * - Better cooldown system, differentiate between graceful cancels and healAttemptHistory
 * - Group up all "Do X for medical" functions into a struct
 * - Restore old progress bar in case of overlap
*/


#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

#pragma semicolon 1
#pragma newdecls required

#define MAXPLAYERS_NMRIH 9

#define SEQ_RUN 3
#define SEQ_IDLE 4
#define SEQ_WALKIDLE 7

#define AMMO_INDEX_GRENADE 	9
#define AMMO_INDEX_MOLOTOV 	10
#define AMMO_INDEX_TNT 		11

#define SND_GIVE_GENERIC "weapons/melee/Melee_Draw_Temp1.wav"
#define SND_GIVE_PILLS "player/medkit/medpills_draw_01.wav"

#define MDL_FAKE_HANDS "models/items/firstaid/v_item_firstaid.mdl"

char menuItemSound[PLATFORM_MAX_PATH];
char menuExitSound[PLATFORM_MAX_PATH];

public Plugin myinfo = 
{	
	name        = "[NMRiH] Team Healing",
	author      = "Dysphie",
	description = "Allow use of first aid kits and bandages on teammates",
	version     = "1.3.5",
	url         = ""
};

ConVar cvUseDistance;
ConVar healCooldown;
ConVar medkitAmt;
ConVar bandageAmt;

float healAttemptHistory[MAXPLAYERS_NMRIH+1][6];
float nextBeginHealCheckTime[MAXPLAYERS_NMRIH+1];
float nextBeginGiveTime[MAXPLAYERS_NMRIH+1];

ConVar cureTime[2];

char medPhrases[][] = 
{
	"First Aid Kit",
	"Bandages",
	"Pills",
	"Gene Therapy"
};

enum MedicalID
{
	Medical_Invalid = -1,
	Medical_FirstAidKit,
	Medical_Bandages,
	Medical_Pills,
	Medical_Gene,
	Medical_MAX
}


enum HealRequestResult
{
	Heal_Refuse,
	Heal_BadCond,
	Heal_Accept
}

enum struct SoundMap
{
	ArrayList keys;
	ArrayList sounds;

	void Init()
	{
		this.keys = new ArrayList();
		this.sounds = new ArrayList(32);
	}

	void Set(int key, const char[] sound)
	{
		this.keys.Push(key);
		this.sounds.PushString(sound);
	}
}

SoundMap sfx[2];
ConVar cvMaxInvCarry;

enum VoiceCommand
{
	VoiceCommand_Stay = 4,
	VoiceCommand_ThankYou = 5
}

enum struct HealingUse
{
	int clientSerial;
	int targetSerial;
	float startTime;
	float duration;
	float canTryHealTime;
	int sndCursor; // Sfx 
	MedicalID medID;
	int itemRef;

	bool IsActive()
	{
		return this.startTime != -1.0;
	}

	void Start(int client, int target, int weapon, MedicalID medID)
	{
		this.targetSerial = GetClientSerial(target);
		this.clientSerial = GetClientSerial(client);
		this.medID = medID;
		this.startTime = GetTickedTime();
		this.duration = GetMedicalDuration(medID);
		this.itemRef = EntIndexToEntRef(weapon);

		FreezePlayer(target);
		FreezePlayer(client);

		ShowProgressBar(client, cureTime[medID].FloatValue);
		ShowProgressBar(target, cureTime[medID].FloatValue);

		TryVoiceCommand(client, VoiceCommand_Stay);

		// Use outsider func because CreateTimer won't let us call our own methods
		CreateTimer(0.1, _ThinkHelper, client, TIMER_REPEAT);
	}

	void UseThink()
	{
		bool shouldContinue = false;

		int client = GetClientFromSerial(this.clientSerial);
		int target = GetClientFromSerial(this.targetSerial);

		for (;;)
		{
			if (this.medID == Medical_Invalid)
				break;

			if (!client || !target)
				break;

			if (!(GetClientButtons(client) & IN_USE))
				break;

			if (GetClientButtons(target) & IN_DUCK)
			{
				PrintCenterText(client, "%t", "Healing Rejected", target);
				break;
			}

			if (!IsPlayerAlive(client) || !IsPlayerAlive(target))
				break;

			if (!IsValidEntity(this.itemRef) || !IsMedicalReady(this.itemRef))
				break;

			if (!CanClientConsumeMedical(target, this.medID))
				break;
			
			float clientPos[3], targetPos[3];
			GetClientAbsOrigin(target, targetPos);
			GetClientAbsOrigin(client, clientPos);

			// Check target distance more leniently in case either player slid a bit
			if (GetVectorDistance(clientPos, targetPos) > cvUseDistance.FloatValue + 40.0)
				break;

			shouldContinue = true;
			break;
		}

		if (!shouldContinue)
		{
			this.Stop(false);
			return;
		}

		// TODO: This seems overly convoluted
		float curTime = GetTickedTime();
		char sound[32]; 
		float elapsedPct = (curTime - this.startTime) / GetMedicalDuration(this.medID) * 100;

		int max = sfx[this.medID].keys.Length;
		for (; this.sndCursor < max; this.sndCursor++)
		{
			int playAtPct = sfx[this.medID].keys.Get(this.sndCursor);

			// Bail if we've exhausted the sounds to play this frame
			if (elapsedPct < playAtPct)
				break;

			sfx[this.medID].sounds.GetString(this.sndCursor, sound, sizeof(sound));
			EmitMedicalSound(client, sound);
		}

		if (curTime >= this.startTime + this.duration)
			this.Succeed(client, target);
	}

	void Succeed(int client, int target)
	{
		DoFunctionForMedical(this.medID, target);
		TryVoiceCommand(target, VoiceCommand_ThankYou); // A little courtesy goes a long way!

		int medical = view_as<int>(FindMedical(client, this.medID));
		if (medical == -1)
		{
			LogError("Heal succeeded but client didn't own medical!");
		}
		else
		{
			SDKHooks_DropWeapon(client, medical);
			RemoveEntity(medical);
		}

		this.Stop(true);
	}

	void Stop(bool success = false)
	{
		int client = GetClientFromSerial(this.clientSerial);
		int target = GetClientFromSerial(this.targetSerial);

		if (client)
			this.RemoveEffects(client, success);

		if (target)
		{
			if (!success)
				RememberLastHealAttempt(target);

			this.RemoveEffects(target, success);
		}

		this.Reset();
	}

	void RemoveEffects(int client, bool success = false)
	{
		PrintCenterText(client, "");
		UnfreezePlayer(client);

		if (!success)
			HideProgressBar(client);
	}

	void Init(int client)
	{
		this.Reset();
	}

	void Reset()
	{	
		this.clientSerial = 0;
		this.targetSerial = 0;
		this.startTime = -1.0;
		this.duration = -1.0;
		this.medID = Medical_Invalid;
		this.sndCursor = 0;
		this.itemRef = INVALID_ENT_REFERENCE;
	}

}

HealingUse healing[MAXPLAYERS_NMRIH+1];

Cookie optOutHealCookie, optOutShareCookie, disableZedCheckCookie;

public void OnPluginStart()
{
	cvMaxInvCarry = FindConVar("inv_maxcarry");

	LoadTranslations("core.phrases");
	LoadTranslations("team-healing.phrases");

	cureTime[Medical_FirstAidKit] = CreateConVar("sm_team_heal_first_aid_time", "8.1", 
					"Seconds it takes for the first aid kit to heal a teammate");

	cureTime[Medical_Bandages] = CreateConVar("sm_team_heal_bandage_time", "2.8",
					"Seconds it takes for bandages to heal a teammate");

	healCooldown = CreateConVar("sm_team_heal_cooldown", "5.0",
					"Cooldown period after a failed team heal attempt");
	cvUseDistance = CreateConVar("sm_team_heal_max_use_distance", "50.0",
					"Maximum use range for medical items");

	medkitAmt = FindConVar("sv_first_aid_heal_amt");
	bandageAmt = FindConVar("sv_bandage_heal_amt");

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			OnClientConnected(i);

	SoundMap medkitSnd;
	medkitSnd.Init();
	medkitSnd.Set(0, "Medkit.Open");
	medkitSnd.Set(8, "MedPills.Draw");
	medkitSnd.Set(13, "MedPills.Open");
	medkitSnd.Set(17, "MedPills.Shake");
	medkitSnd.Set(19, "MedPills.Shake");
	medkitSnd.Set(30, "Medkit.Shuffle");
	medkitSnd.Set(39, "Stitch.Prepare");
	medkitSnd.Set(46, "Stitch.Flesh");
	medkitSnd.Set(49, "Weapon_db.GenericFoley");
	medkitSnd.Set(52, "Stitch.Flesh");
	medkitSnd.Set(55, "Stitch.Flesh");
	medkitSnd.Set(58, "Medkit.Shuffle");
	medkitSnd.Set(66, "Scissors.Snip");
	medkitSnd.Set(67, "Scissors.Snip");
	medkitSnd.Set(75, "Scissors.Snip");
	medkitSnd.Set(78, "Weapon_db.GenericFoley");
	medkitSnd.Set(79, "Medkit.Shuffle");
	medkitSnd.Set(84, "Weapon_db.GenericFoley");
	medkitSnd.Set(90, "Weapon_db.GenericFoley");
	medkitSnd.Set(94, "Tape.unravel");

	SoundMap bandageSnd;
	bandageSnd.Init();
	bandageSnd.Set(0, "Weapon_db.GenericFoley");
	bandageSnd.Set(41, "Bandage.Unravel1");
	bandageSnd.Set(55, "Bandage.Unravel2");
	bandageSnd.Set(80, "Bandage.Apply");

	sfx[Medical_FirstAidKit] = medkitSnd;
	sfx[Medical_Bandages] = bandageSnd;

	AutoExecConfig();

	optOutHealCookie = RegClientCookie("disable_team_heal", "Disable team healing", CookieAccess_Public);
	optOutShareCookie = RegClientCookie("disable_team_share", "Disable team sharing", CookieAccess_Public);
	disableZedCheckCookie = RegClientCookie("disable_team_heal_radius_check", " ", CookieAccess_Public);

	SetCookieMenuItem(EntryCookieMenu, 0, "Team Healing");

	// Sounds used by cookie menu

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/core.cfg");
	SMCParser parser = new SMCParser();
	parser.OnKeyValue = OnKeyValue;
	parser.ParseFile(path);
	delete parser;
}

SMCResult OnKeyValue(SMCParser smc, const char[] key, const char[] value, bool key_quotes, bool value_quotes)
{
	if (!strcmp(key, "MenuItemSound"))
		strcopy(menuItemSound, sizeof(menuItemSound), value);
	else if (!strcmp(key, "MenuExitSound"))
		strcopy(menuExitSound, sizeof(menuExitSound), value);
}

void EntryCookieMenu(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
	if (action == CookieMenuAction_DisplayOption)
	{
		Format(buffer, maxlen, "%T", "Cookie Menu Title", client);
	}

	else if (action == CookieMenuAction_SelectOption)
	{
		if (!AreClientCookiesCached(client))
		{
			PrintToChat(client, "%t", "Cookies Not Available");
			return;
		}

		ShowToggleMenu(client);
	}
}

void ShowToggleMenu(int client)
{
	bool healAllowed, shareAllowed, doRadiusCheck;

	char value[2];
	optOutHealCookie.Get(client, value, sizeof(value));
	healAllowed = value[0] != '1';

	optOutShareCookie.Get(client, value, sizeof(value));
	shareAllowed = value[0] != '1';

	disableZedCheckCookie.Get(client, value, sizeof(value));
	doRadiusCheck = value[0] != '1';

	Panel panel = new Panel();

	char buffer[2048];

	FormatEx(buffer, sizeof(buffer), "%T", "Cookie Menu Title", client);
	panel.SetTitle(buffer);

	panel.DrawText(" ");

	// Team healing cookie
	FormatEx(buffer, sizeof(buffer), "%T: %T", "Cookie Team Healing Name", client, 
		healAllowed ? "Cookie Enabled" : "Cookie Disabled", client);
	panel.DrawItem(buffer);
	FormatEx(buffer, sizeof(buffer), "%T", "Cookie Team Healing Description", client);
	panel.DrawText(buffer);

	panel.DrawText(" ");

	// Item sharing cookie
	FormatEx(buffer, sizeof(buffer), "%T: %T", "Cookie Item Sharing Name", client, 
		shareAllowed ? "Cookie Enabled" : "Cookie Disabled", client);
	panel.DrawItem(buffer);
	FormatEx(buffer, sizeof(buffer), "%T", "Cookie Item Sharing Description", client);
	panel.DrawText(buffer);

	panel.DrawText(" ");

	// Zombie check cookie
	FormatEx(buffer, sizeof(buffer), "%T: %T", "Cookie Radius Check Name", client, 
		doRadiusCheck ? "Cookie Enabled" : "Cookie Disabled", client);
	panel.DrawItem(buffer);	
	FormatEx(buffer, sizeof(buffer), "%T", "Cookie Radius Check Description", client);
	panel.DrawText(buffer);

	panel.DrawText(" ");

	panel.CurrentKey = 8;
	FormatEx(buffer, sizeof(buffer), "%T", "Back", client);
	panel.DrawItem(buffer);

	panel.DrawText(" ");

	panel.CurrentKey = 10;
	FormatEx(buffer, sizeof(buffer), "%T", "Exit", client);
	panel.DrawItem(buffer);

	panel.Send(client, CookieTogglePanel, MENU_TIME_FOREVER);
	delete panel;
}

public int CookieTogglePanel(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		if (!AreClientCookiesCached(param1))
		{
			PrintToChat(param1, "%t", "Cookies Not Available");
			return 0;
		}

		char info[2];

		if (param2 == 1) // Team heal
		{
			optOutHealCookie.Get(param1, info, sizeof(info));
			optOutHealCookie.Set(param1, info[0] == '1' ? "0" : "1");
			EmitSoundToClient(param1, menuItemSound);
			ShowToggleMenu(param1);
		}
		else if (param2 == 2) // Item sharing
		{
			optOutShareCookie.Get(param1, info, sizeof(info));
			optOutShareCookie.Set(param1, info[0] == '1' ? "0" : "1");
			EmitSoundToClient(param1, menuItemSound);
			ShowToggleMenu(param1);
		}

		else if (param2 == 3) // Radius check
		{
			disableZedCheckCookie.Get(param1, info, sizeof(info));
			disableZedCheckCookie.Set(param1, info[0] == '1' ? "0" : "1");
			EmitSoundToClient(param1, menuItemSound);
			ShowToggleMenu(param1);
		}

		else if (param2 == 8) // Back
		{
			EmitSoundToClient(param1, menuItemSound);
			ShowCookieMenu(param1);
		}

		else if (param2 == 10) // Exit
		{
			EmitSoundToClient(param1, menuExitSound);
		}
	}

	return 0;
}

public void OnMapStart()
{
	PrecacheModel(MDL_FAKE_HANDS);
	PrecacheSound(SND_GIVE_PILLS);
	PrecacheSound(SND_GIVE_GENERIC);
	PrecacheSound(menuExitSound);
	PrecacheSound(menuItemSound);
}

void EmitMedicalSound(int client, const char[] game_sound)
{
	static char sound_name[128];

	int entity;
	int channel = SNDCHAN_AUTO;
	int sound_level = SNDLEVEL_NORMAL;
	float volume = SNDVOL_NORMAL;
	int pitch = SNDPITCH_NORMAL;
	GetGameSoundParams(game_sound, channel, sound_level, volume, pitch, sound_name, sizeof(sound_name), entity);

	EmitSoundToAll(sound_name, client, channel, sound_level, SND_CHANGEVOL | SND_CHANGEPITCH, volume, pitch);
}

public void OnClientConnected(int client)
{
	healing[client].Init(client);
	ClearHealAttemptsHistory(client);
}

public void OnClientDisconnect(int client)
{
	if (healing[client].IsActive())
		healing[client].Stop();
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (buttons & IN_USE)
		CheckCanBeginHeal(client);

	else if (buttons & IN_ATTACK2 && !(GetEntProp(client, Prop_Data, "m_nOldButtons") & IN_ATTACK2))
		CheckShouldGive(client);

	return Plugin_Continue;
}

public Action _ThinkHelper(Handle timer, int index)
{
	// Think fn was stopped externally
	if (!healing[index].IsActive())
		return Plugin_Stop;

	healing[index].UseThink();

	return Plugin_Continue;
}

float GetCanHealTime(int client)
{
	int count;
	float mostRecent;

	for (int i; i < sizeof(healAttemptHistory[]); i++)
	{
		if (healAttemptHistory[client][i])
		{
			count++;

			if (!mostRecent)
				mostRecent = healAttemptHistory[client][i];
		}
	}

	if (!mostRecent)
		return 0.0;

	float waitTime = (Pow(2.0, float(count)) - 1) / 0.4;
	return mostRecent + waitTime;
}

void CheckCanBeginHeal(int client)
{
	float curTime = GetTickedTime();
	if (nextBeginHealCheckTime[client] > curTime)
		return;

	nextBeginHealCheckTime[client] = curTime + 0.1;

	if (healing[client].IsActive())
		return;

	// Undone: Let people heal even if they're refusing healing themselves
	// if (ClientOptedOutHealing(client))
	// 	return;

	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (activeWeapon == -1)
		return;

	MedicalID medID = GetMedicalID(activeWeapon);
	if (medID != Medical_FirstAidKit && medID != Medical_Bandages)
		return;

	if (!IsMedicalReady(activeWeapon))
		return;

	// Not aiming at another player / player out of reach
	int target = GetClientUseTarget(client, cvUseDistance.FloatValue);
	if (target == -1)
		return;

	// Target doesn't want it
	if (ClientOptedOutHealing(target))
	{
		PrintCenterText(client, "%t", "Target Opted Out", target);
		return;
	}

	if (GetClientButtons(target) & IN_DUCK)
		return;
	
	if (!CanClientConsumeMedical(target, medID))
	{
		PrintCenterText(client, "%t", "Can't Heal Healthy", target);
		return;
	}

	float canHealTime = GetCanHealTime(target);
	if (canHealTime > curTime)
	{
		PrintCenterText(client, "%t", "Can't Heal Cooldown", RoundToCeil(canHealTime - curTime));
		return;
	}

	if (AreZombiesNearby(target))
	{
		PrintCenterText(client, "%t", "Can't Heal Zombies Nearby", target);
		return;
	}

	// Okay we can heal
	healing[client].Start(client, target, activeWeapon, medID);	
}

void CheckShouldGive(int client)
{
	float curTime = GetTickedTime();
	if (nextBeginGiveTime[client] > curTime)
		return;

	nextBeginGiveTime[client] = curTime + 1.3;

	if (ClientOptedOutSharing(client))
		return;

	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (activeWeapon == -1)
		return;

	MedicalID medID = GetMedicalID(activeWeapon);
	if (medID == Medical_Invalid)
		return;

	int target = GetClientUseTarget(client, 90.0);
	if (target == -1)
		return;

	if (ClientOptedOutSharing(target))
	{
		PrintCenterText(client, "%t", "Target Opted Out", target);
		return;
	}

	if (!CanFitMedical(target, medID, client))
		return;

	float targetPos[3];
	GetClientAbsOrigin(target, targetPos);

	SDKHooks_DropWeapon(client, activeWeapon, targetPos);
	AcceptEntityInput(activeWeapon, "Use", target);

	DoMedicalAnimation(client);

	TryVoiceCommand(target, VoiceCommand_ThankYou);

	PrintCenterText(target, "%t", "Received Item", client, medPhrases[medID], target);
	PrintCenterText(client, "%t", "Gave Item", target, medPhrases[medID], client);

	if (medID == Medical_Pills)
	{
		EmitSoundToClient(client, SND_GIVE_PILLS, client);
		EmitSoundToClient(target, SND_GIVE_PILLS, target);
	}
	else
	{
		EmitSoundToClient(client, SND_GIVE_GENERIC, client);
		EmitSoundToClient(target, SND_GIVE_GENERIC, target);
	}
}

void DoMedicalAnimation(int client)
{
	SetEntProp(client, Prop_Send, "m_bDrawViewmodel", 0);

	int prop = CreateEntityByName("prop_dynamic_override");

	DispatchKeyValue(prop, "model", MDL_FAKE_HANDS);
	DispatchKeyValue(prop, "disablereceiveshadows", "1");
	DispatchKeyValue(prop, "disableshadows", "1");
	DispatchKeyValue(prop, "targetname", "dummy");
	DispatchKeyValue(prop, "solid", "0");
	DispatchSpawn(prop);

	SetEntityMoveType(prop, MOVETYPE_NONE);
	int viewmodel = GetEntPropEnt(client, Prop_Data, "m_hViewModel", 0);

	float pos[3], ang[3];
	GetEntPropVector(viewmodel, Prop_Data, "m_vecAbsOrigin", pos);
	GetEntPropVector(viewmodel, Prop_Data, "m_angAbsRotation", ang);
	TeleportEntity(prop, pos, ang);

	SetVariantString("!activator");
	AcceptEntityInput(prop, "SetParent", viewmodel);

	TeleportEntity(prop, {-2.00, 0.00, 0.00});

	SetVariantString("Give");
	AcceptEntityInput(prop, "SetAnimation");
	SetEntPropFloat(prop, Prop_Send, "m_flPlaybackRate", 2.0);
	SetEntPropEnt(prop, Prop_Send, "m_hOwnerEntity", client);

	// Remove prop when animation ends
	HookSingleEntityOutput(prop, "OnAnimationDone", AnimDone_Give, true);

	// Also remove after 5 seconds in case the above callback doesn't fire somehow
	SetVariantString("OnUser1 !self:Kill::5:-1");
	AcceptEntityInput(prop, "AddOutput");
	AcceptEntityInput(prop, "FireUser1");
}

void AnimDone_Give(const char[] output, int caller, int activator, float delay) 
{
	int client = GetEntPropEnt(caller, Prop_Send, "m_hOwnerEntity");
	RemoveEntity(caller);
	SetEntProp(client, Prop_Send, "m_bDrawViewmodel", 1);
}

bool CanFitMedical(int client, MedicalID medID, int giver)
{
	// This is off by one on purpose, a full inventory gives a significant 
	// movement penalty and we don't want players to be able to trigger this

	if (GetMedicalWeight(medID) >= cvMaxInvCarry.IntValue - GetCarriedWeight(client))
	{
		PrintCenterText(giver, "%t", "Target Is Full", client);
		return false;
	}

	if (FindMedical(client, medID) != -1)
	{
		PrintCenterText(giver, "%t", "Target Already Owns", client, medPhrases[medID], giver);
		return false;
	}

	return true;
}

int GetMedicalWeight(MedicalID medID)
{
	// TODO: Read from config to allow for custom medical weights, or sdkcall GetWeight?
	static int MEDICAL_WEIGHTS[] = {85, 35, 35, 35};
	return MEDICAL_WEIGHTS[medID];
}

int GetClientUseTarget(int client, float range)
{
	float hullAng[3], hullStart[3], hullEnd[3];
	GetClientEyeAngles(client, hullAng);

	GetClientEyePosition(client, hullStart);
	ForwardVector(hullStart, hullAng, range, hullEnd);

	TR_TraceHullFilter(hullStart, hullEnd, {-20.0,-20.0,-20.0 }, {20.0, 20.0, 20.00}, MASK_PLAYERSOLID, TR_OtherPlayers, client);

	int entity = TR_GetEntityIndex();
	return (entity > 0) ? entity : -1;
}

bool TR_OtherPlayers(int entity, int mask, int client)
{
	return entity != client && entity <= MaxClients;
}

void ForwardVector(const float vPos[3], const float vAng[3], float fDistance, float vReturn[3])
{
	float vDir[3];
	GetAngleVectors(vAng, vDir, NULL_VECTOR, NULL_VECTOR);
	vReturn = vPos;
	vReturn[0] += vDir[0] * fDistance;
	vReturn[1] += vDir[1] * fDistance;
	vReturn[2] += vDir[2] * fDistance;
}

stock bool IsPlayerHurt(int client)
{
	return GetClientHealth(client) < GetEntProp(client, Prop_Data, "m_iMaxHealth");
}

stock bool IsPlayerBleeding(int client)
{
	return !!GetEntProp(client, Prop_Send, "_bleedingOut");
}

stock void ShowProgressBar(int client, float duration, float prefill = 0.0)
{
	BfWrite bf = UserMessageToBfWrite(StartMessageOne("ProgressBarShow", client));
	bf.WriteFloat(duration);
	bf.WriteFloat(prefill);
	EndMessage();
}

stock void HideProgressBar(int client)
{
	StartMessageOne("ProgressBarHide", client);
	EndMessage();
}

stock void FreezePlayer(int client)
{
	int curFlags = GetEntProp(client, Prop_Send, "m_fFlags");
	SetEntProp(client, Prop_Send, "m_fFlags", curFlags | 128);
}

stock void UnfreezePlayer(int client)
{
	int curFlags = GetEntProp(client, Prop_Send, "m_fFlags");
	SetEntProp(client, Prop_Send, "m_fFlags", curFlags & ~128);
}

void TryVoiceCommand(int client, VoiceCommand voice)
{
	static float lastVoiceTime[MAXPLAYERS_NMRIH+1];

	static ConVar hVoiceCooldown;
	if (!hVoiceCooldown)
		hVoiceCooldown = FindConVar("sv_voice_cooldown");

	float curTime = GetTickedTime();
	if (curTime - hVoiceCooldown.FloatValue < lastVoiceTime[client])
		return;

	lastVoiceTime[client] = curTime;
	float origin[3];
	GetClientAbsOrigin(client, origin);

	TE_Start("TEVoiceCommand");
	TE_WriteNum("_playerIndex", client);
	TE_WriteNum("_voiceCommand", view_as<int>(voice));
	TE_SendToAllInRange(origin, RangeType_Audibility);
}

void ApplyBandage(int client)
{
	SetEntProp(client, Prop_Send, "_bleedingOut", 0);

	int newHealth = GetClientHealth(client) + bandageAmt.IntValue;
	int maxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	if (newHealth > maxHealth)
		newHealth = maxHealth;

	SetEntityHealth(client, newHealth);
}

void ApplyFirstAidKit(int client)
{
	SetEntProp(client, Prop_Send, "_bleedingOut", 0);

	int newHealth = GetClientHealth(client) + medkitAmt.IntValue;
	int maxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	if (newHealth > maxHealth)
		newHealth = maxHealth;

	SetEntityHealth(client, newHealth);
}

void DoFunctionForMedical(MedicalID medID, int& client)
{
	if (medID == Medical_Bandages)
		ApplyBandage(client);
	else if (medID == Medical_FirstAidKit)
		ApplyFirstAidKit(client);
}

float GetMedicalDuration(MedicalID medID)
{
	if (medID == Medical_Invalid)
	{
		LogError("GetMedicalDuration called with invalid medical ID, returning dummy value");
		return 5.0;
	}

	return cureTime[medID].FloatValue;
}

bool CanClientConsumeMedical(int client, MedicalID medID)
{
	return (medID == Medical_FirstAidKit && IsPlayerHurt(client)) ||
		(medID == Medical_Bandages && IsPlayerBleeding(client));
}

bool IsMedicalReady(int medical)
{
	if (GetEntProp(medical, Prop_Send, "_applied"))
		return false;

	int sequence = GetEntProp(medical, Prop_Send, "m_nSequence");
	return sequence == SEQ_RUN || sequence == SEQ_IDLE || sequence == SEQ_WALKIDLE;
}

MedicalID GetMedicalID(int entity)
{
	if (HasEntProp(entity, Prop_Send, "_applied"))
	{
		char classname[7];
		GetEntityClassname(entity, classname, sizeof(classname));

		switch (classname[5])
		{
			case 'f':
				return Medical_FirstAidKit;
			case 'b':
				return Medical_Bandages;
			case 'p':
				return Medical_Pills;
			case 'g':
				return Medical_Gene;
		}
	}

	return Medical_Invalid;
}

bool ClientOptedOutHealing(int client)
{
	if (!AreClientCookiesCached(client))
		return false; // assume not

	char c[2];
	optOutHealCookie.Get(client, c, sizeof(c));
	return c[0] == '1';
}

bool ClientOptedOutSharing(int client)
{
	if (!AreClientCookiesCached(client))
		return false; // assume not

	char c[2];
	optOutShareCookie.Get(client, c, sizeof(c));
	return c[0] == '1';
}


int FindMedical(int client, MedicalID medID) 
{
	int maxWeapons = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i; i < maxWeapons; i++)
	{
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (weapon != -1 && GetMedicalID(weapon) == medID)
			return weapon;
	}

	return -1;
}

int GetCarriedWeight(int client)
{
	int weight;

	// Ammo boxes weight 5g each, except for nades which weight 0 so we skip them
	int maxAmmo = GetEntPropArraySize(client, Prop_Send, "m_iAmmo");
	for (int i; i < AMMO_INDEX_GRENADE; i++)
		weight += GetEntProp(client, Prop_Send, "m_iAmmo", _, i) * 5;

	for (int i = AMMO_INDEX_TNT+1; i < maxAmmo; i++)
		weight += GetEntProp(client, Prop_Send, "m_iAmmo", _, i) * 5;

	// Weapons themselves also carry weight, so add that
	weight += GetEntProp(client, Prop_Send, "_carriedWeight");
	return weight;
}

bool AreZombiesNearby(int client)
{
	bool result;

	float clientPos[3];
	GetClientEyePosition(client, clientPos);

	ArrayStack results = new ArrayStack();
	TR_EnumerateEntitiesSphere(clientPos, 90.0, MASK_SOLID, ZombiesNearby_Enumerator, results);

	while (!results.Empty)
	{
		int zombie = results.Pop();

		float zombiePos[3];
		GetEntPropVector(zombie, Prop_Send, "m_vecOrigin", zombiePos);
		zombiePos[2] += 40.0; // TODO: This is off for crawlers, do we care?

		// Now check whether zombie is in direct sight of player (not behind wall, etc)
		TR_TraceRayFilter(clientPos, zombiePos, MASK_SOLID_BRUSHONLY, RayType_EndPoint, TR_IgnoreLiving);
		if (!TR_DidHit())
		{
			result = true;
			break;
		}
	}
	delete results;
	return result;
}

public bool TR_IgnoreLiving(int entity, int contentsMask)
{
	return !IsEntityZombie(entity) && !IsEntityPlayer(entity);
}

bool ZombiesNearby_Enumerator(int entity, ArrayStack results)
{
	if (IsValidEntity(entity) && IsEntityZombie(entity))
		results.Push(entity);
	return true;
}

bool IsEntityZombie(int entity)
{
	return HasEntProp(entity, Prop_Send, "_headSplit");
}

bool IsEntityPlayer(int entity)
{
	return 0 < entity <= MaxClients;
}

// Exponential cooldown system
void RememberLastHealAttempt(int client)
{
	float attemptTime = GetTickedTime();

	bool inserted;
	for (int i; i < sizeof(healAttemptHistory[]); i++)
	{
		if (!healAttemptHistory[client][i])
		{
			healAttemptHistory[client][i] = attemptTime;
			inserted = true;
			break;
		}
	}

	if (!inserted)
	{
		int max = sizeof(healAttemptHistory[]) - 1;
		for (int i = max; i > 0; i--)
			healAttemptHistory[client][i] = healAttemptHistory[client][i-1];
		
		healAttemptHistory[client][0] = attemptTime;
	}
}

void ClearHealAttemptsHistory(int client)
{
	for (int i; i < sizeof(healAttemptHistory[]); i++)
		healAttemptHistory[client][i] = 0.0;
}