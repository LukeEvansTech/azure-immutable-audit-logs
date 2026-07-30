using System.Security.Claims;
using AuditLogDemo.Services;
using Microsoft.ApplicationInsights.AspNetCore.Extensions;

var builder = WebApplication.CreateBuilder(args);

// Adaptive sampling is ON by default in this SDK. It must not be, here.
//
// Sampling discards a proportion of telemetry under load and scales the
// surviving records' ItemCount to keep aggregate metrics roughly right. That is
// the correct trade-off for performance monitoring and the wrong one for an
// audit trail: the archive stops being a complete account of what the
// application did, and no amount of care at query time can recover a record that
// was never sent. An incomplete audit archive that is believed to be complete is
// worse than no archive.
//
// If you raise event volume enough to care about ingestion cost, reduce what you
// emit deliberately rather than letting sampling choose for you.
builder.Services.AddApplicationInsightsTelemetry(new ApplicationInsightsServiceOptions
{
    EnableAdaptiveSampling = false
});

builder.Services.AddSingleton<TelemetryService>();

var app = builder.Build();

// App Service Easy Auth terminates authentication at the platform edge and
// forwards the signed-in principal in a header. Promoting it to
// context.User here is what puts a real user identity on every event; without
// it the events are correct but anonymous, which makes them much less useful
// after the fact.
//
// This trusts the header, which is only safe because Easy Auth strips
// client-supplied copies of it before the request reaches the app. Do not
// replicate this pattern behind a proxy that does not do the same.
app.Use(async (context, next) =>
{
    var principalName = context.Request.Headers["X-MS-CLIENT-PRINCIPAL-NAME"].FirstOrDefault();
    if (!string.IsNullOrEmpty(principalName))
    {
        var claims = new[] { new Claim(ClaimTypes.Name, principalName) };
        context.User = new ClaimsPrincipal(new ClaimsIdentity(claims, "EasyAuth"));
    }

    await next();
});

// Plausible request coordinates per event type, so the generated events look
// like traffic rather than noise. Callers can override any of them.
var defaultPaths = new Dictionary<string, (string Path, string Method, string StatusCode)>
{
    ["Login"] = ("/api/auth/login", "POST", "200"),
    ["Logout"] = ("/api/auth/logout", "POST", "200"),
    ["Consultation"] = ("/api/records/view", "GET", "200"),
    ["Combination"] = ("/api/records/merge", "POST", "200"),
    ["Alteration"] = ("/api/records/update", "PUT", "200"),
    ["Erasure"] = ("/api/records/delete", "DELETE", "200"),
    ["AuthDenied"] = ("/api/admin/access", "GET", "401"),
    ["SuspiciousInputDetected"] = ("/api/records/search", "POST", "400"),
    ["HighRiskOperationInvolved"] = ("/api/admin/config", "PUT", "200"),
    ["HighVolumeDataAccess"] = ("/api/records/export", "GET", "200"),
    ["BusinessRuleViolation"] = ("/api/records/update", "PUT", "422"),
    ["SuspiciousSlowRequest"] = ("/api/records/report", "GET", "200"),
    ["UnexpectedHttpMethod"] = ("/api/records/view", "DELETE", "405"),
    ["InternalError"] = ("/api/records/process", "POST", "500"),
};

const string SampleException =
    "System.Net.WebException: No connection could be made because the target machine actively refused it.";

(string Path, string Method, string StatusCode) LookupDefaults(string eventType) =>
    defaultPaths.TryGetValue(eventType, out var val) ? val : ("/api/unknown", "GET", "200");

Dictionary<string, string> BuildProps(string eventType, string? path, string? method, string? statusCode)
{
    var defaults = LookupDefaults(eventType);
    return new Dictionary<string, string>
    {
        ["AspNetCoreEnvironment"] = app.Environment.EnvironmentName,
        ["Path"] = path ?? defaults.Path,
        ["Method"] = method ?? defaults.Method,
        ["StatusCode"] = statusCode ?? defaults.StatusCode,
    };
}

app.UseHttpsRedirection();
app.UseDefaultFiles();
app.UseStaticFiles();

// Liveness probe. Emits no telemetry, on purpose: App Service polls it
// continuously, and a health check in the audit archive is pure noise.
app.MapGet("/healthz", () => Results.Ok(new { status = "healthy" }));

