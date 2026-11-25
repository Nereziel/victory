//! Experimental constant indirect diffuse light in place of missing probe rays.
//! Adapted from Belobug / ShakiraRED-dt c2271e5 via Neptune (GPL-3.0-or-later).
//! No depth approximation or live tuning. Each recorded pass owns its heap
//! until the command list is reset, rather than reusing in-flight descriptors.

use std::sync::OnceLock;
use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
use windows::Win32::Graphics::Direct3D::ID3DBlob;
use windows::Win32::Graphics::Direct3D12::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::core::s;
use crate::host::{HostList, host};
use crate::object::This;

pub(crate) const PROGRAM: &[u8] = b"CS_ScreenProbes_TemporalResolve";
pub(crate) const LIGHT: (u8, u32) = (1, 176);

fn parse_level(value: &str) -> Option<f32> {
    value.trim().parse::<f32>().ok().filter(|v| v.is_finite() && (0.0..=4.0).contains(v))
}

pub(crate) fn level() -> Option<f32> {
    static LEVEL: OnceLock<Option<f32>> = OnceLock::new();
    *LEVEL.get_or_init(|| {
        // Never overwrite actual probe results when RT is explicitly enabled.
        if ["VICTORY_RT_RESOLVE", "VICTORY_BVH_BUILDER"].iter()
            .any(|name| std::env::var_os(*name).is_some_and(|v| v == "1")) {
            return None;
        }
        std::env::var("VICTORY_AMBIENT").ok().as_deref().and_then(parse_level)
    })
}

const SOURCE: &str = r#"
#define RS "RootConstants(num32BitConstants=1, b0), DescriptorTable(UAV(u0))"
cbuffer Floor : register(b0) { uint packed; };
RWTexture2D<uint> light : register(u0);
[RootSignature(RS)]
[numthreads(8, 8, 1)]
void main(uint3 at : SV_DispatchThreadID) {
    uint w, h;
    light.GetDimensions(w, h);
    if (at.x < w && at.y < h) light[at.xy] = packed;
}
"#;

// R9G9B9E5: RGB mantissas with a shared exponent. Keep the packing on
// the CPU, since this experiment writes the same value to every texel.
fn packed(level: f32) -> u32 {
    let rgb = [level, level * 0.98, level * 0.94];
    let mut exp = ((level.max(1e-9).log2().floor() as i32) + 16).clamp(0, 31);
    let mut scale = 2.0f32.powi(24 - exp);
    if level * scale >= 511.5 && exp < 31 {
        exp += 1;
        scale = 2.0f32.powi(24 - exp);
    }
    let [r, g, b] = rgb.map(|v| (v * scale).round().clamp(0.0, 511.0) as u32);
    r | (g << 9) | (b << 18) | ((exp as u32) << 27)
}

struct Pass {
    root: ID3D12RootSignature,
    pso: ID3D12PipelineState,
}
fn make(device: &ID3D12Device) -> windows::core::Result<Pass> {
    let mut code: Option<ID3DBlob> = None;
    let mut errors: Option<ID3DBlob> = None;
    // SAFETY: the source and names live through the call; out pointers ours.
    let compiled = unsafe {
        D3DCompile(
            SOURCE.as_ptr().cast(),
            SOURCE.len(),
            s!("ambient"),
            None,
            None,
            s!("main"),
            s!("cs_5_1"),
            0,
            0,
            &mut code,
            Some(&mut errors),
        )
    };
    let text = |b: &ID3DBlob| {
        // SAFETY: the blob's own bytes.
        unsafe { std::slice::from_raw_parts(b.GetBufferPointer().cast::<u8>(), b.GetBufferSize()) }
            .to_vec()
    };
    if let Err(e) = compiled {
        if let Some(errors) = errors {
            tracing::warn!("ambient light: {}", String::from_utf8_lossy(&text(&errors)));
        }
        return Err(e);
    }
    let code = text(&code.ok_or_else(windows::core::Error::empty)?);
    // SAFETY: the root signature is inside the shader; plain creations.
    unsafe {
        let root: ID3D12RootSignature = device.CreateRootSignature(0, &code)?;
        let pso = device.CreateComputePipelineState(&D3D12_COMPUTE_PIPELINE_STATE_DESC {
            pRootSignature: std::mem::transmute_copy(&root),
            CS: D3D12_SHADER_BYTECODE {
                pShaderBytecode: code.as_ptr().cast(),
                BytecodeLength: code.len(),
            },
            ..Default::default()
        })?;
        Ok(Pass { root, pso })
    }
}

