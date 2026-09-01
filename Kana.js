// Romaji -> hiragana, the way WaniKani's reading input does it. Users type
// "shuppatsu" and the field shows しゅっぱつ; the answer checker compares the
// kana, so this has to match WK's conversion closely.
//
// Rules beyond the plain syllable table:
//   * a doubled consonant (kk, pp, tt, ss ...) becomes small tsu + the
//     syllable ("kk" -> っ + か-row).  "nn" is the exception -> ん.
//   * "n" before a consonant, an apostrophe, or end of string -> ん.
//   * "n" before a vowel or "y" starts the な-row instead.
//   * long vowels are left as the user typed them ("ou", not "お").
//   * unknown characters pass straight through.

.pragma library

var TABLE = {
  a: "あ", i: "い", u: "う", e: "え", o: "お",
  ka: "か", ki: "き", ku: "く", ke: "け", ko: "こ",
  ga: "が", gi: "ぎ", gu: "ぐ", ge: "げ", go: "ご",
  sa: "さ", si: "し", shi: "し", su: "す", se: "せ", so: "そ",
  za: "ざ", zi: "じ", ji: "じ", zu: "ず", ze: "ぜ", zo: "ぞ",
  ta: "た", ti: "ち", chi: "ち", tu: "つ", tsu: "つ", te: "て", to: "と",
  da: "だ", di: "ぢ", du: "づ", de: "で", "do": "ど",
  na: "な", ni: "に", nu: "ぬ", ne: "ね", no: "の",
  ha: "は", hi: "ひ", fu: "ふ", hu: "ふ", he: "へ", ho: "ほ",
  ba: "ば", bi: "び", bu: "ぶ", be: "べ", bo: "ぼ",
  pa: "ぱ", pi: "ぴ", pu: "ぷ", pe: "ぺ", po: "ぽ",
  ma: "ま", mi: "み", mu: "む", me: "め", mo: "も",
  ya: "や", yu: "ゆ", yo: "よ",
  ra: "ら", ri: "り", ru: "る", re: "れ", ro: "ろ",
  wa: "わ", wi: "ゐ", we: "ゑ", wo: "を", "n": "ん", nn: "ん",
  vu: "ゔ",

  kya: "きゃ", kyu: "きゅ", kyo: "きょ",
  gya: "ぎゃ", gyu: "ぎゅ", gyo: "ぎょ",
  sha: "しゃ", shu: "しゅ", sho: "しょ",
  sya: "しゃ", syu: "しゅ", syo: "しょ",
  ja: "じゃ", ju: "じゅ", jo: "じょ",
  jya: "じゃ", jyu: "じゅ", jyo: "じょ",
  zya: "じゃ", zyu: "じゅ", zyo: "じょ",
  cha: "ちゃ", chu: "ちゅ", cho: "ちょ",
  cya: "ちゃ", cyu: "ちゅ", cyo: "ちょ",
  tya: "ちゃ", tyu: "ちゅ", tyo: "ちょ",
  nya: "にゃ", nyu: "にゅ", nyo: "にょ",
  hya: "ひゃ", hyu: "ひゅ", hyo: "ひょ",
  bya: "びゃ", byu: "びゅ", byo: "びょ",
  pya: "ぴゃ", pyu: "ぴゅ", pyo: "ぴょ",
  mya: "みゃ", myu: "みゅ", myo: "みょ",
  rya: "りゃ", ryu: "りゅ", ryo: "りょ",

  fa: "ふぁ", fi: "ふぃ", fe: "ふぇ", fo: "ふぉ",
  "-": "ー"
};

var SMALL = {
  a: "ぁ", i: "ぃ", u: "ぅ", e: "ぇ", o: "ぉ",
  ya: "ゃ", yu: "ゅ", yo: "ょ", tsu: "っ"
};

var SOKUON = "っ"; // small tsu
var LATIN_CONSONANT = "bcdfghjkmpqrstvwxyz"; // 'n' handled on its own

function isVowel(c) { return "aiueo".indexOf(c) >= 0; }

function toKana(input) {
  var s = String(input || "").toLowerCase();
  var out = "";
  var i = 0;
  while (i < s.length) {
    var c = s.charAt(i);

    // small-kana form: leading "x" / "l" ("xtsu" -> っ, "xya" -> ゃ, "xa" -> ぁ)
    if ((c === "x" || c === "l") && i + 1 < s.length) {
      var rest3 = s.substr(i + 1, 3);
      var rest2 = s.substr(i + 1, 2);
      var rest1 = s.substr(i + 1, 1);
      if (SMALL[rest3]) { out += SMALL[rest3]; i += 4; continue; }
      if (SMALL[rest2]) { out += SMALL[rest2]; i += 3; continue; }
      if (SMALL[rest1]) { out += SMALL[rest1]; i += 2; continue; }
    }

    // sokuon: a doubled *latin* consonant that isn't "nn". Guarding on latin
    // keeps toKana idempotent -- "おお" must stay "おお", not become "っお".
    if (c !== "n" && LATIN_CONSONANT.indexOf(c) >= 0
        && i + 1 < s.length && s.charAt(i + 1) === c) {
      out += SOKUON;
      i += 1;
      continue;
    }

    // standalone ん -- before end, an apostrophe, another "n", or any
    // consonant except "y".
    if (c === "n") {
      var next = i + 1 < s.length ? s.charAt(i + 1) : "";
      if (next === "'") { out += TABLE["n"]; i += 2; continue; }
      if (next === "n") {
        // "nn" is one ん; consume both only if nothing follows (so "onna"
        // -> おんな keeps the second n for the な-row, but "nn" -> ん).
        var after = i + 2 < s.length ? s.charAt(i + 2) : "";
        out += TABLE["n"];
        i += (after === "") ? 2 : 1;
        continue;
      }
      if (next === "" || (!isVowel(next) && next !== "y")) {
        out += TABLE["n"]; i += 1; continue;
      }
    }

    // longest syllable match, 3 -> 2 -> 1
    var three = s.substr(i, 3);
    var two = s.substr(i, 2);
    var one = s.substr(i, 1);
    if (TABLE[three]) { out += TABLE[three]; i += 3; continue; }
    if (TABLE[two]) { out += TABLE[two]; i += 2; continue; }
    // a bare "n" only reaches here when it's followed by "y" but no full
    // nya/nyu/nyo has been typed yet (a standalone ん before any other
    // consonant was already handled above) -- leave it as a literal "n" so
    // "ny" -> "nya" can still become にゃ, not んや
    if (TABLE[one] && one !== "n") { out += TABLE[one]; i += 1; continue; }

    // nothing matched -- pass the character through
    out += c;
    i += 1;
  }
  return out;
}

// Katakana -> hiragana, for comparing an on'yomi answer that came back in
// katakana against hiragana input.
function katakanaToHiragana(text) {
  return String(text || "").replace(/[ァ-ヶ]/g, function (ch) {
    return String.fromCharCode(ch.charCodeAt(0) - 0x60);
  });
}

// Is the string entirely kana (+ the long mark)? Used to tell a finished
// reading answer from a half-typed romaji one.
function isKana(text) {
  return /^[぀-ゟ゠-ヿー\s]+$/.test(String(text || ""));
}
