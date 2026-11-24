mod crypto;
mod ffi;
mod signals;
mod swarm;
mod wake;

#[cfg(test)]
mod tests;

pub use crypto::{
    build_oracle_digest, derive_eth_address, derive_eth_address_bytes, sign_keccak_bytes,
    sign_oracle_digest, verify_keccak_bytes_sig, verify_oracle_sig, ASSET_COUNT,
};
pub use ffi::{
    crypto_derive_eth_addr, crypto_keccak_and_sign, crypto_keccak_and_sign_bytes,
    crypto_verify_keccak_bytes_sig, crypto_verify_oracle_sig, p2p_drain_wake, p2p_local_peer_id,
    p2p_peer_count, p2p_peers_csv, p2p_poll, p2p_poll_with_peer, p2p_publish, p2p_start, p2p_stop,
    p2p_wake_fd,
};
pub use signals::{
    p2p_sleep_ms, sys_drain_signal_wake, sys_install_signal_handlers, sys_shutdown_requested,
};
pub use swarm::{P2pNode, TOPIC_NAME};
