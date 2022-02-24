#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <vscript_proxy>
#include <nmr_teamhealing>

#pragma semicolon 1
#pragma newdecls required

#define MAXPLAYERS_NMRIH 9

#define SEQ_RUN 3
#define SEQ_IDLE 4
#define SEQ_WALKIDLE 7

#define ZOMBIE_SAFE_RADIUS 110.0

#define NMR_FL_ATCONTROLS 128

#define PLUGIN_DESCRIPTION "Allows survivors to heal each other via +use"
#define PLUGIN_VERSION "1.5.2"

public Plugin myinfo = 
{
	name        = "Team Healing",
	author      = "Dysphie",
	description = PLUGIN_DESCRIPTION,
	version     = PLUGIN_VERSION,
	url         = "https://github.com/dysphie/nmrih-team-healing"
};


bool healDisabled[MAXPLAYERS_NMRIH+1];
bool ignoreRadiusCheck[MAXPLAYERS_NMRIH+1];

bool sphereQueryAvailable;
Cookie healCookie, radiusCookie;

float healAttemptHistory[MAXPLAYERS_NMRIH+1][6];
float nextBeginHealCheckTime[MAXPLAYERS_NMRIH+1];

GlobalForward healedFwd;
GlobalForward beginHealFwd;

ConVar healAmount[2];
ConVar cureTime[2];

ConVar cvUseDistance;
ConVar pluginEnabled;

// Temporary variables used by enumerator traces
float _traceStartPos[3];
bool _traceResult;

ArrayList sfx[2];

enum HealRequestResult
{
	Heal_Refuse,
	Heal_BadCond,
	Heal_Accept
}

enum struct SoundMap
{
	int pct;
	char sound[PLATFORM_MAX_PATH];
}

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
		// Ask other plugins if we should proceed
		bool applyCooldown;
		Action result;

		Call_StartForward(beginHealFwd);
		Call_PushCell(client);
		Call_PushCell(target);
		Call_PushCell(weapon);
		Call_PushCell(medID);
		Call_PushCellRef(applyCooldown);
		Call_Finish(result);

		if (result >= Plugin_Handled)
		{
			if (applyCooldown)
				RememberLastHealAttempt(target);
			
			return;
		}

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

		// FL_ATCONTROLS is unreliable and allows players to move sometimes
		// just reapply the effect on each think
		FreezePlayer(client);
		FreezePlayer(target);

		PrintCenterText(target, "%t", "Being Healed", client);
		PrintCenterText(client, "%t", "Healing", target);

		float curTime = GetTickedTime();
		float elapsed = curTime - this.startTime;
		float elapsedPct = elapsed / this.duration * 100;

		int maxSounds = sfx[this.medID].Length;

		while (this.sndCursor < maxSounds)
		{
			SoundMap smap;
			sfx[this.medID].GetArray(this.sndCursor, smap);
			if (smap.pct > elapsedPct)
				break;

			EmitMedicalSound(client, smap.sound);
			this.sndCursor++;
		}

		if (elapsed >= this.duration)
			this.Succeed(client, target);
	}

	void Succeed(int client, int target)
	{
		int givenHP = ApplyMedicalEffects(target, this.medID);

		StopHealAction(target);
		TryVoiceCommand(target, VoiceCommand_ThankYou); // A little courtesy goes a long way!
		
		Call_StartForward(healedFwd);
		Call_PushCell(target);
		Call_PushCell(client);
		Call_PushCell(EntRefToEntIndex(this.itemRef));
		Call_PushCell(this.medID);
		Call_PushCell(givenHP);
		Call_Finish();

		SDKHooks_DropWeapon(client, this.itemRef);
		RemoveEntity(this.itemRef);
		
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

/* A menu created by a teamhealing module */
enum struct AddonSettings
{
	int id;
	char title[255];
	PrivateForward fwd;	// Callback living in another plugin
	SettingAction actions;	// Additional actions to pass to the handler
	Handle plugin;	// Handle to the plugin that added this menu
}

ArrayList modEntries;
HealingUse healing[MAXPLAYERS_NMRIH+1];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	modEntries = new ArrayList(sizeof(AddonSettings));
	RegPluginLibrary("nmr_teamhealing");
	MarkNativeAsOptional("TR_EnumerateEntitiesSphere");
	CreateNative("TeamHealing_AddSetting", Native_AddSettingsMenu);
	CreateNative("TeamHealing_ShowSettings", Native_ShowSettings);
	return APLRes_Success;
}

