use std::slice;

use k256::ecdsa::{SigningKey, VerifyingKey};
use tiny_keccak::{Hasher, Keccak};

pub const ASSET_COUNT: usize = 20;

pub(crate) fn read_prices_be160(ptr: *const u8) -> [u64; ASSET_COUNT] {
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

fn verify_prehash_sig(
    digest: &[u8; 32],
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
    let Ok(rec_id) = k256::ecdsa::RecoveryId::try_from(v - 27) else {
        return false;
    };
    let Ok(recovered_vk) = VerifyingKey::recover_from_prehash(digest, &sig, rec_id) else {
        return false;
    };
    &verifying_key_to_eth_address(&recovered_vk) == expected_addr
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
    let digest = build_oracle_digest(chain_id, contract_addr, round_id, prices, timestamp);
    verify_prehash_sig(&digest, expected_addr, v, r, s)
}

pub fn verify_keccak_bytes_sig(
    data: &[u8],
    expected_addr: &[u8; 20],
    v: u8,
    r: &[u8; 32],
    s: &[u8; 32],
) -> bool {
    let mut digest = [0u8; 32];
    let mut keccak = Keccak::v256();
    keccak.update(data);
    keccak.finalize(&mut digest);
    verify_prehash_sig(&digest, expected_addr, v, r, s)
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
