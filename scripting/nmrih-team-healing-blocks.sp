#include <nmr_teamhealing>
#pragma semicolon 1
#pragma newdecls required

#define MAXPLAYERS_NMRIH 9

#define PLUGIN_DESCRIPTION "Player block addon for team healing plugin"
#define PLUGIN_PREFIX "[Team Healing Blocks] "
#define PLUGIN_VERSION "1.0.0"

bool blocked[MAXPLAYERS_NMRIH+1][MAXPLAYERS_NMRIH+1];
bool pendingSave[MAXPLAYERS_NMRIH+1][MAXPLAYERS_NMRIH+1];
Handle syncTimer[MAXPLAYERS_NMRIH+1];

public Plugin myinfo = {
    name        = "Team Healing - Player Blocks",
    author      = "Dysphie",
    description = PLUGIN_DESCRIPTION,
    version     = PLUGIN_VERSION,
    url         = "https://github.com/dysphie/nmrih-team-healing"
};

float nextQueryTime;
ConVar cvDbName;

Database blocksDB;

public void OnPluginStart()
{
	LoadTranslations("team-healing-blocks.phrases");
	cvDbName = CreateConVar("sm_team_heal_block_database", "default", "Database to store blocks");

	CreateConVar("teamhealing_blocks_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION,
		FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	AutoExecConfig(true, "plugin.team-healing-blocks");
}

public void OnConfigsExecuted()
{
	InitializeDatabase();
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("TeamHealing_SetClientBlock", Native_SetClientBlock);
	CreateNative("TeamHealing_IsClientBlocked", Native_IsClientBlocked);
	return APLRes_Success;
}

public any Native_IsClientBlocked(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!ValidateNativeClient(client)) {
		return 0;
	}

	int target = GetNativeCell(2);
	if (!ValidateNativeClient(target)) {
		return 0;
	}

	return blocked[client][target];
}

public any Native_SetClientBlock(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!ValidateNativeClient(client)) {
		return 0;
	}

	int target = GetNativeCell(2);
	if (!ValidateNativeClient(target)) {
		return 0;
	}

	bool state = GetNativeCell(3);

	if (blocked[client][target] != state)
	{
		blocked[client][target] = state;
		pendingSave[client][target] = !pendingSave[client][target];
		TryStoreBlockInDB(client, target);
	}

	return 0;
}

bool ValidateNativeClient(int client)
{
	if (0 >= client > MaxClients)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
		return false;
	}

	if (!IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game", client);
		return false;
	}

	return true;
}

void ShowBlockedMenu(int client)
{
	Menu menu = new Menu(OnBlockMenu);

	char title[255];
	Format(title, sizeof(title), "%T", "Manage Blocks", client);
	menu.SetTitle(title);

	char key[11];
	char name[MAX_NAME_LENGTH];

	for (int target = 1; target <= MaxClients; target++)
	{
		if (target != client && IsClientInGame(target) && !IsFakeClient(target))
		{
			IntToString(GetClientSerial(target), key, sizeof(key));
			
			Format(name, sizeof(name), "%N", target);

			if (blocked[client][target])
			{
				Format(name, sizeof(name), "%s %T", name, "Blocked", client);
			}

			menu.AddItem(key, name);
		}
	}

	if (menu.ItemCount <= 0)
	{
		menu.AddItem("", "No players available", ITEMDRAW_DISABLED); // FIXME: Translate
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int OnBlockMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char selection[11];
		menu.GetItem(param2, selection, sizeof(selection));
		int target = GetClientFromSerial(StringToInt(selection));
		if (target) 
		{
			ToggleBlocked(param1, target);	
		}

		ShowBlockedMenu(param1);
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		TeamHealing_ShowSettings(param1);
	}

	return 0;
}

public void OnLibraryAdded(const char[] name)
{
	if (!strcmp(name, "nmr_teamhealing"))
	{
		TeamHealing_AddSetting("Manage Blocks", BlocksHandler, SettingAction_Display);
	}
}

void BlocksHandler(int client, SettingAction action, char[] buffer, int maxlen)
{
	if (action == SettingAction_Display)
	{
		Format(buffer, maxlen, "%T", "Manage Blocks", client);
	}
	else if (action == SettingAction_Select)
	{
		ShowBlockedMenu(client);
	}
}

