// FerryDesk dashboard session reporting.
//
// Notifies the FerryDesk backend when an outgoing remote-desktop session
// starts and ends so the web dashboard can show live connection state. Like
// the heartbeat, calls are anonymous, fire-and-forget, and best-effort —
// failures log at debug level and never bubble up.
//
// Only the initiator side reports (this client connecting *out* to a peer).
// The receiving end (incoming connections, handled in `src/server/connection.rs`)
// does not, to avoid double-counting.

use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use hbb_common::{
    config::{Config, LocalConfig},
    log,
    tokio::{self, runtime::Runtime, sync::oneshot},
};

const START_URL: &str = "https://ferrydesk.com/api/sessions/start";
const END_URL: &str = "https://ferrydesk.com/api/sessions/end";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const ACCESS_TOKEN_KEY: &str = "ferrydesk_access_token";
// Read fallback so a user logged in on the pre-rebrand Callmor build keeps
// their session. New tokens are always written to the FerryDesk key.
const LEGACY_ACCESS_TOKEN_KEY: &str = "callmor_access_token";

fn auth_header() -> Option<String> {
    let t = LocalConfig::get_option(ACCESS_TOKEN_KEY);
    if !t.is_empty() {
        return Some(t);
    }
    let legacy = LocalConfig::get_option(LEGACY_ACCESS_TOKEN_KEY);
    if legacy.is_empty() { None } else { Some(legacy) }
}

fn http_client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .unwrap_or_else(|_| reqwest::Client::new())
    })
}

// One shared runtime for all callmor-session work, lazily created on first
// call. Reusing it (rather than spawning a fresh runtime per request) keeps
// overhead negligible and lets callers fire from sync FFI context where no
// ambient tokio runtime exists.
fn rt() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .thread_name("callmor-sessions")
            .build()
            .expect("callmor_sessions: failed to build runtime")
    })
}

/// Fire `POST /api/sessions/start` in the background.
///
/// Resolves to `Some(session_id)` on 201, or `None` if the call failed, the
/// server returned 204 (relay session — already tracked by hbbr), or input
/// validation rejected the call (empty / self-loop ids).
pub fn report_start(target_id: String) -> oneshot::Receiver<Option<String>> {
    let (tx, rx) = oneshot::channel();
    let initiator_id = Config::get_id();
    if initiator_id.is_empty() || target_id.is_empty() || initiator_id == target_id {
        let _ = tx.send(None);
        return rx;
    }
    rt().spawn(async move {
        let body = serde_json::json!({
            "initiator_rustdesk_id": initiator_id,
            "target_rustdesk_id": target_id,
        });
        let mut req = http_client().post(START_URL).json(&body);
        if let Some(t) = auth_header() {
            req = req.bearer_auth(&t);
        }
        let session_id = match req.send().await {
            Ok(resp) => {
                let status = resp.status();
                if status == reqwest::StatusCode::CREATED {
                    match resp.json::<serde_json::Value>().await {
                        Ok(v) => v
                            .get("session_id")
                            .and_then(|s| s.as_str())
                            .map(|s| s.to_string()),
                        Err(e) => {
                            log::debug!("callmor sessions: parse /start body failed: {e}");
                            None
                        }
                    }
                } else {
                    if status != reqwest::StatusCode::NO_CONTENT {
                        log::debug!("callmor sessions: /start HTTP {status}");
                    }
                    None
                }
            }
            Err(e) => {
                log::debug!("callmor sessions: /start failed: {e}");
                None
            }
        };
        let _ = tx.send(session_id);
    });
    rx
}

/// Fire-and-forget `POST /api/sessions/end`. Never blocks the caller.
pub fn report_end(session_id: String) {
    if session_id.is_empty() {
        return;
    }
    rt().spawn(async move {
        let body = serde_json::json!({ "session_id": session_id });
        let mut req = http_client().post(END_URL).json(&body);
        if let Some(t) = auth_header() {
            req = req.bearer_auth(&t);
        }
        if let Err(e) = req.send().await {
            log::debug!("callmor sessions: /end failed: {e}");
        }
    });
}

/// Convenience wrapper: kick off `report_start` and write the resolved
/// session_id into `slot` when the server replies. Used by the session
/// lifecycle hooks so the close path can read the slot synchronously.
pub fn report_start_into_slot(target_id: String, slot: Arc<Mutex<Option<String>>>) {
    let rx = report_start(target_id);
    rt().spawn(async move {
        if let Ok(Some(sid)) = rx.await {
            if let Ok(mut s) = slot.lock() {
                *s = Some(sid);
            }
        }
    });
}
