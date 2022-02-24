/** Double-include prevention */
#if defined _teamhealing_included_
  #endinput
#endif
#define _teamhealing_included_


enum SettingAction
{
  SettingAction_Select = (1<<0),
  SettingAction_Display = (1<<1),
}

enum MedicalID
{
  Medical_Invalid = -1,
  Medical_FirstAidKit,
  Medical_Bandages,
  Medical_MAX
}

/**
 * Called when a client attempts to heal a teammate
 *
 * @param healer      Client index of healer.
 * @param recipient   Client index of player getting healed.
 * @param item        Entity index of the medical item.
 * @param itemID      Medical ID of the medical item.
 * @param cooldown    If returning Plugin_Handled, whether a cooldown should be applied.
 * @return            Plugin_Handled to block the action, Plugin_Continue otherwise.
 */
forward Action OnClientBeginTeamHeal(int healer, int recipient, int item, MedicalID itemID, bool& cooldown);


/**
 * Called when a client is healed by a teammate
 *
 * @param healed    Client index of player who got healed.
 * @param healer    Client index of healer.
 * @param item      Entity index of the medical item.
 * @param itemID    Medical ID of the medical item.
 * @param givenHP   Health given
 */
forward void OnClientTeamHealed(int healed, int healer, int item, MedicalID itemID, int givenHP);

/**
 * Called when a teamhealing menu action is received
 * 
 * @param client        Client interacting with the menu.
 * @param action        CookieMenuAction being performed.
 * @param buffer        On SettingAction_Select, optional override text to show on the menu
 * @param maxlen        Max length of the output buffer.
 * 
 */
typedef SettingHandler = function void (int client, SettingAction action, char[] buffer, int maxlen);


/**
 * Adds a new entry to the teamhealing settings menu.
 * Note: This only adds the top level menu item. You need to handle any submenus from the callback.
 * 
 * @param display   Text to show on the menu
 * @param handler   A SettingHandler callback function.
 * @param actions   Actions to receive in the callback. SettingAction_Select will always be received regardless.
 */
native void TeamHealing_AddSetting(const char[] display, SettingHandler handler, SettingAction actions = SettingAction_Select);


/**
 * Displays the teamhealing settings menu to a client.
 * 
 * @param client   Client index
 */
native void TeamHealing_ShowSettings(int client);

