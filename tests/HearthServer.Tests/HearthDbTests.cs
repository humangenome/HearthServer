using Hearth.Persistence;
using FluentAssertions;
using Xunit;

namespace HearthServer.Tests;

public class HearthDbTests : IDisposable
{
    private readonly string _file;
    private readonly HearthDb _db;

    public HearthDbTests()
    {
        _file = Path.Combine(Path.GetTempPath(), $"hearth-test-{Guid.NewGuid():N}.db");
        _db = new HearthDb(_file);
    }

    public void Dispose()
    {
        try { File.Delete(_file); } catch { }
        try { File.Delete(_file + "-wal"); } catch { }
        try { File.Delete(_file + "-shm"); } catch { }
    }

    [Fact]
    public void Audit_log_round_trip()
    {
        _db.Audit("admin", "rcon.exec", target: null, detailJson: "{\"cmd\":\"status\"}", unixSeconds: 1_000);
        _db.Audit("http-api", "save.snapshot", target: "s1", detailJson: null, unixSeconds: 2_000);

        var entries = _db.RecentAudit(10);
        entries.Should().HaveCount(2);
        entries[0].Action.Should().Be("save.snapshot");
        entries[1].Action.Should().Be("rcon.exec");
    }

    [Fact]
    public void Snapshot_history_orders_newest_first()
    {
        _db.RecordSnapshot(new SnapshotRecord("s1", 1_000, "/saves/s1.zip", 1024, "abc", 30));
        _db.RecordSnapshot(new SnapshotRecord("s2", 2_000, "/saves/s2.zip", 2048, "def", 30));
        var list = _db.ListSnapshots();
        list.Should().HaveCount(2);
        list[0].SnapshotId.Should().Be("s2");
        list[1].SnapshotId.Should().Be("s1");
    }
}
