using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;

namespace AuditLogDemo.Services;

/// <summary>
/// Audit event categories.
///
/// These mirror the processing-operation categories that UK data protection law
/// requires be logged for law-enforcement processing (Data Protection Act 2018
/// section 62, implementing Article 25 of the Law Enforcement Directive):
/// collection, alteration, consultation, disclosure, combination and erasure,
/// plus the logon and logoff events the same provision requires.
///
/// They are a reasonable default for any system that has to answer "who touched
/// this record, when, and what did they do to it" after the fact. Replace them
/// with whatever taxonomy your own obligations call for - nothing else in the
/// pipeline depends on these particular names.
/// </summary>
public enum AuditEventType
{
    Consultation,
    Combination,
    Alteration,
    Erasure,
    Login,
    Logout
}

/// <summary>
/// Security event categories. Unlike the audit events above these are not
/// prescribed by anything; they are the set a typical line-of-business API ends
/// up caring about.
/// </summary>
public enum SecurityEventType
{
    HighRiskOperationInvolved,
    SuspiciousInputDetected,
    AuthDenied,
    HighVolumeDataAccess,
    BusinessRuleViolation,
    SuspiciousSlowRequest,
    UnexpectedHttpMethod,
    InternalError
}

public enum TelemetrySeverity
{
    Low,
    Medium,
    High,
    Critical
}

public enum TelemetryOutcome
{
    Succeeded,
    Blocked
}

/// <summary>
/// Emits audit and security events as Application Insights custom events.
///
/// Custom events land in the AppEvents table in Log Analytics, which is a
/// standard table and therefore supported by Data Export. That is the whole
/// reason this uses TrackEvent rather than ILogger or a bespoke sink: it is the
/// shortest path from application code to a table that can be exported into
/// immutable storage, and it needs no ingestion endpoint of its own.
///
/// The properties written here become the columns you query later, so treat the
/// names as an interface. Renaming one breaks every saved query and detection
/// built on top of it, including anything already written into the archive under
/// the old name.
/// </summary>
public class TelemetryService
{
    private readonly TelemetryClient _telemetryClient;

    public TelemetryService(TelemetryClient telemetryClient)
    {
        _telemetryClient = telemetryClient;
    }

    public void TrackAuditEvent(
        HttpContext context,
        AuditEventType eventName,
        TelemetrySeverity severity,
        TelemetryOutcome outcome,
        IDictionary<string, string>? additionalProps = null)
        => Track(context, eventName.ToString(), "AuditEvent", severity, outcome, additionalProps);

    public void TrackSecurityEvent(
        HttpContext context,
        SecurityEventType eventName,
        TelemetrySeverity severity,
        TelemetryOutcome outcome,
        IDictionary<string, string>? additionalProps = null)
        => Track(context, eventName.ToString(), "SecurityEvent", severity, outcome, additionalProps);

    private void Track(
        HttpContext context,
        string eventName,
        string categoryFlag,
        TelemetrySeverity severity,
        TelemetryOutcome outcome,
        IDictionary<string, string>? additionalProps)
    {
        var evt = new EventTelemetry(eventName);

        // A discriminator rather than a shared "Category" column, so a KQL
        // filter can be a cheap existence check on the property bag.
        evt.Properties[categoryFlag] = "true";
        evt.Properties["Severity"] = severity.ToString();
        evt.Properties["Outcome"] = outcome.ToString();
        evt.Properties["Path"] = context.Request.Path;
        evt.Properties["Method"] = context.Request.Method;
        evt.Properties["StatusCode"] = context.Response.StatusCode.ToString();

        // Note this writes the signed-in principal to Properties["UserId"], not
        // to the built-in UserId column on AppEvents. That column holds the
        // SDK's anonymous per-session identifier and is not the person - a query
        // that reaches for the obvious column gets the wrong answer.
        if (context.User?.Identity?.IsAuthenticated == true)
        {
            evt.Properties["UserId"] = context.User.Identity.Name ?? "Unknown";
        }

        if (additionalProps != null)
        {
            foreach (var kvp in additionalProps)
            {
                evt.Properties[kvp.Key] = kvp.Value;
            }
        }

        _telemetryClient.TrackEvent(evt);

        // Critical events are flushed rather than left to the batching channel,
        // which holds telemetry for up to 30 seconds. If the process is about to
        // be terminated - which is often exactly why the event is critical - an
        // unflushed buffer is lost, and a missing record is indistinguishable
        // from an event that never happened.
        if (severity == TelemetrySeverity.Critical)
        {
            _telemetryClient.Flush();
        }
    }
}