/// Replace only the verified R32_UINT, single-slice 2D probe output.
/// The title's dispatch has already bound it in UAV state.
pub(crate) fn raise(list: &HostList, resource: This) -> bool {
    let (Some(level), Some(host)) = (level(), host()) else { return false };
    let Some(light) = crate::resource::host_resource(resource) else { return false };
    // SAFETY: live host resource.
    let d = unsafe { light.GetDesc() };
    if d.Format != DXGI_FORMAT_R32_UINT
        || d.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D
        || d.DepthOrArraySize != 1 || d.SampleDesc.Count != 1
        || d.Flags.0 & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS.0 == 0
        || d.Width == 0 || d.Width > 65535 * 8 || d.Height == 0 || d.Height > 65535 * 8
    {
        return false;
    }
    static PASS: OnceLock<Option<Pass>> = OnceLock::new();
    let Some(pass) = PASS.get_or_init(|| make(&host.device)
        .inspect_err(|e| tracing::warn!(error = %e, "no ambient light")).ok()).as_ref()
    else { return false };
    // A private heap held by the list avoids the upstream ring's lifetime
    // assumption. The extra allocation is acceptable for an opt-in pass.
    let heap: ID3D12DescriptorHeap = match unsafe { host.device.CreateDescriptorHeap(&D3D12_DESCRIPTOR_HEAP_DESC {
        Type: D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
        NumDescriptors: 1,
        Flags: D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,
        NodeMask: 0,
    }) } {
        Ok(heap) => heap,
        Err(e) => { tracing::warn!(error = %e, "no ambient descriptor heap"); return false; }
    };
    list.keep(light);
    list.keep(&heap);
    let view = D3D12_UNORDERED_ACCESS_VIEW_DESC {
        Format: DXGI_FORMAT_R32_UINT,
        ViewDimension: D3D12_UAV_DIMENSION_TEXTURE2D,
        ..Default::default()
    };
    let l = &list.list;
    let barrier = || D3D12_RESOURCE_BARRIER {
        Type: D3D12_RESOURCE_BARRIER_TYPE_UAV,
        ..Default::default()
    };
    // SAFETY: a live UAV and an open command list; the heap is retained.
    unsafe {
        host.device.CreateUnorderedAccessView(light, None::<&ID3D12Resource>, Some(&view), heap.GetCPUDescriptorHandleForHeapStart());
        l.ResourceBarrier(&[barrier()]);
        l.SetDescriptorHeaps(&[Some(heap.clone())]);
        l.SetComputeRootSignature(&pass.root);
        l.SetPipelineState(&pass.pso);
        l.SetComputeRoot32BitConstant(0, packed(level), 0);
        l.SetComputeRootDescriptorTable(1, heap.GetGPUDescriptorHandleForHeapStart());
        l.Dispatch((d.Width as u32).div_ceil(8), d.Height.div_ceil(8), 1);
        l.ResourceBarrier(&[barrier()]);
    }
    static LOGGED: std::sync::Once = std::sync::Once::new();
    LOGGED.call_once(|| tracing::info!(level, width = d.Width, height = d.Height, "experimental ambient light"));
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ambient_is_opt_in_and_levels_are_bounded() {
        assert_eq!(parse_level("off"), None);
        assert_eq!(parse_level(""), None);
        assert_eq!(parse_level("NaN"), None);
        assert_eq!(parse_level("5"), None);
        assert_eq!(parse_level("0.6"), Some(0.6));
        assert_eq!(packed(0.0), 0);
        let p = packed(0.6);
        let scale = 2.0f32.powi((p >> 27) as i32 - 24);
        assert!(((p & 511) as f32 * scale - 0.6).abs() < 0.004);
    }

    #[test]
    fn ambient_pass_builds() {
        if let Some(host) = host() {
            make(&host.device).expect("ambient pass");
        }
    }
}
