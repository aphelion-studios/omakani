#!/usr/bin/env node
// Test suite for Answer.js -- run:  node Answer.test.js

const fs = require("fs");
const path = require("path");

function load(name, extra) {
  const src = fs.readFileSync(path.join(__dirname, name), "utf8")
    .replace(/^\.pragma library\s*$/m, "");
  const mod = {};
  eval(src + "\n" + extra);
  return mod;
}
const Kana = load("Kana.js",
  "mod.toKana=toKana;mod.katakanaToHiragana=katakanaToHiragana;mod.isKana=isKana;");
const Answer = load("Answer.js", "mod.check=check;mod.useKana=useKana;");
Answer.useKana(Kana);

// ---- fixtures (shaped like the helper's `detail` output) ----

const kanjiOne = {
  object: "kanji",
  data: {
    meanings: [{ meaning: "One", primary: true, accepted_answer: true }],
    auxiliary_meanings: [],
    readings: [
      { reading: "いち", primary: true, accepted_answer: true, type: "onyomi" },
      { reading: "いつ", primary: false, accepted_answer: true, type: "onyomi" },
      { reading: "ひと", primary: false, accepted_answer: false, type: "kunyomi" },
    ],
    parts_of_speech: [],
  },
};

const vocabToEat = {
  object: "vocabulary",
  data: {
    meanings: [{ meaning: "To Eat", primary: true, accepted_answer: true }],
    auxiliary_meanings: [{ meaning: "eating", type: "whitelist" }],
    readings: [{ reading: "たべる", primary: true, accepted_answer: true }],
    parts_of_speech: ["ichidan verb", "transitive verb"],
  },
};

const vocabDog = {
  object: "vocabulary",
  data: {
    meanings: [{ meaning: "Dog", primary: true, accepted_answer: true }],
    auxiliary_meanings: [{ meaning: "cat", type: "blacklist" }],
    readings: [{ reading: "いぬ", primary: true, accepted_answer: true }],
    parts_of_speech: ["noun"],
  },
};

const vocabYearEnd = {
  object: "vocabulary",
  data: {
    meanings: [{ meaning: "Year End", primary: true, accepted_answer: true }],
    auxiliary_meanings: [],
    readings: [{ reading: "ねんまつ", primary: true, accepted_answer: true }],
    parts_of_speech: ["noun"],
  },
};

const vocabInternational = {
  object: "vocabulary",
  data: {
    meanings: [{ meaning: "International", primary: true, accepted_answer: true }],
    auxiliary_meanings: [],
    readings: [{ reading: "こくさい", primary: true, accepted_answer: true }],
    parts_of_speech: ["noun"],
  },
};

let failed = 0;
function t(label, got, want) {
  const g = JSON.stringify(got.status);
  if (got.status !== want) {
    failed++;
    console.error(`FAIL  ${label}: got ${g} (${got.reason || ""}), want ${JSON.stringify(want)}`);
  }
}

// meaning: exact / case / whitespace
t("One exact", Answer.check(kanjiOne, null, "meaning", "one"), "correct");
t("One caps", Answer.check(kanjiOne, null, "meaning", "  ONE "), "correct");
t("One wrong", Answer.check(kanjiOne, null, "meaning", "two"), "incorrect");

// meaning: verb "to " prefix optional
t("to eat / eat", Answer.check(vocabToEat, null, "meaning", "eat"), "correct");
t("to eat / to eat", Answer.check(vocabToEat, null, "meaning", "to eat"), "correct");
t("to eat / whitelist", Answer.check(vocabToEat, null, "meaning", "eating"), "correct");

// meaning: typo tolerance scales with length
t("international typo", Answer.check(vocabInternational, null, "meaning", "internationl"), "correct");
t("eating typo (len6)", Answer.check(vocabToEat, null, "meaning", "eatng"), "correct");
// "dog" is 3 chars -> no fuzz at all; strict is the safe failure for SRS
t("dog vs dogs (short, strict)", Answer.check(vocabDog, null, "meaning", "dogs"), "incorrect");
t("dog vs dig", Answer.check(vocabDog, null, "meaning", "dig"), "incorrect");

// multi-word: obvious typos are accepted, like the website
t("year end exact", Answer.check(vocabYearEnd, null, "meaning", "year end"), "correct");
t("year eno (one letter off)", Answer.check(vocabYearEnd, null, "meaning", "year eno"), "correct");
t("yaer end (transposition)", Answer.check(vocabYearEnd, null, "meaning", "yaer end"), "correct");

// meaning: blacklist "close" -> retry, not correct
t("dog / cat blacklist", Answer.check(vocabDog, null, "meaning", "cat"), "retry");

// meaning: synonyms from study material
t("synonym", Answer.check(vocabDog, { meaning_synonyms: ["pup"] }, "meaning", "pup"), "correct");

// meaning: kana typed for a meaning question -> retry
t("kana for meaning", Answer.check(kanjiOne, null, "meaning", "いち"), "retry");

// reading: romaji -> kana, accepted
t("One reading romaji", Answer.check(kanjiOne, null, "reading", "ichi"), "correct");
t("One reading kana", Answer.check(kanjiOne, null, "reading", "いち"), "correct");
t("One reading alt accepted", Answer.check(kanjiOne, null, "reading", "itsu"), "correct");

// reading: real but non-accepted reading -> retry
t("One reading kunyomi -> retry", Answer.check(kanjiOne, null, "reading", "hito"), "retry");

// reading: wrong -> incorrect
t("One reading wrong", Answer.check(kanjiOne, null, "reading", "san"), "incorrect");

// reading: no typo tolerance
t("reading typo is wrong", Answer.check(vocabInternational, null, "reading", "こくさ"), "incorrect");

// reading: incomplete romaji still has latin -> retry
t("half romaji reading", Answer.check(vocabToEat, null, "reading", "tabe.z"), "retry");

if (failed) {
  console.error(`\n${failed} test(s) failed`);
  process.exit(1);
}
console.log("Answer.js: all tests passed");
