use std::sync::atomic::Ordering;
use std::sync::Mutex;
use std::time::Duration;

static SWARM_TEST_LOCK: Mutex<()> = Mutex::new(());

use k256::ecdsa::VerifyingKey;
use libp2p::Multiaddr;
use tiny_keccak::{Hasher, Keccak};

#[cfg(unix)]
use crate::signals::handle_shutdown_signal;
use crate::signals::SHUTDOWN_REQUESTED;
use crate::*;

const TEST_PRICES: [u64; ASSET_COUNT] = [
    9_245_025_000_000,
    342_050_000_000,
    21_840_000_000,
    245_200_000,
    68_520_000_000,
    38_400_000,
    104_500_000,
    26_100_000,
    4_480_000_000,
    2_360_000_000,
    415_200_000,
    892_000_000,
    29_500_000,
    51_230_000_000,
    11_460_000_000,
    1_475_000_000,
    648_000_000,
    1_235_000_000,
    94_500_000,
    31_850_000_000,
];

fn prices_to_be160(prices: &[u64; ASSET_COUNT]) -> [u8; ASSET_COUNT * 8] {
    let mut out = [0u8; ASSET_COUNT * 8];
    for (i, &p) in prices.iter().enumerate() {
        out[i * 8..i * 8 + 8].copy_from_slice(&p.to_be_bytes());
    }
    out
}

#[test]
fn test_crypto_keccak_and_sign_parity_with_evm_vectors() {
    // Exact test vector verified against ingots/evm/src/test.fe and cast!
    let contract = hex::decode("184a05ae4c04d7c42175b96c3faca8084d8ae4e8").unwrap();
    let contract20: [u8; 20] = contract.try_into().unwrap();
    let digest = build_oracle_digest(1, &contract20, 1, &TEST_PRICES, 1);
    assert_eq!(
        hex::encode(digest),
        "b6f49643337479678b657fb9e111e650e7e2b222b2b8b97d2df3fc1ee080101f"
    );

    let prices_be = prices_to_be160(&TEST_PRICES);
    let keys = [
        (
            "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
            "f39fd6e51aad88f6f4ce6ab8827279cfffb92266",
        ),
        (
            "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
            "70997970c51812dc3a010c7d01b50e0d17dc79c8",
        ),
        (
            "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
            "3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
        ),
        (
            "7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
            "90f79bf6eb2c4f870365e785982e1f101e93b906",
        ),
    ];

    for (pk_hex, expected_addr_hex) in keys {
        let pk: [u8; 32] = hex::decode(pk_hex).unwrap().try_into().unwrap();
        let mut out_addr = [0u8; 20];
        let mut out_v = 0u8;
        let mut out_r = [0u8; 32];
        let mut out_s = [0u8; 32];
        let rc = crypto_keccak_and_sign(
            pk.as_ptr(),
            1,
            contract20.as_ptr(),
            1,
            prices_be.as_ptr(),
            1,
            out_addr.as_mut_ptr(),
            &mut out_v as *mut u8,
            out_r.as_mut_ptr(),
            out_s.as_mut_ptr(),
        );
        assert_eq!(rc, 0);
        assert_eq!(hex::encode(out_addr), expected_addr_hex);
        assert!(out_v == 27 || out_v == 28);

        // Recover signer with k256 and confirm exact match
        let mut sig_bytes = [0u8; 64];
        sig_bytes[0..32].copy_from_slice(&out_r);
        sig_bytes[32..64].copy_from_slice(&out_s);
        let sig = k256::ecdsa::Signature::from_slice(&sig_bytes).unwrap();
        let rec_id = k256::ecdsa::RecoveryId::try_from(out_v - 27).unwrap();
        let recovered_vk = VerifyingKey::recover_from_prehash(&digest, &sig, rec_id).unwrap();
        let encoded = recovered_vk.to_encoded_point(false);
        let mut hash = [0u8; 32];
        let mut keccak = Keccak::v256();
        keccak.update(&encoded.as_bytes()[1..65]);
        keccak.finalize(&mut hash);
        assert_eq!(hex::encode(&hash[12..32]), expected_addr_hex);
    }
}

