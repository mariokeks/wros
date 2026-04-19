/*
 * This is based on https://github.com/rtldg/wrsj
 * So most credits go to the contributors of wrsj.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

// TODO?
// - Maybe dont request every style OnConfigsExecuted? We could request styles when a player changes to a mapped style with no gSM_MapsCachedTime set
// - Should we rename stuff? WROSDB / OSDB / Offstyle Database / Offstyle DB? Send help ( ╥ω╥ )
// - Pretty sure i forgot something.. ( ͡° ͜ʖ ͡°)

#include <sourcemod>
#include <convar_class>
#include <morecolors>
#include <clientprefs>

#include <wros>
#include <shavit/steamid-stocks>

#undef REQUIRE_PLUGIN
#include <shavit/core>
#include <shavit/wr>
#include <shavit/replay-playback>
#include <shavit/replay-file>
#include <shavit/mapchooser>
#define REQUIRE_PLUGIN

#include <ripext> // https://github.com/ErikMinekus/sm-ripext
#undef REQUIRE_EXTENSIONS
#include <SteamWorks>
#define REQUIRE_EXTENSIONS

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = 
{
	name = "Offstyle World Record",
	author = "rtldg & Nairda, ƤɾσƅƖeɱ?",
	description = "Grabs WRs from the Offstyle DB API",
	version = "0.8.1"
}

// #define CUSTOM_BUILD // Enables custom stuff that are not part of the public build of shavits bhoptimer

enum 
{
	Flag_CacheReplays,
	Flag_FakeReplayCommand,
	Flag_PurgeReplays,
	Flag_ReplaceReplay,
	Flag_UseSteamWorks,
}

enum 
{
	ReCache_None,
	ReCache_WR,
	ReCache_All
}

enum struct replay_cache_t 
{
	replay_header_t aHeader;
	frame_cache_t aFrameCache;
}

enum struct download_queue_t
{
	char sPath[PLATFORM_MAX_PATH];	// Outputfile path for the download
	char sMap[PLATFORM_MAX_PATH];	// Mapname when we started the request, used for verification so it doesnt start the replay on another map
	char sName[32+1]; 		// Used to cache the name of the record holder of the replay so we can set the replay name correctly......
	char sReplayRef[32]; 	// Reference of the Offstyle replay, used to re-download a replay on download failure
	int iStyle;			// Style index, -1 if not found
	int iRequester;		// Serial of the requester
	int iRetries;		// Retry counter...
	float fTime; 		// EngineTime when we started the download, 0.0 when it was already queued
}
ArrayList gA_DownloadQueue;

enum
{
	Setting_TopLeftHUD,
	Setting_EveryStyle,
	Setting_AfterTopLeft,
	Setting_ShowOnlyDefault,
	Setting_FallbackToDefault,
}
int gI_ClientSettings[MAXPLAYERS+1];
Cookie gH_Cookie;

// Convar gCV_APIKey;
Convar gCV_DLUrl;
Convar gCV_DLDirectory;
Convar gCV_DLRetryCount;
Convar gCV_APIUrl;
Convar gCV_WRCount;
Convar gCV_CacheTime;
Convar gCV_DefaultStyle;
Convar gCV_DefaultSettings;
Convar gCV_AlwaysShowSelection;
Convar gCV_ReCache;
Convar gCV_AuthType;
Convar gCV_Flags;

StringMap gSM_Maps;
StringMap gSM_MapsCachedTime;
StringMap gSM_MapsTotalRecords;
StringMap gSM_RecordInfo; // Lets duplicate our data so we can search easier :3
StringMap gSM_ReplayCount;
StringMap gSM_ReplayCache;
ArrayList gA_Styles;
ArrayList gA_MapList;

int gI_CurrentPagePosition[MAXPLAYERS + 1];
WROS_Menu gI_LastMenu[MAXPLAYERS + 1];
int gI_LastStyle[MAXPLAYERS + 1];
char gS_LastSearch[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
char gS_ClientMap[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
char gS_CurrentMap[PLATFORM_MAX_PATH];

GlobalForward gH_Forward_OnQueryFinished;
GlobalForward gH_Forward_OnMenuMade; 
GlobalForward gH_Forward_OnMenuCallback; 

bool gB_DirExists = false;
bool gB_MapChooser = false;
bool gB_ReplayPlayback = false;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	gH_Forward_OnQueryFinished = new GlobalForward("WROS_OnQueryFinished", ET_Ignore, Param_String, Param_Cell, Param_Cell);

	gH_Forward_OnMenuMade = new GlobalForward("WROS_OnMenuMade", ET_Event, Param_Cell, Param_Cell, Param_Cell);
	gH_Forward_OnMenuCallback = new GlobalForward("WROS_OnMenuCallback", ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);

	CreateNative("WROS_QueryMap", Native_QueryMap);
	CreateNative("WROS_QueryMapWithFunc", Native_QueryMapWithFunc);

	CreateNative("WROS_CanUseReplays", Native_CanUseReplays);
	CreateNative("WROS_OpenMenu", Native_OpenMenu);

	CreateNative("WROS_GetStyleCount", Native_GetStyleCount);
	CreateNative("WROS_GetStyleData", Native_GetStyleData);
	CreateNative("WROS_GetStyleArrayList", Native_GetStyleArrayList);

	RegPluginLibrary("wros");

	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("wros.phrases");

	// gCV_APIKey = new Convar("os_api_key", "", "Replace with your unique api key.", FCVAR_PROTECTED);
	gCV_DLDirectory = new Convar("os_dl_directory", "", "Directory for the temporary replay files.\nLeave empty to disable replay feature.\nRequires a map change or server restart to take effect.\nDoes not create directories automatically.");
	gCV_DLUrl = new Convar("os_dl_url", "https://offstyles.tommyy.dev/api/replay?id=", "Download URL. Can be changed for testing.", FCVAR_PROTECTED);
	gCV_DLRetryCount = new Convar("os_dl_retry_count", "1", "How many times to retry a failed replay download before giving up.", 0, true, 0.0, true, 5.0);
	gCV_APIUrl = new Convar("os_api_url", "https://offstyles.net/api/times?map={map}&style={style}&sort=Fastest&best=true&page=1&limit=50", "API endpoint for fetching records."
		..."\nPlaceholders: {map} = map name, {style} = style ID."
		..."\nlimit - Records per page/request (Default 50)"
		..."\npage - Page number, shouldn't be changed since we dont send multiple paged requests"
		..."\nbest - Whether to show only the best record of a player or all records from a player"
		..."\nsort - Sort type (Fastest/Slowest/Newest/Oldest)"
		..."\nFull docs: https://offstyles.net/api/docs/#/Record/get_times", FCVAR_PROTECTED);	
	gCV_WRCount = new Convar("os_api_wr_count", "50", "How many top times should be shown in the !wros menu.\nCannot exceed the limit set in os_api_url.", 0, true, 0.0);
	gCV_CacheTime = new Convar("os_api_cache_time", "666.0", "How many seconds to cache a map from the Offstyle API.", 0, true, 5.0);
	gCV_DefaultStyle = new Convar("os_default_style", "190", "(Offstyle) Style ID to use as the default for the Top Left HUD.", 0, true, 0.0);
	gCV_AlwaysShowSelection = new Convar("os_always_show_selection", "1", "Always show the map selection menu, even if only a single matching map is found.\nYou may disable this if you have a large map list on the server.", 0, true, 0.0, true, 1.0);
	gCV_Flags = new Convar("os_flags", "3", "Miscellaneous options as bitflag"
		..."\n1 = Cache replay data for the map session"
		..."\n2 = Execute 'sm_replay' for the player after replay start"
		..."\n4 = Purge \".replays\" files inside of os_dl_directory on map start (Does not affect subdirectories)"
		..."\n8 = Replace a running replay bot instead of notifying the player"
		..."\n16 = Use the SteamWorks extension for API requests (Recommended for windows)", 0, true, 0.0);
	gCV_ReCache = new Convar("os_recache", "2", "Re-cache a map & style"
		..."\n0 = Disabled"
		..."\n1 = Only when a WR is being broken"
		..."\n2 = For every improved record"
		..."\nBonus tracks are always ignored."
		..."\nStyles with no valid server style (style_server) set in the config are ignored.", 0, true, 0.0, true, 2.0);
	gCV_AuthType = new Convar("os_steamid_format", "1", "SteamID format to use when displaying the SteamID of a player"
		..."\n1 = Steam2 (STEAM_1:1:4153990)"
		..."\n2 = Steam3 ([U:1:8307981])"
		..."\n3 = SteamID64 (76561197968573709)", 0, true, 1.0, true, 3.0);
	gCV_DefaultSettings = new Convar("os_default_settings", "23", "Default settings as a bitflag"
		..."\n1 = Enable the OS time (Top Left HUD)"
		..."\n2 = Show the OS time in every style"
		..."\n4 = Show the OS time after the WR/PB lines"
		..."\n8 = Always show the default style time, regardless of the current style"
		..."\n16 = Fall back to the default style time (with style name shown) when no time is available for the current style", 0, true, 0.0);	
	Convar.AutoExecConfig("wros");

	RegConsoleCmd("sm_wrossettings", Command_Settings, "Opens the wros settings menu.");
	RegConsoleCmd("sm_wross", Command_Settings, "Opens the wros settings menu.");
	RegConsoleCmd("sm_wros", Command_WROS, "View global world records from Offstyle's API.");
	RegConsoleCmd("sm_oswr", Command_WROS, "View global world records from Offstyle's API.");
	RegConsoleCmd("sm_wrosr", Command_WROSReplay, "View global world records from Offstyle's API.");

	gSM_Maps = new StringMap();
	gSM_MapsCachedTime = new StringMap();
	gSM_MapsTotalRecords = new StringMap();
	gSM_RecordInfo = new StringMap();
	gSM_ReplayCount = new StringMap();
	gA_MapList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	LoadConfig();
	
	SetCookieMenuItem(MenuHandler_Cookie, 0, "wros");
	gH_Cookie = new Cookie("wros", "Offstyle World Record Settings", CookieAccess_Private);
}

public void OnPluginEnd()
{
	// Delete all incomplete replays so the plugin download them again 
	if(gA_DownloadQueue	!= null)
	{
		download_queue_t aQueue;
		for(int i = gA_DownloadQueue.Length - 1; i >= 0; i--)
		{
			gA_DownloadQueue.GetArray(i, aQueue);
			DeleteFile(aQueue.sPath);
		}
	}
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "shavit-replay-playback"))
	{
		gB_ReplayPlayback = true;
	}
	else if(StrEqual(name, "shavit-mapchooser"))
	{
		gB_MapChooser = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "shavit-replay-playback"))
	{
		gB_ReplayPlayback = false;
	}
	else if(StrEqual(name, "shavit-mapchooser"))
	{
		gB_MapChooser = false;
	}
}

public void OnMapStart()
{
	GetCurrentMap(gS_CurrentMap, sizeof(gS_CurrentMap));
	GetMapDisplayName(gS_CurrentMap, gS_CurrentMap, sizeof(gS_CurrentMap));

	// Purge expired arraylist
	float cached_time;
	ArrayList records;
	WROS_RecordInfo record;
	char sKey[PLATFORM_MAX_PATH];
	StringMapSnapshot snapshot = gSM_Maps.Snapshot();
	for(int i = snapshot.Length - 1; i >= 0; i--)
	{
		snapshot.GetKey(i, sKey, sizeof(sKey));
		
		gSM_Maps.GetValue(sKey, records);
		gSM_MapsCachedTime.GetValue(sKey, cached_time);

		if(cached_time <= (GetEngineTime() - gCV_CacheTime.FloatValue))
		{
			for(int x = records.Length - 1; x >= 0; x--)
			{
				records.GetArray(x, record);
				gSM_RecordInfo.Remove(record._id);
			}

			delete records;
			gSM_Maps.Remove(sKey);
			gSM_MapsCachedTime.Remove(sKey);
			gSM_MapsTotalRecords.Remove(sKey);
		}
	}
	delete snapshot;

	if(gSM_ReplayCache != null)
	{
		replay_cache_t aCache;
		snapshot = gSM_ReplayCache.Snapshot();
		for(int i = snapshot.Length - 1; i >= 0; i--)
		{
			snapshot.GetKey(i, sKey, sizeof(sKey));

			gSM_ReplayCache.GetArray(sKey, aCache, sizeof(aCache));
			delete aCache.aFrameCache.aFrames;
		}
		delete snapshot;
		delete gSM_ReplayCache;
	}
}

public void OnConfigsExecuted()
{
	// For now load everything
	int iSize = gA_Styles.Length;
	for(int i = 0; i < iSize; i++)
	{
		RetrieveWRs(0, gS_CurrentMap, gA_Styles.Get(i, WROS_Style_Offstyle));
	}

	static int iMapSerial = -1;
	ReadMapList(gA_MapList, iMapSerial, "default", MAPLIST_FLAG_CLEARARRAY);

	char sDirectory[PLATFORM_MAX_PATH];
	gCV_DLDirectory.GetString(sDirectory, sizeof(sDirectory));
	if(sDirectory[0] == '\0')
	{
		gB_DirExists = false; // Disables replay features
	}
	else if(!(gB_DirExists = DirExists(sDirectory)))
	{
		LogError("Directory '%s' does not exist. Please create the directory or change the convar os_dl_directory.", sDirectory);
	}
	else if(gB_DirExists && IsFlagEnabled(Flag_PurgeReplays))
	{
		
		DirectoryListing hDir = OpenDirectory(sDirectory);
		if(hDir != null)
		{
			FileType iFileType; int iLen;
			char sPath[PLATFORM_MAX_PATH];
			while(hDir.GetNext(sPath, sizeof(sPath), iFileType))
			{
				if(iFileType == FileType_File)
				{
					iLen = strlen(sPath);
					if(iLen > 7 && StrEqual(sPath[iLen-7], ".replay"))
					{
						Format(sPath, sizeof(sPath), "%s/%s", sDirectory, sPath);
						DeleteFile(sPath);
					}
				}
			}
		}
		delete hDir;
	}
}

Action Timer_Refresh(Handle timer, any style)
{
	RetrieveWRs(0, gS_CurrentMap, style);
	return Plugin_Stop;
}

public void Shavit_OnFinish_Post(int client, int style, float time, int jumps, int strafes, float sync, int rank, int overwrite, int track)
{
	if(track > Track_Main)
		return;

	if(gCV_ReCache.IntValue == ReCache_All || (gCV_ReCache.IntValue == ReCache_WR && time == Shavit_GetWorldRecord(style, track)))
	{
		// I think its better to recache the records when we got a new WR/PB
		// So that players dont ask why WROS is broken :tableflip:

		int iStyle = WROS_ConvertStyle(style, WROS_Style_Server, WROS_Style_Offstyle);
		if(iStyle != -1)
		{
			// Maybe restart the timer when its already running?
			CreateTimer(5.0, Timer_Refresh, iStyle, TIMER_FLAG_NO_MAPCHANGE);
		}
	}
}

public Action Shavit_OnTopLeftHUD(int client, int target, char[] topleft, int topleftlength)
{
	if(!IsSettingEnabled(client, Setting_TopLeftHUD))
		return Plugin_Continue;

	int isReplay = (gB_ReplayPlayback && Shavit_IsReplayEntity(target));
	int style = isReplay ? Shavit_GetReplayBotStyle(target) : Shavit_GetBhopStyle(target);
	int track = isReplay ? Shavit_GetReplayBotTrack(target) : Shavit_GetClientTrack(target);
	style = (style == -1) ? 0 : style; // central replay bot probably
	track = (track == -1) ? 0 : track; // central replay bot probably

	if((!IsSettingEnabled(client, Setting_EveryStyle) && WROS_ConvertStyle(style, WROS_Style_Server, WROS_Style_Offstyle) != gCV_DefaultStyle.IntValue) || track > Track_Main)
		return Plugin_Continue;

	ArrayList records;
	bool bFallback = false;

	if(IsSettingEnabled(client, Setting_ShowOnlyDefault))
	{
		// We only need the records of the default style, when empty return
		if(!GetCachedRecords(gS_CurrentMap, gCV_DefaultStyle.IntValue, records))
			return Plugin_Continue;
	}
	else
	{
		// Get the records for the current style when possible
		if(!GetCachedRecords(gS_CurrentMap, WROS_ConvertStyle(style, WROS_Style_Server, WROS_Style_Offstyle), records))
		{
			// When the current styles get the records from the default when possible and the player wants it, ignore it when we have only one style...
			if(gA_Styles.Length <= 1 || !(bFallback = IsSettingEnabled(client, Setting_FallbackToDefault)) || !GetCachedRecords(gS_CurrentMap, gCV_DefaultStyle.IntValue, records))
			{
				return Plugin_Continue;
			}
		}
	}

	WROS_RecordInfo info;
	records.GetArray(0, info);

	char ostext[80], sTime[32];
	FormatSeconds(info.time, sTime, sizeof(sTime));
	if(!bFallback)
	{
		FormatEx(ostext, sizeof(ostext), "%T", "OnTopLeftHUD", client, sTime, info.name);
	}
	else
	{
		WROS_StyleInfo aStyle;
		gA_Styles.GetArray(gA_Styles.FindValue(gCV_DefaultStyle.IntValue, WROS_Style_Offstyle), aStyle);
		FormatEx(ostext, sizeof(ostext), "%T", "OnTopLeftHUD_Fallback", client, sTime, info.name, aStyle.sStyleName);
	}

	if(IsSettingEnabled(client, Setting_AfterTopLeft))
		Format(topleft, topleftlength, "%s%s%s", topleft, (topleft[0] != '\0') ? "\n" : "", ostext);
	else
		Format(topleft, topleftlength, "%s%s%s", ostext, (topleft[0] != '\0') ? "\n" : "", topleft);

	return Plugin_Changed;
}

void ChooseStyleMenu(int client)
{
	int iSize = gA_Styles.Length;
	if(iSize > 1)
	{
		Menu menu = new Menu(MenuHandler_ChooseStyle);
		menu.SetTitle("%T\n ", "ChooseStyle_Title", client, gS_ClientMap[client]);

		WROS_StyleInfo aStyle;
		char sInfo[8], sCount[16], sDisplay[128];
		for(int i = 0; i < iSize; i++)
		{
			gA_Styles.GetArray(i, aStyle);

			IntToString(aStyle.iStyle_Offstyle, sInfo, sizeof(sInfo));
			GetRecordCount(gI_LastMenu[client], gS_ClientMap[client], aStyle.iStyle_Offstyle, sCount, sizeof(sCount));
			FormatEx(sDisplay, sizeof(sDisplay), "%T", "ChooseStyle_Item", client, aStyle.sStyleName, sCount);
			menu.AddItem(sInfo, sDisplay);
		}
		
		menu.ExitBackButton = (gS_LastSearch[client][0] != '\0');

		if(Forward_OnMenuMade(client, WROS_Menu_Styles|gI_LastMenu[client], menu))
		{
			menu.Display(client, MENU_TIME_FOREVER);
		}
	}
	else
	{
		gI_LastStyle[client] = gA_Styles.Get(0, WROS_Style_Offstyle);
		CheckWRCache(client, gS_ClientMap[client], gI_LastStyle[client], gI_LastMenu[client]);
	}
}

void GetRecordCount(WROS_Menu type, const char[] map, int style, char[] output, int maxlen)
{
	ArrayList aRecords;
	char sKey[PLATFORM_MAX_PATH];
	FormatKey(map, style, sKey, sizeof(sKey));
	if(!gSM_Maps.GetValue(sKey, aRecords))
	{
		strcopy(output, maxlen, "?");
	}
	else
	{
		if(type == WROS_Menu_Replays)
		{
			int iReplays;
			gSM_ReplayCount.GetValue(sKey, iReplays);
			FormatEx(output, maxlen, "%d/%d", iReplays, aRecords ? aRecords.Length : 0);
			// IntToString(iReplays, output, maxlen);
		}
		else
		{
			IntToString(aRecords ? aRecords.Length : 0, output, maxlen);
		}
	}
}

public void MenuHandler_ChooseStyle(Menu menu, MenuAction action, int client, int param2)
{
	if(action != MenuAction_End && !Forward_OnMenuCallback(client, WROS_Menu_Styles|gI_LastMenu[client], menu, action, param2))
	{
		return;
	}

	switch(action)
	{
		case MenuAction_End: delete menu;
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
			{
				if(gS_LastSearch[client][0] != '\0')
				{
					GuessBestMapNameEx(client, gS_LastSearch[client], gS_LastSearch[client], gS_ClientMap[client], MenuHandler_SelectMap);
				}
			}
		}
		case MenuAction_Select:
		{
			char sInfo[8];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			gI_LastStyle[client] = StringToInt(sInfo);

			CheckWRCache(client, gS_ClientMap[client], gI_LastStyle[client], gI_LastMenu[client]);
		}
	}
}

void BuildWRMenu(int client, int first_item=0)
{
	gI_CurrentPagePosition[client] = 0;

	ArrayList records;
	if(!GetCachedRecords(gS_ClientMap[client], gI_LastStyle[client], records))
	{
		if(gA_Styles.Length > 1)
		{
			ChooseStyleMenu(client); // Go instantly back to the style selection for our lazy ppl
			CPrintToChat(client, "%T", "Chat_BuildWRMenu_Nothing", client);
		}
		return;
	}

	int maxrecords = gCV_WRCount.IntValue;
	maxrecords = (maxrecords < records.Length) ? maxrecords : records.Length;
	int totalrecords = GetCachedTotalRecords(gS_ClientMap[client], gI_LastStyle[client]);

	WROS_StyleInfo aStyle;
	gA_Styles.GetArray(gA_Styles.FindValue(gI_LastStyle[client], WROS_Style_Offstyle), aStyle);

	Menu menu = new Menu(MenuHandler_BuildWRMenu);
	menu.SetTitle("%T\n ", "BuildWRMenu_Title", client, gS_ClientMap[client], maxrecords, aStyle.sStyleName, totalrecords);

	WROS_RecordInfo record;
	char sDisplay[128], sTime[32], sDiff[32];
	for (int i = 0; i < maxrecords; i++)
	{
		records.GetArray(i, record, sizeof(record));

		FormatSeconds(record.time, sTime, sizeof(sTime));
		FormatDiff(client, record.time, record.wr_time, sDiff, sizeof(sDiff));

		FormatEx(sDisplay, sizeof(sDisplay), "%T", "BuildWRMenu_Item", client, i+1, record.name, sTime, sDiff);
		menu.AddItem(record._id, sDisplay);
	}

	if(menu.ItemCount == 0)
	{
		FormatEx(sDisplay, sizeof(sDisplay), "%T", "BuildWRMenu_Nothing", client);
		menu.AddItem("-1", sDisplay);
	}

	menu.ExitBackButton = (gA_Styles.Length > 1) ? true : (gS_LastSearch[client][0] != '\0');
	
	if(Forward_OnMenuMade(client, WROS_Menu_Records, menu))
	{
		menu.DisplayAt(client, first_item, MENU_TIME_FOREVER);
	}
}

void MenuHandler_BuildWRMenu(Menu menu, MenuAction action, int client, int param2)
{
	if(action != MenuAction_End && !Forward_OnMenuCallback(client, WROS_Menu_Records, menu, action, param2))
	{
		return;
	}

	switch(action)
	{
		case MenuAction_End: delete menu;
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
			{
				if(gA_Styles.Length > 1)
				{
					ChooseStyleMenu(client);
				}
				else if(gS_LastSearch[client][0] != '\0')
				{
					GuessBestMapNameEx(client, gS_LastSearch[client], gS_LastSearch[client], gS_ClientMap[client], MenuHandler_SelectMap);
				}
			}
		}
		case MenuAction_Select:
		{
			char sInfo[64];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if(StrEqual(sInfo, "-1"))
			{
				return;
			}

			WROS_RecordInfo record;
			if(!GetRecordInfo(sInfo, record)) // Probably a recache and a record has been improved..?
			{
				CPrintToChat(client, "%T", "Chat_Record_NotFound", client);
				BuildWRMenu(client);
				return;
			}

			Menu submenu = new Menu(MenuHandler_RecordInfo);
			
			char sAuth[32];
			AccountIDToSteamID(record.accountid, sAuth, sizeof(sAuth));

			char sDisplay[128], sDate[32], sTime[32], sDiff[32];
			FormatSeconds(record.time, sTime, sizeof(sTime));
			if(record.date != 0) 
			{
				FormatTime(sDate, sizeof(sDate), "%Y-%m-%d %X", record.date);
			}
			else // Why you do this :(
			{
				FormatEx(sDate, sizeof(sDate), "%T", "RecordInfo_Unknown", client);
			}
			FormatDiff(client, record.time, record.wr_time, sDiff, sizeof(sDiff));
		
			WROS_StyleInfo aStyle;
			gA_Styles.GetArray(gA_Styles.FindValue(gI_LastStyle[client], WROS_Style_Offstyle), aStyle);

			submenu.SetTitle("%T\n ", "RecordInfo_Title", client,
				record.name, sAuth, sDate, sTime, sDiff, record.jumps,
				record.strafes, record.sync, record.server_hostname, aStyle.sStyleName, gS_ClientMap[client]);

			FormatEx(sDisplay, sizeof(sDisplay), "%T", "RecordInfo_Item_SteamProfile", client);
			FormatEx(sInfo, sizeof(sInfo), "1%s", record._id);
			submenu.AddItem(sInfo, sDisplay);

			FormatEx(sDisplay, sizeof(sDisplay), "%T", "RecordInfo_Item_OSProfile", client);
			FormatEx(sInfo, sizeof(sInfo), "2%s", record._id);
			submenu.AddItem(sInfo, sDisplay);

			// Only show the option when the extension and replay-playback are loaded, we have a replay style set and the player has access
			if(AllowReplays(client, record.style, false))
			{
				FormatEx(sDisplay, sizeof(sDisplay), "%T", "RecordInfo_Item_LoadReplay", client);
				Format(sInfo, sizeof(sInfo), "3%s", record._id);
				submenu.AddItem(sInfo, sDisplay, (record.replay_ref[0] != '\0') ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED); // GetReplay checks for the map
			}

			submenu.ExitBackButton = true;
			submenu.Display(client, MENU_TIME_FOREVER);

			gI_CurrentPagePosition[client] = GetMenuSelectionPosition();
		}
	}
}

int MenuHandler_RecordInfo(Menu menu, MenuAction action, int client, int param2)
{
	static bool DONT_CLOSE_MENU = false;

	switch(action)
	{
		case MenuAction_End: 
		{
			if(!DONT_CLOSE_MENU)
				delete menu;
			DONT_CLOSE_MENU = false;
		}
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
			{
				BuildWRMenu(client, gI_CurrentPagePosition[client]);
			}
		}
		case MenuAction_Select:
		{
			char info[PLATFORM_MAX_PATH];
			menu.GetItem(param2, info, sizeof(info));

			if(!info[0])
			{
				return 0;
			}

			switch(info[0])
			{
				case '1', '2': 
				{
					DataPack pack = new DataPack();
					pack.WriteString(info[1]);
					info[1] = '\0';
					pack.WriteCell(StringToInt(info[0]));

					QueryClientConVar(client, "cl_disablehtmlmotd", Query_Disablehtmlmotd, pack);
				}
				case '3':
				{
					GetReplay(client, info[1]);
				}
			}

			DONT_CLOSE_MENU = true;
			menu.Display(client, MENU_TIME_FOREVER);
		}
	}

	return 0;
}

public void Query_Disablehtmlmotd(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, DataPack pack)
{
	pack.Reset();
	char sID[sizeof(WROS_RecordInfo::_id)];
	pack.ReadString(sID, sizeof(sID));
	int type = pack.ReadCell();	
	delete pack;

	if(!client || client > MaxClients || !IsClientInGame(client))
		return;
	
	WROS_RecordInfo record;
	if(!GetRecordInfo(sID, record))
	{
		return;
	}

	char sAuth[32];
	AccountIDToSteamID(record.accountid, sAuth, sizeof(sAuth));

	if(StringToInt(cvarValue) == 0)
	{	
		char sURL[192+1], sTitle[128];
		switch(type)
		{
			case 1:
			{
				FormatEx(sTitle, sizeof(sTitle), "%T", "MOTD_Title_SteamProfile", client, record.name, sAuth);
				FormatEx(sURL, sizeof(sURL), "https://steamcommunity.com/profiles/%s", record.steamid);
			}
			case 2:
			{
				FormatEx(sTitle, sizeof(sTitle), "%T", "MOTD_Title_OffstyleProfile", client, record.name, sAuth);
				FormatEx(sURL, sizeof(sURL), "https://offstyles.tommyy.dev/players/%s/", record.steamid);
			}
		}
		ShowMOTDPanel(client, sTitle, sURL, MOTDPANEL_TYPE_URL);
	}
	else
	{
		switch(type)
		{
			case 1: CPrintToChat(client, "%T", "Chat_Steam_Profile_URL", client, record.name, sAuth, record.steamid);
			case 2: CPrintToChat(client, "%T", "Chat_Offstyle_Profile_URL", client, record.name, sAuth, record.steamid);
		}
	}
}

void BuildReplayMenu(int client, int first_item=0)
{
	gI_CurrentPagePosition[client] = 0;

	ArrayList records;
	if(!GetCachedRecords(gS_ClientMap[client], gI_LastStyle[client], records))
	{
		if(gA_Styles.Length > 1)
		{
			ChooseStyleMenu(client); // Go instantly back to the style selection for our lazy ppl
			CPrintToChat(client, "%T", "Chat_BuildReplayMenu_Nothing", client);
		}
		return;
	}

	int maxrecords = gCV_WRCount.IntValue;
	maxrecords = (maxrecords < records.Length) ? maxrecords : records.Length;
	int totalrecords = GetCachedTotalRecords(gS_ClientMap[client], gI_LastStyle[client]);

	WROS_StyleInfo aStyle;
	gA_Styles.GetArray(gA_Styles.FindValue(gI_LastStyle[client], WROS_Style_Offstyle), aStyle);

	Menu menu = new Menu(MenuHandler_BuildReplayMenu);
	menu.SetTitle("%T\n ", "BuildReplayMenu_Title", client, gS_ClientMap[client], maxrecords, aStyle.sStyleName, totalrecords);

	WROS_RecordInfo record;
	char sDisplay[128], sTime[32], sDiff[32];
	for (int i = 0; i < maxrecords; i++)
	{
		records.GetArray(i, record, sizeof(record));

		FormatSeconds(record.time, sTime, sizeof(sTime));
		FormatDiff(client, record.time, record.wr_time, sDiff, sizeof(sDiff));

		FormatEx(sDisplay, sizeof(sDisplay), "%T", "BuildReplayMenu_Item", client, i+1, record.name, sTime, sDiff);
		menu.AddItem(record._id, sDisplay, (record.replay_ref[0] != '\0') ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}

	if(menu.ItemCount == 0)
	{
		FormatEx(sDisplay, sizeof(sDisplay), "%T", "BuildReplayMenu_Nothing", client);
		menu.AddItem("-1", sDisplay);
	}

	menu.ExitBackButton = (gA_Styles.Length > 1) ? true : (gS_LastSearch[client][0] != '\0');
	
	if(Forward_OnMenuMade(client, WROS_Menu_Replays, menu))
	{
		menu.DisplayAt(client, first_item, MENU_TIME_FOREVER);
	}
}

void MenuHandler_BuildReplayMenu(Menu menu, MenuAction action, int client, int param2)
{
	if(action != MenuAction_End && !Forward_OnMenuCallback(client, WROS_Menu_Replays, menu, action, param2))
	{
		return;
	}

	switch(action)
	{
		case MenuAction_End: delete menu;
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
			{
				if(gA_Styles.Length > 1)
				{
					ChooseStyleMenu(client);
				}
				else if(gS_LastSearch[client][0] != '\0')
				{
					GuessBestMapNameEx(client, gS_LastSearch[client], gS_LastSearch[client], gS_ClientMap[client], MenuHandler_SelectMap);
				}
			}
		}
		case MenuAction_Select:
		{
			char sInfo[64];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if(StrEqual(sInfo, "-1"))
			{
				return;
			}

			if(!GetReplay(client, sInfo))
			{
				BuildReplayMenu(client, GetMenuSelectionPosition());
			}
		}
	}
}

ArrayList CacheMap(char mapname[PLATFORM_MAX_PATH], JSONArray json, int style, int total_records)
{
	char sKey[PLATFORM_MAX_PATH];
	FormatKey(mapname, style, sKey, sizeof(sKey));

	ArrayList records;
	if(gSM_Maps.GetValue(sKey, records))
	{
		WROS_RecordInfo record;
		for(int x = records.Length - 1; x >= 0; x--)
		{
			records.GetArray(x, record);
			gSM_RecordInfo.Remove(record._id);
		}
		delete records;
	}

	records = new ArrayList(sizeof(WROS_RecordInfo));

	gSM_MapsCachedTime.SetValue(sKey, GetEngineTime(), true);
	gSM_MapsTotalRecords.SetValue(sKey, total_records);
	gSM_Maps.SetValue(sKey, records, true);

	int iSize = json.Length, iReplays;
	for(int i = 0; i < iSize; i++)
	{
		JSONObject record = view_as<JSONObject>(json.Get(i));

		WROS_RecordInfo info;
		record.GetString("_id", info._id, sizeof(info._id));
		record.GetString("map", info.map, sizeof(info.map));
		record.GetString("steamid", info.steamid, sizeof(info.steamid));
		record.GetString("name", info.name, sizeof(info.name));
		info.time = record.GetFloat("time");
		info.sync = record.GetFloat("sync");
		info.strafes = record.GetInt("strafes");
		info.jumps = record.GetInt("jumps");
		info.date = record.GetInt("date");
		record.GetString("replay_ref", info.replay_ref, sizeof(info.replay_ref));
		info.style = record.GetInt("style");
		info.is_invalid = record.GetBool("is_invalid");
		info.is_banned = record.GetBool("is_banned");
		info.wr_time = record.GetFloat("wr_time");
		info.rank = record.GetInt("rank");

		JSONObject server = view_as<JSONObject>(record.Get("server"));
		server.GetString("hostname", info.server_hostname, sizeof(info.server_hostname));
		server.GetString("key_id", info.server_key_id, sizeof(info.server_key_id));
		delete server;

		info.accountid = SteamIDToAccountID(info.steamid);

		records.PushArray(info, sizeof(info));	
		gSM_RecordInfo.SetArray(info._id, info, sizeof(info));

		if(info.replay_ref[0] != '\0')
		{
			iReplays++;
		}

		delete record;
	}
	gSM_ReplayCount.SetValue(sKey, iReplays);

	CallOnQueryFinishedCallback(mapname, records, style);
	return records;
}

void RIP_Request_Callback(HTTPResponse response, DataPack pack, const char[] error)
{
	bool bSuccess = (response.Status == HTTPStatus_OK);
	HandleRequest(pack, bSuccess ? view_as<JSONObject>(response.Data) : null, bSuccess, false, response.Status, error);
}

public void SteamWorks_Request_Callback(Handle request, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, DataPack pack)
{
	if (bFailure || !bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK)
	{
		HandleRequest(pack, null, false, true, eStatusCode);
		return;
	}

	SteamWorks_GetHTTPResponseBodyCallback(request, SteamWorks_RequestBody_Callback, pack);
	delete request;
}

void SteamWorks_RequestBody_Callback(const char[] data, DataPack pack)
{
	HandleRequest(pack, JSONObject.FromString(data), true, true);
}

void HandleRequest(DataPack pack, JSONObject json_response, bool success, bool steamworks, int status = -1, const char[] error = "")
{
	pack.Reset();

	int client = GetClientFromSerial(pack.ReadCell());
	char mapname[PLATFORM_MAX_PATH];
	pack.ReadString(mapname, sizeof(mapname));
	int style = pack.ReadCell();
	WROS_Menu menu = pack.ReadCell();

	DataPack callback_pack = pack.ReadCell();

	CloseHandle(pack);

	//PrintToChat(client, "status = %d, error = '%s'", response.Status, error);
	if(!success)
	{
		CallOnQueryFinishedCallback(mapname, null, style);
		if(callback_pack)
			CallOnQueryFinishedWithFunctionCallback(mapname, null, callback_pack);

		if(client != 0)
			PrintToChat(client, "[WROS] Offstyle API request failed (%s)", mapname);
		if(status != -1) // Exclude when called from RetrieveWRs directly
			LogError("(%s) Offstyle API request failed (%s) status %d", steamworks ? "SteamWorks" : "SM-RIP", mapname, status);
		if(error[0] != '\0')
			LogError("%s", error);
		return;
	}

	JSONArray records = view_as<JSONArray>(json_response.Get("data"));
	int total_records = json_response.GetInt("total");
	ArrayList records2 = CacheMap(mapname, records, style, total_records);
	delete records;

	// the records handle is closed by ripext post-callback
	if(steamworks)
	{
		delete json_response;		
	}

	if(callback_pack)
		CallOnQueryFinishedWithFunctionCallback(mapname, records2, callback_pack);

	if(client != 0)
	{
		gI_LastMenu[client] = menu;
		gI_LastStyle[client] = style;
		gS_ClientMap[client] = mapname;

		switch(gI_LastMenu[client])
		{
			case WROS_Menu_Records: BuildWRMenu(client);
			case WROS_Menu_Replays: BuildReplayMenu(client);
		}
	}

}

bool RetrieveWRs(int client, const char[] mapname, int style, int menu = WROS_Menu_Records, DataPack MOREPACKS=null)
{
	int serial = client ? GetClientSerial(client) : 0;
	// char apikey[40];
	char sURL[230];

	// gCV_APIKey.GetString(apikey, sizeof(apikey));
	gCV_APIUrl.GetString(sURL, sizeof(sURL));

	// if(apikey[0] == 0 || sURL[0] == 0)
	if(sURL[0] == 0)
	{
		// ReplyToCommand(client, "[WROS] Offstyle API key or URL is not set.");
		// LogError("WROS: Offstyle API key or URL is not set.");
		if(client != 0)
			PrintToChat(client, "[WROS] Offstyle URL is not set.");
		LogError("WROS: Offstyle URL is not set.");
		return false;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(serial);
	pack.WriteString(mapname);
	pack.WriteCell(style);
	pack.WriteCell(menu);
	pack.WriteCell(MOREPACKS);

	// https://offstyles.net/api/times?map={map}&style={style}&sort=Fastest&best=true&page=1&limit=50
	char sStyleID[11];
	IntToString(style, sStyleID, sizeof(sStyleID));
	ReplaceStringEx(sURL, sizeof(sURL), "{map}", mapname);
	ReplaceStringEx(sURL, sizeof(sURL), "{style}", sStyleID);

	if(!IsFlagEnabled(Flag_UseSteamWorks))
	{
		HTTPRequest http = new HTTPRequest(sURL);
		// http.SetHeader("api-key", "%s", apikey);
		http.Get(RIP_Request_Callback, pack);
		return true;
	}

	// From shavit-zones-http.sp
	Handle hRequest;
	if (!(hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sURL))
	//   || (apikey[0] && !SteamWorks_SetHTTPRequestHeaderValue(hRequest, "api-key", apikey))
	  || !SteamWorks_SetHTTPRequestHeaderValue(hRequest, "accept", "application/json")
	//   || !(!apikey[0] || SteamWorks_SetHTTPRequestHeaderValue(hRequest, "api-key", apikey))
	//   || !SteamWorks_SetHTTPRequestHeaderValue(hRequest, "map", mapname)
	  || !SteamWorks_SetHTTPRequestContextValue(hRequest, pack)
	  || !SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(hRequest, 4000)
	//|| !SteamWorks_SetHTTPRequestRequiresVerifiedCertificate(hRequest, true)
	  || !SteamWorks_SetHTTPCallbacks(hRequest, SteamWorks_Request_Callback)
	  || !SteamWorks_SendHTTPRequest(hRequest)
	)
	{
		delete hRequest;
		HandleRequest(pack, null, false, true, _, "Failed to setup & send HTTP request");
		return false;
	}

	return true;
}

Action Command_WROSReplay(int client, int args)
{
	return WROSCommand(client, args, WROS_Menu_Replays);
}

Action Command_WROS(int client, int args)
{
	return WROSCommand(client, args, WROS_Menu_Records);
}

Action WROSCommand(int client, int args, WROS_Menu menu)
{
	if(client == 0 || IsFakeClient(client))// || !IsClientAuthorized(client))
		return Plugin_Handled;

	if(menu == WROS_Menu_Replays && !AllowReplays(client))
	{
		return Plugin_Handled;
	}

	gI_LastMenu[client] = menu;
	
	if(args < 1)
	{
		gS_LastSearch[client][0] = '\0';
		gS_ClientMap[client] = gS_CurrentMap;
	}
	else
	{
		GetCmdArgString(gS_LastSearch[client], sizeof(gS_LastSearch[]));
		if(!GuessBestMapNameEx(client, gS_LastSearch[client], gS_LastSearch[client], gS_ClientMap[client], MenuHandler_SelectMap))
			return Plugin_Handled;
	}

	if(gA_Styles.Length > 1)
	{
		ChooseStyleMenu(client);
	}
	else
	{
		gI_LastStyle[client] = gA_Styles.Get(0, WROS_Style_Offstyle);
		CheckWRCache(client, gS_ClientMap[client], gI_LastStyle[client], gI_LastMenu[client]);
	}
	return Plugin_Handled;

}

bool GetRecordInfo(const char[] id, WROS_RecordInfo info)
{
	return gSM_RecordInfo.GetArray(id, info, sizeof(info));
}

public any Native_QueryMap(Handle plugin, int numParams)
{
	char map[PLATFORM_MAX_PATH];
	GetNativeString(1, map, sizeof(map));
	LowercaseString(map);

	bool cache_okay = GetNativeCell(2);
	int style = GetNativeCell(3);

	if(cache_okay)
	{
		ArrayList records;

		if(gSM_Maps.GetValue(map, records) && records && records.Length)
		{
			CallOnQueryFinishedCallback(map, records, style);
			return true;
		}
	}

	return RetrieveWRs(0, map, style, 0);
}

public any Native_QueryMapWithFunc(Handle plugin, int numParams)
{
	char map[PLATFORM_MAX_PATH];
	GetNativeString(1, map, sizeof(map));
	LowercaseString(map);

	bool cache_okay = GetNativeCell(2);
	int style = GetNativeCell(3);

	DataPack data = new DataPack();
	data.WriteFunction(GetNativeFunction(4));
	data.WriteCell(plugin);
	data.WriteCell(GetNativeCell(5));

	if(cache_okay)
	{
		ArrayList records;

		if(gSM_Maps.GetValue(map, records) && records && records.Length)
		{
			CallOnQueryFinishedWithFunctionCallback(map, records, data);
			return true;
		}
	}

	bool res = RetrieveWRs(0, map, style, 0, data);

	if(!res)
		delete data;

	return res;
}

int Native_CanUseReplays(Handle plugin, int numParams)
{
	return AllowReplays(GetNativeCell(1), _, GetNativeCell(2));
}

int Native_GetStyleCount(Handle plugin, int numParams)
{
	return gA_Styles.Length;
}

int Native_GetStyleData(Handle plugin, int numParams)
{
	if(GetNativeCell(3) != sizeof(WROS_StyleInfo))
	{
		return ThrowNativeError(200, "WROS_StyleInfo does not match latest(got %i expected %i). Please update your includes and recompile your plugins", GetNativeCell(3), sizeof(WROS_StyleInfo));
	}

	int iIndex = GetNativeCell(1);

	WROS_StyleInfo aData;
	gA_Styles.GetArray(iIndex, aData, sizeof(WROS_StyleInfo));

	return SetNativeArray(2, aData, sizeof(WROS_StyleInfo));
}

int Native_GetStyleArrayList(Handle plugin, int numParams)
{
	return gA_Styles;
}

int Native_OpenMenu(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	WROS_Menu type = GetNativeCell(2);
	GetNativeString(3, gS_ClientMap[client], sizeof(gS_ClientMap[]));
	int style = GetNativeCell(4);

	gS_LastSearch[client][0] = '\0';
	gS_ClientMap[client] = (gS_ClientMap[client][0] == '\0') ? gS_CurrentMap : gS_ClientMap[client];

	gI_LastMenu[client] = (type & (WROS_Menu_Records|WROS_Menu_Replays));
	if((gI_LastMenu[client] & (WROS_Menu_Records|WROS_Menu_Replays)) == view_as<WROS_Menu>(0))
	{
		ThrowNativeError(200, "No target menu specified WROS_Menu_Records or WROS_Menu_Replays.");
		return false;
	}

	if(type & WROS_Menu_Replays && !AllowReplays(client, _, false))
	{
		return false;
	}
	
	if(type & WROS_Menu_Maps)
	{
		gS_LastSearch[client] = gS_ClientMap[client];
		if(!GuessBestMapNameEx(client, gS_LastSearch[client], gS_LastSearch[client], gS_ClientMap[client], MenuHandler_SelectMap))
			return true;
	}

	if(style == -1 && gA_Styles.Length > 1)
	{
		ChooseStyleMenu(client);
	}
	else
	{
		gI_LastStyle[client] = (style != -1) ? style : gA_Styles.Get(0, WROS_Style_Offstyle); // Use provided style or the only style available
		CheckWRCache(client, gS_ClientMap[client], gI_LastStyle[client], gI_LastMenu[client]);
	}
	return true;
}

void CallOnQueryFinishedWithFunctionCallback(const char map[PLATFORM_MAX_PATH], ArrayList records, DataPack callerinfo)
{
	callerinfo.Reset();
	Function func = callerinfo.ReadFunction();
	Handle plugin = callerinfo.ReadCell();
	int callerdata = callerinfo.ReadCell();
	delete callerinfo;

	Call_StartFunction(plugin, func);
	Call_PushString(map);
	Call_PushCell(records);
	Call_PushCell(callerdata);
	Call_Finish();
}

void CallOnQueryFinishedCallback(const char map[PLATFORM_MAX_PATH], ArrayList records, int style)
{
	Call_StartForward(gH_Forward_OnQueryFinished);
	Call_PushString(map);
	Call_PushCell(records);
	Call_PushCell(style);
	Call_Finish();
}

public void OnClientConnected(int client)
{
	gI_ClientSettings[client] = gCV_DefaultSettings.IntValue;
}

public void OnClientCookiesCached(int client)
{
	if(!IsFakeClient(client))
	{
		char sCookie[11];
		gH_Cookie.Get(client, sCookie, sizeof(sCookie));
		if(sCookie[0] != '\0')
		{
			gI_ClientSettings[client] = StringToInt(sCookie);
		}
	}
}

bool IsSettingEnabled(int client, int setting)
{
	return view_as<bool>((1<<setting) & gI_ClientSettings[client]);
}

bool IsFlagEnabled(int flag)
{
	return ((gCV_Flags.IntValue & (1<<flag)) != 0); // We could add the flags as input and replace IsSettingEnabled but lets keep it for now
}

void AddSettingItem(Menu menu, int client, int hud, char[] translation)
{
	char sInfo[16], sDisplay[64];
	IntToString(1<<hud, sInfo, sizeof(sInfo));
	FormatEx(sDisplay, sizeof(sDisplay), "[%s] %T", ((gI_ClientSettings[client] & 1<<hud) > 0) ? "✓" : "✘", translation, client);
	menu.AddItem(sInfo, sDisplay);
}

void FormatDiff(int client, float time, float wr_time, char[] output, int maxlen)
{
	if(time == wr_time)
	{
		FormatEx(output, maxlen, "%T", "Difference_WR", client);
	}
	else // Everything else should be higher than the wr time..
	{
		FormatSeconds(time - wr_time, output, maxlen);
		Format(output, maxlen, "+%s", output);
	}
}

bool GetReplay(int client, const char[] id)
{
	WROS_RecordInfo record;
	if(!GetRecordInfo(id, record))
	{
		LogError("Could not find record info for '%s'", id);
		return false;
	}

	if(!StrEqual(record.map, gS_CurrentMap, false))
	{
		CPrintToChat(client, "%T", "Chat_Replay_MapMismatch", client, record.map);
		return false;
	}

	// Convert our offstyle style to a timer style for the replay "style_replay"
	int iReplayStyle = WROS_ConvertStyle(record.style, WROS_Style_Offstyle, WROS_Style_Replay);
	if(iReplayStyle == -1)
	{
		CPrintToChat(client, "%T", "Chat_NoAccess_ReplayStyle", client);
		return false; // Disabled
	}

	char sOutputFile[PLATFORM_MAX_PATH];
	gCV_DLDirectory.GetString(sOutputFile, sizeof(sOutputFile));
	Format(sOutputFile, sizeof(sOutputFile), "%s/%s.replay", sOutputFile, record.replay_ref);

	bool bQueued = (gA_DownloadQueue != null && gA_DownloadQueue.FindString(sOutputFile, 0) != -1);

	if(!bQueued && FileExists(sOutputFile))
	{
		return StartReplay(client, iReplayStyle, sOutputFile, record.name);
	}
	else if(bQueued)
	{
		download_queue_t aQueue;
		int iSize = gA_DownloadQueue.Length, iSerial = GetClientSerial(client);
		for(int i = 0; i < iSize; i++)
		{
			gA_DownloadQueue.GetArray(i, aQueue);
			if(aQueue.iRequester == iSerial && StrEqual(sOutputFile, aQueue.sPath))
			{
				CPrintToChat(client, "%T", "Chat_Download_Queued", client);
				return false;
			}
		}
	}
	
	if(gA_DownloadQueue == null)
	{
		gA_DownloadQueue = new ArrayList(sizeof(download_queue_t));
	}

	download_queue_t aQueue;
	aQueue.iRequester = GetClientSerial(client);
	aQueue.sPath = sOutputFile;
	aQueue.sMap = gS_CurrentMap;
	aQueue.iStyle = iReplayStyle;
	aQueue.sName = record.name;
	aQueue.sReplayRef = record.replay_ref;
	aQueue.fTime = bQueued ? 0.0 : GetEngineTime();
	gA_DownloadQueue.PushArray(aQueue);

	if(!bQueued)
	{
		DownloadReplay(aQueue);
		CPrintToChat(client, "%T", "Chat_Downloading", client);
	}
	else
	{
		CPrintToChat(client, "%T", "Chat_Download_Queued", client);
	}

	return true; // Request send or queued
}

void DownloadReplay(download_queue_t queue)
{
	char sURL[128];
	gCV_DLUrl.GetString(sURL, sizeof(sURL));
	StrCat(sURL, sizeof(sURL), queue.sReplayRef);

	DataPack hPack = new DataPack();
	hPack.WriteString(queue.sPath);

	// Does this have the same issue on windows too???
	// I cannot think of another method to download stuff async :tableflip:
	HTTPRequest hRequest = new HTTPRequest(sURL);
	hRequest.DownloadFile(queue.sPath, OnDownloadFinished_Callback, hPack);
}

void OnDownloadFinished_Callback(HTTPStatus status, any value, const char[] error)
{
	DataPack hPack = view_as<DataPack>(value);
	hPack.Reset();
	char sOutputFile[PLATFORM_MAX_PATH];
	hPack.ReadString(sOutputFile, sizeof(sOutputFile));
	delete hPack;

	bool bSuccess = true;
	if(status != HTTPStatus_OK)
	{
		bSuccess = false;
		LogError("Expected HTTP status code 200, but got %d", status);
		if(error[0] != '\0')
		{
			LogError("%s", error);
		}
	}

	// Assuming the OS is windows and the replay did only partially download..............................
	// Im not really familiar with failures for downloads in the first place maybe someone else knows how to catch errors correctly
	// Error: h2_process_pending_input: nghttp2_session_mem_recv() returned -2561650531219013632:Success
	if(IsFlagEnabled(Flag_UseSteamWorks) && strncmp(error, "h2_process_pending_input", 24) == 0)
	{
		bSuccess = false;
	}
	// Maybe check if the replay is valid by the frame size?

	download_queue_t aQueue;
	int iIndex = gA_DownloadQueue.FindString(sOutputFile, 0);
	if(iIndex == -1)
	{
		LogError("Could not find replay file '%s' in the download queue.", sOutputFile);
		return; // ???
	}
	gA_DownloadQueue.GetArray(iIndex, aQueue);

	// Delete file on failure
	if(!bSuccess)
	{
		DeleteFile(sOutputFile);

		if(++aQueue.iRetries <= gCV_DLRetryCount.IntValue)
		{
			// We dont update aQueue.fTime here to get the total time it took
			gA_DownloadQueue.SetArray(iIndex, aQueue);
			DownloadReplay(aQueue);
			return;
		}
	}

	gA_DownloadQueue.Erase(iIndex);

	float fTimeElapsed = GetEngineTime() - aQueue.fTime;
	int client = GetClientFromSerial(aQueue.iRequester);
	DownloadFinished(client, bSuccess, aQueue, fTimeElapsed);

	// Check if someone else already requested it and trigger the same 
	// Maybe add an option to handle behavior? Like dont start the same replay for another play just notify him?
	for(int i = gA_DownloadQueue.Length - 1; i >= 0; i--)
	{
		gA_DownloadQueue.GetArray(i, aQueue);
		if(StrEqual(aQueue.sPath, sOutputFile))
		{
			client = GetClientFromSerial(aQueue.iRequester);
			DownloadFinished(client, bSuccess, aQueue, fTimeElapsed);
			gA_DownloadQueue.Erase(i);
		}
	}

	if(gA_DownloadQueue.Length == 0)
	{
		delete gA_DownloadQueue;
	}
}

void DownloadFinished(int client, bool success, download_queue_t queue, float time_elapsed)
{
	if(client)
	{
		if(!success)
		{
			CPrintToChat(client, "%T", "Chat_Download_Failed", client);
		}
		else if(StrEqual(queue.sMap, gS_CurrentMap))
		{
			CPrintToChat(client, "%T", "Chat_Download_Finished", client, time_elapsed);
			StartReplay(client, queue.iStyle, queue.sPath, queue.sName);
		}
	}
}

bool StartReplay(int client, int style, const char[] path, const char[] replay_name)
{
	// Check if the player already has a running bot...
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && IsFakeClient(i) && Shavit_GetReplayStarter(i) == client)
		{
			if(!IsFlagEnabled(Flag_ReplaceReplay))
			{
				CPrintToChat(client, "%T", "Chat_Replay_Running", client);
				return false;
			}
			else
			{
				KickClientEx(i, "You shall not stay!"); // Thats not really nice.. Shavit_StopReplay where?
				CPrintToChat(client, "%T", "Chat_Replay_Stopped", client);
			}
		}
	}

	bool bFound = false;
	replay_cache_t aCache; // null cache
	if(IsFlagEnabled(Flag_CacheReplays))
	{
		if(gSM_ReplayCache == null)
		{
			gSM_ReplayCache = new StringMap();
		}

		bFound = gSM_ReplayCache.GetArray(path, aCache, sizeof(aCache));
	}

	if(aCache.aFrameCache.aFrames == null)
	{
		if(!LoadReplayCache2(aCache.aHeader, aCache.aFrameCache, path, aCache.aHeader.sMap))
		{
			CPrintToChat(client, "%T", "Chat_Replay_Unreadable", client);
			return false;
		}
		else
		{
			aCache.aHeader.iStyle = style;
			strcopy(aCache.aFrameCache.sReplayName, sizeof(aCache.aFrameCache.sReplayName), replay_name); // Set replay name the server might not have it ...
		}
	}

	int bot = Shavit_StartReplayFromFrameCache(aCache.aHeader.iStyle, aCache.aHeader.iTrack, -1.0, client, -1, Replay_Dynamic, false, aCache.aFrameCache);

	if(!IsFlagEnabled(Flag_CacheReplays)) // File cache will use the handle when enabled otherwise delete it
	{
		// Shavit_StartReplayFromFrameCache should clone the handle so we delete this here
		delete aCache.aFrameCache.aFrames; 
	}
	else if(!bFound)
	{
		gSM_ReplayCache.SetArray(path, aCache, sizeof(aCache));
	}

	if(bot != 0 && IsFlagEnabled(Flag_FakeReplayCommand))
	{
		// We have to wait or the menu only shows unselectable items
		CreateTimer(0.5, Timer_FakeReplayCommand, GetClientSerial(client));
	}

	return (bot != 0);
}

void Timer_FakeReplayCommand(Handle timer, any data)
{
	int client = GetClientFromSerial(data);
	if(client)
	{
		FakeClientCommand(client, "sm_replay");
	}
}

// Custom LoadReplayCache without any track/style checks + returns the header
stock bool LoadReplayCache2(replay_header_t header, frame_cache_t cache, const char[] path, const char[] mapname)
{
	bool success = false;
	File fFile = ReadReplayHeader(path, header);

	if (fFile != null)
	{
		if (header.iReplayVersion > REPLAY_FORMAT_SUBVERSION)
		{
			// lets log and error if we cannot read the replay
			LogError("Replay file '%s' was recorded on a newer version (v%d) than supported (v%d) - cannot read", path, header.iReplayVersion, REPLAY_FORMAT_SUBVERSION);		
		}
		else if (header.iReplayVersion < 0x03 || StrEqual(header.sMap, mapname, false))
		{
			success = ReadReplayFrames(fFile, header, cache);
		}
		else
		{
			LogError("Replay file '%s' was recorded on map '%s' but current map is '%s' - skipping", path, header.sMap, mapname);		
		}

		delete fFile;
	}

	return success;
}

bool GuessBestMapNameEx(int client, char last_search[PLATFORM_MAX_PATH], char search[PLATFORM_MAX_PATH], char output[PLATFORM_MAX_PATH], MenuHandler menu_handler)
{
	TrimString(search);
	
	ArrayList aMaps = null;
	if(gB_MapChooser)
	{
		aMaps = Shavit_GetMapsArrayList();
	}
	else if(gA_MapList != null)
	{
		aMaps = gA_MapList;
	}
	else
	{
		output = search;
		last_search[0] = '\0';
		return true; // Map list not available let it pass
	}

	Menu menu = new Menu(menu_handler);
			
	int iSize = aMaps.Length, iCount;
	char sMap[PLATFORM_MAX_PATH], sLastMap[PLATFORM_MAX_PATH];
	for(int i = 0; i < iSize; i++)
	{
		aMaps.GetString(i, sMap, sizeof(sMap));
		if(StrContains(sMap, search, false) != -1)
		{
			iCount++;
			sLastMap = sMap;
			menu.AddItem(sMap, sMap);
		}
	}

	char sDisplay[256];
	FormatEx(sDisplay, sizeof(sDisplay), "%T", "GuessBestMapName_SelectInput", client, search, iCount);
	menu.InsertItem(0, search, sDisplay);
	
	if(iCount == 0) // Query for the map if we cant find any matches in our list
	{
		delete menu;
		output = search;
		last_search[0] = '\0';
		return true;
	}
	else if(!gCV_AlwaysShowSelection.BoolValue && iCount == 1)
	{
		last_search[0] = '\0';
		output = sLastMap;
		delete menu;
		return true;
	}

	last_search = search;
	
	menu.SetTitle("%T", "GuessBestMapName_Title", client, search, iCount);
	if(Forward_OnMenuMade(client, WROS_Menu_Maps|gI_LastMenu[client], menu))
	{
		menu.Display(client, MENU_TIME_FOREVER);
	}
	return false;
}

void MenuHandler_SelectMap(Menu menu, MenuAction action, int client, int param2)
{
	if(action != MenuAction_End && !Forward_OnMenuCallback(client, WROS_Menu_Maps|gI_LastMenu[client], menu, action, param2))
	{
		return;
	}

	switch(action)
	{
		case MenuAction_End: delete menu;
		case MenuAction_Select:
		{
			menu.GetItem(param2, gS_ClientMap[client], sizeof(gS_ClientMap[]));
			if(gA_Styles.Length > 1)
			{
				ChooseStyleMenu(client);
			}
			else
			{
				gI_LastStyle[client] = gA_Styles.Get(0, WROS_Style_Offstyle);
				CheckWRCache(client, gS_ClientMap[client], gI_LastStyle[client], gI_LastMenu[client]);
			}
		}
	}
}

void CheckWRCache(int client, const char[] map, int style, int menu)
{
	char sKey[PLATFORM_MAX_PATH];
	FormatKey(map, style, sKey, sizeof(sKey));

	float cached_time;
	if(gSM_MapsCachedTime.GetValue(sKey, cached_time))
	{
		if(cached_time > (GetEngineTime() - gCV_CacheTime.FloatValue))
		{
			switch(menu)
			{
				case WROS_Menu_Records: BuildWRMenu(client);
				case WROS_Menu_Replays: BuildReplayMenu(client);
			}
			return;
		}
	}

	RetrieveWRs(client, map, style, menu);
}

/**
 * Returns an ArrayList with the records from the cache when available.
 * 
 * @param map         Mapname.
 * @param style       Style ID in the Offstyle API.
 * @param records     By-reference variable to store the ArrayList with records.
 * @return            True on success, false if the map & style are not cached or empty.
 */
