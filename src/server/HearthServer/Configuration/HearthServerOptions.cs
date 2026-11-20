namespace HearthServer.Configuration;

public sealed class HearthServerOptions
{
    /// <summary>
    /// When true, the process logs at Debug level (per-request HTTP, A2S query
    /// decisions, RCON auth/dispatch, pidfile probes).
    /// Default false = Information. Can also be enabled via the HEARTH_VERBOSE
    /// env var. Read at startup in Program.ResolveVerbose to set Serilog's
    /// minimum level; this field documents/binds the appsettings.json key.
    /// </summary>
    public bool Verbose { get; set; }

    public string InstanceId { get; set; } = "default";

    /// <summary>
    /// Old name kept on purpose: hearth.db (the snapshot list and audit log) lives in this file's
    /// folder ("data" by default). The key file itself belonged to the unused plugin pipe removed in
    /// v0.1.100; the start removes a leftover hmac.key here (LegacyKeyFiles). Renaming the setting
    /// would move every server's snapshot list.
    /// </summary>
    public string HmacKeyPath { get; set; } = "data/hmac.key";

    public int GameplayPort { get; set; } = 27015;

    public int ControlPort { get; set; } = 27016;

    public int QueryPort { get; set; } = 27017;

    public int RconPort { get; set; } = 27018;

    /// <summary>
    /// HTTP API port. Used by the launcher to list/upload/download/restore
    /// snapshots and to fetch instance metadata. Requests are signed with
    /// HMAC-SHA256 under a key derived from <see cref="RconPassword"/>.
    /// </summary>
    public int HttpPort { get; set; } = 27019;

    /// <summary>
    /// Maximum upload size for snapshot import / restore. Bellwright worlds
    /// are typically &lt; 200 MB; cap at 2 GB by default to reject malformed
    /// or hostile uploads without exhausting RAM.
    /// </summary>
    public long MaxUploadBytes { get; set; } = 2L * 1024 * 1024 * 1024;

    /// <summary>
    /// What a world zip (restore, import, migrate) may unpack to, checked before the game is stopped and before
    /// anything is written: all entries together, the number of entries, any one entry, and the free space the
    /// unpack must leave on the disk. A small zip can unpack to far more than its upload size. A real Bellwright
    /// save folder is far below these (the largest seen in November 2026 was under 100 MB zipped, a few dozen
    /// files); 4 GB is twice <see cref="MaxUploadBytes"/>.
    /// </summary>
    public long MaxRestoreUnpackedBytes { get; set; } = 4L * 1024 * 1024 * 1024;

    /// <summary>See <see cref="MaxRestoreUnpackedBytes"/>.</summary>
    public int MaxRestoreEntries { get; set; } = 10_000;

    /// <summary>See <see cref="MaxRestoreUnpackedBytes"/>.</summary>
    public long MaxRestoreEntryBytes { get; set; } = 2L * 1024 * 1024 * 1024;

    /// <summary>See <see cref="MaxRestoreUnpackedBytes"/>. 0 turns the free-space check off.</summary>
    public long RestoreFreeSpaceFloorBytes { get; set; } = 2L * 1024 * 1024 * 1024;

    /// <summary>
    /// Room for stored world backups in <see cref="SaveDir"/> (backups taken here, the copy each restore takes
    /// first, and uploads): the newest <see cref="MaxSnapshotsKept"/> are kept while they fit in
    /// <see cref="MaxSnapshotBytes"/> together, counted from the newest, and older ones are removed. 30 days
    /// still removes any. The newest one, and one a restore is reading, are always kept. 0 turns that limit
    /// off. Applied after every backup, upload and restore.
    /// </summary>
    public int MaxSnapshotsKept { get; set; } = 20;

    /// <summary>See <see cref="MaxSnapshotsKept"/>.</summary>
    public long MaxSnapshotBytes { get; set; } = 4L * 1024 * 1024 * 1024;

    public string RconPassword { get; set; } = "";

    /// <summary>
    /// The join password (2026-11-02). Empty = open server. When set, a player gets in only if their Hearth app sends
    /// it with the join (the app asks for it when the server query says the server is passworded). HearthServer writes
    /// its salted hash to data/join-gate.txt on every start (JoinGateFileService); the bw_ident host mod refuses a join
    /// without it inside the game's own login check, before the player gets a character. Spaces around it are ignored.
    /// Also sets the A2S "password required" flag. Takes effect at the next start.
    /// </summary>
    public string JoinPassword { get; set; } = "";

    /// <summary>
    /// LEGACY name for <see cref="JoinPassword"/>, read only when JoinPassword is empty (an older config that set it
    /// keeps its password). Nothing else reads it: the HearthAuth.lua gate it was meant for was never built.
    /// </summary>
    public string HearthAuthPassword { get; set; } = "";

    public string ServerName { get; set; } = "";

    public string GameInstallRoot { get; set; } = @"C:\Hearth\game";

    /// <summary>
    /// Optional direct path to the Bellwright executable. Leave empty to
    /// auto-detect supported Steam/Epic Win64 and Xbox WinGDK layouts under
    /// <see cref="GameInstallRoot"/>.
    /// </summary>
    public string GameExecutablePath { get; set; } = "";

    public string GameUserDir { get; set; } = @"C:\Hearth\userdir";

    public string SaveDir { get; set; } = @"C:\Hearth\saves";

