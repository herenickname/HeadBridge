(() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  function __accessProp(key) {
    return this[key];
  }
  var __toCommonJS = (from) => {
    var entry = (__moduleCache ??= new WeakMap).get(from), desc;
    if (entry)
      return entry;
    entry = __defProp({}, "__esModule", { value: true });
    if (from && typeof from === "object" || typeof from === "function") {
      for (var key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(entry, key))
          __defProp(entry, key, {
            get: __accessProp.bind(from, key),
            enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable
          });
    }
    __moduleCache.set(from, entry);
    return entry;
  };
  var __moduleCache;
  var __returnValue = (v) => v;
  function __exportSetter(name, newValue) {
    this[name] = __returnValue.bind(null, newValue);
  }
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: __exportSetter.bind(all, name)
      });
  };

  // ../../../../../../../../../private/tmp/phoenix2-auth-research-20261111/web/src/jl-auth.ts
  var exports_jl_auth = {};
  __export(exports_jl_auth, {
    getRandomAuthData: () => getRandomAuthData,
    getEncryptedAuthData: () => getEncryptedAuthData,
    functionE1test: () => functionE1test,
    STATIC_KEY: () => STATIC_KEY,
    MAGIC: () => MAGIC
  });
  var KS_TABLE = [
    100,
    172,
    40,
    90,
    201,
    179,
    55,
    197,
    10,
    16,
    183,
    163,
    186,
    177,
    151,
    70,
    61,
    5,
    220,
    102,
    110,
    246,
    154,
    248,
    13,
    88,
    149,
    103,
    198,
    170,
    171,
    236,
    160,
    104,
    155,
    150,
    212,
    235,
    191,
    67,
    73,
    54,
    233,
    106,
    137,
    216,
    195,
    138,
    148,
    99,
    153,
    188,
    123,
    190,
    193,
    34,
    187,
    92,
    113,
    213,
    31,
    146,
    87,
    93,
    143,
    68,
    65,
    29,
    81,
    230,
    64,
    23,
    251,
    253,
    25,
    50,
    52,
    184,
    97,
    42,
    202,
    35,
    111,
    218,
    57,
    247,
    162,
    1,
    127,
    214,
    49,
    231,
    222,
    128,
    4,
    221,
    44,
    89,
    130,
    175,
    168,
    224,
    15,
    205,
    161,
    18,
    62,
    48,
    209,
    28,
    208,
    58,
    51,
    114,
    46,
    79,
    144,
    2,
    19,
    6,
    117,
    206,
    135,
    194,
    239,
    178,
    173,
    125,
    56,
    21,
    225,
    82,
    159,
    122,
    108,
    47,
    39,
    196,
    226,
    129,
    169,
    207,
    141,
    192,
    215,
    223,
    255,
    96,
    118,
    20,
    140,
    94,
    85,
    9,
    228,
    8,
    199,
    66,
    32,
    252,
    210,
    80,
    145,
    217,
    76,
    98,
    158,
    232,
    185,
    166,
    249,
    26,
    0,
    33,
    11,
    250,
    53,
    156,
    78,
    75,
    105,
    72,
    203,
    14,
    200,
    164,
    91,
    234,
    132,
    7,
    180,
    24,
    244,
    174,
    107,
    219,
    167,
    204,
    63,
    139,
    74,
    12,
    60,
    37,
    229,
    84,
    77,
    69,
    131,
    237,
    17,
    240,
    176,
    83,
    147,
    242,
    116,
    38,
    181,
    157,
    109,
    124,
    243,
    45,
    241,
    86,
    36,
    126,
    71,
    27,
    134,
    189,
    112,
    142,
    30,
    59,
    115,
    22,
    3,
    182,
    172,
    40,
    90,
    201,
    179,
    55,
    197,
    10,
    16,
    183,
    163,
    186,
    177,
    151,
    70,
    136
  ];
  var SBOX = [
    1,
    45,
    226,
    147,
    190,
    69,
    21,
    174,
    120,
    3,
    135,
    164,
    184,
    56,
    207,
    63,
    8,
    103,
    9,
    148,
    235,
    38,
    168,
    107,
    189,
    24,
    52,
    27,
    187,
    191,
    114,
    247,
    64,
    53,
    72,
    156,
    81,
    47,
    59,
    85,
    227,
    192,
    159,
    216,
    211,
    243,
    141,
    177,
    255,
    167,
    62,
    220,
    134,
    119,
    215,
    166,
    17,
    251,
    244,
    186,
    146,
    145,
    100,
    131,
    241,
    51,
    239,
    218,
    44,
    181,
    178,
    43,
    136,
    209,
    153,
    203,
    140,
    132,
    29,
    20,
    129,
    151,
    113,
    202,
    95,
    163,
    139,
    87,
    60,
    130,
    196,
    82,
    92,
    28,
    232,
    160,
    4,
    180,
    133,
    74,
    246,
    19,
    84,
    182,
    223,
    12,
    26,
    142,
    222,
    224,
    57,
    252,
    32,
    155,
    36,
    78,
    169,
    152,
    158,
    171,
    242,
    96,
    208,
    108,
    234,
    250,
    199,
    217,
    0,
    212,
    31,
    110,
    67,
    188,
    236,
    83,
    137,
    254,
    122,
    93,
    73,
    201,
    50,
    194,
    249,
    154,
    248,
    109,
    22,
    219,
    89,
    150,
    68,
    233,
    205,
    230,
    70,
    66,
    143,
    10,
    193,
    204,
    185,
    101,
    176,
    210,
    198,
    172,
    30,
    65,
    98,
    41,
    46,
    14,
    116,
    80,
    2,
    90,
    195,
    37,
    123,
    138,
    42,
    91,
    240,
    6,
    13,
    71,
    111,
    112,
    157,
    126,
    16,
    206,
    18,
    39,
    213,
    76,
    79,
    214,
    121,
    48,
    104,
    54,
    117,
    125,
    228,
    237,
    128,
    106,
    144,
    55,
    162,
    94,
    118,
    170,
    197,
    127,
    61,
    175,
    165,
    229,
    25,
    97,
    253,
    77,
    124,
    183,
    11,
    238,
    173,
    75,
    34,
    245,
    231,
    115,
    35,
    33,
    200,
    5,
    225,
    102,
    221,
    179,
    88,
    105,
    99,
    86,
    15,
    161,
    49,
    149,
    23,
    7,
    58,
    40
  ];
  var ISBOX = [
    128,
    0,
    176,
    9,
    96,
    239,
    185,
    253,
    16,
    18,
    159,
    228,
    105,
    186,
    173,
    248,
    192,
    56,
    194,
    101,
    79,
    6,
    148,
    252,
    25,
    222,
    106,
    27,
    93,
    78,
    168,
    130,
    112,
    237,
    232,
    236,
    114,
    179,
    21,
    195,
    255,
    171,
    182,
    71,
    68,
    1,
    172,
    37,
    201,
    250,
    142,
    65,
    26,
    33,
    203,
    211,
    13,
    110,
    254,
    38,
    88,
    218,
    50,
    15,
    32,
    169,
    157,
    132,
    152,
    5,
    156,
    187,
    34,
    140,
    99,
    231,
    197,
    225,
    115,
    198,
    175,
    36,
    91,
    135,
    102,
    39,
    247,
    87,
    244,
    150,
    177,
    183,
    92,
    139,
    213,
    84,
    121,
    223,
    170,
    246,
    62,
    163,
    241,
    17,
    202,
    245,
    209,
    23,
    123,
    147,
    131,
    188,
    189,
    82,
    30,
    235,
    174,
    204,
    214,
    53,
    8,
    200,
    138,
    180,
    226,
    205,
    191,
    217,
    208,
    80,
    89,
    63,
    77,
    98,
    52,
    10,
    72,
    136,
    181,
    86,
    76,
    46,
    107,
    158,
    210,
    61,
    60,
    3,
    19,
    251,
    151,
    81,
    117,
    74,
    145,
    113,
    35,
    190,
    118,
    42,
    95,
    249,
    212,
    85,
    11,
    220,
    55,
    49,
    22,
    116,
    215,
    119,
    167,
    230,
    7,
    219,
    164,
    47,
    70,
    243,
    97,
    69,
    103,
    227,
    12,
    162,
    59,
    28,
    133,
    24,
    4,
    29,
    41,
    160,
    143,
    178,
    90,
    216,
    166,
    126,
    238,
    141,
    83,
    75,
    161,
    154,
    193,
    14,
    122,
    73,
    165,
    44,
    129,
    196,
    199,
    54,
    43,
    127,
    67,
    149,
    51,
    242,
    108,
    104,
    109,
    240,
    2,
    40,
    206,
    221,
    155,
    234,
    94,
    153,
    124,
    20,
    134,
    207,
    229,
    66,
    184,
    64,
    120,
    45,
    58,
    233,
    100,
    31,
    146,
    144,
    125,
    57,
    111,
    224,
    137,
    48
  ];
  var STATIC_KEY = [
    6,
    119,
    95,
    135,
    145,
    141,
    212,
    35,
    0,
    93,
    241,
    216,
    207,
    12,
    20,
    43
  ];
  var MAGIC = [17, 34, 51, 51, 34, 17];
  var MASK = 39321;
  function keySchedule(data16) {
    const out = new Array(272).fill(0);
    for (let i = 0;i < 16; i++)
      out[i] = data16[i];
    const buf = data16.slice(0, 16);
    let checksum = 0;
    for (const b of data16)
      checksum ^= b;
    buf.push(checksum & 255);
    for (let rnd = 0;rnd < 16; rnd++) {
      for (let i = 0;i < 17; i++) {
        const b = buf[i];
        buf[i] = (b << 3 | b >>> 5) & 255;
      }
      let readPos = (rnd + 1) % 17;
      for (let j = 0;j < 16; j++) {
        const src = buf[readPos];
        const tblIdx = 15 + rnd * 16 - j;
        out[16 + rnd * 16 + j] = KS_TABLE[tblIdx] + src & 255;
        readPos += 1;
        if (readPos > 16)
          readPos = 0;
      }
    }
    return out;
  }
  function fibonacciMix(s) {
    const r = {};
    const M = 4294967295;
    r[16] = s[0];
    r[17] = s[1];
    r[3] = s[2];
    r[4] = s[3];
    r[5] = s[4];
    r[6] = s[5];
    r[7] = s[6];
    r[19] = s[7];
    r[20] = s[8];
    r[21] = s[9];
    r[22] = s[10];
    r[23] = s[11];
    r[24] = s[12];
    r[25] = s[13];
    r[26] = s[14];
    r[27] = s[15];
    r[28] = r[17] + r[16] * 2 & M;
    r[16] = r[17] + r[16] & M;
    r[17] = r[4] + r[3] * 2 & M;
    r[3] = r[4] + r[3] & M;
    r[4] = r[6] + r[5] * 2 & M;
    r[5] = r[6] + r[5] & M;
    r[6] = r[19] + r[7] * 2 & M;
    r[7] = r[19] + r[7] & M;
    r[19] = r[21] + r[20] * 2 & M;
    r[20] = r[21] + r[20] & M;
    r[21] = r[23] + r[22] * 2 & M;
    r[22] = r[23] + r[22] & M;
    r[23] = r[25] + r[24] * 2 & M;
    r[24] = r[25] + r[24] & M;
    r[25] = r[27] + r[26] * 2 & M;
    r[26] = r[27] + r[26] & M;
    r[27] = r[22] + r[19] * 2 & M;
    r[19] = r[22] + r[19] & M;
    r[22] = r[26] + r[23] * 2 & M;
    r[23] = r[26] + r[23] & M;
    r[26] = r[16] + r[17] * 2 & M;
    r[16] = r[17] + r[16] & M;
    r[17] = r[5] + r[6] * 2 & M;
    r[5] = r[6] + r[5] & M;
    r[6] = r[20] + r[21] * 2 & M;
    r[20] = r[21] + r[20] & M;
    r[21] = r[24] + r[25] * 2 & M;
    r[24] = r[25] + r[24] & M;
    r[25] = r[7] + r[28] * 2 & M;
    r[7] = r[7] + r[28] & M;
    r[28] = r[3] + r[4] * 2 & M;
    r[3] = r[4] + r[3] & M;
    r[4] = r[24] + r[6] * 2 & M;
    r[6] = r[24] + r[6] & M;
    r[24] = r[3] + r[25] * 2 & M;
    r[3] = r[25] + r[3] & M;
    r[25] = r[19] + r[22] * 2 & M;
    r[19] = r[22] + r[19] & M;
    r[22] = r[16] + r[17] * 2 & M;
    r[16] = r[17] + r[16] & M;
    r[17] = r[20] + r[21] * 2 & M;
    r[20] = r[21] + r[20] & M;
    r[21] = r[7] + r[28] * 2 & M;
    r[7] = r[7] + r[28] & M;
    r[28] = r[5] + r[27] * 2 & M;
    r[5] = r[27] + r[5] & M;
    r[27] = r[23] + r[26] * 2 & M;
    r[23] = r[23] + r[26] & M;
    r[26] = r[7] + r[17] * 2 & M;
    r[17] = r[17] + r[7] & M;
    r[7] = r[23] + r[28] * 2 & M;
    r[23] = r[23] + r[28] & M;
    r[28] = r[6] + r[24] * 2 & M;
    r[6] = r[6] + r[24] & M;
    r[24] = r[19] + r[22] * 2 & M;
    r[19] = r[19] + r[22] & M;
    r[22] = r[20] + r[21] * 2 & M;
    r[20] = r[20] + r[21] & M;
    r[21] = r[5] + r[27] * 2 & M;
    r[5] = r[27] + r[5] & M;
    r[27] = r[16] + r[4] * 2 & M;
    r[16] = r[4] + r[16] & M;
    r[4] = r[3] + r[25] * 2 & M;
    r[3] = r[25] + r[3] & M;
    return [
      r[26] & 255,
      r[17] & 255,
      r[7] & 255,
      r[23] & 255,
      r[28] & 255,
      r[6] & 255,
      r[24] & 255,
      r[19] & 255,
      r[22] & 255,
      r[20] & 255,
      r[21] & 255,
      r[5] & 255,
      r[27] & 255,
      r[16] & 255,
      r[4] & 255,
      r[3] & 255
    ];
  }
  function condMix(state, keyBlock, mask, phase) {
    const result = state.slice();
    for (let i = 0;i < 16; i++) {
      const bitSet = (1 << i & mask) !== 0;
      if (phase === 3) {
        result[i] = bitSet ? result[i] ^ keyBlock[i] : keyBlock[i] + result[i] & 255;
      } else {
        result[i] = bitSet ? keyBlock[i] + result[i] & 255 : result[i] ^ keyBlock[i];
      }
    }
    return result;
  }
  function sboxSub(state) {
    const result = state.slice();
    for (const pos of [0, 3, 4, 7, 8, 11, 12, 15])
      result[pos] = SBOX[result[pos]];
    for (const pos of [1, 2, 5, 6, 9, 10, 13, 14])
      result[pos] = ISBOX[result[pos]];
    return result;
  }
  function blockCipher(stateIn, ek, mode) {
    let s = stateIn.slice();
    const initial = stateIn.slice();
    s = condMix(s, ek.slice(0, 16), MASK, 3);
    s = sboxSub(s);
    s = condMix(s, ek.slice(16, 32), MASK, 5);
    for (let x9 = 1;x9 <= 8; x9++) {
      s = fibonacciMix(s);
      const ekOff = x9 * 32;
      if (x9 === 8) {
        s = condMix(s, ek.slice(256, 272), MASK, 3);
        break;
      }
      if (mode !== 0 && x9 === 2) {
        for (let i = 0;i < 16; i++) {
          const bitSet = (1 << i & MASK) !== 0;
          s[i] = bitSet ? s[i] ^ initial[i] : initial[i] + s[i] & 255;
        }
      }
      s = condMix(s, ek.slice(ekOff, ekOff + 16), MASK, 3);
      s = sboxSub(s);
      s = condMix(s, ek.slice(ekOff + 16, ekOff + 32), MASK, 5);
    }
    return s;
  }
  function functionE1test(key6, input16, seed16) {
    const expandedKey = Array.from({ length: 16 }, (_, i) => key6[i % 6]);
    const output = input16.slice(0, 16);
    const ks1 = keySchedule(seed16.slice(0, 16));
    const cipherOut = blockCipher(output, ks1, 0);
    for (let i = 0;i < 16; i++) {
      cipherOut[i] = expandedKey[i] + (cipherOut[i] ^ input16[i]) & 255;
    }
    const obf = [
      seed16[0] - 23 & 255,
      seed16[1] ^ 229,
      seed16[2] - 33 & 255,
      seed16[3] ^ 193,
      seed16[4] - 77 & 255,
      seed16[5] ^ 167,
      seed16[6] - 107 & 255,
      seed16[7] ^ 131,
      seed16[8] ^ 233,
      seed16[9] - 27 & 255,
      seed16[10] ^ 223,
      seed16[11] - 63 & 255,
      seed16[12] ^ 179,
      seed16[13] - 89 & 255,
      seed16[14] ^ 149,
      seed16[15] - 125 & 255
    ];
    const ks2 = keySchedule(obf);
    return blockCipher(cipherOut, ks2, 1);
  }
  function getRandomAuthData() {
    const result = new Uint8Array(17);
    result[0] = 0;
    crypto.getRandomValues(result.subarray(1));
    return result;
  }
  function getEncryptedAuthData(deviceData17) {
    const input16 = Array.from(deviceData17.subarray(1, 17));
    const encrypted = functionE1test(MAGIC, input16, STATIC_KEY);
    const result = new Uint8Array(17);
    result[0] = 1;
    for (let i = 0;i < 16; i++)
      result[i + 1] = encrypted[i];
    return result;
  }
  globalThis.JieLiAuth = exports_jl_auth;
})();
