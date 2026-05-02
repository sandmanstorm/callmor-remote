// FerryDesk dashboard presence heartbeat.
//
// Posts the local rustdesk ID to the FerryDesk backend every 30s so the user
// dashboard shows the machine as online in real time. The endpoint is
// unauthenticated by design — it accepts any rustdesk_id and silently does
// nothing for IDs that aren't registered to a dashboard user (returns 404).
//
// Failures are non-fatal and logged at debug level. The loop keeps running for
// the lifetime of the process.
//
// Auto-claim on first run: if this process's .exe filename embeds an
// `install_token=...` marker (set by the backend's per-tenant download
// endpoint), POST it to /api/installers/claim before the first heartbeat.
// That registers the machine into the operator's tenant directly instead
// of landing in the bootstrap (Default) tenant. One-shot per token.

use std::time::Duration;

use hbb_common::{
    config::{Config, LocalConfig},
    log,
    tokio::{self, time::sleep},
};

const HEARTBEAT_URL: &str = "https://ferrydesk.com/api/machines/heartbeat";
#[cfg(feature = "paid-host")]
const CLAIM_URL: &str = "https://ferrydesk.com/api/installers/claim";
const INTERVAL: Duration = Duration::from_secs(30);
const STARTUP_DELAY: Duration = Duration::from_secs(5);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const ACCESS_TOKEN_KEY: &str = "ferrydesk_access_token";
const USER_JSON_KEY: &str = "ferrydesk_user_json";
// Pre-rebrand keys — read as fallback so users carrying state from the
// Callmor build keep their session. New writes always go to the FerryDesk
// keys; the legacy keys are only ever cleared.
const LEGACY_ACCESS_TOKEN_KEY: &str = "callmor_access_token";
const LEGACY_USER_JSON_KEY: &str = "callmor_user_json";
// Persist the LAST install_token we successfully claimed (or terminally
// failed against). A boolean flag would block re-installs that ship a
// fresh per-tenant token; storing the token itself lets a re-install
// with a different token re-claim. Empty string ⇒ never claimed.
#[cfg(feature = "paid-host")]
const INSTALL_CLAIMED_TOKEN_KEY: &str = "ferrydesk_install_claimed_token";

fn read_token() -> String {
    let v = LocalConfig::get_option(ACCESS_TOKEN_KEY);
    if !v.is_empty() {
        return v;
    }
    LocalConfig::get_option(LEGACY_ACCESS_TOKEN_KEY)
}

fn clear_session() {
    LocalConfig::set_option(ACCESS_TOKEN_KEY.to_string(), String::new());
    LocalConfig::set_option(USER_JSON_KEY.to_string(), String::new());
    LocalConfig::set_option(LEGACY_ACCESS_TOKEN_KEY.to_string(), String::new());
    LocalConfig::set_option(LEGACY_USER_JSON_KEY.to_string(), String::new());
}

/// Extract the `install_token=...` segment from this process's .exe filename.
/// Mirrors the comma-delimited tokenizer in `custom_server.rs` but runs at
/// runtime against `current_exe()`. Returns "" on any failure or when no
/// install_token marker is present (generic / non-tenanted install).
#[cfg(feature = "paid-host")]
fn read_install_token_from_exe() -> String {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return String::new(),
    };
    let name = match exe.file_name().and_then(|n| n.to_str()) {
        Some(n) => n.to_string(),
        None => return String::new(),
    };
    // Strip .exe / .exe.exe to match the custom_server.rs preprocessing.
    let lower = name.to_lowercase();
    let stem: &str = if lower.ends_with(".exe.exe") {
        &name[..name.len() - 8]
    } else if lower.ends_with(".exe") {
        &name[..name.len() - 4]
    } else {
        &name
    };
    let lower_stem = stem.to_lowercase();
    let needle = "install_token=";
    let start = match lower_stem.find(needle) {
        Some(i) => i + needle.len(),
        None => return String::new(),
    };
    let rest = &stem[start..];
    // Terminator: comma (filename tokenizer convention), or a Windows-
    // rename `(1)` suffix, or whitespace. Be liberal — the install_token
    // we mint server-side is base32/hex so none of these chars appear in
    // a legitimate token.
    let end = rest
        .find(|c: char| c == ',' || c == '(' || c.is_whitespace())
        .unwrap_or(rest.len());
    rest[..end].trim().to_string()
}

