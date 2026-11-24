use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use crate::crypto::{
    derive_eth_address_bytes, read_prices_be160, sign_keccak_bytes, sign_oracle_digest,
    verify_keccak_bytes_sig, verify_oracle_sig,
};
use crate::swarm::{parse_bootstrap_list, P2pNode};

fn read_utf8_arg<'a>(ptr: *const u8, len: usize) -> Result<&'a str, i32> {
    if len == 0 {
        return Ok("");
    }
    if ptr.is_null() {
        return Err(-2);
    }
    let bytes = unsafe { slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(bytes).map_err(|_| -3)
}

unsafe fn with_node<F: FnOnce(&P2pNode) -> i32>(handle: u64, f: F) -> i32 {
    let Ok(addr) = usize::try_from(handle) else {
        return -2;
    };
    if addr == 0 {
        return -7;
    }
    let node = &*(addr as *const P2pNode);
    f(node)
}

#[no_mangle]
pub extern "C" fn p2p_start(
    listen_port: u32,
    bootstrap_ptr: *const u8,
    bootstrap_len: usize,
    out_handle8_ptr: *mut u8,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if out_handle8_ptr.is_null() {
            return -2;
        }
        let Ok(listen_port_u16) = u16::try_from(listen_port) else {
            return -2;
        };
        let bootstrap_str = match read_utf8_arg(bootstrap_ptr, bootstrap_len) {
            Ok(s) => s,
            Err(code) => return code,
        };
        let bootstrap_addrs = match parse_bootstrap_list(bootstrap_str) {
            Ok(list) => list,
            Err(_) => return -4,
        };

        match P2pNode::start(listen_port_u16, bootstrap_addrs) {
            Ok(node) => {
                let raw = Box::into_raw(Box::new(node)) as usize as u64;
                let handle_be = raw.to_be_bytes();
                unsafe {
                    std::ptr::copy_nonoverlapping(handle_be.as_ptr(), out_handle8_ptr, 8);
                }
                0
            }
            Err(_) => -6,
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_wake_fd(handle: u64) -> i32 {
    catch_unwind(AssertUnwindSafe(|| unsafe {
        with_node(handle, |node| node.wake_fd())
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_drain_wake(handle: u64) -> i32 {
    catch_unwind(AssertUnwindSafe(|| unsafe {
        with_node(handle, |node| {
            i32::try_from(node.drain_wake()).unwrap_or(i32::MAX)
        })
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_local_peer_id(handle: u64, out_buf: *mut u8, max_len: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| unsafe {
        with_node(handle, |node| {
            let peer_str = node.local_peer_id().to_string();
            let bytes = peer_str.as_bytes();
            if bytes.len() > max_len || (!bytes.is_empty() && out_buf.is_null()) {
                return -2;
            }
            if !bytes.is_empty() {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf, bytes.len());
            }
            i32::try_from(bytes.len()).unwrap_or(-2)
        })
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_peers_csv(
    handle: u64,
    out_ver8_ptr: *mut u8,
    out_buf: *mut u8,
    max_len: usize,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if out_ver8_ptr.is_null() {
            return -2;
        }
        unsafe {
            with_node(handle, |node| {
                let (ver, csv) = node.peers_snapshot();
                let bytes = csv.as_bytes();
                if bytes.len() > max_len || (!bytes.is_empty() && out_buf.is_null()) {
                    return -2;
                }
                let ver_be = ver.to_be_bytes();
                std::ptr::copy_nonoverlapping(ver_be.as_ptr(), out_ver8_ptr, 8);
                if !bytes.is_empty() {
                    std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf, bytes.len());
                }
                i32::try_from(bytes.len()).unwrap_or(-2)
            })
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_publish(handle: u64, data_ptr: *const u8, data_len: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if data_len > 0 && data_ptr.is_null() {
            return -2;
        }
        let payload = if data_len == 0 {
            Vec::new()
        } else {
            unsafe { slice::from_raw_parts(data_ptr, data_len) }.to_vec()
        };
        unsafe {
            with_node(handle, |node| match node.publish(payload) {
                Ok(()) => 0,
                Err(_) => -8,
            })
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_poll_with_peer(
    handle: u64,
    out_ptr: *mut u8,
    out_cap: usize,
    out_meta16_ptr: *mut u8,
    out_peer_ptr: *mut u8,
    out_peer_cap: usize,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if out_meta16_ptr.is_null() {
            return -2;
        }
        unsafe {
            with_node(handle, |node| {
                let Some(front_len) = node.peek_front_len() else {
                    return 0;
                };
                if front_len > out_cap || (front_len > 0 && out_ptr.is_null()) {
                    return -1;
                }
                let Some((origin_tag, peer_str, msg)) = node.poll_with_peer() else {
                    return 0;
                };
                if msg.len() > out_cap {
                    return -1;
                }
                if !msg.is_empty() {
                    std::ptr::copy_nonoverlapping(msg.as_ptr(), out_ptr, msg.len());
                }
                let peer_bytes = peer_str.as_bytes();
                let peer_copy = peer_bytes.len().min(out_peer_cap);
                let mut meta = [0u8; 16];
                meta[0..8].copy_from_slice(&origin_tag.to_be_bytes());
                meta[8..16].copy_from_slice(&(peer_copy as u64).to_be_bytes());
                std::ptr::copy_nonoverlapping(meta.as_ptr(), out_meta16_ptr, 16);
                if peer_copy > 0 && !out_peer_ptr.is_null() {
                    std::ptr::copy_nonoverlapping(peer_bytes.as_ptr(), out_peer_ptr, peer_copy);
                }
                i32::try_from(msg.len()).unwrap_or(-1)
            })
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_poll(handle: u64, out_ptr: *mut u8, out_cap: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| unsafe {
        with_node(handle, |node| {
            let Some(front_len) = node.peek_front_len() else {
                return 0;
            };
            if front_len > out_cap || (front_len > 0 && out_ptr.is_null()) {
                return -1;
            }
            let Some(msg) = node.poll() else {
                return 0;
            };
            if msg.len() > out_cap {
                return -1;
            }
            if !msg.is_empty() {
                std::ptr::copy_nonoverlapping(msg.as_ptr(), out_ptr, msg.len());
            }
            i32::try_from(msg.len()).unwrap_or(-1)
        })
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_peer_count(handle: u64) -> i32 {
    catch_unwind(AssertUnwindSafe(|| unsafe {
        with_node(handle, |node| {
            i32::try_from(node.peer_count()).unwrap_or(i32::MAX)
        })
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_stop(handle: u64) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if handle == 0 {
            return 0;
        }
        let Ok(addr) = usize::try_from(handle) else {
            return -2;
        };
        let boxed = unsafe { Box::from_raw(addr as *mut P2pNode) };
        boxed.stop();
        0
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn crypto_keccak_and_sign_bytes(
    privkey32_ptr: *const u8,
    data_ptr: *const u8,
    data_len: usize,
    out_addr20: *mut u8,
    out_rec_id: *mut u8,
    out_r32: *mut u8,
    out_s32: *mut u8,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if privkey32_ptr.is_null()
            || (data_len > 0 && data_ptr.is_null())
            || out_addr20.is_null()
            || out_rec_id.is_null()
            || out_r32.is_null()
            || out_s32.is_null()
        {
            return -2;
        }
        let mut privkey = [0u8; 32];
        unsafe {
            std::ptr::copy_nonoverlapping(privkey32_ptr, privkey.as_mut_ptr(), 32);
        }
        let data = if data_len == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(data_ptr, data_len) }
        };

        match sign_keccak_bytes(&privkey, data) {
            Ok((addr, rec_id, r, s)) => {
                unsafe {
                    std::ptr::copy_nonoverlapping(addr.as_ptr(), out_addr20, 20);
                    *out_rec_id = rec_id;
                    std::ptr::copy_nonoverlapping(r.as_ptr(), out_r32, 32);
                    std::ptr::copy_nonoverlapping(s.as_ptr(), out_s32, 32);
                }
                0
            }
            Err(_) => -3,
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn crypto_keccak_and_sign(
    privkey32_ptr: *const u8,
    chain_id: u64,
    contract20_ptr: *const u8,
    round_id: u64,
    prices_be160_ptr: *const u8,
    timestamp: u64,
    out_addr20: *mut u8,
    out_v: *mut u8,
    out_r32: *mut u8,
    out_s32: *mut u8,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if privkey32_ptr.is_null()
            || contract20_ptr.is_null()
            || prices_be160_ptr.is_null()
            || out_addr20.is_null()
            || out_v.is_null()
            || out_r32.is_null()
            || out_s32.is_null()
        {
            return -2;
        }
        let mut privkey = [0u8; 32];
        let mut contract = [0u8; 20];
        unsafe {
            std::ptr::copy_nonoverlapping(privkey32_ptr, privkey.as_mut_ptr(), 32);
            std::ptr::copy_nonoverlapping(contract20_ptr, contract.as_mut_ptr(), 20);
        }
        let prices = read_prices_be160(prices_be160_ptr);

        match sign_oracle_digest(&privkey, chain_id, &contract, round_id, &prices, timestamp) {
            Ok((addr, v, r, s)) => {
                unsafe {
                    std::ptr::copy_nonoverlapping(addr.as_ptr(), out_addr20, 20);
                    *out_v = v;
                    std::ptr::copy_nonoverlapping(r.as_ptr(), out_r32, 32);
                    std::ptr::copy_nonoverlapping(s.as_ptr(), out_s32, 32);
                }
                0
            }
            Err(_) => -3,
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn crypto_derive_eth_addr(privkey32_ptr: *const u8, out_addr20: *mut u8) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if privkey32_ptr.is_null() || out_addr20.is_null() {
            return -2;
        }
        let mut privkey = [0u8; 32];
        unsafe {
            std::ptr::copy_nonoverlapping(privkey32_ptr, privkey.as_mut_ptr(), 32);
        }
        match derive_eth_address_bytes(&privkey) {
            Ok(addr) => {
                unsafe {
                    std::ptr::copy_nonoverlapping(addr.as_ptr(), out_addr20, 20);
                }
                0
            }
            Err(_) => -3,
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn crypto_verify_oracle_sig(
    chain_id: u64,
    contract20_ptr: *const u8,
    round_id: u64,
    prices_be160_ptr: *const u8,
    timestamp: u64,
    expected_addr20_ptr: *const u8,
    v: u32,
    r32_ptr: *const u8,
    s32_ptr: *const u8,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if contract20_ptr.is_null()
            || prices_be160_ptr.is_null()
            || expected_addr20_ptr.is_null()
            || r32_ptr.is_null()
            || s32_ptr.is_null()
        {
            return -2;
        }
        let Ok(v_u8) = u8::try_from(v) else {
            return 0;
        };
        let mut contract = [0u8; 20];
        let mut expected = [0u8; 20];
        let mut r = [0u8; 32];
        let mut s = [0u8; 32];
        unsafe {
            std::ptr::copy_nonoverlapping(contract20_ptr, contract.as_mut_ptr(), 20);
            std::ptr::copy_nonoverlapping(expected_addr20_ptr, expected.as_mut_ptr(), 20);
            std::ptr::copy_nonoverlapping(r32_ptr, r.as_mut_ptr(), 32);
            std::ptr::copy_nonoverlapping(s32_ptr, s.as_mut_ptr(), 32);
        }
        let prices = read_prices_be160(prices_be160_ptr);
        if verify_oracle_sig(
            chain_id, &contract, round_id, &prices, timestamp, &expected, v_u8, &r, &s,
        ) {
            1
        } else {
            0
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn crypto_verify_keccak_bytes_sig(
    data_ptr: *const u8,
    data_len: usize,
    expected_addr20_ptr: *const u8,
    v: u32,
    r32_ptr: *const u8,
    s32_ptr: *const u8,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if (data_len > 0 && data_ptr.is_null())
            || expected_addr20_ptr.is_null()
            || r32_ptr.is_null()
            || s32_ptr.is_null()
        {
            return -2;
        }
        let Ok(v_u8) = u8::try_from(v) else {
            return 0;
        };
        let data = if data_len == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(data_ptr, data_len) }
        };
        let mut expected = [0u8; 20];
        let mut r = [0u8; 32];
        let mut s = [0u8; 32];
        unsafe {
            std::ptr::copy_nonoverlapping(expected_addr20_ptr, expected.as_mut_ptr(), 20);
            std::ptr::copy_nonoverlapping(r32_ptr, r.as_mut_ptr(), 32);
            std::ptr::copy_nonoverlapping(s32_ptr, s.as_mut_ptr(), 32);
        }
        if verify_keccak_bytes_sig(data, &expected, v_u8, &r, &s) {
            1
        } else {
            0
        }
    }))
    .unwrap_or(-99)
}