public void OnPluginStart()
{
	healedFwd = new GlobalForward("OnClientTeamHealed", 
		ET_Ignore, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);
	beginHealFwd = new GlobalForward("OnClientBeginTeamHeal", 
		ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_CellByRef);

	sphereQueryAvailable = GetFeatureStatus(FeatureType_Native, 
		"TR_EnumerateEntitiesSphere") == FeatureStatus_Available;

	LoadTranslations("core.phrases"); // used for cookie messages
	LoadTranslations("team-healing.phrases");

	pluginEnabled = CreateConVar("sm_team_heal_enabled", "1");

	cureTime[Medical_FirstAidKit] = CreateConVar("sm_team_heal_first_aid_time", "8.1", 
					"Seconds it takes for the first aid kit to heal a teammate");

	cureTime[Medical_Bandages] = CreateConVar("sm_team_heal_bandage_time", "2.8",
					"Seconds it takes for bandages to heal a teammate");

	cvUseDistance = FindConVar("sv_use_max_reach");

	CreateConVar("teamhealing_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION,
    	FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	healAmount[Medical_FirstAidKit] = FindConVar("sv_first_aid_heal_amt");
	healAmount[Medical_Bandages] = FindConVar("sv_bandage_heal_amt");

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			OnClientConnected(i);

	LoadMedicalSounds();

	AutoExecConfig();

	healCookie = new Cookie("disable_team_heal", "Prevents teammates from healing you", CookieAccess_Public);
	radiusCookie = new Cookie("disable_team_heal_radius_check", "Disables heal prevention when zombies are close", CookieAccess_Public);

	SetCookieMenuItem(EntryCookieMenu, 0, "Team Healing");

	RegAdminCmd("teamhealing_reload_sounds", Cmd_ReloadMedicalSounds, ADMFLAG_GENERIC);
}

Action Cmd_ReloadMedicalSounds(int client, int args)
{
	LoadMedicalSounds();
	ReplyToCommand(client, "Reloaded medical sounds from config");

	// If playing a map, precache the new sounds
	char a[2];
	if (GetCurrentMap(a, sizeof(a)))
		PrecacheMedicalSounds();
	 
	return Plugin_Handled;
}

void LoadMedicalSounds()
{
	delete sfx[Medical_FirstAidKit];
	delete sfx[Medical_Bandages];

	sfx[Medical_FirstAidKit] = new ArrayList(sizeof(SoundMap));
	sfx[Medical_Bandages] = new ArrayList(sizeof(SoundMap));

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/teamhealing.cfg");

	KeyValues kv = new KeyValues("Team Healing");
	if (!kv.ImportFromFile(path))
	{
		LogError("Failed to locate config file: %s. Medical sounds will be unavailable", path);
		delete kv;
		return;
	}

	if (!kv.JumpToKey("Heal Sounds"))
	{
		delete kv;
		return;
	}
	
	SaveHealSounds(kv, "item_first_aid", sfx[Medical_FirstAidKit]);
	SaveHealSounds(kv, "item_bandages", sfx[Medical_Bandages]);

	// kv.GoBack();
	delete kv;
}

void SaveHealSounds(KeyValues kv, const char[] key, ArrayList arr)
{
	if (kv.JumpToKey(key))
	{
		if (kv.GotoFirstSubKey(false))
		{
			do
			{
				SoundMap smap;

				char pctStr[11]; 
				kv.GetSectionName(pctStr, sizeof(pctStr));

				if (StringToIntEx(pctStr, smap.pct) != strlen(pctStr))
				{
					LogError("Got bogus sound key \"%s\" in \"%s\"", pctStr, key);
					continue;
				}

				kv.GetString(NULL_STRING, smap.sound, sizeof(smap.sound));
				if (!smap.sound[0])
				{
					LogError("Got empty sound entry for \"%s\" in \"%s\"", pctStr, key);
					continue;	
				}

				arr.PushArray(smap);

			} while (kv.GotoNextKey(false));
		}

		kv.GoBack();
	}

	kv.GoBack();
}

void EntryCookieMenu(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
	if (action == CookieMenuAction_DisplayOption)
	{
		Format(buffer, maxlen, "%T", "Cookie Menu Title", client);
	}

	else if (action == CookieMenuAction_SelectOption)
	{
		ShowTeamHealingMenu(client);
	}
}

public void OnClientCookiesCached(int client)
{
	healDisabled[client] = GetCookieBool(client, healCookie);
	ignoreRadiusCheck[client] = GetCookieBool(client, radiusCookie);
}

public int Native_ShowSettings(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (0 >= client > MaxClients)
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	
	if (!IsClientInGame(client))
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game", client);

	ShowTeamHealingMenu(client);

	return 0;
}

public int Native_AddSettingsMenu(Handle plugin, int numParams)
{
	static int id = 0;

	AddonSettings entry;
	entry.id = id++;
	
	Function handler = GetNativeFunction(2);

	if (handler == INVALID_FUNCTION) {
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid handler");
	}

	entry.fwd = new PrivateForward(ET_Event, Param_Cell, Param_Cell, Param_String, Param_Cell);
	entry.fwd.AddFunction(plugin, handler);

	GetNativeString(1, entry.title, sizeof(entry.title));
	entry.plugin = plugin;

	entry.actions = GetNativeCell(3);

	modEntries.PushArray(entry);

	return 0;
}

void ShowTeamHealingMenu(int client)
{
	Menu menu = new Menu(MainMenuHandler, MenuAction_DisplayItem);

	char buffer[2048];
	FormatEx(buffer, sizeof(buffer), "%T", "Cookie Menu Title", client);
	menu.SetTitle(buffer);

	// Team healing cookie
	FormatEx(buffer, sizeof(buffer), "%T: %T", "Cookie Team Healing Name", client, 
		healDisabled[client] ? "Cookie Disabled" : "Cookie Enabled", client);
	menu.AddItem("toggle", buffer);

	// Zombie check cookie
	if (sphereQueryAvailable)
	{
		FormatEx(buffer, sizeof(buffer), "%T: %T", "Cookie Radius Check Name", client, 
			ignoreRadiusCheck[client] ? "Cookie Disabled" : "Cookie Enabled", client);
		menu.AddItem("zcheck", buffer);	
	}

	// Add any module settings
	int maxModEntries = modEntries.Length; 
	for (int i = maxModEntries -1; i >= 0; i--)
	{
		AddonSettings entry;
		modEntries.GetArray(i, entry);

		char key[32];
		Format(key, sizeof(key), "mod_%d", entry.id);
		menu.AddItem(key, entry.title);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

public void OnNotifyPluginUnloaded(Handle plugin)
{
	int idx = modEntries.FindValue(plugin, AddonSettings::plugin);
	if (idx != -1) 
	{
		AddonSettings entry;
		modEntries.GetArray(idx, entry);
		delete entry.fwd;
		modEntries.Erase(idx);
	}
}

int MainMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
		return 0;
	}

	if (action == MenuAction_Select)
	{
		char info[32], display[255];
		menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display));

		if (!strcmp(info, "toggle"))
		{
			healDisabled[param1] = !healDisabled[param1];
			SetCookieBool(param1, healCookie, healDisabled[param1]);
			ShowTeamHealingMenu(param1);	
		}

		else if (!strcmp(info, "zcheck"))
		{
			ignoreRadiusCheck[param1] = !ignoreRadiusCheck[param1];
			SetCookieBool(param1, radiusCookie, ignoreRadiusCheck[param1]);
			ShowTeamHealingMenu(param1);	
		}

		// Check if we selected a mod entry
		else if (!strncmp(info, "mod_", 4))
		{
			int id = StringToInt(info[4]);
			int idx = modEntries.FindValue(id, AddonSettings::id);
			if (idx == -1) 
			{
				ShowTeamHealingMenu(param1);
				return 0;
			}

			AddonSettings entry;
			modEntries.GetArray(idx, entry);

			Call_StartForward(entry.fwd);
			Call_PushCell(param1);
			Call_PushCell(SettingAction_Select);
			Call_PushStringEx(display, sizeof(display), SM_PARAM_STRING_UTF8|SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
			Call_PushCell(sizeof(display));
			Call_Finish();
		}
	}

	else if (action == MenuAction_DisplayItem)
	{
		char info[32], display[255];
		menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display));

		// Check if we selected a mod entry
		if (!strncmp(info, "mod_", 4))
		{
			int id = StringToInt(info[4]);
			int idx = modEntries.FindValue(id, AddonSettings::id);
			if (idx == -1) {
				return 0;
			}

			AddonSettings entry;
			modEntries.GetArray(idx, entry);

			if ((entry.actions & SettingAction_Display)) 
			{
				Call_StartForward(entry.fwd);
				Call_PushCell(param1);
				Call_PushCell(SettingAction_Display);
				Call_PushStringEx(display, sizeof(display), SM_PARAM_STRING_UTF8|SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
				Call_PushCell(sizeof(display));
				Call_Finish();

				return RedrawMenuItem(display);
			}
		}
	}

	return 0;
}

