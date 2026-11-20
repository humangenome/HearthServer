using Dapper;
using Microsoft.Data.Sqlite;

namespace Hearth.Persistence;

/// <summary>
/// SQLite WAL store for Hearth's operational state. Owns its connection string;
/// callers do not hold connections — every method opens a short-lived one. WAL
/// mode + autovacuum + sane synchronous settings are applied at first open.
///
/// Tables:
///   save_snapshots — record of save backups taken
///   audit_log      — snapshot and restore actions, who asked and when
///
/// The players, bans and join_tickets tables of the first version were never
/// written by anything (admin join tickets live in their own file, see
/// AdminJoinTicketService) and were removed in v0.1.100. Old database files
/// keep those empty tables; nothing reads them.
/// </summary>
public sealed class HearthDb
{
    private readonly string _connectionString;

    public HearthDb(string filePath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(filePath))!);
        _connectionString = $"Data Source={filePath};Cache=Shared;Pooling=True";
        EnsureSchema();
    }

    private SqliteConnection Open()
    {
        var c = new SqliteConnection(_connectionString);
        c.Open();
        return c;
    }

    private void EnsureSchema()
    {
        using var c = Open();
        c.Execute("PRAGMA journal_mode=WAL;");
        c.Execute("PRAGMA synchronous=NORMAL;");
        c.Execute("PRAGMA foreign_keys=ON;");
        c.Execute("""
            CREATE TABLE IF NOT EXISTS save_snapshots (
                snapshot_id      TEXT PRIMARY KEY,
                taken_unix       INTEGER NOT NULL,
                file_path        TEXT NOT NULL,
                size_bytes       INTEGER NOT NULL,
                sha256_hex       TEXT NOT NULL,
                retention_days   INTEGER NOT NULL
            );
            """);
        c.Execute("""
            CREATE TABLE IF NOT EXISTS audit_log (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                ts_unix          INTEGER NOT NULL,
                actor            TEXT NOT NULL,
                action           TEXT NOT NULL,
                target           TEXT,
                detail_json      TEXT
            );
            CREATE INDEX IF NOT EXISTS audit_ts_idx ON audit_log (ts_unix DESC);
            """);
    }

    // ── Save Snapshots ────────────────────────────────────────────────────

    public void RecordSnapshot(SnapshotRecord s)
    {
        using var c = Open();
        c.Execute("""
            INSERT INTO save_snapshots (snapshot_id, taken_unix, file_path, size_bytes, sha256_hex, retention_days)
            VALUES (@SnapshotId, @TakenUnix, @FilePath, @SizeBytes, @Sha256Hex, @RetentionDays);
            """, s);
    }

    public IReadOnlyList<SnapshotRecord> ListSnapshots(int limit = 30)
    {
        using var c = Open();
        return c.Query<SnapshotRecord>("""
            SELECT snapshot_id AS SnapshotId, taken_unix AS TakenUnix, file_path AS FilePath,
                   size_bytes AS SizeBytes, sha256_hex AS Sha256Hex, retention_days AS RetentionDays
            FROM save_snapshots ORDER BY taken_unix DESC LIMIT @lim
            """, new { lim = limit }).ToList();
    }

    /// <summary>Remove a snapshot's row (its zip was removed, or was already gone).</summary>
    public void DeleteSnapshot(string snapshotId)
    {
        using var c = Open();
        c.Execute("DELETE FROM save_snapshots WHERE snapshot_id = @id;", new { id = snapshotId });
    }

    // ── Audit ─────────────────────────────────────────────────────────────

    public void Audit(string actor, string action, string? target, string? detailJson, long unixSeconds)
    {
        using var c = Open();
        c.Execute("""
            INSERT INTO audit_log (ts_unix, actor, action, target, detail_json)
            VALUES (@ts, @actor, @action, @target, @detail);
            """, new { ts = unixSeconds, actor, action, target, detail = detailJson });
    }

    public IReadOnlyList<AuditEntry> RecentAudit(int limit = 50)
    {
        using var c = Open();
        return c.Query<AuditEntry>("""
            SELECT id AS Id, ts_unix AS TsUnix, actor AS Actor, action AS Action,
                   target AS Target, detail_json AS DetailJson
            FROM audit_log ORDER BY ts_unix DESC LIMIT @lim
            """, new { lim = limit }).ToList();
    }
}

public sealed record SnapshotRecord(string SnapshotId, long TakenUnix, string FilePath, long SizeBytes, string Sha256Hex, long RetentionDays);

public sealed record AuditEntry(long Id, long TsUnix, string Actor, string Action, string? Target, string? DetailJson);
