//! QR capacity tables. Direct port of nodejs/src/lib/constants.ts -- values
//! must match exactly, the sender's chunk-size math depends on them.

use crate::qrtypes::EccLevel;

// Maximum Byte capacity for each version (1-40) at EC Level L
const QR_CAPACITY_L: [u32; 40] = [
    17, 32, 53, 78, 106, 134, 154, 192, 230, 271, 321, 367, 425, 458, 520, 586, 644, 718, 792, 858,
    929, 1003, 1091, 1171, 1273, 1367, 1465, 1528, 1628, 1732, 1840, 1952, 2068, 2188, 2303, 2431,
    2563, 2699, 2809, 2953,
];

// EC Level M
const QR_CAPACITY_M: [u32; 40] = [
    14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362, 412, 450, 504, 560, 624, 666,
    711, 779, 857, 911, 997, 1059, 1125, 1190, 1264, 1370, 1452, 1538, 1628, 1722, 1809, 1911,
    1989, 2099, 2213, 2331,
];

// EC Level Q
const QR_CAPACITY_Q: [u32; 40] = [
    11, 20, 32, 46, 60, 74, 86, 108, 130, 151, 177, 203, 241, 258, 292, 322, 364, 394, 442, 482,
    509, 565, 611, 661, 715, 751, 805, 868, 908, 982, 1030, 1112, 1168, 1228, 1283, 1351, 1423,
    1499, 1579, 1663,
];

// EC Level H
const QR_CAPACITY_H: [u32; 40] = [
    7,
    14,
    24,
    34,
    44,
    58,
    64,
    84,
    98,
    119,
    137,
    155,
    177,
    194,
    220,
    250,
    280,
    310,
    338,
    382,
    403,
    439,
    461,
    514,
    535,
    593,
    625,
    658,
    698,
    742,
    790,
    842,
    898,
    958,
    983,
    1051,
    1093,
    1139,
    1219,
    1273 - 100, // Safe margin for V40 H
];

pub fn get_max_capacity(version: i32, ecc: EccLevel) -> u32 {
    let index = (version.clamp(1, 40) - 1) as usize;
    match ecc {
        EccLevel::L => QR_CAPACITY_L[index],
        EccLevel::M => QR_CAPACITY_M[index],
        EccLevel::Q => QR_CAPACITY_Q[index],
        EccLevel::H => QR_CAPACITY_H[index],
    }
}