    /// <summary>
    /// Optional path for the Bellwright login identity cache consumed by
    /// bw_host.lua. Empty writes login-identities.tsv next to HearthServer.exe.
    /// </summary>
    public string LoginIdentityCachePath { get; set; } = "";

    /// <summary>
    /// Optional path to a single-line file containing the PID of the game
    /// process this HearthServer instance owns. Used by KillGame as a
    /// fallback when neither <see cref="GameInstallRoot"/> nor a command-line
    /// scope exists (e.g. panel-managed deploys where the panel's
    /// PowerShell owns the game's lifecycle and writes Logs\game.pid). The pid
    /// is always validated against the game process-name whitelist before
    /// kill — a recycled OS PID owned by an unrelated process will not
    /// be touched. Empty disables the pid-file kill path.
    /// </summary>
    public string GamePidFile { get; set; } = "";

    /// <summary>
    /// Slot count reported via A2S. The session UI labels lobbies as 1/4, so
    /// 4 is the natural default — anything higher and the in-game host UI
    /// reports a slot count that doesn't match what HearthServer hands out.
    /// </summary>
    public int MaxPlayers { get; set; } = 4;

    /// <summary>
    /// Steam64 IDs allowed to use Bellwright's host-only gameplay settings.
    /// The host overlay validates each ID again before granting authority.
    /// </summary>
    public List<string> AdminSteamIds { get; set; } = [];

    /// <summary>
    /// Server-local registry of short-lived, one-use admin join tickets.
    /// HearthServer writes it after RCON-authenticated launcher requests;
    /// the UE4SS host overlay consumes it while admitting the matching
    /// Steam64 identity. Keep this outside customer saves.
    /// </summary>
    public string AdminJoinTicketPath { get; set; } = "data/admin-join-tickets.tsv";

    /// <summary>
    /// Take a snapshot zip of the SaveGames dir into <see cref="SaveDir"/>
    /// on every auto-save (via FileSystemWatcher). Useful for self-hosters
    /// who want a rollback option. Hosting providers that run their own
    /// backup chain should set this to false to avoid disk churn — a
    /// 1-per-minute snapshot rate produces ~1500 zips and ~1 GB per
    /// instance per day.
    /// </summary>
    public bool SnapshotsEnabled { get; set; } = true;

    /// <summary>
    /// Mod manifest published at GET /api/v1/manifest. Hosters list the mods
    /// they require, recommend, or forbid; the launcher reads this on join
    /// and installs/offers/warns accordingly. Spec: protocol/manifest-v1.md.
    /// </summary>
    public ModsOptions Mods { get; set; } = new();

    /// <summary>
    /// A returning player's character follows their Steam account (HearthIdentity host mod). The app asks
    /// POST /api/v1/identity/token with a Steam session ticket; once Steam has checked it, HearthServer signs a
    /// short-lived token the join carries, and the host mod points that Steam ID at the first computer id recorded
    /// for it in the identity folder.
    /// </summary>
    public IdentityOptions Identity { get; set; } = new();
}

public sealed class IdentityOptions
{
    /// <summary>Master switch for the token route and the Steam-to-first-computer map.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Folder for token.key and steam-map.tsv, relative to HearthServer's folder unless rooted.</summary>
    public string Directory { get; set; } = "data/identity";

    /// <summary>
    /// The Steam API library used for the anonymous Steam game-server login that checks tickets. Empty = the game's own
    /// copy beside HearthServer (in Engine\Binaries\ThirdParty\Steamworks\Steamv161\Win64).
    /// </summary>
    public string SteamApiPath { get; set; } = "";

    /// <summary>
    /// steamclient64.dll for the game-server login (a Steam game server needs it; Valve's Steamworks redistributable,
    /// app 1007, anonymous SteamCMD, has it with tier0_s64 and vstdlib_s64 beside it). The file or the folder holding it; a
    /// host sets this. Empty, or no file there = Steam checks stay off and players keep the character of the computer they
    /// join from; no other folder is searched (not HearthServer's own, not an installed Steam client's).
    /// All three files must be signed by Valve and are loaded only by full path (SteamLibraryGuard). When HearthServer
    /// runs with administrator rights, the folder and the files must also be ones only administrators can change, or
    /// Steam checks stay off.
    /// </summary>
    public string SteamClientPath { get; set; } = "";

    /// <summary>Bellwright's Steam app id; tickets are checked for this app.</summary>
    public uint SteamAppId { get; set; } = 1812450;

    /// <summary>How long a signed join token stays valid (the host mod refuses anything over 600).</summary>
    public int TokenLifetimeSeconds { get; set; } = 600;

    /// <summary>Token requests allowed per source address per minute.</summary>
    public int MaxTokenRequestsPerMinute { get; set; } = 6;

    /// <summary>How long to wait for Steam's answer on one ticket.</summary>
    public int SteamCheckTimeoutSeconds { get; set; } = 15;
}

public sealed class ModsOptions
{
    public List<ModEntry> Required { get; set; } = new();
    public List<ModEntry> Recommended { get; set; } = new();
    public List<BlockedModEntry> Blocked { get; set; } = new();
}

public sealed class ModEntry
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Version { get; set; } = "";
    public string Url { get; set; } = "";
    public string? Sha256 { get; set; }
    public long? SizeBytes { get; set; }
    public string InstallRoot { get; set; } = "";
    public string? Notes { get; set; }
}

public sealed class BlockedModEntry
{
    public string Id { get; set; } = "";
    public string Reason { get; set; } = "";
}

