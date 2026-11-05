using System.Diagnostics;
using HearthServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// Watches plugin heartbeats. If we haven't heard from the plugin in
/// <see cref="HearthServerOptions.PluginHeartbeatTimeoutSeconds"/>, log a warning;
/// future work hooks process supervision into this to restart the Bellwright instance.
///
/// Password enforcement model (2026-11-02):
///   The join password (Hearth:JoinPassword) is enforced by the bw_ident host
///   mod inside the game's own login check, from data/join-gate.txt (see
///   JoinGateFileService); this watchdog never stops the game over it. The
///   native Hearth.dll ApproveLogin path stays disabled (see
///   HearthProcessSupervisorService.EmitPluginConfig): EmitPluginConfig always
///   emits an empty ServerPassword to plugin-config.json.
///
///   The legacy <see cref="CheckServerPasswordReady"/> path is kept as a
///   defensive bug-detector: if the plugin EVER reports
///   ServerPasswordConfigured=1, something has gone wrong upstream (a
///   stale plugin-config.json carrying a non-empty ServerPassword from an
///   earlier deploy, or a manually-edited plugin config). In that
///   case the native and Lua paths could race and reproduce the Bellwright
///   crash loop, so we kill the game loudly with a CRITICAL log rather than
///   let a customer hit it. The expected steady-state is
///   Configured=0 + HookReady=0 across standard installations.
/// </summary>
public sealed class HeartbeatWatchdogService : BackgroundService
{
    private readonly ILogger<HeartbeatWatchdogService> _log;
    private readonly PipeServerState _state;
    private readonly HearthRestartCoordinator _coordinator;
    private readonly HearthServerOptions _opts;
    private readonly TimeSpan _timeout;

    // Grace period after we first see the plugin connect before we'll
    // start fail-closing. The plugin's bootstrap thread installs the
    // ApproveLogin hook AFTER the pipe handshake, so the first few
    // heartbeats can legitimately report hook-not-ready while the
    // bootstrap is still racing.
    private static readonly TimeSpan AuthGraceWindow = TimeSpan.FromSeconds(20);

    // Throttle for the "configured but native gate down" warning so we
    // don't spam the log every ~10s while waiting on the supervisor.
    private DateTimeOffset _lastFailClosedWarnAt = DateTimeOffset.MinValue;

