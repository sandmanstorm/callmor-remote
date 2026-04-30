// On-demand screenshot capture for the FerryDesk chat path.
//
// Captures one frame from the primary display via `scrap`, normalizes the
// pixel format to RGBA, downscales to MAX_WIDTH if needed, JPEG-encodes at
// JPEG_QUALITY, and returns the bytes as a base64 string suitable for
// embedding in a JSON message over the chat WebSocket.
//
// Limitations on Windows when running as a normal user-session process:
//   - UAC consent screens, the lock screen, and the secure-attention sequence
//     render as black. Switching to the SYSTEM service mode would lift this.

use std::io::ErrorKind;
use std::time::{Duration, Instant};

use hbb_common::{anyhow::anyhow, base64::Engine, log, ResultType};
use image::{codecs::jpeg::JpegEncoder, ImageBuffer, RgbaImage};
use scrap::{Capturer, Display, Frame, Pixfmt, TraitCapturer, TraitPixelBuffer};

const MAX_WIDTH: u32 = 1280;
const JPEG_QUALITY: u8 = 60;
const CAPTURE_BUDGET: Duration = Duration::from_millis(1500);

pub fn capture_jpeg_base64() -> ResultType<String> {
    let bytes = capture_jpeg_bytes()?;
    Ok(hbb_common::base64::engine::general_purpose::STANDARD.encode(&bytes))
}

pub fn capture_jpeg_bytes() -> ResultType<Vec<u8>> {
    let display = Display::primary().map_err(|e| anyhow!("primary display: {e}"))?;
    let mut capturer = Capturer::new(display).map_err(|e| anyhow!("capturer: {e}"))?;
    let (rgba, w, h) = grab_frame(&mut capturer)?;
    let img: RgbaImage =
        ImageBuffer::from_raw(w, h, rgba).ok_or_else(|| anyhow!("rgba buffer mismatch"))?;
    let img = if w > MAX_WIDTH {
        let scale = MAX_WIDTH as f32 / w as f32;
        let nw = MAX_WIDTH;
        let nh = (h as f32 * scale).round().max(1.0) as u32;
        image::imageops::resize(&img, nw, nh, image::imageops::FilterType::Triangle)
    } else {
        img
    };
    let rgb = image::DynamicImage::ImageRgba8(img).to_rgb8();
    let mut jpeg = Vec::with_capacity(96 * 1024);
    let mut enc = JpegEncoder::new_with_quality(&mut jpeg, JPEG_QUALITY);
    enc.encode(
        rgb.as_raw(),
        rgb.width(),
        rgb.height(),
        image::ColorType::Rgb8,
    )
    .map_err(|e| anyhow!("jpeg encode: {e}"))?;
    Ok(jpeg)
}

// Pull the first non-empty PixelBuffer frame within the capture budget,
// converting to RGBA on the fly. Returns (rgba_bytes, width, height).
fn grab_frame(capturer: &mut Capturer) -> ResultType<(Vec<u8>, u32, u32)> {
    let deadline = Instant::now() + CAPTURE_BUDGET;
    loop {
        match capturer.frame(Duration::from_millis(33)) {
            Ok(Frame::PixelBuffer(pb)) => {
                let strides = pb.stride();
                if pb.data().is_empty() || strides.is_empty() {
                    if Instant::now() > deadline {
                        return Err(anyhow!("capture timed out (empty frames)"));
                    }
                    continue;
                }
                let stride = strides[0];
                let w = pb.width() as u32;
                let h = pb.height() as u32;
                let rgba = match pb.pixfmt() {
                    Pixfmt::BGRA => bgra_to_rgba(pb.data(), w as usize, h as usize, stride),
                    Pixfmt::RGBA => rgba_copy(pb.data(), w as usize, h as usize, stride),
                    other => return Err(anyhow!("unsupported pixfmt: {other:?}")),
                };
                return Ok((rgba, w, h));
            }
            Ok(Frame::Texture(_)) => {
                return Err(anyhow!("texture frame not supported for screenshot"));
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock => {
                if Instant::now() > deadline {
                    return Err(anyhow!("capture timed out (wouldblock)"));
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(e) => {
                if Instant::now() > deadline {
                    return Err(anyhow!("capture failed: {e}"));
                }
                log::debug!("callmor screenshot: transient frame error: {e}");
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    }
}

fn bgra_to_rgba(src: &[u8], w: usize, h: usize, stride: usize) -> Vec<u8> {
    let row_bytes = w * 4;
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let s_off = y * stride;
        let d_off = y * row_bytes;
        let s_row = &src[s_off..s_off + row_bytes];
        let d_row = &mut out[d_off..d_off + row_bytes];
        for x in 0..w {
            let i = x * 4;
            d_row[i] = s_row[i + 2]; // R ← B
            d_row[i + 1] = s_row[i + 1]; // G
            d_row[i + 2] = s_row[i]; // B ← R
            d_row[i + 3] = 255; // opaque
        }
    }
    out
}

fn rgba_copy(src: &[u8], w: usize, h: usize, stride: usize) -> Vec<u8> {
    let row_bytes = w * 4;
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let s_off = y * stride;
        let d_off = y * row_bytes;
        out[d_off..d_off + row_bytes].copy_from_slice(&src[s_off..s_off + row_bytes]);
    }
    out
}
