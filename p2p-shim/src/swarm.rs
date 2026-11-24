use std::collections::{HashSet, VecDeque};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::StreamExt;
use libp2p::gossipsub::{self, IdentTopic, MessageAuthenticity, MessageId, ValidationMode};
use libp2p::mdns;
use libp2p::swarm::{NetworkBehaviour, SwarmEvent};
use libp2p::{noise, tcp, yamux, Multiaddr, PeerId, Swarm};
use tiny_keccak::{Hasher, Keccak};
use tokio::sync::{mpsc, oneshot};

use crate::wake::{make_wake_pair, WakeReceiver};

pub const TOPIC_NAME: &str = "fe-oracle/top20-usd/v1";
const MAX_INBOX_LEN: usize = 1024;

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
    wake_rx: WakeReceiver,
    tx: mpsc::Sender<ControlMsg>,
    shutdown_rx: Option<oneshot::Receiver<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl P2pNode {
    pub fn start(listen_port: u16, bootstrap_addrs: Vec<Multiaddr>) -> Result<Self, String> {
        let inbox = Arc::new(Mutex::new(VecDeque::with_capacity(64)));
        let peer_count = Arc::new(AtomicUsize::new(0));
        let peers_snapshot = Arc::new(Mutex::new((0u64, String::new())));
        let (wake_rx, wake_tx) = make_wake_pair()?;
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
                                if subscribed_peers.len() < 3 && !bootstrap_addrs.is_empty() {
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
                                                wake_tx.notify();
                                            }
                                        }
                                    }
                                    SwarmEvent::Behaviour(OracleBehaviourEvent::Gossipsub(gossipsub::Event::Unsubscribed { peer_id, topic: sub_topic })) => {
                                        if sub_topic == topic.hash() && subscribed_peers.remove(&peer_id) {
                                            peer_count_bg.store(subscribed_peers.len(), Ordering::Release);
                                            update_peers_snapshot(&peers_snapshot_bg, &subscribed_peers);
                                            wake_tx.notify();
                                        }
                                    }
                                    SwarmEvent::ConnectionClosed { peer_id, num_established, .. } => {
                                        if num_established == 0 && subscribed_peers.remove(&peer_id) {
                                            peer_count_bg.store(subscribed_peers.len(), Ordering::Release);
                                            update_peers_snapshot(&peers_snapshot_bg, &subscribed_peers);
                                            wake_tx.notify();
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
                                        let origin_tag = peer_id_tag(&source_peer);
                                        let peer_str = source_peer.to_string();
                                        let mut pushed = false;
                                        if let Ok(mut guard) = inbox_bg.lock() {
                                            if guard.len() >= MAX_INBOX_LEN {
                                                guard.pop_front();
                                            }
                                            guard.push_back((origin_tag, peer_str, data));
                                            pushed = true;
                                        }
                                        if pushed {
                                            wake_tx.notify();
                                        }
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }

                    wake_tx.notify();
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
            wake_rx,
            tx,
            shutdown_rx: Some(shutdown_rx),
            thread: Some(thread),
        })
    }

    pub fn local_peer_id(&self) -> PeerId {
        self.local_peer_id
    }

    pub fn wake_fd(&self) -> i32 {
        self.wake_rx.fd()
    }

    pub fn drain_wake(&self) -> usize {
        self.wake_rx.drain()
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

pub(crate) fn parse_bootstrap_list(raw: &str) -> Result<Vec<Multiaddr>, String> {
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
