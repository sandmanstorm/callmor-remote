// Machine identity + spec sent to the FerryDesk dashboard on every heartbeat.
//
// Static fields (CPU model, RAM total, hostname, MAC, etc.) are cached on
// first call so we don't pay the gather cost every 30s. Dynamic fields
// (free RAM, uptime, current outbound IP) are re-read each call.
//
// This module is the single source of truth for what an agent reports —
// extending the schema means adding a field here AND on the backend's
// /api/machines/heartbeat handler.

use std::net::UdpSocket;
use std::sync::OnceLock;

use hbb_common::{mac_address, sysinfo::System, whoami};
use serde_json::{json, Value};

/// Map std::env::consts::OS to the dashboard platform enum
/// (win | mac | linux | android | ios).
fn platform_name() -> &'static str {
    match std::env::consts::OS {
        "windows" => "win",
        "macos" => "mac",
        "linux" => "linux",
        "android" => "android",
        "ios" => "ios",
        other => other,
    }
}

struct StaticInfo {
    hostname: String,
    username: String,
    os: &'static str,
    os_version: String,
    arch: &'static str,
    cpu_model: String,
    cpu_mhz: u64,
    cpu_logical: usize,
    cpu_physical: usize,
    ram_total_mb: u64,
    boot_time_unix: u64,
    timezone_offset_minutes: i32,
    primary_mac: String,
}

fn gather_static() -> StaticInfo {
    let mut sys = System::new();
    sys.refresh_memory();
    sys.refresh_cpu();

    let cpus = sys.cpus();
    let cpu_model = cpus
        .first()
        .map(|c| c.brand().trim().to_string())
        .unwrap_or_default();
    let cpu_mhz = cpus.first().map(|c| c.frequency()).unwrap_or(0);

    let mut os_version = sys.long_os_version().unwrap_or_default();
    #[cfg(windows)]
    {
        if let Some(v) = sys.os_version() {
            os_version = format!("{} - {}", os_version, v);
        }
    }

    let primary_mac = mac_address::get_mac_address()
        .ok()
        .flatten()
        .map(|m| m.to_string())
        .unwrap_or_default();

    StaticInfo {
        hostname: whoami::fallible::hostname().unwrap_or_default(),
        username: whoami::username(),
        os: platform_name(),
        os_version,
        arch: std::env::consts::ARCH,
        cpu_model,
        cpu_mhz,
        cpu_logical: num_cpus::get(),
        cpu_physical: num_cpus::get_physical(),
        ram_total_mb: sys.total_memory() / 1024 / 1024,
        boot_time_unix: sys.boot_time(),
        timezone_offset_minutes: chrono::Local::now().offset().local_minus_utc() / 60,
        primary_mac,
    }
}

fn uptime_seconds() -> u64 {
    // boot_time / uptime are instance methods on this fork of sysinfo, but
    // neither requires a refresh — System::new() suffices.
    System::new().uptime()
}

fn static_info() -> &'static StaticInfo {
    static CACHE: OnceLock<StaticInfo> = OnceLock::new();
    CACHE.get_or_init(gather_static)
}

fn ram_free_mb() -> u64 {
    let mut sys = System::new();
    sys.refresh_memory();
    sys.available_memory() / 1024 / 1024
}

/// "Primary" outbound IP — the one the OS would route through to reach the
/// FerryDesk server. Doesn't actually send anything; the connect on a UDP
/// socket just resolves the routing decision.
fn primary_local_ip() -> String {
    let sock = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return String::new(),
    };
    if sock.connect("ferrydesk.com:443").is_err() {
        return String::new();
    }
    sock.local_addr()
        .map(|a| a.ip().to_string())
        .unwrap_or_default()
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn is_installed() -> bool {
    crate::platform::is_installed()
}

#[cfg(any(target_os = "android", target_os = "ios"))]
fn is_installed() -> bool {
    true
}

/// Build the full machine-info payload sent in every heartbeat.
pub fn full_payload(rustdesk_id: &str, agent_version: &str) -> Value {
    let s = static_info();
    json!({
        "rustdesk_id": rustdesk_id,
        "platform": s.os,
        "version": agent_version,
        "hostname": s.hostname,
        "username": s.username,
        "os_version": s.os_version,
        "arch": s.arch,
        "cpu_model": s.cpu_model,
        "cpu_mhz": s.cpu_mhz,
        "cpu_cores": s.cpu_physical,
        "cpu_logical": s.cpu_logical,
        "ram_total_mb": s.ram_total_mb,
        "ram_free_mb": ram_free_mb(),
        "boot_time_unix": s.boot_time_unix,
        "uptime_seconds": uptime_seconds(),
        "timezone_offset_minutes": s.timezone_offset_minutes,
        "primary_mac": s.primary_mac,
        "primary_local_ip": primary_local_ip(),
        "is_installed": is_installed(),
    })
}
