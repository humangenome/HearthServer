using System.Net;
using System.Security.Cryptography;
using System.Text;
using FluentAssertions;
using HearthServer.Services;
using Microsoft.Extensions.Logging;

namespace HearthServer.Tests;

// A route that throws answers 500 with a fixed error, never the exception's text: that text can
// carry a path on the server's machine, and the HTTP door answers anyone (BeaconServer has answered
// "internal error" here since 2026-10-30). The signed body the route was given is still deleted from
// the upload temp folder, so a throw never leaves an upload of up to MaxUploadBytes behind.
// Shares the upload temp folder with the lockout and auth tests, so it never runs beside them.
[Collection("SourceGuard")]
public sealed class HttpErrorReplyTests
{
    private static readonly string UploadTempDir = Path.Combine(Path.GetTempPath(), "hearth-uploads");

    [Fact]
    public async Task A_route_that_throws_answers_a_fixed_error_and_leaves_no_upload_behind()
    {
        var log = new ListLogger<HearthHttpService>();
        await using var h = await HttpLockoutTests.Harness.StartAsync(log);

        // The save folder is a file now, so the upload route's folder step throws an IOException
        // whose message names the path.
        Directory.Delete(h.SaveDir);
        File.WriteAllText(h.SaveDir, "not a folder");

        var body = new byte[4096];
        RandomNumberGenerator.Fill(body);
        var bodySha = HttpLockoutTests.Harness.Sha(body);

        var (status, text) = await SignedWithReplyAsync(h, "POST", "/api/v1/snapshots", body, bodySha);

        status.Should().Be(500);
        text.Should().Be("{\"error\":\"internal error\"}");
        text.Should().NotContain(h.SaveDir).And.NotContain("saves");
        log.Entries.Should().Contain(e => e.Level == LogLevel.Error && e.Text.Contains("POST /api/v1/snapshots threw"),
            "the detail stays in the server's own log");

        // The body was written to the upload temp folder before the route ran; it must not stay there.
        var left = true;
        for (var i = 0; i < 50 && left; i++)
        {
            left = UploadTempHolds(bodySha);
            if (left) await Task.Delay(50);
        }
        left.Should().BeFalse("a route that throws still deletes the signed body it was given");
    }

    private static bool UploadTempHolds(string sha)
    {
        if (!Directory.Exists(UploadTempDir)) return false;
        foreach (var f in Directory.GetFiles(UploadTempDir))
        {
            try
            {
                if (new FileInfo(f).Length != 4096) continue;
                var s = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(f))).ToLowerInvariant();
                if (s == sha) return true;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return false;
    }

    private static async Task<(int Status, string Text)> SignedWithReplyAsync(
        HttpLockoutTests.Harness h, string method, string path, byte[] body, string bodySha)
    {
        var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        using var req = new HttpRequestMessage(new HttpMethod(method), $"http://{IPAddress.Loopback}:{h.Port}{path}");
        req.Headers.Add("X-Hearth-Timestamp", ts.ToString());
        req.Headers.Add("X-Hearth-Signature", HttpLockoutTests.Harness.Sign(HttpLockoutTests.Key, method, path, ts, bodySha));
        req.Content = new ByteArrayContent(body);
        using var resp = await http.SendAsync(req);
        return ((int)resp.StatusCode, Encoding.UTF8.GetString(await resp.Content.ReadAsByteArrayAsync()));
    }
}