public void OnMapStart()
{
	PrecacheMedicalSounds();
}

void PrecacheMedicalSounds()
{
	for (int i; i < sizeof(sfx); i++)
	{
		for (int j; j < sfx[i].Length; j++)
		{
			SoundMap smap;
			sfx[i].GetArray(j, smap, sizeof(smap));

			if (smap.sound[0])
				PrecacheScriptSound(smap.sound);
		}
	}
}

void EmitMedicalSound(int client, const char[] game_sound)
{
	static char sound_name[PLATFORM_MAX_PATH];

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
	healDisabled[client] = false;
	ignoreRadiusCheck[client] = false;

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
	if (buttons & IN_USE && pluginEnabled.BoolValue &&
	 	!(GetEntProp(client, Prop_Data, "m_nOldButtons") & IN_USE))
	{
		CheckCanBeginHeal(client);
	}

	return Plugin_Continue;
}

Action _ThinkHelper(Handle timer, int index)
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
	if (healDisabled[target])
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

	if (!ignoreRadiusCheck[target] && AreZombiesNearby(target))
	{
		PrintCenterText(client, "%t", "Can't Heal Zombies Nearby", target);
		return;
	}

	// Okay we can heal
	healing[client].Start(client, target, activeWeapon, medID);	
}

int GetClientUseTarget(int client, float range)
{
	float hullAng[3], hullStart[3], hullEnd[3];
	GetClientEyeAngles(client, hullAng);

	GetClientEyePosition(client, hullStart);
	ForwardVector(hullStart, hullAng, range, hullEnd);

	TR_TraceRayFilter(hullStart, hullEnd, CONTENTS_SOLID, RayType_EndPoint, TR_OtherPlayers, client);

	bool didHit = TR_DidHit();
	if (!didHit)
	{
		TR_TraceHullFilter(hullStart, hullEnd, 
			view_as<float>({-20.0,-20.0,-20.0}), 
			view_as<float>({20.0, 20.0, 20.00}), 
			CONTENTS_SOLID, TR_OtherPlayers, client);
		
		didHit = TR_DidHit();
	}

	if (didHit)
	{
		int entity = TR_GetEntityIndex();
		if (entity > 0)
		{
			return entity;
		}
	}
	return -1;
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

bool IsPlayerHurt(int client)
{
	return GetClientHealth(client) < GetEntProp(client, Prop_Data, "m_iMaxHealth");
}

bool IsPlayerBleeding(int client)
{
	return view_as<bool>(GetEntProp(client, Prop_Send, "_bleedingOut"));
}

void ShowProgressBar(int client, float duration, float prefill = 0.0)
{
	BfWrite bf = UserMessageToBfWrite(StartMessageOne("ProgressBarShow", client));
	bf.WriteFloat(duration);
	bf.WriteFloat(prefill);
	EndMessage();
}

void HideProgressBar(int client)
{
	StartMessageOne("ProgressBarHide", client);
	EndMessage();
}

void FreezePlayer(int client)
{
	int curFlags = GetEntProp(client, Prop_Send, "m_fFlags");
	SetEntProp(client, Prop_Send, "m_fFlags", curFlags | NMR_FL_ATCONTROLS);	
}

void UnfreezePlayer(int client)
{
	int curFlags = GetEntProp(client, Prop_Send, "m_fFlags");
	SetEntProp(client, Prop_Send, "m_fFlags", curFlags & ~NMR_FL_ATCONTROLS);
}

void TryVoiceCommand(int client, VoiceCommand voice)
{
	if (!IsVoiceCommandTimerExpired(client))
		return;

	float origin[3];
	GetClientAbsOrigin(client, origin);

	TE_Start("TEVoiceCommand");
	TE_WriteNum("_playerIndex", client);
	TE_WriteNum("_voiceCommand", view_as<int>(voice));
	TE_SendToAllInRange(origin, RangeType_Audibility);
}

bool IsVoiceCommandTimerExpired(int client)
{
	return RunEntVScriptBool(client, "IsVoiceCommandTimerExpired()");
}

int ApplyMedicalEffects(int client, MedicalID medID)
{
	SetEntProp(client, Prop_Send, "_bleedingOut", 0);

	int curHealth = GetClientHealth(client);
	int newHealth = curHealth + healAmount[medID].IntValue;
	int maxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	if (newHealth > maxHealth)
		newHealth = maxHealth;

	SetEntityHealth(client, newHealth);
	return newHealth - curHealth;
}

float GetMedicalDuration(MedicalID medID)
{
	if (medID == Medical_Invalid)
		ThrowError("Invalid medical ID (%d)", medID);
	
	return cureTime[medID].FloatValue;
}

bool CanClientConsumeMedical(int client, MedicalID medID)
{
	return (medID == Medical_FirstAidKit && CanUseFirstAid(client)) ||
		(medID == Medical_Bandages && CanUseBandages(client));
}

bool IsMedicalReady(int medical)
{
	if (GetEntProp(medical, Prop_Send, "_applied"))
		return false;

	int sequence = GetEntProp(medical, Prop_Send, "m_nSequence");
	return sequence == SEQ_RUN || sequence == SEQ_IDLE || sequence == SEQ_WALKIDLE;
}

bool CanUseFirstAid(int client)
{
	return IsPlayerBleeding(client) || IsPlayerHurt(client);
}

bool CanUseBandages(int client)
{
	return IsPlayerBleeding(client);
}

// Prevent players from wasting their own medical item after being healed by a teammate
void StopHealAction(int client)
{
	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (activeWeapon == -1)
		return;

	MedicalID medID = GetMedicalID(activeWeapon);
	if (medID != Medical_Bandages && medID != Medical_FirstAidKit)
		return;

	if (!CanClientConsumeMedical(client, medID))
		ForceIdleWeapon(activeWeapon);
}

void ForceIdleWeapon(int weapon)
{
	float curTime =  GetGameTime();
	SetEntPropFloat(weapon, Prop_Send, "m_flTimeWeaponIdle", curTime);
	SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", curTime);
	SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", curTime);	
}

MedicalID GetMedicalIDByClassname(const char[] classname)
{
	if (StrEqual(classname, "item_fi"))
		return Medical_FirstAidKit;
	else if (StrEqual(classname, "item_ba"))
		return Medical_Bandages;

	return Medical_Invalid;	
}

MedicalID GetMedicalID(int weapon)
{
	char classname[8];
	GetEntityClassname(weapon, classname, sizeof(classname));
	return GetMedicalIDByClassname(classname);
}

bool GetCookieBool(int client, Cookie cookie)
{
	char value[11];
	cookie.Get(client, value, sizeof(value));

	if (!value[0])
		return false;
	
	// if it's not empty, it's true unless explicitly "0"
	return !StrEqual(value, "0");
}

void SetCookieBool(int client, Cookie cookie, bool state)
{
	if (AreClientCookiesCached(client))
	{
		char value[11];
		FormatEx(value, sizeof(value), "%d", state);
		cookie.Set(client, value);		
	}
}

bool AreZombiesNearby(int client)
{
	if (!sphereQueryAvailable)
		return false;

	GetClientAbsOrigin(client, _traceStartPos);

	_traceResult = false;
	TR_EnumerateEntitiesSphere(_traceStartPos, ZOMBIE_SAFE_RADIUS, PARTITION_NON_STATIC_EDICTS, ZombiesNearby_Enumerator, client);
	return _traceResult;
}

bool TR_IgnoreLiving(int entity, int contentsMask)
{
	return !IsEntityZombie(entity) && !IsEntityPlayer(entity);
}

bool IsEntityPlayer(int entity)
{
	return 0 < entity <= MaxClients;
}

bool ZombiesNearby_Enumerator(int entity, int client)
{
	if (entity != client && IsValidEntity(entity) && IsEntityZombie(entity))
	{
		// FIXME: Buggy!
		// TR_ClipCurrentRayToEntity(MASK_ALL, entity);
		// if (!TR_DidHit()){
		// 	return true;
		// }

		float zombiePos[3];
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", zombiePos);

		// Now check whether zombie is in direct sight of player (not behind wall, etc)
		TR_TraceRayFilter(_traceStartPos, zombiePos, MASK_SOLID_BRUSHONLY, RayType_EndPoint, TR_IgnoreLiving);
		if (!TR_DidHit())
		{
			_traceResult = true;
			return false;
		}
	}
	return true;
}

bool IsEntityZombie(int entity)
{
	char classname[11];
	GetEntityClassname(entity, classname, sizeof(classname));
	return (StrEqual(classname, "npc_nmrih_"));
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