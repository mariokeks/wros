#if defined _wros_included
	#endinput
#endif
#define _wros_included

enum struct WROS_RecordInfo 
{
	char _id[32];
	char map[PLATFORM_MAX_PATH];
	char name[32+1];
	float time;
	char steamid[24];
	int accountid;
	int date;
	float sync;
	int strafes;
	int jumps;
	char replay_ref[32];
	int style;
	bool is_invalid;
	bool is_banned;
	float wr_time;
	int rank;
	char server_hostname[128];
	char server_key_id[32];
}

enum struct wros_style_t
{
	int iStyle_Offstyle;
	int iStyle_Server;
	int iStyle_Replay;
	char sStyleName[64];
}

enum WROS_Menu
{
	WROS_Menu_Maps = (1<<0),
	WROS_Menu_Styles = (1<<1),
	WROS_Menu_Records = (1<<2),
	WROS_Menu_Replays = (1<<3)
}

enum WROS_Style
{
	WROS_Style_Offstyle,
	WROS_Style_Server,
	WROS_Style_Replay
}

typeset WROS_QueryFinishedFunc
{
	function void (const char map[PLATFORM_MAX_PATH], ArrayList records, any data);
};

/**
 * Queries a map in the Offstyle API.
 * 
 * @param map                     Map name.
 * @param cached_results_okay     True to allow cached results, false otherwise.
 * @param style                   Style ID in the Offstyle API.
 * @return                        Returns true if request has been sent or cached results have been found, false otherwise.
 */
native bool WROS_QueryMap(const char[] map, bool cached_results_okay = true, int style);

/**
 * Queries a map in the Offstyle API. BUT! You can set a callback.
 * 
 * @param map                     Map name.
 * @param cached_results_okay     True to allow cached results, false otherwise.
 * @param style                   Style ID in the Offstyle API.
 * @param callback                Callback.
 * @param data                    Extra data value to pass to the callback.
 * @return                        Return description
 */
native bool WROS_QueryMapWithFunc(const char[] map, bool cached_results_okay, int style, WROS_QueryFinishedFunc callback, any data);

/**
 * Returns if a player is allowed to use the replay feature. (Download / Play)
 * 
 * @param client                  Client index.
 * @param notify                  True to notify the client on failure, false to keep it silent.
 * @return                        True on access, false otherwise.
 */
native bool WROS_CanUseReplays(int client, bool notify = true);

/**
 * Returns the ArrayList of the wros styles. (wros.cfg)
 * Do not close or modify the ArrayList!
 * 
 * @return                        ArrayList of the styles. (wros_style_t)
 */
native ArrayList WROS_GetStyleArrayList();

/**
 * Returns the amount of styles in wros.
 * 
 * @return                        Amount of styles.
 */
native int WROS_GetStyleCount();

/**
 * Gets style data at a specified index.
 * 
 * @param index                   Index of style data to get.
 * @param cpcache                 Buffer to store style data in sizeof(wros_style_t)
 * @param size                    Size of the style data buffer, e.g sizeof(wros_style_t)
 * 
 * @noreturn
 */
native void WROS_GetStyleData(int index, any[] data, int size = sizeof(wros_style_t));

/**
 * Opens a wros menu for a player.
 * 
 * @param client                  Client index.
 * @param type                    Menu types.
 *                                This must contain either WROSMenu_Records or WROSMenu_Replays.
 *                                You may includes WROSMenu_Maps or WROSMenu_Styles if you want the player to choose.
 * @param map                     Full mapname or partially mapname when including WROSMenu_Maps.
 * @param style                   Style ID in the Offstyle DB. -1 for style selection or the default style.
 * @return                        Return description
 */
native void WROS_OpenMenu(int client, WROS_Menu type, const char[] map, int style = -1);

/**
 * Sets the ArrayList of maps to use for the GuessBestMapNameEx to list similiar maps.
 * This clones the ArrayList via CloneHandle.
 * 
 * @param maplist                 ArrayList of maps or use "null" to delete the ArrayList.
 * @noreturn
 */
native void WROS_SetMapList(ArrayList maplist);

/**
 * Called when WROS retrieved results for a map.
 *
 * @param map                       Map name...
 * @param success                   If results could not be retrieved, this is `null`. On success it will be an ArrayList of WROS_RecordInfo's.
 * @noreturn
 */
forward void WROS_OnQueryFinished(const char map[PLATFORM_MAX_PATH], ArrayList records, int style);

/**
 * Called when a player opens a wros menu.
 * 
 * @param client                    Client index.
 * @param type                      Menu types.
 *                                  This always has either WROSMenu_Records or WROSMenu_Replays. 
 *                                  Includes WROSMenu_Maps or WROSMenu_Styles when selecting a map or style.
 * @param menu                      Menu handle.
 * @return                          Return any other value than Plugin_Continue to block the menu from displaying.
 */
forward Action WROS_OnMenuMade(int client, WROS_Menu type, Menu menu);

/**
 * Called when a wros menu action is completed.
 * 
 * @param client                    Client index.
 * @param type                      Menu types.
 *                                  This always has either WROSMenu_Records or WROSMenu_Replays. 
 *                                  Includes WROSMenu_Maps or WROSMenu_Styles when selecting a map or style.
 * @param menu                      Menu handle.
 * @param action                    Menu action.
 * @param param2                    Action parameter (usually the item).
 * @return                          Return any other value than Plugin_Continue to block the menu callback.
 */
forward Action WROS_OnMenuCallback(int client, WROS_Menu type, Menu menu, MenuAction action, int param2);

/**
 * Converts a style from or to an Offstyle, Server or Replay style.
 * 
 * @param style                     Input style.
 * @param from                      Type to convert from.
 * @param to                        Type to convert to.
 * @return                          Style index/id on sucess, -1 on failure.
 */
stock int WROS_ConvertStyle(int style, WROS_Style from, WROS_Style to)
{
	ArrayList aStyles = WROS_GetStyleArrayList();
	int iIndex = aStyles.FindValue(style, from);
	if(iIndex != -1)
	{
		return aStyles.Get(iIndex, to);
	}
	return -1;
}

public SharedPlugin __pl_wros =
{
	name = "wros",
	file = "wros.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_wros_SetNTVOptional()
{
	MarkNativeAsOptional("WROS_QueryMap");
	MarkNativeAsOptional("WROS_QueryMapWithFunc");
	MarkNativeAsOptional("WROS_CanUseReplays");
	MarkNativeAsOptional("WROS_OpenMenu");
}
#endif
