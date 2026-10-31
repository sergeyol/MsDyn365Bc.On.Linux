// Stub for Microsoft.AspNetCore.Server.HttpSys — redirects to Kestrel on Linux.
// BC calls: builder.UseHttpSys(configure) then builder.UseUrls("http://+:7048/BC/api")
// We redirect to Kestrel and use an IStartupFilter to strip URL paths at app startup.
using System;
using System.Linq;
using System.Security.Claims;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;

namespace Microsoft.AspNetCore.Server.HttpSys
{
    public class HttpSysOptions
    {
        public bool AllowSynchronousIO { get; set; }
        public long? MaxConnections { get; set; }
        public int MaxAccepts { get; set; }
        public long? MaxRequestBodySize { get; set; }
        public AuthenticationManager Authentication { get; } = new AuthenticationManager();
        public TimeoutManager Timeouts { get; } = new TimeoutManager();
        public bool ThrowWriteExceptions { get; set; }
        public int RequestQueueLimit { get; set; }
        public string? RequestQueueName { get; set; }
        public bool UnsafePreferInlineScheduling { get; set; }
    }

    public class AuthenticationManager
    {
        public bool AllowAnonymous { get; set; } = true;
        public AuthenticationSchemes Schemes { get; set; } = AuthenticationSchemes.None;
        public bool AutomaticAuthentication { get; set; }
    }

    public class TimeoutManager
    {
        public TimeSpan IdleConnection { get; set; }
        public TimeSpan EntityBody { get; set; }
        public TimeSpan DrainEntityBody { get; set; }
        public TimeSpan RequestQueue { get; set; }
        public TimeSpan HeaderWait { get; set; }
        public long MinSendBytesPerSecond { get; set; }
    }

    [Flags]
    public enum AuthenticationSchemes
    {
        None = 0, Basic = 1, Anonymous = 2, NTLM = 4, Negotiate = 8, Kerberos = 16,
    }
}

namespace Microsoft.AspNetCore.Hosting
{
    public static class WebHostBuilderHttpSysExtensions
    {
        private static readonly System.Collections.Generic.HashSet<int> _boundPorts = new();

        public static IWebHostBuilder UseHttpSys(this IWebHostBuilder builder,
            Action<Microsoft.AspNetCore.Server.HttpSys.HttpSysOptions> configure)
        {
            var opts = new Microsoft.AspNetCore.Server.HttpSys.HttpSysOptions();
            configure?.Invoke(opts);

            builder.UseKestrel(k =>
            {
                k.AllowSynchronousIO = opts.AllowSynchronousIO;
                if (opts.MaxRequestBodySize.HasValue)
                    k.Limits.MaxRequestBodySize = opts.MaxRequestBodySize;
            });

            builder.ConfigureServices(services =>
            {
                services.AddSingleton<IStartupFilter>(new UrlStrippingStartupFilter(_boundPorts));
            });

            return builder;
        }

        public static IWebHostBuilder UseHttpSys(this IWebHostBuilder builder)
        {
            return builder.UseKestrel();
        }
    }

    /// <summary>
    /// Startup filter that:
    /// 1. Strips URL paths from server addresses (Kestrel can't handle path-based URLs)
    /// 2. Adds UsePathBase() so BC's middleware routes correctly
    /// 3. Sets admin identity on every request (bypasses auth for all endpoints)
    /// </summary>
    internal class UrlStrippingStartupFilter : IStartupFilter
    {
        private readonly System.Collections.Generic.HashSet<int> _boundPorts;

        public UrlStrippingStartupFilter(System.Collections.Generic.HashSet<int> boundPorts)
        {
            _boundPorts = boundPorts;
        }

