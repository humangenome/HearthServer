using System.Diagnostics;
using HearthServer.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// Runs the bundled Bellwright save guard before launch-sensitive work and after
/// game auto-saves. The guard preserves rich offline player records in a private
/// per-instance ledger and restores records Bellwright drops while players are away.
/// </summary>
public sealed class SaveProtectionService
{
    private readonly ILogger<SaveProtectionService> _log;
    private readonly HearthServerOptions _opts;
    private readonly string _guardPath;
    private readonly string _ledgerDir;

    public SaveProtectionService(
        ILogger<SaveProtectionService> log,
        IOptions<HearthServerOptions> opts)
    {
        _log = log;
        _opts = opts.Value;
        _guardPath = Path.Combine(AppContext.BaseDirectory, "HearthSaveGuard.exe");
        _ledgerDir = Path.Combine(AppContext.BaseDirectory, "data", "player-records");
    }

    public async Task<bool> ProtectCanonicalAsync(CancellationToken ct = default)
    {
        var savePath = CanonicalSavePath();
        if (savePath is null)
        {
            return true;
        }
        if (!File.Exists(_guardPath))
        {
            _log.LogError("Save protection helper is missing; refusing unprotected save work");
            return false;
        }

        Directory.CreateDirectory(_ledgerDir);
        var start = new ProcessStartInfo
        {
            FileName = _guardPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("protect");
        start.ArgumentList.Add("--save");
        start.ArgumentList.Add(savePath);
        start.ArgumentList.Add("--ledger");
        start.ArgumentList.Add(_ledgerDir);

        try
        {
            using var process = Process.Start(start);
            if (process is null)
            {
                _log.LogError("Save protection helper did not start");
                return false;
            }

            var stdoutTask = process.StandardOutput.ReadToEndAsync(ct);
            var stderrTask = process.StandardError.ReadToEndAsync(ct);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                _log.LogError("Save protection helper timed out");
                return false;
            }

            var stdout = (await stdoutTask.ConfigureAwait(false)).Trim();
            var stderr = (await stderrTask.ConfigureAwait(false)).Trim();
            if (process.ExitCode != 0)
            {
                _log.LogError("Save protection failed: {Message}", Bounded(stderr));
                return false;
            }
            _log.LogInformation("Save protection complete: {Result}", Bounded(stdout));
            if (stdout.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Contains("world_restored=1", StringComparer.Ordinal))
            {
                _log.LogWarning(
                    "Bellwright world regression recovered on disk; leaving the already-loaded world online to avoid an autosave restart loop");
            }
            return true;
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Save protection helper failed");
            return false;
        }
    }

    public bool ResetForWorldReplacement()
    {
        var previous = _ledgerDir + ".replaced-" + Guid.NewGuid().ToString("N")[..8];
        var moved = false;
        try
        {
            if (Directory.Exists(_ledgerDir))
            {
                Directory.Move(_ledgerDir, previous);
                moved = true;
            }
            Directory.CreateDirectory(_ledgerDir);
            if (moved)
            {
                try { Directory.Delete(previous, recursive: true); } catch { }
            }
            _log.LogInformation("Save protection state reset for replacement world");
            return true;
        }
        catch (Exception ex)
        {
            try
            {
                if (moved && !Directory.Exists(_ledgerDir) && Directory.Exists(previous))
                {
                    Directory.Move(previous, _ledgerDir);
                }
            }
            catch { }
            _log.LogError(ex, "Save protection state could not be reset for replacement world");
            return false;
        }
    }

    private string? CanonicalSavePath()
    {
        if (string.IsNullOrWhiteSpace(_opts.GameUserDir))
        {
            return null;
        }
        var saveDir = Path.Combine(_opts.GameUserDir, "Saved", "SaveGames");
        var tempAuto = Path.Combine(saveDir, "TEMP_auto.sav");
        if (File.Exists(tempAuto))
        {
            return tempAuto;
        }
        var legacy = Path.Combine(saveDir, "savegame_0.sav");
        return File.Exists(legacy) ? legacy : null;
    }

    private static string Bounded(string value)
    {
        const int max = 300;
        if (string.IsNullOrWhiteSpace(value))
        {
            return "no details";
        }
        value = value.Replace('\r', ' ').Replace('\n', ' ');
        return value.Length <= max ? value : value[..max];
    }
}
