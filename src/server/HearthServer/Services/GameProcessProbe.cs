using System;
using System.Diagnostics;
using System.IO;

namespace HearthServer.Services;

/// <summary>
/// Reports whether the Bellwright game process named in <c>GamePidFile</c> is alive.
/// This alone decides "online" for A2S, RCON status and <c>/api/v1/health</c>.
/// Validates the process NAME (not just the PID) to defend against
/// PID reuse: a recycled PID belonging to some unrelated process must not read as online.
/// </summary>
public static class GameProcessProbe
{
    // Matches BellwrightGame-Win64-Shipping(.exe); ProcessName has no extension.
    private const string ExeNameFragment = "BellwrightGame";

    public static bool IsAlive(string? pidFile)
    {
        if (string.IsNullOrWhiteSpace(pidFile))
        {
            Serilog.Log.Debug("GameProcessProbe: no pidfile configured -> not alive");
            return false;
        }
        try
        {
            if (!File.Exists(pidFile))
            {
                Serilog.Log.Debug("GameProcessProbe: pidfile missing {PidFile} -> not alive", pidFile);
                return false;
            }
            var raw = File.ReadAllText(pidFile).Trim();
            if (!int.TryParse(raw, out var pid) || pid <= 0)
            {
                Serilog.Log.Debug("GameProcessProbe: pidfile {PidFile} content '{Raw}' not a valid pid -> not alive", pidFile, raw);
                return false;
            }

            using var p = Process.GetProcessById(pid);
            if (p.HasExited)
            {
                Serilog.Log.Debug("GameProcessProbe: pid {Pid} has exited -> not alive", pid);
                return false;
            }
            var name = p.ProcessName;
            var match = name.IndexOf(ExeNameFragment, StringComparison.OrdinalIgnoreCase) >= 0;
            Serilog.Log.Debug("GameProcessProbe: pid {Pid} name='{Name}' nameMatch={Match} -> {Alive}",
                pid, name, match, match);
            return match;
        }
        catch (Exception ex)
        {
            // GetProcessById throws if the PID isn't running; any read/race error = not alive.
            Serilog.Log.Debug("GameProcessProbe: probe of {PidFile} failed ({Ex}) -> not alive", pidFile, ex.GetType().Name);
            return false;
        }
    }
}
