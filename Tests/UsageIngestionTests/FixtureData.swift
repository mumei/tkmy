import Foundation

enum FixtureData {
    static let codexSession = Data(
        """
        {"timestamp":"2026-08-01T01:02:03.000Z","type":"session_meta","payload":{"id":"codex-session-1"}}
        {"timestamp":"2026-08-01T01:03:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5","total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2}}}}
        not-json
        {"timestamp":"2026-08-01T01:04:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":20,"reasoning_output_tokens":5}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1786168800},"secondary":null}}}

        """.utf8
    )

    static let claudeSession = Data(
        """
        {"type":"assistant","timestamp":"2026-08-02T02:00:00.000Z","sessionId":"claude-session-1","requestId":"request-1","costUSD":"0.001234","message":{"id":"msg-1","model":"claude-opus-4-1","usage":{"input_tokens":40,"output_tokens":8,"cache_read_input_tokens":10,"cache_creation_input_tokens":6}}}
        {"type":"assistant","timestamp":"2026-08-02T02:00:00.000Z","sessionId":"claude-session-1","requestId":"request-1","costUSD":"0.001234","message":{"id":"msg-1","model":"claude-opus-4-1","usage":{"input_tokens":40,"output_tokens":8,"cache_read_input_tokens":10,"cache_creation_input_tokens":6}}}
        {"type":"assistant","timestamp":"2026-08-02T02:01:00Z","sessionId":"claude-session-1","requestId":"request-2","isSidechain":true,"message":{"id":"msg-1","model":"claude-opus-4-1","usage":{"input_tokens":5,"output_tokens":2,"cache_creation":{"ephemeral_5m_input_tokens":3,"ephemeral_1h_input_tokens":4}}}}

        """.utf8
    )
}
