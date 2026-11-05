using System.Security.Cryptography;
using System.Text;
using HearthServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// The join password's file for the bw_ident host mod (src/native/Hearth.Identity, JoinGateCore). On every start it
/// writes data/join-gate.txt: "open" when no password is set, otherwise "v1 " and the lowercase hex SHA-256 of
/// "hearth-join-v1\n" + the trimmed password (the same digest the host mod computes from the password the app sends;
/// both sides test the same vectors). The plain password is never written there. The file is replaced in one step, so
/// the host mod never reads half of it, and it is always written, so an old password never lingers.
/// </summary>
public sealed class JoinGateFileService : IHostedService
{
    internal const string DigestPrefix = "hearth-join-v1\n";
    internal const string FileName = "join-gate.txt";

    // PHP's trim() set (what a PHP host writing appsettings.json strips): space, tab, LF, CR, NUL, vertical tab.
    private static readonly char[] TrimChars = { ' ', '\t', '\n', '\r', '\0', '\v' };

    private readonly HearthServerOptions _opts;
    private readonly ILogger<JoinGateFileService> _log;
    private readonly string _dataDir;

    public JoinGateFileService(IOptions<HearthServerOptions> options, ILogger<JoinGateFileService> log)
        : this(options.Value, log, Path.Combine(AppContext.BaseDirectory, "data"))
    {
    }

    internal JoinGateFileService(HearthServerOptions opts, ILogger<JoinGateFileService> log, string dataDir)
    {
        _opts = opts;
        _log = log;
        _dataDir = dataDir;
    }

    /// <summary>The password in force: JoinPassword, else the legacy HearthAuthPassword; trimmed; "" = open.</summary>
    public static string EffectivePassword(HearthServerOptions opts)
    {
        var join = (opts.JoinPassword ?? "").Trim(TrimChars);
        return join.Length > 0 ? join : (opts.HearthAuthPassword ?? "").Trim(TrimChars);
    }

    public static bool PasswordRequired(HearthServerOptions opts) => EffectivePassword(opts).Length > 0;

    public static string Digest(string password) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(DigestPrefix + password.Trim(TrimChars)))).ToLowerInvariant();

    public static string FileText(HearthServerOptions opts)
    {
        var password = EffectivePassword(opts);
        return password.Length == 0 ? "open\n" : "v1 " + Digest(password) + "\n";
    }

    public string FilePath => Path.Combine(_dataDir, FileName);

    public Task StartAsync(CancellationToken cancellationToken)
    {
        // Retried briefly: a host mod reading the old file can hold it for a moment. If it still fails, the old file
        // stays (and says so in the log); the host mod refuses every join when the file it reads makes no sense.
        Exception? last = null;
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Write();
                _log.LogInformation("Join password: {State} ({File})",
                    PasswordRequired(_opts) ? "ON, players need it to join" : "off, open server", FilePath);
                return Task.CompletedTask;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                last = ex;
                Thread.Sleep(200);
            }
        }
        _log.LogError(last, "Join password: could not write {File}; the host mod keeps the last file it read", FilePath);
        return Task.CompletedTask;
    }

    internal void Write()
    {
        Directory.CreateDirectory(_dataDir);
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, FileText(_opts), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        File.Move(tmp, FilePath, overwrite: true);
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