bool GetCachedRecords(const char[] map, int style, ArrayList &records)
{
	if(style == -1)
		return false;

	char sKey[PLATFORM_MAX_PATH];
	FormatKey(map, style, sKey, sizeof(sKey));
	if(!gSM_Maps.GetValue(sKey, records) || !records || !records.Length)
		return false;

	return true;
}

/**
 * Returns the total records Offstyle holds for a specific map and style.
 * The total amount of records inside the record ArrayLists is set by the URL!
 * 
 * @param map       Mapname
 * @param style     Style ID in the Offstyle API.
 * @return         	Amount of total records, -1 if the map & style not cached.
 */
int GetCachedTotalRecords(const char[] map, int style)
{
	char sKey[PLATFORM_MAX_PATH];
	FormatKey(map, style, sKey, sizeof(sKey));

	int iTotalRecords = -1;
	gSM_MapsTotalRecords.GetValue(sKey, iTotalRecords);
	return iTotalRecords;
}

void FormatKey(const char[] map, int style, char[] output, int maxlen)
{
	FormatEx(output, maxlen, "%d%s", style, map);
}

bool AllowReplays(int client, int style = -1, bool notify = true)
{
	if(!gB_DirExists || !gB_ReplayPlayback)
	{
		if(notify) 
		{
			CPrintToChat(client, "%T", "Chat_NoAccess_ReplayFeature", client);
		}
		return false;
	}

	if(style != -1 && WROS_ConvertStyle(style, WROS_Style_Offstyle, WROS_Style_Replay) == -1)
	{
		if(notify) 
		{
			CPrintToChat(client, "%T", "Chat_NoAccess_ReplayStyle", client);
		}
		return false;
	}

	if(!CheckCommandAccess(client, "sm_wros_getreplay", ADMFLAG_BAN))
	{
		if(notify) 
		{
			CPrintToChat(client, "%T", "Chat_NoAccess_ReplayCommand", client);
		}
		return false;
	}

	return true;
}

