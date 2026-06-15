using HearthServer.Configuration;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

public sealed class InstanceIdentityProvider
{
    private readonly HearthServerOptions _options;

    public InstanceIdentityProvider(IOptions<HearthServerOptions> options)
    {
        _options = options.Value;
    }

    public string InstanceId => _options.InstanceId;

    public string PipeName => _options.PipeName;

    public int GameplayPort => _options.GameplayPort;
    public int ControlPort => _options.ControlPort;
    public int QueryPort => _options.QueryPort;
    public int RconPort => _options.RconPort;
}
