/** Double-include prevention */
#if defined _teamhealing_included_
  #endinput
#endif
#define _teamhealing_included_

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
 * @param healer		Client index of healer.
 * @param recipient		Client index of player getting healed.
 * @param item			Entity index of the medical item.
 * @param itemID		Medical ID of the medical item.
 * @param cooldown		If returning Plugin_Handled, whether a cooldown should be applied.
 * @return				Plugin_Handled to block the action, Plugin_Continue otherwise.
 */
forward Action OnClientBeginTeamHeal(int healer, int recipient, int item, MedicalID itemID, bool& cooldown);


/**
 * Called when a client is healed by a teammate
 *
 * @param healed		Client index of player who got healed.
 * @param healer		Client index of healer.
 * @param item			Entity index of the medical item.
 * @param itemID		Medical ID of the medical item.
 */
forward void OnClientTeamHealed(int healed, int healer, int item, MedicalID itemID);

