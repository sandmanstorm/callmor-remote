// FerryDesk dashboard presence heartbeat.
//
// Posts the local rustdesk ID to the FerryDesk backend every 30s so the user
// dashboard shows the machine as online in real time. The endpoint is
// unauthenticated by design — it accepts any rustdesk_id and silently does
// nothing for IDs that aren't registered to a dashboard user (returns 404).
//
// Failures are non-fatal and logged at debug level. The loop keeps running for
// the lifetime of the process.

use std::time::Duration;

use hbb_common::{
    config::{Config, LocalConfig},
    log,
    tokio::{self, time::sleep},
};

const HEARTBEAT_URL: &str = "https://ferrydesk.com/api/machines/heartbeat";
const INTERVAL: Duration = Duration::from_secs(30);
const STARTUP_DELAY: Duration = Duration::from_secs(5);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const ACCESS_TOKEN_KEY: &str = "callmor_access_token";
const USER_JSON_KEY: &str = "callmor_user_json";

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
                let body = serde_json::json!({ "rustdesk_id": id });
                let mut req = client.post(HEARTBEAT_URL).json(&body);
                let token = LocalConfig::get_option(ACCESS_TOKEN_KEY);
                if !token.is_empty() {
                    req = req.bearer_auth(&token);
                }
                match req.send().await {
                    Ok(resp) => {
                        let s = resp.status();
                        if s.as_u16() == 401 && !token.is_empty() {
                            // Token rejected by server — clear it so future
                            // calls fall back to anonymous and the UI prompts
                            // for re-login.
                            log::debug!("ferrydesk heartbeat: token rejected, clearing");
                            LocalConfig::set_option(ACCESS_TOKEN_KEY.to_string(), String::new());
                            LocalConfig::set_option(USER_JSON_KEY.to_string(), String::new());
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