    public HeartbeatWatchdogService(
        ILogger<HeartbeatWatchdogService> log,
        PipeServerState state,
        HearthRestartCoordinator coordinator,
        IOptions<HearthServerOptions> options)
    {
        _log = log;
        _state = state;
        _coordinator = coordinator;
        _opts = options.Value;
        _timeout = TimeSpan.FromSeconds(options.Value.PluginHeartbeatTimeoutSeconds);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var period = TimeSpan.FromSeconds(Math.Max(1, _timeout.TotalSeconds / 3));
        using var timer = new PeriodicTimer(period);
        while (await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false))
        {
            try
            {
                CheckHeartbeatStale();
                CheckServerPasswordReady();
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "HeartbeatWatchdog tick error");
            }
        }
    }

    // The HearthAuth.lua fail-closed killer that stood here (CheckHearthAuthLuaReady) is gone (2026-11-02). It waited for
    // a Lua gate and a Hearth.dll pipe connection that the Bellwright host never had, so with HearthAuthPassword set it
    // would have stopped the game through the pid file about 3 minutes after every start (the panel never set it, which
    // is why the Lock Password reached nothing). The join password is now
    // enforced inside the game's own login check by the bw_ident host mod (HearthIdentity.dll) from
    // data/join-gate.txt, which JoinGateFileService writes; a refusal there never stops the server.

    private static readonly string[] HearthKillProcessNameWhitelist = new[]
    {
        // Process names are sometimes case-insensitive on Windows;
        // Process.ProcessName has no .exe suffix. The plugin is loaded
        // into the Bellwright binary.
        "BellwrightGame-Win64-Shipping",
    };

    private void TryKillByPluginPid(int pid)
    {
        if (pid <= 0) return;
        try
        {
            using var p = Process.GetProcessById(pid);
            if (p.HasExited) return;

            // PID-reuse guard. Hearth.dll is loaded into the game process,
            // so the PluginPid reported on handshake must belong to one
            // of the game binaries. If the PID was recycled between the
            // handshake and the kill, the new owner's process name will
            // not match the game whitelist; refusing to kill prevents us
            // from terminating an unrelated user process. Case-insensitive
            // because Windows process names round-trip case unpredictably.
            var name = p.ProcessName ?? "";
            var isWhitelistedG2 = false;
            foreach (var allowed in HearthKillProcessNameWhitelist)
            {
                if (string.Equals(name, allowed, StringComparison.OrdinalIgnoreCase))
                {
                    isWhitelistedG2 = true;
                    break;
                }
            }
            if (!isWhitelistedG2)
            {
                _log.LogWarning(
                    "FAIL-CLOSED (Lua): PluginPid={Pid} now belongs to '{Name}' (not Bellwright); refusing to kill",
                    pid, name);
                return;
            }

            _log.LogWarning("FAIL-CLOSED (Lua): killing Bellwright plugin host pid={Pid} name={Name} via PluginPid path", pid, name);
            p.Kill(entireProcessTree: false);
        }
        catch (ArgumentException)
        {
            // pid no longer exists — race with normal supervisor exit
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "FAIL-CLOSED (Lua): KillByPluginPid({Pid}) failed", pid);
        }
    }

    // Tracks the last staleness state we logged so we emit one line on each
    // transition (fresh -> stale, stale -> fresh) rather than spamming every tick.
    private bool _heartbeatStale;

    private void CheckHeartbeatStale()
    {
        var conn = _state.Connection;
        if (conn is null) return;
        var last = _state.LastHeartbeatAt;
        if (last is null) return;
        var age = DateTimeOffset.UtcNow - last.Value;
        var stale = age > _timeout;

        _log.LogDebug("Heartbeat: instance={Instance} pid={Pid} age={Age}s stale={Stale}",
            conn.InstanceId, conn.PluginPid, (int)age.TotalSeconds, stale);

        if (stale && !_heartbeatStale)
        {
            _log.LogWarning("Plugin heartbeat went STALE: instance={Instance} pid={Pid} age={Age}s",
                conn.InstanceId, conn.PluginPid, (int)age.TotalSeconds);
        }
        else if (!stale && _heartbeatStale)
        {
            _log.LogInformation("Plugin heartbeat RECOVERED: instance={Instance} pid={Pid} age={Age}s",
                conn.InstanceId, conn.PluginPid, (int)age.TotalSeconds);
        }
        else if (stale)
        {
            // Keep the original per-tick warning as a Debug heartbeat-still-stale
            // line so verbose logs retain the continuous signal.
            _log.LogDebug("Plugin heartbeat still stale: instance={Instance} pid={Pid} age={Age}s",
                conn.InstanceId, conn.PluginPid, (int)age.TotalSeconds);
        }

        _heartbeatStale = stale;
    }

    private void CheckServerPasswordReady()
    {
        // Steady-state under the Lua-only enforcement model is
        // ServerPasswordConfigured=0 across standard installations. The native
        // ApproveLogin hook is intentionally disabled (plugin-config.json
        // always has an empty ServerPassword), so if the plugin EVER
        // reports Configured=1, something upstream is broken and we
        // could be heading for the Bellwright crash loop that necessitated
        // the pivot to Lua-only enforcement in the first place. Treat that
        // as a fail-closed condition.
        var conn = _state.Connection;
        if (conn is null) return;

        // Wait for the bootstrap-grace window after first contact. The
        // plugin's bootstrap thread populates the heartbeat fields
        // shortly after the handshake; first heartbeat or two can race.
        var sinceConnect = DateTimeOffset.UtcNow - conn.ConnectedAt;
        if (sinceConnect < AuthGraceWindow) return;

        // Plugin reporting Configured=0 is the expected steady state.
        // Nothing to do.
        if (_state.LastServerPasswordConfigured == 0) return;

        // Plugin says "I see ServerPassword in plugin-config.json." Under
        // the Lua-only model this should be impossible — EmitPluginConfig
        // hardcodes ServerPassword="". A non-zero value here means a stale
        // config from a previous deploy, a manually-edited plugin-config.json,
        // or a Hearth update that regressed EmitPluginConfig. Stop the game
        // before native + Lua enforcement layers race into the crash.
        var now = DateTimeOffset.UtcNow;
        var sinceWarn = now - _lastFailClosedWarnAt;
        if (sinceWarn > TimeSpan.FromSeconds(15))
        {
            _log.LogCritical(
                "FAIL-CLOSED: native plugin reported ServerPasswordConfigured={Configured} " +
                "hookReady={Ready}, but Hearth enforces password in HearthAuth.lua only " +
                "and emits an empty ServerPassword in plugin-config.json. This usually means a " +
                "stale plugin-config.json from an earlier deploy or a manually-edited config. " +
                "Stopping Bellwright to prevent the native gate from racing with the Lua gate " +
                "(which reproduces the Bellwright fatal crash loop). Fix plugin-config.json " +
                "ServerPassword field to empty and restart.",
                _state.LastServerPasswordConfigured, _state.LastServerPasswordHookReady);
            _lastFailClosedWarnAt = now;
        }

        // Kill the game. Path-scoped KillGame covers standalone deploys (where
        // GameInstallRoot is configured); PluginPid-based kill covers
        // panel-managed deploys (where GameInstallRoot is intentionally
        // empty and KillGame logs "no anchor to scope by"). The IPC
        // handshake gives us the exact game PID — Hearth.dll calls
        // GetCurrentProcessId() inside the game process when sending
        // handshake.
        try
        {
            _coordinator.KillGame(TimeSpan.FromSeconds(10));
            TryKillByPluginPid(conn.PluginPid);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "FAIL-CLOSED: KillGame / KillByPluginPid threw");
        }
    }
}
