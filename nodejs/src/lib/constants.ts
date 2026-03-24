// Maximum Byte capacity for each version (1-40) at EC Level L
export const qrCapacityL = [
  17, 32, 53, 78, 106, 134, 154, 192, 230, 271, 321, 367, 425, 458, 520, 586, 644, 718, 792, 858,
  929, 1003, 1091, 1171, 1273, 1367, 1465, 1528, 1628, 1732, 1840, 1952, 2068, 2188, 2303, 2431,
  2563, 2699, 2809, 2953,
];

// EC Level M
export const qrCapacityM = [
  14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362, 412, 450, 504, 560, 624, 666,
  711, 779, 857, 911, 997, 1059, 1125, 1190, 1264, 1370, 1452, 1538, 1628, 1722, 1809, 1911, 1989,
  2099, 2213, 2331,
];

// EC Level Q
export const qrCapacityQ = [
  11, 20, 32, 46, 60, 74, 86, 108, 130, 151, 177, 203, 241, 258, 292, 322, 364, 394, 442, 482, 509,
  565, 611, 661, 715, 751, 805, 868, 908, 982, 1030, 1112, 1168, 1228, 1283, 1351, 1423, 1499, 1579,
  1663,
];

// EC Level H
export const qrCapacityH = [
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

export function getMaxCapacity(version: number, ecc: 'L' | 'M' | 'Q' | 'H'): number {
  const index = Math.max(1, Math.min(40, version)) - 1;
  switch (ecc) {
    case 'L':
      return qrCapacityL[index];
    case 'M':
      return qrCapacityM[index];
    case 'Q':
      return qrCapacityQ[index];
    case 'H':
      return qrCapacityH[index];
    default:
      return qrCapacityL[index];
  }
}
