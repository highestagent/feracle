use std::collections::{HashSet, VecDeque};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::StreamExt;
use k256::ecdsa::{SigningKey, VerifyingKey};
use libp2p::gossipsub::{self, IdentTopic, MessageAuthenticity, MessageId, ValidationMode};
use libp2p::mdns;
use libp2p::swarm::{NetworkBehaviour, SwarmEvent};
use libp2p::{noise, tcp, yamux, Multiaddr, PeerId, Swarm};
use tiny_keccak::{Hasher, Keccak};
use tokio::sync::{mpsc, oneshot};

pub const TOPIC_NAME: &str = "fe-oracle/top20-usd/v1";
pub const ASSET_COUNT: usize = 20;
const MAX_INBOX_LEN: usize = 1024;
const MSG_TYPE_QUOTE: u8 = 0;
const QUOTE_FRAME_LEN: usize = 177;

#[derive(NetworkBehaviour)]
struct OracleBehaviour {
    gossipsub: gossipsub::Behaviour,
    mdns: mdns::tokio::Behaviour,
}

enum ControlMsg {
    Publish(Vec<u8>),
    Shutdown,
}

fn update_peers_snapshot(snapshot: &Mutex<(u64, String)>, peers: &HashSet<PeerId>) {
    let mut list: Vec<String> = peers.iter().map(|p| p.to_string()).collect();
    list.sort();
    let csv = list.join(",");
    if let Ok(mut guard) = snapshot.lock() {
        guard.0 = guard.0.saturating_add(1);
        guard.1 = csv;
    }
}