void InitializeDatabase()
{
	char dbName[256];
	cvDbName.GetString(dbName, sizeof(dbName));
	PrintToServer(PLUGIN_PREFIX ... "Connecting to database \"%s\"", dbName);
	Database.Connect(DatabaseConnectResult, dbName);
}

public void DatabaseConnectResult(Database db, const char[] error, any data)
{
	static int numRetries = 1;

	if (db)
	{
		PrintToServer(PLUGIN_PREFIX ... "Successfully connected to database");

		char query[1024];
		db.Format(query, sizeof(query), 
			"CREATE TABLE IF NOT EXISTS `teamhealing_blocks` (" ...
			"`client_id` int(11) NOT NULL, " ...
			"`target_id` int(11) NOT NULL, " ...
			"UNIQUE KEY `block` (`client_id`,`target_id`))");

		db.Query(OnDatabaseSetupSuccess, query, db);
		return;
	}

	else if (numRetries <= 3)
	{
		PrintToServer(PLUGIN_PREFIX ... "Connection failed (%d), retrying in 5 seconds ...", numRetries);
		numRetries++;
		CreateTimer(5.0, Timer_RetryDatabaseConnection);
	}

	else
	{
		LogError("Connection to database failed after %d retries. " ...
			"Player blocks won't persist past map changes", numRetries);
	}
}

Action Timer_RetryDatabaseConnection(Handle timer)
{
	InitializeDatabase();
	return Plugin_Continue;
}

void ToggleBlocked(int client, int target)
{
	blocked[client][target] = !blocked[client][target];
	pendingSave[client][target] = !pendingSave[client][target];
	TryStoreBlockInDB(client, target);
}

void TryStoreBlockInDB(int client, int target)
{
	if (!pendingSave[client][target]) {
		return;
	}

	float curTime = GetEngineTime();
	float cooldown = nextQueryTime - curTime;

	if (cooldown > 0)
	{
		if (!syncTimer[client])
		{
			syncTimer[client] = CreateTimer(cooldown, 
				Timer_StorePendingBlocksInDB, GetClientSerial(client));
		}
	}
	else 
	{
		StoreBlockInDB(client, target);
	}
}

void StoreBlockInDB(int client, int target)
{
	int clientId = GetSteamAccountID(client);
	if (!clientId)
		return;

	int targetId = GetSteamAccountID(target);
	if (!targetId)
		return;

	char query[256];
	BuildDbQuery(clientId, targetId, blocked[client][target], query, sizeof(query));
	
	blocksDB.Query(OnBlockStoredInDB, query);
	pendingSave[client][target] = false;
	nextQueryTime = GetEngineTime() + 5.0;
}

void OnBlockStoredInDB(Database db, DBResultSet results, const char[] error, any data)
{
	
}

public void OnClientDisconnect(int client)
{
	int clientId = GetSteamAccountID(client);
	if (!clientId) {
		return;
	}

	Transaction txn;

	for (int other = 1; other <= MaxClients; other++)
	{
		if (!IsClientInGame(other))
			continue;

		int otherId = GetSteamAccountID(other);
		if (!otherId) {
			continue;
		}

		if (pendingSave[client][other])
		{
			if (!txn) {
				txn = new Transaction();
			}

			char query[512];
			BuildDbQuery(clientId, otherId, blocked[client][other], query, sizeof(query));
			txn.AddQuery(query);
			pendingSave[client][other] = false;
		}

		if (pendingSave[other][client])
		{
			if (!txn) {
				txn = new Transaction();
			}

			char query[512];
			BuildDbQuery(otherId, clientId, blocked[other][client], query, sizeof(query));
			txn.AddQuery(query);	
			pendingSave[other][client] = false;
		}
	}

	if (txn) 
	{
		blocksDB.Execute(txn, OnTransactionSuccess, OnTransactionError);
		nextQueryTime = GetEngineTime() + 5.0;
		delete txn;
	}
}

public void OnClientConnected(int client)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		for (int j = 1; j <= MaxClients; j++)
		{
			blocked[i][j] = false;
			pendingSave[i][j] = false;
		}
	}
}

void OnDatabaseSetupSuccess(Database db, DBResultSet results, const char[] error, Database permahandle)
{
	if (!db || !results || error[0]) 
	{
		LogError("Failed to fetch blocked/blockedby: %s.", error);
		return;
	} 

	blocksDB = permahandle;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsClientAuthorized(i))
		{
			FetchBlocksForClient(i);
		}
	}
}

void OnTransactionSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
}

void OnTransactionError(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("Error saving player blocks: %s", error);
}


void BuildDbQuery(int clientId, int targetId, bool isBlocked, char[] query, int maxlen)
{
	if (!isBlocked) 
	{
		blocksDB.Format(query, maxlen,
			"DELETE FROM `teamhealing_blocks` WHERE `client_id` = %d AND `target_id` = %d",
			clientId, targetId);
	}
	else
	{
		blocksDB.Format(query, maxlen,
			"INSERT IGNORE INTO `teamhealing_blocks`(`client_id`, `target_id`) VALUES (%d, %d)", 
			clientId, targetId);
	}
}

Action Timer_StorePendingBlocksInDB(Handle timer, int serial)
{
	int client = GetClientFromSerial(serial);
	if (!client) {
		return Plugin_Continue;
	}

	Transaction txn;
	syncTimer[client] = null;

	char clientId = GetSteamAccountID(client);
	if (!clientId) {
		return Plugin_Continue;
	}

	for (int target = 1; target <= MaxClients; target++)
	{
		if (target == client || 
			!pendingSave[client][target] || 
			!IsClientInGame(target))
		{
			continue;
		}

		char targetId = GetSteamAccountID(target); 
		if (!targetId) {
			continue;
		}

		if (!txn) {
			txn = new Transaction();
		}
		
		char query[512];
		BuildDbQuery(clientId, targetId, blocked[client][target], query, sizeof(query));
		txn.AddQuery(query);
		pendingSave[client][target] = false;
	}

	if (txn) 
	{
		blocksDB.Execute(txn, OnTransactionSuccess, OnTransactionError);
		nextQueryTime = GetEngineTime() + 5.0;
		delete txn;
	}

	return Plugin_Continue;
}

public void OnClientAuthorized(int client)
{
	FetchBlocksForClient(client);
}

void FetchBlocksForClient(int client)
{
	if (!blocksDB) {
		return;
	}

	char clientId = GetSteamAccountID(client);
	if (!clientId) {
		return;
	}

	int numOtherIds;
	char otherIds[255];

	for (int other = 1; other <= MaxClients; other++)
	{
		if (other == client || !IsClientInGame(other)) {
			continue;
		}

		int otherId = GetSteamAccountID(other);
		if (!otherId) {
			continue;
		}

		if (numOtherIds == 0) {
			FormatEx(otherIds, sizeof(otherIds), "%d", otherId);
		} else {
			Format(otherIds, sizeof(otherIds), "%s, %d", otherIds, otherId);
		}

		numOtherIds++;
	}

	// No other clients online!
	if (!numOtherIds) {
		return;
	}

	char query[1024];
	blocksDB.Format(query, sizeof(query), 
		"SELECT `client_id`, `target_id` FROM `teamhealing_blocks` " ...
		"WHERE (`client_id` = %d AND `target_id` IN (%s)) " ...
			"OR (`target_id` = %d AND `client_id` IN (%s))", 
		clientId, otherIds, clientId, otherIds);

	blocksDB.Query(OnPostAuthQuery, query, GetClientSerial(client));
}

void OnPostAuthQuery(Database db, DBResultSet results, const char[] error, int serial)
{
	if (!db || !results || error[0]) 
	{
		LogError("Failed to fetch blocked/blockedby: %s.", error);
		return;
	} 

	if (!GetClientFromSerial(serial)) {
		return;
	}

	if (results.RowCount <= 0) 
	{
		return;
	}

	while (results.FetchRow())
	{
		int blockerId = results.FetchInt(0);
		int targetId = results.FetchInt(1);


		int blocker = FindClientByAccountID(blockerId);
		if (blocker == -1) {
			continue;
		}

		int target = FindClientByAccountID(targetId);
		if (target == -1) {
			continue;
		}

		blocked[blocker][target] = true;
		pendingSave[blocker][target] = false;
	}
}

int FindClientByAccountID(int accountId)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientConnected(client)) {
			continue;
		}

		int clientId = GetSteamAccountID(client);
		if (clientId && clientId == accountId) {
			return client;
		}
	}
	return -1;
}

public Action OnClientBeginTeamHeal(int healer, int target, int item, MedicalID itemID, bool& cooldown)
{
	if (blocked[target][healer])
	{
		PrintCenterText(healer, "%t", "Target Blocked You", target);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}