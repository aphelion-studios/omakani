// WaniKani answer checking -- the part that must not be wrong, because a
// false "correct" moves real SRS state through POST /reviews.
//
// This module needs the kana helpers from Kana.js. The consuming QML does:
//     import "Kana.js" as Kana
//     import "Answer.js" as Answer
//     Component.onCompleted: Answer.useKana(Kana)
// then calls Answer.check(subject, studyMaterial, questionType, raw).
//
// check(...) returns:
//   { status: "correct" }                  accept, advance
//   { status: "incorrect" }                wrong, mark it
//   { status: "retry", reason: "..." }     shake, don't count
//
// "retry" is WaniKani's yellow-shake: a meaning typed for a reading question
// (or vice versa), a real-but-unwanted reading, romaji left in a reading
// answer, a "close" blacklisted meaning.

var _kana = null;
function useKana(mod) { _kana = mod; }
function _toKana(s) { return _kana ? _kana.toKana(s) : String(s); }
function _kata(s) { return _kana ? _kana.katakanaToHiragana(s) : String(s); }
function _isKana(s) { return _kana ? _kana.isKana(s) : false; }

// -------------------------------------------------------------- normalising

function normMeaning(text) {
  return String(text || "")
    .toLowerCase()
    .replace(/’/g, "'")
    .replace(/[.,!?;:"()\[\]{}]/g, " ")
    .replace(/\s+/g, " ")
    .replace(/^\s+|\s+$/g, "");
}

// "to eat" -> "eat", so a verb answer without the particle still matches.
function stripTo(text, verb) {
  return verb ? text.replace(/^to\s+/, "") : text;
}

function normReading(text) {
  return _kata(String(text || ""))
    .replace(/\s+/g, "")
    .replace(/[.,!?、。]/g, "");
}

// -------------------------------------------------------------- levenshtein

// Optimal string alignment (restricted Damerau-Levenshtein): like plain edit
// distance but an adjacent transposition ("yaer" -> "year") costs 1, not 2 --
// which is how WaniKani treats that common typo.
function levenshtein(a, b) {
  a = String(a); b = String(b);
  if (a === b) return 0;
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  var d = [];
  for (var i = 0; i <= a.length; i++) { d[i] = [i]; }
  for (var j = 0; j <= b.length; j++) { d[0][j] = j; }
  for (i = 1; i <= a.length; i++) {
    for (j = 1; j <= b.length; j++) {
      var cost = a.charAt(i - 1) === b.charAt(j - 1) ? 0 : 1;
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
      if (i > 1 && j > 1
          && a.charAt(i - 1) === b.charAt(j - 2)
          && a.charAt(i - 2) === b.charAt(j - 1)) {
        d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
      }
    }
  }
  return d[a.length][b.length];
}

// WaniKani's fuzzy tolerance: exact under 4 chars, then loosens with length.
// Matches the website -- an obvious typo ("year eno" for "year end") should
// still be accepted; being made to type it 100% exactly is just annoying.
function closeEnough(correct, given) {
  if (correct === given) return true;
  if (correct.length <= 3) return false;
  var allowed = correct.length <= 5 ? 1 : Math.floor(correct.length / 7) + 1;
  if (Math.abs(correct.length - given.length) > allowed) return false;
  return levenshtein(correct, given) <= allowed;
}

// -------------------------------------------------------------- collectors

function meaningList(subject, studyMaterial) {
  var data = (subject && subject.data) || {};
  var accepted = [];
  var blacklist = [];
  (data.meanings || []).forEach(function (m) {
    if (m && m.meaning && m.accepted_answer !== false) accepted.push(m.meaning);
  });
  (data.auxiliary_meanings || []).forEach(function (m) {
    if (!m || !m.meaning) return;
    if (m.type === "whitelist") accepted.push(m.meaning);
    else if (m.type === "blacklist") blacklist.push(m.meaning);
  });
  ((studyMaterial && studyMaterial.meaning_synonyms) || []).forEach(function (s) {
    if (s) accepted.push(s);
  });
  return { accepted: accepted, blacklist: blacklist };
}

function readingList(subject) {
  var data = (subject && subject.data) || {};
  var accepted = [];
  var acceptedTypes = [];
  var known = [];
  var knownTypes = [];
  (data.readings || []).forEach(function (r) {
    if (!r || !r.reading) return;
    known.push(r.reading);
    knownTypes.push(r.type || "");
    if (r.accepted_answer !== false) {
      accepted.push(r.reading);
      acceptedTypes.push(r.type || "");
    }
  });
  return { accepted: accepted, acceptedTypes: acceptedTypes,
           known: known, knownTypes: knownTypes };
}

// the one reading-type WaniKani is accepting here (onyomi / kunyomi / nanori),
// or "" when it takes more than one -- so we can say which one it wants.
function wantReadingType(types) {
  var seen = {};
  (types || []).forEach(function (t) { if (t) seen[t] = true; });
  var keys = Object.keys(seen);
  return keys.length === 1 ? keys[0] : "";
}
function readingTypeLabel(t) {
  if (t === "onyomi") return "on'yomi";
  if (t === "kunyomi") return "kun'yomi";
  if (t === "nanori") return "nanori";
  return "other";
}

function isVerb(subject) {
  var pos = ((subject && subject.data) || {}).parts_of_speech || [];
  for (var i = 0; i < pos.length; i++) {
    if (/verb/.test(String(pos[i]))) return true;
  }
  return false;
}

// -------------------------------------------------------------- checkers

function checkMeaning(subject, studyMaterial, raw) {
  var given = normMeaning(raw);
  if (given === "") return { status: "retry", reason: "Type an answer" };

  var verb = isVerb(subject);
  var givenBare = stripTo(given, verb);
  var lists = meaningList(subject, studyMaterial);

  for (var i = 0; i < lists.accepted.length; i++) {
    var want = normMeaning(lists.accepted[i]);
    if (given === want || givenBare === stripTo(want, verb))
      return { status: "correct" };
  }
  for (var b = 0; b < lists.blacklist.length; b++) {
    if (closeEnough(normMeaning(lists.blacklist[b]), given))
      return { status: "retry", reason: "Close, but not what we want" };
  }
  for (var j = 0; j < lists.accepted.length; j++) {
    var w = normMeaning(lists.accepted[j]);
    if (closeEnough(w, given) || closeEnough(stripTo(w, verb), givenBare))
      return { status: "correct", fuzzy: true };
  }

  // an English box, but you typed a reading -- romaji, or kana that spells one
  // of this item's readings. WaniKani shakes here instead of marking it wrong,
  // so a fast misread of meaning-vs-reading doesn't cost you the item.
  var bare = String(raw || "").replace(/\s+/g, "");
  if (bare !== "") {
    var asK = _isKana(bare) ? _kata(bare) : _toKana(bare);
    if (asK && _isKana(String(asK).replace(/\s+/g, ""))) {
      var rl = readingList(subject);
      for (var r = 0; r < rl.known.length; r++) {
        if (normReading(asK) === normReading(rl.known[r]))
          return { status: "retry", reason: "We want the meaning, not the reading" };
      }
    }
  }

  if (_isKana(bare))
    return { status: "retry", reason: "We want the meaning here" };

  return { status: "incorrect" };
}

function checkReading(subject, raw) {
  var typed = String(raw || "");
  var asKana = _isKana(typed.replace(/\s+/g, "")) ? typed : _toKana(typed);
  var given = normReading(asKana);
  if (given === "") return { status: "retry", reason: "Type an answer" };

  if (/[a-z]/i.test(given))
    return { status: "retry", reason: "Your answer must be in kana" };

  var lists = readingList(subject);
  for (var i = 0; i < lists.accepted.length; i++) {
    if (given === normReading(lists.accepted[i])) return { status: "correct" };
  }
  for (var k = 0; k < lists.known.length; k++) {
    if (given === normReading(lists.known[k])) {
      // a real reading of this kanji, just not the half being asked -- name the
      // reading type WaniKani wants so you know which way you slipped
      var want = wantReadingType(lists.acceptedTypes);
      if (want && lists.knownTypes[k] && lists.knownTypes[k] !== want)
        return { status: "retry",
                 reason: "WaniKani is looking for the " + readingTypeLabel(want)
                   + " reading." };
      return { status: "retry", reason: "WaniKani wants a different reading" };
    }
  }
  return { status: "incorrect" };
}

// questionType: "meaning" | "reading"
function check(subject, studyMaterial, questionType, raw) {
  if (questionType === "reading") return checkReading(subject, raw);
  return checkMeaning(subject, studyMaterial, raw);
}