// Send a single audit event.
app.MapPost("/api/events/audit", (HttpContext context, TelemetryService telemetry, AuditEventRequest req) =>
{
    if (!Enum.TryParse<AuditEventType>(req.EventType, ignoreCase: true, out var eventType))
        return Results.BadRequest(new { error = $"Invalid EventType '{req.EventType}'. Valid values: {string.Join(", ", Enum.GetNames<AuditEventType>())}" });
    if (!Enum.TryParse<TelemetrySeverity>(req.Severity, ignoreCase: true, out var severity))
        return Results.BadRequest(new { error = $"Invalid Severity '{req.Severity}'. Valid values: {string.Join(", ", Enum.GetNames<TelemetrySeverity>())}" });
    if (!Enum.TryParse<TelemetryOutcome>(req.Outcome, ignoreCase: true, out var outcome))
        return Results.BadRequest(new { error = $"Invalid Outcome '{req.Outcome}'. Valid values: {string.Join(", ", Enum.GetNames<TelemetryOutcome>())}" });

    var props = BuildProps(eventType.ToString(), req.Path, req.Method, req.StatusCode);

    if (req.Properties != null)
    {
        foreach (var kvp in req.Properties)
            props[kvp.Key] = kvp.Value;
    }

    telemetry.TrackAuditEvent(context, eventType, severity, outcome, props);
    return Results.Ok(new { success = true, eventType = eventType.ToString(), timestamp = DateTime.UtcNow.ToString("o") });
});

// Send a single security event.
app.MapPost("/api/events/security", (HttpContext context, TelemetryService telemetry, SecurityEventRequest req) =>
{
    if (!Enum.TryParse<SecurityEventType>(req.EventType, ignoreCase: true, out var eventType))
        return Results.BadRequest(new { error = $"Invalid EventType '{req.EventType}'. Valid values: {string.Join(", ", Enum.GetNames<SecurityEventType>())}" });
    if (!Enum.TryParse<TelemetrySeverity>(req.Severity, ignoreCase: true, out var severity))
        return Results.BadRequest(new { error = $"Invalid Severity '{req.Severity}'. Valid values: {string.Join(", ", Enum.GetNames<TelemetrySeverity>())}" });
    if (!Enum.TryParse<TelemetryOutcome>(req.Outcome, ignoreCase: true, out var outcome))
        return Results.BadRequest(new { error = $"Invalid Outcome '{req.Outcome}'. Valid values: {string.Join(", ", Enum.GetNames<TelemetryOutcome>())}" });

    var props = BuildProps(eventType.ToString(), req.Path, req.Method, req.StatusCode);

    if (eventType == SecurityEventType.InternalError)
        props["Exception"] = SampleException;

    if (eventType == SecurityEventType.SuspiciousSlowRequest)
        props["DurationMs"] = Random.Shared.Next(2001, 15000).ToString();

    if (req.Properties != null)
    {
        foreach (var kvp in req.Properties)
            props[kvp.Key] = kvp.Value;
    }

    telemetry.TrackSecurityEvent(context, eventType, severity, outcome, props);
    return Results.Ok(new { success = true, eventType = eventType.ToString(), timestamp = DateTime.UtcNow.ToString("o") });
});

// Generate a mixed batch, weighted 60/40 audit to security.
app.MapPost("/api/events/bulk", (HttpContext context, TelemetryService telemetry, BulkRequest req) =>
{
    var count = Math.Clamp(req.Count, 1, 100);

    var auditEvents = Enum.GetValues<AuditEventType>();
    var securityEvents = Enum.GetValues<SecurityEventType>();
    var severities = Enum.GetValues<TelemetrySeverity>();
    var outcomes = Enum.GetValues<TelemetryOutcome>();

    var auditCount = (int)Math.Round(count * 0.6);
    var securityCount = count - auditCount;

    for (var i = 0; i < auditCount; i++)
    {
        var eventName = auditEvents[Random.Shared.Next(auditEvents.Length)];
        var props = BuildProps(eventName.ToString(), null, null, null);

        if (Random.Shared.NextDouble() > 0.7)
            props["DurationMs"] = Random.Shared.Next(50, 5000).ToString();

        telemetry.TrackAuditEvent(
            context,
            eventName,
            severities[Random.Shared.Next(severities.Length)],
            outcomes[Random.Shared.Next(outcomes.Length)],
            props);
    }

    for (var i = 0; i < securityCount; i++)
    {
        var eventName = securityEvents[Random.Shared.Next(securityEvents.Length)];
        var props = BuildProps(eventName.ToString(), null, null, null);

        if (eventName == SecurityEventType.InternalError)
            props["Exception"] = SampleException;

        if (eventName == SecurityEventType.SuspiciousSlowRequest)
            props["DurationMs"] = Random.Shared.Next(2001, 15000).ToString();

        telemetry.TrackSecurityEvent(
            context,
            eventName,
            severities[Random.Shared.Next(severities.Length)],
            outcomes[Random.Shared.Next(outcomes.Length)],
            props);
    }

    return Results.Ok(new
    {
        success = true,
        count,
        audit = auditCount,
        security = securityCount,
        timestamp = DateTime.UtcNow.ToString("o")
    });
});

app.Run();

record AuditEventRequest(
    string EventType,
    string Severity,
    string Outcome,
    string? Path = null,
    string? Method = null,
    string? StatusCode = null,
    Dictionary<string, string>? Properties = null);

record SecurityEventRequest(
    string EventType,
    string Severity,
    string Outcome,
    string? Path = null,
    string? Method = null,
    string? StatusCode = null,
    Dictionary<string, string>? Properties = null);

record BulkRequest(int Count = 25);
