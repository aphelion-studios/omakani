#!/usr/bin/env node
// Test suite for Kana.js -- run:  node Kana.test.js
// Strips the QML `.pragma library` line, then evals the module.

const fs = require("fs");
const path = require("path");

const src = fs.readFileSync(path.join(__dirname, "Kana.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "");
const K = {};
eval(src + "\nK.toKana=toKana;K.katakanaToHiragana=katakanaToHiragana;K.isKana=isKana;");

const KANA = [
  ["ichi", "いち"],
  ["shuppatsu", "しゅっぱつ"],
  ["kippu", "きっぷ"],
  ["nihon", "にほん"],
  ["shinbun", "しんぶん"],
  ["kin'youbi", "きんようび"],
  ["gakkou", "がっこう"],
  ["sensei", "せんせい"],
  ["chotto", "ちょっと"],
  ["ryokou", "りょこう"],
  ["ohayou", "おはよう"],
  ["ja", "じゃ"],
  ["jya", "じゃ"],
  ["tsuki", "つき"],
  ["n", "ん"],
  ["onna", "おんな"],
  ["shinnen", "しんねん"],
  ["konnichiwa", "こんにちわ"],
  ["xtsu", "っ"],
  ["kya", "きゃ"],
  ["fufun", "ふふん"],
  ["daigaku", "だいがく"],
  ["kyou", "きょう"],
  ["wo", "を"],
  ["desu", "です"],
];

let failed = 0;
for (const [input, expected] of KANA) {
  const got = K.toKana(input);
  if (got !== expected) {
    failed++;
    console.error(`FAIL  toKana(${JSON.stringify(input)}) = ${JSON.stringify(got)}, want ${JSON.stringify(expected)}`);
  }
}

function check(name, got, want) {
  if (got !== want) {
    failed++;
    console.error(`FAIL  ${name} = ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  }
}
check("katakanaToHiragana", K.katakanaToHiragana("ニチ"), "にち");
check("isKana(kana)", K.isKana("しゅっぱつ"), true);
check("isKana(romaji)", K.isKana("shu"), false);

// toKana must be idempotent -- feeding it kana returns the same kana
// (doubled vowels like おお must not turn into っお).
for (const kana of ["おおきさ", "がっこう", "きゅう", "しゅっぱつ",
    "ぜんぜん", "こんにちは", "ええ", "とおい"]) {
  check("idempotent " + kana, K.toKana(kana), kana);
}

if (failed) {
  console.error(`\n${failed} test(s) failed`);
  process.exit(1);
}
console.log(`Kana.js: ${KANA.length + 3} tests passed`);