pub struct P2pNode {
    local_peer_id: PeerId,
    inbox: Arc<Mutex<VecDeque<(u64, String, Vec<u8>)>>>,
    peer_count: Arc<AtomicUsize>,
    peers_snapshot: Arc<Mutex<(u64, String)>>,
    tx: mpsc::Sender<ControlMsg>,
    shutdown_rx: Option<oneshot::Receiver<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

static GLOBAL_NODE: Mutex<Option<P2pNode>> = Mutex::new(None);

impl P2pNode {
    pub fn start(listen_port: u16, bootstrap_addrs: Vec<Multiaddr>) -> Result<Self, String> {
        let inbox = Arc::new(Mutex::new(VecDeque::with_capacity(64)));
        let peer_count = Arc::new(AtomicUsize::new(0));
        let peers_snapshot = Arc::new(Mutex::new((0u64, String::new())));
        let (tx, mut rx) = mpsc::channel::<ControlMsg>(256);
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<PeerId, String>>();
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();

        let inbox_bg = Arc::clone(&inbox);
        let peer_count_bg = Arc::clone(&peer_count);
        let peers_snapshot_bg = Arc::clone(&peers_snapshot);

        let thread = std::thread::Builder::new()
            .name("fe-oracle-p2p".to_string())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .enable_all()
                    .build()
                {
                    Ok(rt) => rt,
                    Err(e) => {
                        let _ = ready_tx.send(Err(format!("tokio runtime error: {e}")));
                        return;
                    }
                };

                rt.block_on(async move {
                    let swarm_res = build_swarm(listen_port);
                    let mut swarm = match swarm_res {
                        Ok(s) => s,
                        Err(e) => {
                            let _ = ready_tx.send(Err(e));
                            return;
                        }
                    };

                    let local_peer_id = *swarm.local_peer_id();
                    let topic = IdentTopic::new(TOPIC_NAME);
                    if let Err(e) = swarm.behaviour_mut().gossipsub.subscribe(&topic) {
                        let _ = ready_tx.send(Err(format!("subscribe error: {e:?}")));
                        return;
                    }

                    for addr in &bootstrap_addrs {
                        let _ = swarm.dial(addr.clone());
                    }

                    let _ = ready_tx.send(Ok(local_peer_id));

                    let mut subscribed_peers: HashSet<PeerId> = HashSet::new();
                    let mut seen_quotes: HashSet<(PeerId, u64)> = HashSet::new();
                    let mut redial_tick = tokio::time::interval(Duration::from_secs(1));

                    loop {
                        tokio::select! {
                            cmd = rx.recv() => {
                                match cmd {
                                    Some(ControlMsg::Publish(bytes)) => {
                                        if let Err(e) = swarm.behaviour_mut().gossipsub.publish(topic.clone(), bytes) {
                                            // Transient InsufficientPeers before mesh forms is expected; Fe rebroadcasts.
                                            let _ = e;
                                        }
                                    }
                                    Some(ControlMsg::Shutdown) | None => {
                                        break;
                                    }
                                }
                            }
                            _ = redial_tick.tick() => {
                                if subscribed_peers.len() < 2 && !bootstrap_addrs.is_empty() {
                                    for addr in &bootstrap_addrs {
                                        let _ = swarm.dial(addr.clone());
                                    }
                                }
                            }
                            event = swarm.select_next_some() => {
                                match event {
                                    SwarmEvent::Behaviour(OracleBehaviourEvent::Mdns(mdns::Event::Discovered(list))) => {
                                        for (peer_id, multiaddr) in list {
                                            if peer_id == local_peer_id {
                                                continue;
                                            }
                                            swarm.behaviour_mut().gossipsub.add_explicit_peer(&peer_id);
                                            if !swarm.is_connected(&peer_id) {
                                                let _ = swarm.dial(multiaddr);
                                            }
                                        }
                                    }
                                    SwarmEvent::Behaviour(OracleBehaviourEvent::Mdns(mdns::Event::Expired(list))) => {
                                        for (peer_id, _) in list {
                                            swarm.behaviour_mut().gossipsub.remove_explicit_peer(&peer_id);
                                        }
                                    }
                                    SwarmEvent::Behaviour(OracleBehaviourEvent::Gossipsub(gossipsub::Event::Subscribed { peer_id, topic: sub_topic })) => {
                                        if sub_topic == topic.hash() && peer_id != local_peer_id {
                                            if subscribed_peers.insert(peer_id) {
                                                peer_count_bg.store(subscribed_peers.len(), Ordering::Release);
                                                update_peers_snapshot(&peers_snapshot_bg, &subscribed_peers);
                                            }
                                        }
                                    }
                                    SwarmEvent::Behaviour(OracleBehaviourEvent::Gossipsub(gossipsub::Event::Unsubscribed { peer_id, topic: sub_topic })) => {
                                        if sub_topic == topic.hash() && subscribed_peers.remove(&peer_id) {
                                            peer_count_bg.store(subscribed_peers.len(), Ordering::Release);
                                            update_peers_snapshot(&peers_snapshot_bg, &subscribed_peers);
                                        }
                                    }
                                    SwarmEvent::ConnectionClosed { peer_id, num_established, .. } => {
                                        if num_established == 0 && subscribed_peers.remove(&peer_id) {
                                            peer_count_bg.store(subscribed_peers.len(), Ordering::Release);
                                            update_peers_snapshot(&peers_snapshot_bg, &subscribed_peers);
                                        }
                                    }
                                    SwarmEvent::Behaviour(OracleBehaviourEvent::Gossipsub(gossipsub::Event::Message {
                                        propagation_source,
                                        message,
                                        ..
                                    })) => {
                                        let source_peer = message.source.unwrap_or(propagation_source);
                                        if source_peer == local_peer_id {
                                            continue;
                                        }
                                        let data = message.data;
                                        if data.len() == QUOTE_FRAME_LEN && data[0] == MSG_TYPE_QUOTE {
                                            let round_id = u64::from_be_bytes([
                                                data[1], data[2], data[3], data[4],
                                                data[5], data[6], data[7], data[8],
                                            ]);
                                            if !seen_quotes.insert((source_peer, round_id)) {
                                                continue;
                                            }
                                        }
                                        let origin_tag = peer_id_tag(&source_peer);
                                        let peer_str = source_peer.to_string();
                                        if let Ok(mut guard) = inbox_bg.lock() {
                                            if guard.len() >= MAX_INBOX_LEN {
                                                guard.pop_front();
                                            }
                                            guard.push_back((origin_tag, peer_str, data));
                                        }
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }

                    let _ = shutdown_tx.send(());
                });
            })
            .map_err(|e| format!("failed to spawn p2p thread: {e}"))?;

        let local_peer_id = ready_rx
            .recv()
            .map_err(|e| format!("p2p init channel closed: {e}"))??;

        Ok(Self {
            local_peer_id,
            inbox,
            peer_count,
            peers_snapshot,
            tx,
            shutdown_rx: Some(shutdown_rx),
            thread: Some(thread),
        })
    }

    pub fn local_peer_id(&self) -> PeerId {
        self.local_peer_id
    }

    pub fn peer_count(&self) -> usize {
        self.peer_count.load(Ordering::Acquire)
    }

    pub fn peers_snapshot(&self) -> (u64, String) {
        self.peers_snapshot
            .lock()
            .map(|g| g.clone())
            .unwrap_or((0, String::new()))
    }

    pub fn publish(&self, data: Vec<u8>) -> Result<(), String> {
        self.tx
            .try_send(ControlMsg::Publish(data))
            .map_err(|e| format!("publish enqueue failed: {e}"))
    }

    pub fn poll(&self) -> Option<Vec<u8>> {
        let mut guard = self.inbox.lock().ok()?;
        guard.pop_front().map(|(_, _, data)| data)
    }

    pub fn poll_with_peer(&self) -> Option<(u64, String, Vec<u8>)> {
        let mut guard = self.inbox.lock().ok()?;
        guard.pop_front()
    }

    pub fn peek_front_len(&self) -> Option<usize> {
        let guard = self.inbox.lock().ok()?;
        guard.front().map(|(_, _, data)| data.len())
    }

    pub fn stop(mut self) {
        let _ = self.tx.try_send(ControlMsg::Shutdown);
        if let Some(rx) = self.shutdown_rx.take() {
            let _ = rx.blocking_recv();
        }
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for P2pNode {
    fn drop(&mut self) {
        let _ = self.tx.try_send(ControlMsg::Shutdown);
        if let Some(rx) = self.shutdown_rx.take() {
            let _ = rx.blocking_recv();
        }
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
    }
}

fn build_swarm(listen_port: u16) -> Result<Swarm<OracleBehaviour>, String> {
    let mut swarm = libp2p::SwarmBuilder::with_new_identity()
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )
        .map_err(|e| format!("tcp/noise/yamux setup failed: {e}"))?
        .with_behaviour(|key| {
            let message_id_fn = |message: &gossipsub::Message| {
                let mut h = Keccak::v256();
                if let Some(src) = &message.source {
                    h.update(&src.to_bytes());
                }
                if let Some(seq) = message.sequence_number {
                    h.update(&seq.to_be_bytes());
                }
                h.update(&message.data);
                let mut out = [0u8; 32];
                h.finalize(&mut out);
                MessageId::from(out.to_vec())
            };

            let gossipsub_config = gossipsub::ConfigBuilder::default()
                .heartbeat_interval(Duration::from_millis(250))
                .validation_mode(ValidationMode::Strict)
                .flood_publish(true)
                .mesh_n_low(1)
                .mesh_n(2)
                .mesh_n_high(6)
                .mesh_outbound_min(0)
                .message_id_fn(message_id_fn)
                .build()
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

            let gossipsub = gossipsub::Behaviour::new(
                MessageAuthenticity::Signed(key.clone()),
                gossipsub_config,
            )
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

            let mdns =
                mdns::tokio::Behaviour::new(mdns::Config::default(), key.public().to_peer_id())?;

            Ok(OracleBehaviour { gossipsub, mdns })
        })
        .map_err(|e| format!("behaviour setup failed: {e}"))?
        .with_swarm_config(|cfg| cfg.with_idle_connection_timeout(Duration::from_secs(60)))
        .build();

    let listen_addr: Multiaddr = format!("/ip4/0.0.0.0/tcp/{listen_port}")
        .parse()
        .map_err(|e| format!("invalid listen addr: {e}"))?;
    swarm
        .listen_on(listen_addr)
        .map_err(|e| format!("listen failed: {e}"))?;

    Ok(swarm)
}

fn parse_bootstrap_list(raw: &str) -> Result<Vec<Multiaddr>, String> {
    let mut out = Vec::new();
    for part in raw.split(',') {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            continue;
        }
        let addr: Multiaddr = trimmed
            .parse()
            .map_err(|e| format!("invalid bootstrap multiaddr '{trimmed}': {e}"))?;
        out.push(addr);
    }
    Ok(out)
}

fn read_prices_be160(ptr: *const u8) -> [u64; ASSET_COUNT] {
    if ptr.is_null() {
        return [0u64; ASSET_COUNT];
    }
    let bytes = unsafe { slice::from_raw_parts(ptr, ASSET_COUNT * 8) };
    let mut prices = [0u64; ASSET_COUNT];
    for (i, slot) in prices.iter_mut().enumerate() {
        let base = i * 8;
        *slot = u64::from_be_bytes([
            bytes[base],
            bytes[base + 1],
            bytes[base + 2],
            bytes[base + 3],
            bytes[base + 4],
            bytes[base + 5],
            bytes[base + 6],
            bytes[base + 7],
        ]);
    }
    prices
}

pub fn build_oracle_digest(
    chain_id: u64,
    contract_addr: &[u8; 20],
    round_id: u64,
    prices: &[u64; ASSET_COUNT],
    timestamp: u64,
) -> [u8; 32] {
    let mut prices_words = [0u8; ASSET_COUNT * 32];
    for (i, &price) in prices.iter().enumerate() {
        let word_start = i * 32;
        prices_words[word_start + 24..word_start + 32].copy_from_slice(&price.to_be_bytes());
    }
    let mut prices_hash = [0u8; 32];
    let mut k_prices = Keccak::v256();
    k_prices.update(&prices_words);
    k_prices.finalize(&mut prices_hash);

    let mut preimage = [0u8; 160];
    preimage[24..32].copy_from_slice(&chain_id.to_be_bytes());
    preimage[44..64].copy_from_slice(contract_addr);
    preimage[88..96].copy_from_slice(&round_id.to_be_bytes());
    preimage[96..128].copy_from_slice(&prices_hash);
    preimage[152..160].copy_from_slice(&timestamp.to_be_bytes());

    let mut digest = [0u8; 32];
    let mut keccak = Keccak::v256();
    keccak.update(&preimage);
    keccak.finalize(&mut digest);
    digest
}

fn peer_id_tag(peer_id: &PeerId) -> u64 {
    let mut hash = [0u8; 32];
    let mut keccak = Keccak::v256();
    keccak.update(&peer_id.to_bytes());
    keccak.finalize(&mut hash);
    let raw = u64::from_be_bytes([
        hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
    ]);
    raw | 1
}

fn verifying_key_to_eth_address(verifying_key: &VerifyingKey) -> [u8; 20] {
    let encoded = verifying_key.to_encoded_point(false);
    let uncompressed = encoded.as_bytes();
    let mut hash = [0u8; 32];
    let mut keccak = Keccak::v256();
    keccak.update(&uncompressed[1..65]);
    keccak.finalize(&mut hash);
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&hash[12..32]);
    addr
}

pub fn derive_eth_address(signing_key: &SigningKey) -> [u8; 20] {
    let verifying_key = VerifyingKey::from(signing_key);
    verifying_key_to_eth_address(&verifying_key)
}

pub fn derive_eth_address_bytes(privkey: &[u8; 32]) -> Result<[u8; 20], String> {
    let signing_key =
        SigningKey::from_bytes(privkey.into()).map_err(|e| format!("invalid private key: {e}"))?;
    Ok(derive_eth_address(&signing_key))
}

pub fn verify_oracle_sig(
    chain_id: u64,
    contract_addr: &[u8; 20],
    round_id: u64,
    prices: &[u64; ASSET_COUNT],
    timestamp: u64,
    expected_addr: &[u8; 20],
    v: u8,
    r: &[u8; 32],
    s: &[u8; 32],
) -> bool {
    if v != 27 && v != 28 {
        return false;
    }
    let mut sig_bytes = [0u8; 64];
    sig_bytes[0..32].copy_from_slice(r);
    sig_bytes[32..64].copy_from_slice(s);
    let Ok(sig) = k256::ecdsa::Signature::from_slice(&sig_bytes) else {
        return false;
    };
    if sig.normalize_s().is_some() {
        return false;
    }
    let digest = build_oracle_digest(chain_id, contract_addr, round_id, prices, timestamp);
    let Ok(rec_id) = k256::ecdsa::RecoveryId::try_from(v - 27) else {
        return false;
    };
    let Ok(recovered_vk) = VerifyingKey::recover_from_prehash(&digest, &sig, rec_id) else {
        return false;
    };
    &verifying_key_to_eth_address(&recovered_vk) == expected_addr
}

fn sign_prehash_with_key(
    privkey: &[u8; 32],
    digest: &[u8; 32],
) -> Result<([u8; 20], u8, [u8; 32], [u8; 32]), String> {
    let signing_key =
        SigningKey::from_bytes(privkey.into()).map_err(|e| format!("invalid private key: {e}"))?;
    let addr = derive_eth_address(&signing_key);

    let (sig, rec_id) = signing_key
        .sign_prehash_recoverable(digest)
        .map_err(|e| format!("ecdsa sign failed: {e}"))?;

    let mut normalized_sig = sig;
    let mut recovery_byte = rec_id.to_byte();
    if let Some(low_s) = sig.normalize_s() {
        normalized_sig = low_s;
        recovery_byte ^= 1;
    }

    let sig_bytes = normalized_sig.to_bytes();
    let mut r = [0u8; 32];
    let mut s = [0u8; 32];
    r.copy_from_slice(&sig_bytes[0..32]);
    s.copy_from_slice(&sig_bytes[32..64]);
    Ok((addr, recovery_byte & 1, r, s))
}

pub fn sign_oracle_digest(
    privkey: &[u8; 32],
    chain_id: u64,
    contract_addr: &[u8; 20],
    round_id: u64,
    prices: &[u64; ASSET_COUNT],
    timestamp: u64,
) -> Result<([u8; 20], u8, [u8; 32], [u8; 32]), String> {
    let digest = build_oracle_digest(chain_id, contract_addr, round_id, prices, timestamp);
    let (addr, rec_bit, r, s) = sign_prehash_with_key(privkey, &digest)?;
    Ok((addr, 27 + rec_bit, r, s))
}

pub fn sign_keccak_bytes(
    privkey: &[u8; 32],
    data: &[u8],
) -> Result<([u8; 20], u8, [u8; 32], [u8; 32]), String> {
    let mut digest = [0u8; 32];
    let mut keccak = Keccak::v256();
    keccak.update(data);
    keccak.finalize(&mut digest);
    sign_prehash_with_key(privkey, &digest)
}

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

fn start_global_node(listen_port: u16, bootstrap_ptr: *const u8, bootstrap_len: usize) -> i32 {
    let bootstrap_str = match read_utf8_arg(bootstrap_ptr, bootstrap_len) {
        Ok(s) => s,
        Err(code) => return code,
    };

    let bootstrap_addrs = match parse_bootstrap_list(bootstrap_str) {
        Ok(list) => list,
        Err(_) => return -4,
    };

    let mut guard = match GLOBAL_NODE.lock() {
        Ok(g) => g,
        Err(_) => return -5,
    };
    if guard.is_some() {
        *guard = None;
    }

    match P2pNode::start(listen_port, bootstrap_addrs) {
        Ok(node) => {
            *guard = Some(node);
            0
        }
        Err(_) => -6,
    }
}

#[no_mangle]
pub extern "C" fn p2p_start(
    listen_port: u32,
    bootstrap_ptr: *const u8,
    bootstrap_len: usize,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(listen_port_u16) = u16::try_from(listen_port) else {
            return -2;
        };
        start_global_node(listen_port_u16, bootstrap_ptr, bootstrap_len)
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_local_peer_id(out_buf: *mut u8, max_len: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let guard = match GLOBAL_NODE.lock() {
            Ok(g) => g,
            Err(_) => return -5,
        };
        let Some(node) = guard.as_ref() else {
            return -7;
        };
        let peer_str = node.local_peer_id().to_string();
        let bytes = peer_str.as_bytes();
        if bytes.len() > max_len || (!bytes.is_empty() && out_buf.is_null()) {
            return -2;
        }
        if !bytes.is_empty() {
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf, bytes.len());
            }
        }
        i32::try_from(bytes.len()).unwrap_or(-2)
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_peers_csv(out_ver8_ptr: *mut u8, out_buf: *mut u8, max_len: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if out_ver8_ptr.is_null() {
            return -2;
        }
        let guard = match GLOBAL_NODE.lock() {
            Ok(g) => g,
            Err(_) => return -5,
        };
        let Some(node) = guard.as_ref() else {
            return -7;
        };
        let (ver, csv) = node.peers_snapshot();
        let bytes = csv.as_bytes();
        if bytes.len() > max_len || (!bytes.is_empty() && out_buf.is_null()) {
            return -2;
        }
        let ver_be = ver.to_be_bytes();
        unsafe {
            std::ptr::copy_nonoverlapping(ver_be.as_ptr(), out_ver8_ptr, 8);
            if !bytes.is_empty() {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf, bytes.len());
            }
        }
        i32::try_from(bytes.len()).unwrap_or(-2)
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_publish(data_ptr: *const u8, data_len: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if data_len > 0 && data_ptr.is_null() {
            return -2;
        }
        let payload = if data_len == 0 {
            Vec::new()
        } else {
            unsafe { slice::from_raw_parts(data_ptr, data_len) }.to_vec()
        };
        let guard = match GLOBAL_NODE.lock() {
            Ok(g) => g,
            Err(_) => return -5,
        };
        let Some(node) = guard.as_ref() else {
            return -7;
        };
        match node.publish(payload) {
            Ok(()) => 0,
            Err(_) => -8,
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_poll_with_peer(
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
        let guard = match GLOBAL_NODE.lock() {
            Ok(g) => g,
            Err(_) => return -5,
        };
        let Some(node) = guard.as_ref() else {
            return -7;
        };

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
            unsafe {
                std::ptr::copy_nonoverlapping(msg.as_ptr(), out_ptr, msg.len());
            }
        }
        let peer_bytes = peer_str.as_bytes();
        let peer_copy = peer_bytes.len().min(out_peer_cap);
        let mut meta = [0u8; 16];
        meta[0..8].copy_from_slice(&origin_tag.to_be_bytes());
        meta[8..16].copy_from_slice(&(peer_copy as u64).to_be_bytes());
        unsafe {
            std::ptr::copy_nonoverlapping(meta.as_ptr(), out_meta16_ptr, 16);
            if peer_copy > 0 && !out_peer_ptr.is_null() {
                std::ptr::copy_nonoverlapping(peer_bytes.as_ptr(), out_peer_ptr, peer_copy);
            }
        }
        i32::try_from(msg.len()).unwrap_or(-1)
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_poll(out_ptr: *mut u8, out_cap: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let guard = match GLOBAL_NODE.lock() {
            Ok(g) => g,
            Err(_) => return -5,
        };
        let Some(node) = guard.as_ref() else {
            return -7;
        };

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
            unsafe {
                std::ptr::copy_nonoverlapping(msg.as_ptr(), out_ptr, msg.len());
            }
        }
        i32::try_from(msg.len()).unwrap_or(-1)
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_peer_count() -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let guard = match GLOBAL_NODE.lock() {
            Ok(g) => g,
            Err(_) => return -5,
        };
        let Some(node) = guard.as_ref() else {
            return -7;
        };
        i32::try_from(node.peer_count()).unwrap_or(i32::MAX)
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_stop() -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let mut guard = match GLOBAL_NODE.lock() {
            Ok(g) => g,
            Err(_) => return -5,
        };
        if let Some(node) = guard.take() {
            node.stop();
        }
        0
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn p2p_sleep_ms(ms: u32) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        std::thread::sleep(Duration::from_millis(u64::from(ms)));
    }));
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

#[cfg(test)]
mod tests {
    use super::*;

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
        let contract = hex::decode("12b7796311880f2adce95dd9da0265425fed32b0").unwrap();
        let contract20: [u8; 20] = contract.try_into().unwrap();
        let digest = build_oracle_digest(1, &contract20, 1, &TEST_PRICES, 1);
        assert_eq!(
            hex::encode(digest),
            "abaa019c372782c3b99f19a716dc0e73d5a653ebefb898e4af0584b04c985f8a"
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
        let port_a = 17101;
        let port_b = 17102;
        let port_c = 17103;

        let node_a = P2pNode::start(port_a, vec![]).expect("start A");
        let addr_a: Multiaddr =
            format!("/ip4/127.0.0.1/tcp/{port_a}/p2p/{}", node_a.local_peer_id())
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

        // Publish a 177-byte quote from A twice; B and C must each receive it once (deduped)
        let mut quote = vec![0u8; QUOTE_FRAME_LEN];
        quote[0] = MSG_TYPE_QUOTE;
        quote[1..9].copy_from_slice(&1u64.to_be_bytes());
        quote[9..17].copy_from_slice(&1_795_250_000u64.to_be_bytes());
        quote[17..177].copy_from_slice(&prices_to_be160(&TEST_PRICES));

        node_a.publish(quote.clone()).unwrap();
        std::thread::sleep(Duration::from_millis(100));
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

        // Give time for any second quote broadcast to arrive and verify dedup dropped it
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(node_b.poll(), None);
        assert_eq!(node_c.poll(), None);

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
        let n_minus_s = k256::U256::from_be_hex(
            "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
        )
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
}
