/**
 * dod_vech_carma.sp
 * Carmageddon-style vehicle kill game mode for Day of Defeat: Source.
 * Requires the Driveable Vehicles plugin (vehicles.sp).
 *
 * Players compete to reach a configurable kill goal using vehicles only.
 * Kills detected via weapon="prop_vehicle_driveable" in player_death.
 * Human player deaths deduct 1 kill (floor at 0).
 * Fireworks trigger on win. HLStatsX log entry written on win.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION      "0.1.20"
#define START_DELAY         5.0
#define BOARD_INTERVAL      3.5     // Seconds between scoreboard refreshes
#define BOARD_DURATION      2       // Seconds the scoreboard menu displays (must be < BOARD_INTERVAL)
#define FIREWORKS_FREQUENCY 0.1

// Fireworks assets (ported from dod_fireworks by Silent_Water, playboycyberclub)
char g_sModels[][] = {
    "sprites/sprite_fire01.vmt",
    "sprites/blueglow1.vmt",
    "sprites/redglow1.vmt",
    "sprites/greenglow1.vmt",
    "sprites/yellowglow1.vmt",
    "sprites/purpleglow1.vmt",
    "sprites/orangeglow1.vmt",
    "sprites/glow1.vmt"
};

char g_sSounds[][] = {
    "ambient/explosions/exp1.wav",
    "ambient/explosions/explode_8.wav",
    "weapons/explode3.wav",
    "weapons/stinger_fire1.wav",
    "weapons/rpg/rocketfire1.wav",
    "weapons/mortar/mortar_explode1.wav",
    "weapons/mortar/mortar_explode2.wav",
    "weapons/mortar/mortar_explode3.wav",
    "weapons/mortar/mortar_shell_incomming1.wav"
};

//-----------------------------------------------------------------------------
// Globals
//-----------------------------------------------------------------------------

ConVar g_cvKillGoal;
ConVar g_cvDebug;
ConVar g_cvFireworksTimeout;
ConVar g_cvFireworksSound;

int   g_iPlayerKills[MAXPLAYERS + 1];
float g_fMenuSuppressUntil[MAXPLAYERS + 1]; // Suppresses scoreboard when another menu is open

bool  g_bGameRunning;
bool  g_bStartPending; // Guards against double-start when round_start + dod_round_start fire together
float g_fRoundStartTime;

bool  g_bMapRecordSet;
float g_fMapBestTime;
char  g_sMapRecordHolder[MAX_NAME_LENGTH];

Handle g_hScoreboardTimer;

// Fireworks
int    g_ExplosionSprite[8];
Handle g_hFireworksTimer;
int    g_iPositionCount;
float  g_fFireworksFrequency;
float  g_fPositions[10][3];

//-----------------------------------------------------------------------------
// Plugin info
//-----------------------------------------------------------------------------

public Plugin myinfo =
{
    name        = "Vehicle Carmageddon",
    author      = "claude.ai guided by DNA.styx",
    description = "Carmageddon-style vehicle kill game mode",
    version     = PLUGIN_VERSION,
    url         = ""
};

//-----------------------------------------------------------------------------
// SourceMod forwards
//-----------------------------------------------------------------------------

public void OnPluginStart()
{
    // Public version CVAR
    CreateConVar("sm_dvc_version", PLUGIN_VERSION,
        "Vehicle Carmageddon plugin version.",
        FCVAR_NOTIFY | FCVAR_REPLICATED);

    // Private CVARs (no FCVAR_NOTIFY/FCVAR_REPLICATED)
    g_cvKillGoal = CreateConVar(
        "sm_dvc_kill_goal", "10",
        "Number of vehicle kills needed to win.",
        0, true, 1.0, true, 100.0
    );

    g_cvDebug = CreateConVar(
        "sm_dvc_debug", "0",
        "Enable debug logging to chat. 0=off 1=on.",
        0, true, 0.0, true, 1.0
    );

    g_cvFireworksTimeout = CreateConVar(
        "sm_dvc_fireworks_timeout", "10",
        "How long fireworks run after a win (seconds).",
        0, true, 5.0, true, 120.0
    );

    g_cvFireworksSound = CreateConVar(
        "sm_dvc_fireworks_sound", "1",
        "Play sounds with fireworks. 0=off 1=on.",
        0, true, 0.0, true, 1.0
    );

    HookEvent("round_start",       Event_RoundStart);
    HookEvent("dod_round_start",   Event_RoundStart); // Fires between rounds on same map
    HookEvent("player_death",      Event_PlayerDeath, EventHookMode_Post);
    HookEvent("dod_round_win",     Event_RoundEnd);

    AutoExecConfig(true, "dod_vech_carma");

    // Hook clients already in-game (mid-round load)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            OnClientPutInServer(i);
    }

    // Start game immediately if loaded mid-round (guard against double-fire)
    if (!g_bStartPending)
    {
        g_bStartPending = true;
        CreateTimer(START_DELAY, Timer_StartGame, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnMapStart()
{
    g_bMapRecordSet       = false;
    g_fMapBestTime        = 0.0;
    g_sMapRecordHolder[0] = '\0';
    g_bStartPending       = false;

    // Timers with TIMER_FLAG_NO_MAPCHANGE are auto-freed by SourceMod on map change.
    // Null these here so StopGame does not attempt to delete an already-freed handle.
    g_hScoreboardTimer = null;
    g_hFireworksTimer  = null;

    for (int i = 0; i < sizeof(g_sModels); i++)
        g_ExplosionSprite[i] = PrecacheModel(g_sModels[i]);

    for (int i = 0; i < sizeof(g_sSounds); i++)
        PrecacheSound(g_sSounds[i], true);

    g_iPositionCount      = 0;
    g_fFireworksFrequency = FIREWORKS_FREQUENCY;
    CreateTimer(0.1, Timer_FindPositions, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
    StopFireworks();
}

public void OnClientPutInServer(int client)
{
    g_iPlayerKills[client]       = 0;
    g_fMenuSuppressUntil[client] = 0.0;
}

public void OnClientDisconnect(int client)
{
    g_iPlayerKills[client]       = 0;
    g_fMenuSuppressUntil[client] = 0.0;
}

//-----------------------------------------------------------------------------
// Kill tracking
//-----------------------------------------------------------------------------

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bGameRunning)
        return;

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    // Human player died - deduct 1 kill (floor at 0)
    if (IsValidHumanClient(victim))
    {
        if (g_iPlayerKills[victim] > 0)
        {
            g_iPlayerKills[victim]--;

            char victimName[MAX_NAME_LENGTH];
            GetClientName(victim, victimName, sizeof(victimName));
            PrintToChatAll("\x01\x04[Carma]\x01 %s was killed! -1 kill (%d remaining)",
                victimName, g_iPlayerKills[victim]);

            UpdateScoreboards();
        }
        return;
    }

    // Bot victim - check for vehicle kill by a human
    if (!IsValidBotClient(victim) || !IsValidHumanClient(attacker) || attacker == victim)
        return;

    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));

    if (g_cvDebug.BoolValue)
        PrintToChatAll("[DBG] player_death: victim=%d attacker=%d weapon=%s", victim, attacker, weapon);

    if (!StrEqual(weapon, "prop_vehicle_driveable"))
        return;

    g_iPlayerKills[attacker]++;

    char attackerName[MAX_NAME_LENGTH];
    GetClientName(attacker, attackerName, sizeof(attackerName));

    int killGoal = g_cvKillGoal.IntValue;

    PrintToChatAll("\x01\x04[Carma]\x01 %s | %d / %d kills",
        attackerName, g_iPlayerKills[attacker], killGoal);

    if (g_iPlayerKills[attacker] >= killGoal)
    {
        EndGame(attacker);
        return;
    }

    UpdateScoreboards();
}

//-----------------------------------------------------------------------------
// Round events
//-----------------------------------------------------------------------------

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    StopGame();
    StopFireworks();
    ResetAllKills();

    if (!g_bStartPending)
    {
        g_bStartPending = true;
        CreateTimer(START_DELAY, Timer_StartGame, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bGameRunning)
        return;

    int leader = GetLeader();
    if (leader != -1)
    {
        char leaderName[MAX_NAME_LENGTH];
        GetClientName(leader, leaderName, sizeof(leaderName));
        PrintToChatAll("\x01\x04[Carma]\x01 Round ended. Leader: %s with %d kills.",
            leaderName, g_iPlayerKills[leader]);
    }
    else
    {
        PrintToChatAll("\x01\x04[Carma]\x01 Round ended. No vehicle kills registered.");
    }

    StopGame();
}

public Action Timer_StartGame(Handle timer)
{
    g_bStartPending   = false;
    g_bGameRunning    = true;
    g_fRoundStartTime = GetGameTime();

    PrintToChatAll("\x01\x04[Carma]\x01 Game on! First to %d vehicle kills wins!",
        g_cvKillGoal.IntValue);

    g_hScoreboardTimer = CreateTimer(BOARD_INTERVAL, Timer_Scoreboard, _,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    UpdateScoreboards();
    return Plugin_Stop;
}

public Action Timer_Scoreboard(Handle timer)
{
    UpdateScoreboards();
    return Plugin_Continue;
}

//-----------------------------------------------------------------------------
// Win condition
//-----------------------------------------------------------------------------

void EndGame(int winner)
{
    g_bGameRunning = false;
    if (g_hScoreboardTimer != null)
    {
        delete g_hScoreboardTimer;
        g_hScoreboardTimer = null;
    }

    float elapsed = GetGameTime() - g_fRoundStartTime;

    char winnerName[MAX_NAME_LENGTH];
    GetClientName(winner, winnerName, sizeof(winnerName));

    char timeStr[32];
    FormatElapsed(elapsed, timeStr, sizeof(timeStr));

    bool newRecord = !g_bMapRecordSet || elapsed < g_fMapBestTime;
    if (newRecord)
    {
        g_fMapBestTime  = elapsed;
        g_bMapRecordSet = true;
        strcopy(g_sMapRecordHolder, sizeof(g_sMapRecordHolder), winnerName);
    }

    char bestTimeStr[32];
    FormatElapsed(g_fMapBestTime, bestTimeStr, sizeof(bestTimeStr));

    PrintToChatAll("\x01\x04[Carma]\x01 %s wins! %d kills in %s",
        winnerName, g_cvKillGoal.IntValue, timeStr);

    if (newRecord)
        PrintToChatAll("\x01\x04[Carma]\x01 New map record: %s", timeStr);
    else
        PrintToChatAll("\x01\x04[Carma]\x01 Map record: %s by %s",
            bestTimeStr, g_sMapRecordHolder);

    LogCarmageddonWinner(winner);
    StartFireworks();

    // Restart the DoDS round once fireworks finish so Carmageddon restarts cleanly
    float restartDelay = g_cvFireworksTimeout.FloatValue + 2.0;
    CreateTimer(restartDelay, Timer_RestartRound, _, TIMER_FLAG_NO_MAPCHANGE);

    UpdateScoreboards();
}

public Action Timer_RestartRound(Handle timer)
{
    PrintToChatAll("\x01\x04[Carma]\x01 Restarting round...");
    GameRules_SetPropFloat("m_flRestartRoundTime", GetGameTime() + 5.0);
    return Plugin_Stop;
}

//-----------------------------------------------------------------------------
// HLStatsX logging
//-----------------------------------------------------------------------------

void LogCarmageddonWinner(int client)
{
    char playerName[MAX_NAME_LENGTH];
    char authId[32];
    char teamName[16];

    GetClientName(client, playerName, sizeof(playerName));
    GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

    switch (GetClientTeam(client))
    {
        case 2:  strcopy(teamName, sizeof(teamName), "Allies");
        case 3:  strcopy(teamName, sizeof(teamName), "Axis");
        default: strcopy(teamName, sizeof(teamName), "Unassigned");
    }

    LogToGame("\"%s<%d><%s><%s>\" triggered \"carmageddon_winner\"",
        playerName, GetClientUserId(client), authId, teamName);
}

//-----------------------------------------------------------------------------
// Scoreboard
//-----------------------------------------------------------------------------

void UpdateScoreboards()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidHumanClient(i))
            ShowScoreboard(i);
    }
}

void ShowScoreboard(int client)
{
    // Skip if another menu (admin, vote, etc.) recently replaced ours
    if (GetGameTime() < g_fMenuSuppressUntil[client])
        return;

    int players[MAXPLAYERS];
    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidHumanClient(i))
            players[count++] = i;
    }

    // Bubble sort descending by kills
    for (int i = 0; i < count - 1; i++)
    {
        for (int j = 0; j < count - i - 1; j++)
        {
            if (g_iPlayerKills[players[j]] < g_iPlayerKills[players[j + 1]])
            {
                int tmp        = players[j];
                players[j]     = players[j + 1];
                players[j + 1] = tmp;
            }
        }
    }

    int   killGoal = g_cvKillGoal.IntValue;
    float elapsed  = g_bGameRunning ? GetGameTime() - g_fRoundStartTime : 0.0;

    char timeStr[32];
    FormatElapsed(elapsed, timeStr, sizeof(timeStr));

    char title[128];
    Format(title, sizeof(title), "= CARMAGEDDON = | Goal: %d | Time: %s", killGoal, timeStr);

    Menu menu = new Menu(Menu_ScoreboardHandler, MENU_ACTIONS_DEFAULT);
    menu.SetTitle(title);

    char line[128];
    char pName[MAX_NAME_LENGTH];

    for (int i = 0; i < count; i++)
    {
        int p = players[i];
        GetClientName(p, pName, sizeof(pName));
        Format(line, sizeof(line), "%s%s: %d kills",
            (p == client) ? "> " : "  ",
            pName, g_iPlayerKills[p]);
        menu.AddItem("", line, ITEMDRAW_DISABLED);
    }

    menu.AddItem("", " ", ITEMDRAW_DISABLED);

    char recordStr[80];
    if (g_bMapRecordSet)
    {
        char bestTimeStr[32];
        FormatElapsed(g_fMapBestTime, bestTimeStr, sizeof(bestTimeStr));
        Format(recordStr, sizeof(recordStr), "Record: %s by %s", bestTimeStr, g_sMapRecordHolder);
    }
    else
    {
        Format(recordStr, sizeof(recordStr), "Record: none this map");
    }
    menu.AddItem("", recordStr, ITEMDRAW_DISABLED);

    menu.ExitButton = true;
    menu.Display(client, BOARD_DURATION);
}

public int Menu_ScoreboardHandler(Menu menu, MenuAction action, int param1, int param2)
{
    // Another menu replaced ours while it was still showing - suppress for 15 seconds.
    // BOARD_DURATION < BOARD_INTERVAL ensures self-interruption is not possible,
    // so this only triggers from genuinely external menus (admin, votes, etc.).
    if (action == MenuAction_Cancel && param2 == MenuCancel_Interrupted)
        g_fMenuSuppressUntil[param1] = GetGameTime() + 15.0;

    return 0;
}

//-----------------------------------------------------------------------------
// Fireworks (ported from dod_fireworks by Silent_Water, playboycyberclub)
//-----------------------------------------------------------------------------

public Action Timer_FindPositions(Handle timer)
{
    float cpoint[3];
    int   ent = -1;
    g_iPositionCount = 0;

    while (((ent = FindEntityByClassname(ent, "dod_control_point")) != -1) && g_iPositionCount < 10)
    {
        GetEntPropVector(ent, Prop_Data, "m_vecOrigin", cpoint);
        g_fPositions[g_iPositionCount][0] = cpoint[0];
        g_fPositions[g_iPositionCount][1] = cpoint[1];
        g_fPositions[g_iPositionCount][2] = cpoint[2];
        g_iPositionCount++;
    }

    // Fallback: use spawn points if no control points found
    if (g_iPositionCount == 0)
    {
        ent = -1;
        while (((ent = FindEntityByClassname(ent, "info_player_allies")) != -1) && g_iPositionCount < 5)
        {
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin", cpoint);
            g_fPositions[g_iPositionCount][0] = cpoint[0];
            g_fPositions[g_iPositionCount][1] = cpoint[1];
            g_fPositions[g_iPositionCount][2] = cpoint[2];
            g_iPositionCount++;
        }
        ent = -1;
        while (((ent = FindEntityByClassname(ent, "info_player_axis")) != -1) && g_iPositionCount < 10)
        {
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin", cpoint);
            g_fPositions[g_iPositionCount][0] = cpoint[0];
            g_fPositions[g_iPositionCount][1] = cpoint[1];
            g_fPositions[g_iPositionCount][2] = cpoint[2];
            g_iPositionCount++;
        }
    }

    if (g_iPositionCount < 3)
        g_fFireworksFrequency = 0.2;

    return Plugin_Stop;
}

void StartFireworks()
{
    StopFireworks();
    g_hFireworksTimer = CreateTimer(g_fFireworksFrequency, Timer_FireworksEvent, _,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(g_cvFireworksTimeout.FloatValue, Timer_FireworksTimeout, _,
        TIMER_FLAG_NO_MAPCHANGE);
}

void StopFireworks()
{
    if (g_hFireworksTimer != null)
    {
        delete g_hFireworksTimer;
        g_hFireworksTimer = null;
    }
}

public Action Timer_FireworksTimeout(Handle timer)
{
    StopFireworks();
    return Plugin_Stop;
}

public Action Timer_FireworksEvent(Handle timer)
{
    float rorigin[3];

    rorigin[0] = GetRandomFloat(-400.0, 400.0) * -1.0;
    rorigin[1] = GetRandomFloat(-400.0, 400.0);
    rorigin[2] = GetRandomFloat(-50.0, 50.0);

    if (g_iPositionCount > 0)
    {
        int rpos   = GetRandomInt(0, g_iPositionCount - 1);
        rorigin[0] = g_fPositions[rpos][0] + GetRandomFloat(-300.0, 300.0);
        rorigin[1] = g_fPositions[rpos][1] + GetRandomFloat(-300.0, 300.0);
        rorigin[2] = g_fPositions[rpos][2] + 300.0 + GetRandomFloat(-100.0, 200.0);
    }

    switch (GetRandomInt(0, 2))
    {
        case 0: { FW_Explode(rorigin); FW_Sphere(rorigin); }
        case 1: { FW_Spark(rorigin);   FW_Explode(rorigin); FW_Sphere(rorigin); }
        case 2: { FW_Explode(rorigin); }
    }

    return Plugin_Continue;
}

void FW_Explode(float vec[3])
{
    float normal[3] = {0.0, 0.0, 1.0};
    float scale     = GetRandomFloat(1.0, 12.0);

    if (g_cvFireworksSound.BoolValue)
    {
        int randsnd = GetRandomInt(0, sizeof(g_sSounds) - 1);
        FW_EmitSoundFromOrigin(g_sSounds[randsnd], vec);
    }

    TE_SetupExplosion(vec, g_ExplosionSprite[0], scale, 1, 0, 0, 5000, normal, '-');
    TE_SendToAll();
}

void FW_Spark(float vec[3])
{
    float direction[3] = {0.0, 0.0, 0.0};
    TE_SetupSparks(vec, direction, GetRandomInt(500, 2000), GetRandomInt(2, 10));
    TE_SendToAll();
}

void FW_Sphere(float vec[3])
{
    float rpos[3];
    int   randmod = GetRandomInt(1, sizeof(g_sModels) - 1);
    float radius  = GetRandomFloat(75.0, 125.0);

    for (int i = 0; i < 50; i++)
    {
        float delay  = GetRandomFloat(0.0, 0.5);
        float live   = 2.0 + delay;
        float size   = GetRandomFloat(0.5, 0.7);
        float phi    = GetRandomFloat(0.0, 6.283185);
        float theta  = GetRandomFloat(0.0, 6.283185);
        int   bright = GetRandomInt(128, 255);

        rpos[0] = vec[0] + radius * Sine(phi) * Cosine(theta);
        rpos[1] = vec[1] + radius * Sine(phi) * Sine(theta);
        rpos[2] = vec[2] + radius * Cosine(phi);

        TE_SetupGlowSprite(rpos, g_ExplosionSprite[randmod], live, size, bright);
        TE_SendToAll(delay);
    }
}

void FW_EmitSoundFromOrigin(const char[] sound, const float orig[3])
{
    EmitSoundToAll(sound, SOUND_FROM_WORLD, SNDCHAN_AUTO, SNDLEVEL_NORMAL,
        SND_NOFLAGS, SNDVOL_NORMAL, SNDPITCH_NORMAL, -1, orig, NULL_VECTOR, true, 0.0);
}

//-----------------------------------------------------------------------------
// Helpers
//-----------------------------------------------------------------------------

void StopGame()
{
    g_bGameRunning = false;
    if (g_hScoreboardTimer != null)
    {
        delete g_hScoreboardTimer;
        g_hScoreboardTimer = null;
    }
}

void ResetAllKills()
{
    for (int i = 1; i <= MaxClients; i++)
        g_iPlayerKills[i] = 0;
}

int GetLeader()
{
    int best = -1, bestKills = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidHumanClient(i) && g_iPlayerKills[i] > bestKills)
        {
            bestKills = g_iPlayerKills[i];
            best      = i;
        }
    }
    return best;
}

bool IsValidHumanClient(int client)
{
    return client >= 1 && client <= MaxClients
        && IsClientInGame(client)
        && !IsFakeClient(client);
}

bool IsValidBotClient(int client)
{
    return client >= 1 && client <= MaxClients
        && IsClientInGame(client)
        && IsFakeClient(client);
}

void FormatElapsed(float seconds, char[] buffer, int maxlen)
{
    int total = RoundToFloor(seconds);
    Format(buffer, maxlen, "%02d:%02d", total / 60, total % 60);
}