/// One-shot per token: POST {install_token, rustdesk_id, platform} to
/// FerryDesk's anonymous claim endpoint, registering the machine into
/// the operator's tenant. Idempotent — won't fire twice for the same
/// token. Stores the claimed token in `LocalConfig` on terminal outcomes
/// (success OR known-bad: 404/409/410) so transient failures retry on
/// the next heartbeat tick.
///
/// On a successful claim, also sets the local RustDesk permanent password
/// from the response body's `permanent_password` field. Without this step,
/// the operator's dashboard knows password X (server-side) while the host's
/// RustDesk accepts only its random session-default → incoming connections
/// from the dashboard get rejected. The backend started echoing the
/// password in the claim response in commit b85e9f9.
#[cfg(feature = "paid-host")]
async fn try_claim_install(client: &reqwest::Client, rustdesk_id: &str) {
    let token = read_install_token_from_exe();
    if token.is_empty() {
        return;
    }
    if LocalConfig::get_option(INSTALL_CLAIMED_TOKEN_KEY) == token {
        return;
    }

    // Reqwest's .json() serializes any Serialize value via the serde_json
    // it already pulls in transitively, so a HashMap<&str, &str> avoids
    // adding a direct serde_json dep just for this body.
    let mut body = std::collections::HashMap::new();
    body.insert("install_token", token.as_str());
    body.insert("rustdesk_id", rustdesk_id);
    body.insert("platform", "win");

    match client.post(CLAIM_URL).json(&body).send().await {
        Ok(resp) => {
            let code = resp.status().as_u16();
            if resp.status().is_success() {
                // Pull the permanent password out of the response and set
                // it locally before marking the token consumed. If the
                // server didn't include one (older backend), we still mark
                // claimed — the dashboard's password reveal endpoint is
                // the manual fallback in that case.
                match resp.json::<serde_json::Value>().await {
                    Ok(body) => {
                        if let Some(pw) =
                            body.get("permanent_password").and_then(|v| v.as_str())
                        {
                            if !pw.is_empty() {
                                if let Err(e) =
                                    crate::ipc::set_permanent_password(pw.to_string())
                                {
                                    log::warn!(
                                        "ferrydesk install claim: set_permanent_password failed: {e}"
                                    );
                                } else {
                                    log::info!(
                                        "ferrydesk install claim: ok, password set"
                                    );
                                }
                            } else {
                                log::info!(
                                    "ferrydesk install claim: ok (server returned empty password)"
                                );
                            }
                        } else {
                            log::info!(
                                "ferrydesk install claim: ok (no password in response — older backend?)"
                            );
                        }
                    }
                    Err(e) => {
                        // Body wasn't JSON or transport error reading it.
                        // Claim itself was 2xx so still mark consumed.
                        log::warn!(
                            "ferrydesk install claim: 2xx but body unreadable: {e}"
                        );
                    }
                }
                LocalConfig::set_option(
                    INSTALL_CLAIMED_TOKEN_KEY.to_string(),
                    token,
                );
            } else if code == 404 || code == 409 || code == 410 {
                // Unknown / already consumed / expired — terminal. Mark
                // so we stop retrying every 30s for the lifetime of the
                // process.
                log::warn!(
                    "ferrydesk install claim: terminal HTTP {code}, not retrying"
                );
                LocalConfig::set_option(
                    INSTALL_CLAIMED_TOKEN_KEY.to_string(),
                    token,
                );
            } else {
                log::debug!("ferrydesk install claim: HTTP {code}, will retry");
            }
        }
        Err(e) => {
            log::debug!("ferrydesk install claim: send failed: {e}");
        }
    }
}

pub fn start() {
    tokio::spawn(async move {
        sleep(STARTUP_DELAY).await;

        let client = match reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
        {
            Ok(c) => c,
            Err(e) => {
                log::warn!("ferrydesk heartbeat: client build failed: {e}");
                return;
            }
        };

        loop {
            let id = Config::get_id();
            if !id.is_empty() {
                // Auto-claim runs *before* the heartbeat — landing the
                // machine in the right tenant from its very first row in
                // the dashboard rather than after a manual transfer. Self-
                // gates via LocalConfig, so this is a near-noop after the
                // first successful claim. Compiled in only for paid-host
                // — paid-operator binaries have no install_token in their
                // filename so this would always early-return anyway.
                #[cfg(feature = "paid-host")]
                try_claim_install(&client, &id).await;

                let body = crate::ferrydesk_machine_info::full_payload(
                    &id,
                    env!("CARGO_PKG_VERSION"),
                );
                let mut req = client.post(HEARTBEAT_URL).json(&body);
                let token = read_token();
                if !token.is_empty() {
                    req = req.bearer_auth(&token);
                }
                match req.send().await {
                    Ok(resp) => {
                        let s = resp.status();
                        if s.as_u16() == 401 && !token.is_empty() {
                            // Token rejected by server — clear it (and the
                            // legacy aliases) so future calls fall back to
                            // anonymous and the UI prompts for re-login.
                            log::debug!("ferrydesk heartbeat: token rejected, clearing");
                            clear_session();
                        } else if !s.is_success() && s.as_u16() != 404 {
                            log::debug!("ferrydesk heartbeat: HTTP {s}");
                        }
                    }
                    Err(e) => {
                        log::debug!("ferrydesk heartbeat: send failed: {e}");
                    }
                }
            }
            sleep(INTERVAL).await;
        }
    });
}