void AccountIDToSteamID(int accountid, char[] output, int maxlen)
{
	switch(gCV_AuthType.IntValue)
	{
		case AuthId_Steam2: AccountIDToSteamID2(accountid, output, maxlen);
		case AuthId_Steam3: FormatEx(output, maxlen, "[U:1:%d]", accountid);
		case AuthId_SteamID64: AccountIDToSteamID64(accountid, output, maxlen);
	}
}

bool Forward_OnMenuMade(int client, WROS_Menu type, Menu menu)
{
	Action result = Plugin_Continue;
	Call_StartForward(gH_Forward_OnMenuMade);
	Call_PushCell(client);
	Call_PushCell(type);
	Call_PushCell(menu);
	Call_Finish(result);
	if(result != Plugin_Continue)
	{
		delete menu;
	}
	return (result == Plugin_Continue);
}

bool Forward_OnMenuCallback(int client, WROS_Menu type, Menu menu, MenuAction action, int param2)
{
	Action result = Plugin_Continue;
	Call_StartForward(gH_Forward_OnMenuCallback);
	Call_PushCell(client);
	Call_PushCell(type);
	Call_PushCell(menu);
	Call_PushCell(action);
	Call_PushCell(param2);
	Call_Finish(result);
	return (result == Plugin_Continue);
}