#[test]
fn test_gossipsub_three_peer_loopback_and_quote_dedup() {
    let _guard = SWARM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let port_a = 17101;
    let port_b = 17102;
    let port_c = 17103;

    let node_a = P2pNode::start(port_a, vec![]).expect("start A");
    let addr_a: Multiaddr = format!("/ip4/127.0.0.1/tcp/{port_a}/p2p/{}", node_a.local_peer_id())
        .parse()
        .unwrap();
    let node_b = P2pNode::start(port_b, vec![addr_a.clone()]).expect("start B");
    let node_c = P2pNode::start(port_c, vec![addr_a]).expect("start C");

    // Wait up to 10s for mesh / mDNS readiness
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while std::time::Instant::now() < deadline {
        if node_a.peer_count() >= 2 && node_b.peer_count() >= 1 && node_c.peer_count() >= 1 {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        node_a.peer_count() >= 2,
        "node_a peer_count={}",
        node_a.peer_count()
    );
    assert!(
        node_b.peer_count() >= 1,
        "node_b peer_count={}",
        node_b.peer_count()
    );
    assert!(
        node_c.peer_count() >= 1,
        "node_c peer_count={}",
        node_c.peer_count()
    );
    let (ver_a, csv_a) = node_a.peers_snapshot();
    assert!(ver_a >= 2, "ver_a={ver_a}");
    assert!(
        csv_a.contains(&node_b.local_peer_id().to_string()),
        "csv_a={csv_a}"
    );
    assert!(
        csv_a.contains(&node_c.local_peer_id().to_string()),
        "csv_a={csv_a}"
    );
    let (ver_b, csv_b) = node_b.peers_snapshot();
    assert!(ver_b >= 1, "ver_b={ver_b}");
    assert!(
        csv_b.contains(&node_a.local_peer_id().to_string()),
        "csv_b={csv_b}"
    );

    // Single quote publish delivers once per peer (no GossipSub relay duplication);
    // explicit rebroadcast delivers again so late-joining/out-of-phase peers recover.
    const MSG_TYPE_QUOTE: u8 = 0;
    const QUOTE_FRAME_LEN: usize = 262;
    let mut quote = vec![0u8; QUOTE_FRAME_LEN];
    quote[0] = MSG_TYPE_QUOTE;
    quote[1..9].copy_from_slice(&1u64.to_be_bytes());
    quote[9..17].copy_from_slice(&1_795_250_000u64.to_be_bytes());
    quote[17..177].copy_from_slice(&prices_to_be160(&TEST_PRICES));
    quote[177..197].copy_from_slice(&[0x11; 20]);
    quote[197] = 27;

    node_a.publish(quote.clone()).unwrap();

    let mut got_b = None;
    let mut got_c = None;
    let recv_deadline = std::time::Instant::now() + Duration::from_secs(8);
    while std::time::Instant::now() < recv_deadline {
        if got_b.is_none() {
            got_b = node_b.poll();
        }
        if got_c.is_none() {
            got_c = node_c.poll();
        }
        if got_b.is_some() && got_c.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    assert_eq!(got_b.as_ref(), Some(&quote));
    assert_eq!(got_c.as_ref(), Some(&quote));

    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(node_b.poll(), None);
    assert_eq!(node_c.poll(), None);

    // Explicit rebroadcast (e.g. step_rebroadcast) must still be delivered to peers.
    node_a.publish(quote.clone()).unwrap();
    let mut rebroadcast_b = None;
    let mut rebroadcast_c = None;
    let retry_deadline = std::time::Instant::now() + Duration::from_secs(8);
    while std::time::Instant::now() < retry_deadline {
        if rebroadcast_b.is_none() {
            rebroadcast_b = node_b.poll();
        }
        if rebroadcast_c.is_none() {
            rebroadcast_c = node_c.poll();
        }
        if rebroadcast_b.is_some() && rebroadcast_c.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    assert_eq!(rebroadcast_b.as_ref(), Some(&quote));
    assert_eq!(rebroadcast_c.as_ref(), Some(&quote));

    // Publish 262-byte sig from B -> A and C receive via relay/mesh
    const MSG_TYPE_SIG: u8 = 1;
    const SIG_FRAME_LEN: usize = 262;
    let mut sig_msg = vec![0xab; SIG_FRAME_LEN];
    sig_msg[0] = MSG_TYPE_SIG;
    node_b.publish(sig_msg.clone()).unwrap();

    let mut got_a = None;
    let mut got_c2 = None;
    let sig_deadline = std::time::Instant::now() + Duration::from_secs(8);
    while std::time::Instant::now() < sig_deadline {
        if got_a.is_none() {
            got_a = node_a.poll();
        }
        if got_c2.is_none() {
            got_c2 = node_c.poll();
        }
        if got_a.is_some() && got_c2.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    assert_eq!(got_a.as_ref(), Some(&sig_msg));
    assert_eq!(got_c2.as_ref(), Some(&sig_msg));

    node_c.stop();
    node_b.stop();
    node_a.stop();
}

#[test]
fn test_crypto_keccak_and_sign_bytes_recovery() {
    let pk: [u8; 32] =
        hex::decode("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
            .unwrap()
            .try_into()
            .unwrap();
    let preimage = b"\xe4\x09\x85\x04\xa8\x17\xc8\x00\x82\x52\x08\x94\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x35\x80\x80\x01\x80\x80";
    let mut addr = [0u8; 20];
    let mut rec_id = 9u8;
    let mut r = [0u8; 32];
    let mut s = [0u8; 32];
    let rc = crypto_keccak_and_sign_bytes(
        pk.as_ptr(),
        preimage.as_ptr(),
        preimage.len(),
        addr.as_mut_ptr(),
        &mut rec_id as *mut u8,
        r.as_mut_ptr(),
        s.as_mut_ptr(),
    );
    assert_eq!(rc, 0);
    assert_eq!(
        hex::encode(addr),
        "f39fd6e51aad88f6f4ce6ab8827279cfffb92266"
    );
    assert!(rec_id == 0 || rec_id == 1);

    let mut digest = [0u8; 32];
    let mut keccak = Keccak::v256();
    keccak.update(preimage);
    keccak.finalize(&mut digest);
    let mut sig_bytes = [0u8; 64];
    sig_bytes[0..32].copy_from_slice(&r);
    sig_bytes[32..64].copy_from_slice(&s);
    let sig = k256::ecdsa::Signature::from_slice(&sig_bytes).unwrap();
    let rid = k256::ecdsa::RecoveryId::try_from(rec_id).unwrap();
    let recovered = VerifyingKey::recover_from_prehash(&digest, &sig, rid).unwrap();
    let encoded = recovered.to_encoded_point(false);
    let mut hash = [0u8; 32];
    let mut k2 = Keccak::v256();
    k2.update(&encoded.as_bytes()[1..65]);
    k2.finalize(&mut hash);
    assert_eq!(&hash[12..32], &addr);
}

#[test]
fn test_crypto_derive_addr_and_verify_oracle_sig() {
    let pk: [u8; 32] =
        hex::decode("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
            .unwrap()
            .try_into()
            .unwrap();
    let contract20: [u8; 20] = hex::decode("3244d0de654b2d7e00fedb548d3f5a6c6175dcf0")
        .unwrap()
        .try_into()
        .unwrap();
    let mut derived = [0u8; 20];
    assert_eq!(crypto_derive_eth_addr(pk.as_ptr(), derived.as_mut_ptr()), 0);
    assert_eq!(
        hex::encode(derived),
        "f39fd6e51aad88f6f4ce6ab8827279cfffb92266"
    );

    let prices_be = prices_to_be160(&TEST_PRICES);
    let (_, v, r, s) = sign_oracle_digest(&pk, 1, &contract20, 1, &TEST_PRICES, 1).unwrap();
    assert_eq!(
        crypto_verify_oracle_sig(
            1,
            contract20.as_ptr(),
            1,
            prices_be.as_ptr(),
            1,
            derived.as_ptr(),
            u32::from(v),
            r.as_ptr(),
            s.as_ptr(),
        ),
        1
    );

    // Wrong claimed address fails
    let mut wrong_addr = derived;
    wrong_addr[0] ^= 0xff;
    assert_eq!(
        crypto_verify_oracle_sig(
            1,
            contract20.as_ptr(),
            1,
            prices_be.as_ptr(),
            1,
            wrong_addr.as_ptr(),
            u32::from(v),
            r.as_ptr(),
            s.as_ptr(),
        ),
        0
    );

    // Corrupted signature fails
    let mut bad_r = r;
    bad_r[0] ^= 0x01;
    assert_eq!(
        crypto_verify_oracle_sig(
            1,
            contract20.as_ptr(),
            1,
            prices_be.as_ptr(),
            1,
            derived.as_ptr(),
            u32::from(v),
            bad_r.as_ptr(),
            s.as_ptr(),
        ),
        0
    );

    // Invalid v fails
    assert_eq!(
        crypto_verify_oracle_sig(
            1,
            contract20.as_ptr(),
            1,
            prices_be.as_ptr(),
            1,
            derived.as_ptr(),
            26,
            r.as_ptr(),
            s.as_ptr(),
        ),
        0
    );

    // High-s malleable signature (N - s) fails EIP-2 check
    use k256::elliptic_curve::bigint::Encoding as _;
    let n_minus_s =
        k256::U256::from_be_hex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")
            .wrapping_sub(&k256::U256::from_be_slice(&s));
    let high_s: [u8; 32] = n_minus_s.to_be_bytes();
    let flipped_v = if v == 27 { 28 } else { 27 };
    assert_eq!(
        crypto_verify_oracle_sig(
            1,
            contract20.as_ptr(),
            1,
            prices_be.as_ptr(),
            1,
            derived.as_ptr(),
            flipped_v,
            r.as_ptr(),
            high_s.as_ptr(),
        ),
        0
    );
}

#[test]
fn test_crypto_verify_keccak_bytes_sig_and_domain_sep() {
    let pk: [u8; 32] =
        hex::decode("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
            .unwrap()
            .try_into()
            .unwrap();
    let contract20: [u8; 20] = hex::decode("3244d0de654b2d7e00fedb548d3f5a6c6175dcf0")
        .unwrap()
        .try_into()
        .unwrap();
    let mut preimage = Vec::with_capacity(220);
    preimage.extend_from_slice(b"feracle-quote-v1");
    preimage.extend_from_slice(&1u64.to_be_bytes());
    preimage.extend_from_slice(&contract20);
    preimage.extend_from_slice(&1u64.to_be_bytes());
    preimage.extend_from_slice(&1u64.to_be_bytes());
    preimage.extend_from_slice(&prices_to_be160(&TEST_PRICES));
    assert_eq!(preimage.len(), 220);

    let mut addr = [0u8; 20];
    let mut rec_id = 9u8;
    let mut r = [0u8; 32];
    let mut s = [0u8; 32];
    assert_eq!(
        crypto_keccak_and_sign_bytes(
            pk.as_ptr(),
            preimage.as_ptr(),
            preimage.len(),
            addr.as_mut_ptr(),
            &mut rec_id as *mut u8,
            r.as_mut_ptr(),
            s.as_mut_ptr(),
        ),
        0
    );
    let v = u32::from(27 + rec_id);
    assert_eq!(
        crypto_verify_keccak_bytes_sig(
            preimage.as_ptr(),
            preimage.len(),
            addr.as_ptr(),
            v,
            r.as_ptr(),
            s.as_ptr(),
        ),
        1
    );

    // Domain separation: quote signature must NOT verify as on-chain oracle settlement sig
    let prices_be = prices_to_be160(&TEST_PRICES);
    assert_eq!(
        crypto_verify_oracle_sig(
            1,
            contract20.as_ptr(),
            1,
            prices_be.as_ptr(),
            1,
            addr.as_ptr(),
            v,
            r.as_ptr(),
            s.as_ptr(),
        ),
        0
    );

    // Tampered payload fails
    let mut tampered = preimage.clone();
    tampered[219] ^= 0x01;
    assert_eq!(
        crypto_verify_keccak_bytes_sig(
            tampered.as_ptr(),
            tampered.len(),
            addr.as_ptr(),
            v,
            r.as_ptr(),
            s.as_ptr(),
        ),
        0
    );

    // Wrong address fails
    let mut wrong_addr = addr;
    wrong_addr[0] ^= 0xff;
    assert_eq!(
        crypto_verify_keccak_bytes_sig(
            preimage.as_ptr(),
            preimage.len(),
            wrong_addr.as_ptr(),
            v,
            r.as_ptr(),
            s.as_ptr(),
        ),
        0
    );

    // Invalid v and high-s malleability fail
    assert_eq!(
        crypto_verify_keccak_bytes_sig(
            preimage.as_ptr(),
            preimage.len(),
            addr.as_ptr(),
            26,
            r.as_ptr(),
            s.as_ptr(),
        ),
        0
    );
    use k256::elliptic_curve::bigint::Encoding as _;
    let n_minus_s =
        k256::U256::from_be_hex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")
            .wrapping_sub(&k256::U256::from_be_slice(&s));
    let high_s: [u8; 32] = n_minus_s.to_be_bytes();
    let flipped_v = if v == 27 { 28 } else { 27 };
    assert_eq!(
        crypto_verify_keccak_bytes_sig(
            preimage.as_ptr(),
            preimage.len(),
            addr.as_ptr(),
            flipped_v,
            r.as_ptr(),
            high_s.as_ptr(),
        ),
        0
    );
}

#[test]
fn test_opaque_handle_concurrent_nodes_and_wakeup_fd() {
    let _guard = SWARM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut h_a_be = [0u8; 8];
    let mut h_b_be = [0u8; 8];
    assert_eq!(
        p2p_start(17201, std::ptr::null(), 0, h_a_be.as_mut_ptr()),
        0
    );
    let h_a = u64::from_be_bytes(h_a_be);
    assert_ne!(h_a, 0);

    let mut peer_a_buf = [0u8; 128];
    let peer_a_len = p2p_local_peer_id(h_a, peer_a_buf.as_mut_ptr(), peer_a_buf.len());
    assert!(peer_a_len > 0);
    let peer_a = std::str::from_utf8(&peer_a_buf[..peer_a_len as usize]).unwrap();

    let boot_b = format!("/ip4/127.0.0.1/tcp/17201/p2p/{peer_a}");
    assert_eq!(
        p2p_start(17202, boot_b.as_ptr(), boot_b.len(), h_b_be.as_mut_ptr()),
        0
    );
    let h_b = u64::from_be_bytes(h_b_be);
    assert_ne!(h_b, 0);
    assert_ne!(h_a, h_b);

    #[cfg(unix)]
    {
        assert!(p2p_wake_fd(h_a) >= 0);
        assert!(p2p_wake_fd(h_b) >= 0);
    }

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while std::time::Instant::now() < deadline {
        if p2p_peer_count(h_a) >= 1 && p2p_peer_count(h_b) >= 1 {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(p2p_peer_count(h_a) >= 1);
    assert!(p2p_peer_count(h_b) >= 1);
    assert!(p2p_drain_wake(h_b) >= 1);
    assert_eq!(p2p_drain_wake(h_b), 0);

    let payload = b"wake-check-payload";
    assert_eq!(p2p_publish(h_a, payload.as_ptr(), payload.len()), 0);

    let mut rx_buf = [0u8; 256];
    let mut got = 0i32;
    let rx_deadline = std::time::Instant::now() + Duration::from_secs(8);
    while std::time::Instant::now() < rx_deadline {
        let n = p2p_poll(h_b, rx_buf.as_mut_ptr(), rx_buf.len());
        if n > 0 {
            got = n;
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert_eq!(got, payload.len() as i32);
    assert_eq!(&rx_buf[..got as usize], payload);
    #[cfg(unix)]
    assert!(p2p_drain_wake(h_b) >= 1);
    assert_eq!(p2p_drain_wake(h_b), 0);

    assert_eq!(p2p_stop(h_b), 0);
    assert_eq!(p2p_stop(h_a), 0);
    assert_eq!(p2p_stop(0), 0);
    assert_eq!(p2p_peer_count(0), -7);
}

#[test]
fn test_signal_flag_and_wake_fd() {
    let fd = sys_install_signal_handlers();
    assert_eq!(sys_shutdown_requested(), 0);
    #[cfg(unix)]
    {
        assert!(fd >= 0);
        handle_shutdown_signal(15);
        assert_eq!(sys_shutdown_requested(), 1);
        assert!(sys_drain_signal_wake() >= 1);
        assert_eq!(sys_drain_signal_wake(), 0);
    }
    #[cfg(not(unix))]
    let _ = fd;
    SHUTDOWN_REQUESTED.store(false, Ordering::SeqCst);
}