        public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next)
        {
            return app =>
            {
                // Strip paths from server addresses before the server starts
                var addressFeature = app.ServerFeatures.Get<IServerAddressesFeature>();
                string? pathBase = null;
                if (addressFeature != null && addressFeature.Addresses.Count > 0)
                {
                    var original = addressFeature.Addresses.ToList();
                    addressFeature.Addresses.Clear();
                    foreach (var addr in original)
                    {
                        var (stripped, path) = StripPath(addr);
                        if (stripped != null)
                        {
                            addressFeature.Addresses.Add(stripped);
                            if (!string.IsNullOrEmpty(path))
                                pathBase = path;
                            Console.WriteLine($"[HttpSysStub] {addr} → {stripped}");
                        }
                    }
                }

                if (!string.IsNullOrEmpty(pathBase))
                    app.UsePathBase(pathBase);

                // Behind a reverse proxy that rewrites Host (GitHub Codespaces sends
                // "Host: localhost:<port>" and the browser-facing name only in
                // X-Forwarded-Host), BC builds its redirects and resource links from the
                // wrong host and scheme. BC_WEBCLIENT_TRUST_FORWARDED_HEADERS=1 applies
                // X-Forwarded-Host / X-Forwarded-Proto before BC's own pipeline runs.
                // Off by default: only turn it on when a proxy you control sets them.
                if (Environment.GetEnvironmentVariable("BC_WEBCLIENT_TRUST_FORWARDED_HEADERS") == "1")
                {
                    app.Use(async (context, nextMiddleware) =>
                    {
                        var origHost = context.Request.Host.Value;
                        var fwdHost = context.Request.Headers["X-Forwarded-Host"].ToString().Split(',')[0].Trim();
                        if (fwdHost.Length > 0)
                            context.Request.Host = new HostString(fwdHost);
                        var fwdProto = context.Request.Headers["X-Forwarded-Proto"].ToString().Split(',')[0].Trim();
                        if (fwdProto == "http" || fwdProto == "https")
                            context.Request.Scheme = fwdProto;
                        // The same proxy rewrites the host of Origin to match the rewritten Host
                        // (Origin: http://localhost:<port> or https://localhost:<port>: it keeps
                        // the browser's scheme, which differs between tunnel clusters). BC compares
                        // Origin with the request's own origin on POSTs and WebSocket upgrades and
                        // rejects a mismatch (400 / 403), so translate it the same way: when
                        // Origin names the original host, whatever the scheme, replace it.
                        if (Uri.TryCreate(context.Request.Headers["Origin"].ToString(), UriKind.Absolute, out var origin)
                            && string.Equals(origin.Authority, origHost, StringComparison.OrdinalIgnoreCase))
                            context.Request.Headers["Origin"] = $"{context.Request.Scheme}://{context.Request.Host.Value}";
                        await nextMiddleware();
                    });
                }

                // Set authenticated admin identity on every request.
                // HTTPSYS_STUB_INJECT_IDENTITY=0 disables this for processes that
                // run their own authentication (e.g. the self-hosted web client,
                // whose forms sign-in must not see a pre-authenticated principal).
                if (Environment.GetEnvironmentVariable("HTTPSYS_STUB_INJECT_IDENTITY") != "0")
                {
                    app.Use(async (context, nextMiddleware) =>
                    {
                        var identity = new ClaimsIdentity(new[] {
                            new Claim(ClaimTypes.Name, "admin"),
                            new Claim(ClaimTypes.Role, "SUPER"),
                            new Claim(ClaimTypes.Role, "AdminService"),
                            new Claim(ClaimTypes.NameIdentifier, "00000000-0000-0000-0000-000000000001"),
                        }, "Passthrough");
                        context.User = new ClaimsPrincipal(identity);
                        await nextMiddleware();
                    });
                }

                next(app);
            };
        }

        private (string? address, string? pathBase) StripPath(string url)
        {
            try
            {
                var parsed = url.Replace("://+:", "://localhost:").Replace("://*:", "://localhost:");
                var uri = new Uri(parsed);
                var scheme = url.Substring(0, url.IndexOf("://"));
                var host = url.Contains("://+:") ? "+" : url.Contains("://*:") ? "*" : uri.Host;
                var port = uri.Port;
                var path = uri.AbsolutePath.TrimEnd('/');

                lock (_boundPorts)
                {
                    if (!_boundPorts.Add(port))
                        while (!_boundPorts.Add(++port)) { }
                }
                return ($"{scheme}://{host}:{port}", string.IsNullOrEmpty(path) || path == "/" ? null : path);
            }
            catch
            {
                return (url, null);
            }
        }
    }
}