void LoadConfig()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/wros.cfg");

	if(!FileExists(sPath))
	{
		return;
	}

	KeyValues kv = new KeyValues("root");
	if(!kv.ImportFromFile(sPath))
	{
		SetFailState("Cannot read config file '%s'", sPath);
	}

	gA_Styles = new ArrayList(sizeof(WROS_StyleInfo));

	if(kv.GotoFirstSubKey())
	{
		WROS_StyleInfo aStyle;
		do
		{
			char sBuffer[11];
			kv.GetSectionName(sBuffer, sizeof(sBuffer));
			aStyle.iStyle_Offstyle = StringToInt(sBuffer);
			aStyle.iStyle_Server = kv.GetNum("style_server", -1);
			aStyle.iStyle_Replay = kv.GetNum("style_replay", -1);
			kv.GetString("style_name", aStyle.sStyleName, sizeof(aStyle.sStyleName));

			gA_Styles.PushArray(aStyle);
		}
		while(kv.GotoNextKey());
	}

	delete kv;
}

public int MenuHandler_Cookie(int client, CookieMenuAction action, any info, char[] buffer, int maxlen) 
{
	switch(action)
	{
		case CookieMenuAction_DisplayOption: FormatEx(buffer, maxlen, "%T", "SettingItem_Offstyle", client);
		case CookieMenuAction_SelectOption: Command_Settings(client, 0);
	}
	return 0;
}

