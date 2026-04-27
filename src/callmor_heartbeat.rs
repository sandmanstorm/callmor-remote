// Callmor.ai dashboard presence heartbeat.
//
// Posts the local rustdesk ID to the Callmor.ai backend every 30s so the user
// dashboard shows the machine as online in real time. The endpoint is
// unauthenticated by design — it accepts any rustdesk_id and silently does
// nothing for IDs that aren't registered to a dashboard user (returns 404).
//
// Failures are non-fatal and logged at debug level. The loop keeps running for
// the lifetime of the process.

use std::time::Duration;

use hbb_common::{
    config::Config,
    log,
    tokio::{self, time::sleep},
};

const HEARTBEAT_URL: &str = "https://remote.callmor.ai/api/machines/heartbeat";
const INTERVAL: Duration = Duration::from_secs(30);
const STARTUP_DELAY: Duration = Duration::from_secs(5);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

pub fn start() {
    tokio::spawn(async move {
        sleep(STARTUP_DELAY).await;

        let client = match reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
        {
            Ok(c) => c,
            Err(e) => {
                log::warn!("callmor heartbeat: client build failed: {e}");
                return;
            }
        };

        loop {
            let id = Config::get_id();
            if !id.is_empty() {
                let body = serde_json::json!({ "rustdesk_id": id });
                match client.post(HEARTBEAT_URL).json(&body).send().await {
                    Ok(resp) => {
                        let s = resp.status();
                        if !s.is_success() && s.as_u16() != 404 {
                            log::debug!("callmor heartbeat: HTTP {s}");
                        }
                    }
                    Err(e) => {
                        log::debug!("callmor heartbeat: send failed: {e}");
                    }
                }
            }
            sleep(INTERVAL).await;
        }
    });
}
