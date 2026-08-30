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

function levenshtein(a, b) {
  a = String(a); b = String(b);
  if (a === b) return 0;
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  var prev = [];
  for (var j = 0; j <= b.length; j++) prev[j] = j;
  for (var i = 1; i <= a.length; i++) {
    var cur = [i];
    for (var k = 1; k <= b.length; k++) {
      var cost = a.charAt(i - 1) === b.charAt(k - 1) ? 0 : 1;
      cur[k] = Math.min(prev[k] + 1, cur[k - 1] + 1, prev[k - 1] + cost);
    }
    prev = cur;
  }
  return prev[b.length];
}

// WaniKani's fuzzy tolerance: exact under 4 chars, then loosens with length.
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
  var known = [];
  (data.readings || []).forEach(function (r) {
    if (!r || !r.reading) return;
    known.push(r.reading);
    if (r.accepted_answer !== false) accepted.push(r.reading);
  });
  return { accepted: accepted, known: known };
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

  if (_isKana(String(raw || "").replace(/\s+/g, "")))
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
    if (given === normReading(lists.known[k]))
      return { status: "retry", reason: "WaniKani wants a different reading" };
  }
  return { status: "incorrect" };
}

// questionType: "meaning" | "reading"
function check(subject, studyMaterial, questionType, raw) {
  if (questionType === "reading") return checkReading(subject, raw);
  return checkMeaning(subject, studyMaterial, raw);
}