public Action Command_Settings(int client, int args)
{
	SettingsMenu(client);
	return Plugin_Handled;
}

void SettingsMenu(int client, int item = 0)
{
	Menu menu = new Menu(MenuHandler_Settings);
	menu.SetTitle("%T", "SettingTitle", client);

	AddSettingItem(menu, client, Setting_TopLeftHUD, "SettingItem_TopLeftHUD");
	AddSettingItem(menu, client, Setting_AfterTopLeft, "SettingItem_AfterTopLeft");
	AddSettingItem(menu, client, Setting_EveryStyle, "SettingItem_EveryStyle");
	if(gA_Styles.Length > 1)
	{
		AddSettingItem(menu, client, Setting_ShowOnlyDefault, "SettingItem_ShowOnlyDefault");
		AddSettingItem(menu, client, Setting_FallbackToDefault, "SettingItem_FallbackToDefault");
	}
	
	menu.ExitBackButton = true;
	menu.DisplayAt(client, item, MENU_TIME_FOREVER);
}

public int MenuHandler_Settings(Menu menu, MenuAction action, int client, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		int iSelection = StringToInt(sInfo);

		gI_ClientSettings[client] ^= iSelection;
		gH_Cookie.SetInt(client, gI_ClientSettings[client]);

		SettingsMenu(client, GetMenuSelectionPosition());
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
#if defined CUSTOM_BUILD
			Shavit_ShowCookieMenu(client); 
#else
			ShowCookieMenu(client);
#endif
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

#if defined CUSTOM_BUILD
public void Shavit_OnMapListLoaded(ArrayList maps)
{
	delete gA_MapList;
	gA_MapList = view_as<ArrayList>(CloneHandle(maps));	
}

public void Shavit_OnSettingsMenuRequest(int client)
{
	char sDisplay[64];
	FormatEx(sDisplay, sizeof(sDisplay), "%T", "SettingItem_Offstyle", client);
	Shavit_AddSetting("menu_wros", sDisplay);
}

public void Shavit_OnSettingsMenuSelect(int client, Menu menu, int position, int select_position, const char[] info)
{
	if(StrEqual(info, "menu_wros"))
	{
		Command_Settings(client, 0);
	}
}
#endif
