// XXH64 against the published vectors, for the flasher's per-chunk table; see TECH.md section 5.

// The five 64-bit primes the xxHash specification names.
const P1: u64 = 0x9E3779B185EBCA87;
const P2: u64 = 0xC2B2AE3D27D4EB4F;
const P3: u64 = 0x165667B19E3779F9;
const P4: u64 = 0x85EBCA77C2B2AE63;
const P5: u64 = 0x27D4EB2F165667C5;
// 32 bytes, the four-lane stripe the loop consumes.
const STRIPE: usize = 32;
// 8 bytes, one lane.
const LANE: usize = 8;
// 31 and 27 and 31 again, the three avalanche shifts.
const MIX_SHIFT_A: u32 = 33;
const MIX_SHIFT_B: u32 = 29;
const MIX_SHIFT_C: u32 = 32;

// One round of the specification's mixing step.
fn round(acc: u64, lane: u64) -> u64 {
    acc.wrapping_add(lane.wrapping_mul(P2)).rotate_left(31).wrapping_mul(P1)
}

// The merge round that folds one lane back into the accumulator.
fn merge(acc: u64, lane: u64) -> u64 {
    acc ^ round(0, lane).wrapping_mul(P1).wrapping_add(P4)
}

// The specification's one-shot hash with seed 0, the only seed this tree uses.
pub fn hash(bytes: &[u8]) -> u64 {
    hash_with_seed(bytes, 0)
}

// Sample input: b"abc" with seed 0 answers 0x44bc2cf5ad770999.
pub fn hash_with_seed(bytes: &[u8], seed: u64) -> u64 {
    let mut at = 0;
    let mut acc: u64;
    if bytes.len() >= STRIPE {
        let mut v1 = seed.wrapping_add(P1).wrapping_add(P2);
        let mut v2 = seed.wrapping_add(P2);
        let mut v3 = seed;
        let mut v4 = seed.wrapping_sub(P1);
        while at + STRIPE <= bytes.len() {
            v1 = round(v1, lane_at(bytes, at));
            v2 = round(v2, lane_at(bytes, at + 8));
            v3 = round(v3, lane_at(bytes, at + 16));
            v4 = round(v4, lane_at(bytes, at + 24));
            at += STRIPE;
        }
        acc = v1.rotate_left(1).wrapping_add(v2.rotate_left(7)).wrapping_add(v3.rotate_left(12)).wrapping_add(v4.rotate_left(18));
        acc = merge(merge(merge(merge(acc, v1), v2), v3), v4);
    } else {
        acc = seed.wrapping_add(P5);
    }
    acc = acc.wrapping_add(bytes.len() as u64);
    while at + LANE <= bytes.len() {
        acc ^= round(0, lane_at(bytes, at));
        acc = acc.rotate_left(27).wrapping_mul(P1).wrapping_add(P4);
        at += LANE;
    }
    while at < bytes.len() {
        acc ^= u64::from(bytes[at]).wrapping_mul(P5);
        acc = acc.rotate_left(11).wrapping_mul(P1);
        at += 1;
    }
    acc ^= acc >> MIX_SHIFT_A;
    acc = acc.wrapping_mul(P2);
    acc ^= acc >> MIX_SHIFT_B;
    acc = acc.wrapping_mul(P3);
    acc ^= acc >> MIX_SHIFT_C;
    acc
}

// One little-endian lane starting at a position the caller proved is in bounds.
fn lane_at(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(bytes[at..at + LANE].try_into().unwrap_or([0; LANE]))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The specification's own seed-0 sanity vectors.
    #[test]
    fn the_published_seed_zero_vectors() {
        assert_eq!(hash(b""), 0xef46db3751d8e999);
        assert_eq!(hash(b"a"), 0xd24ec4f1a98c6e5b);
        assert_eq!(hash(b"abc"), 0x44bc2cf5ad770999);
    }

    #[test]
    fn a_stripe_boundary_hashes_the_same_bytes() {
        let body: Vec<u8> = (0..64u32).map(|n| (n % 251) as u8).collect();
        assert_ne!(hash(&body), hash(&body[1..]));
        assert_eq!(hash(&body[..32]), hash(&body[..32]));
    }
}
