// WaniKani mnemonic markup -> Qt RichText HTML.
//
// Mnemonics come with inline tags: <radical>, <kanji>, <vocabulary>,
// <reading>, <meaning>, <ja>. Each becomes a coloured bold run so the parts
// of the mnemonic read the way they do on the website. Colours are passed in
// (bright variants tuned for the dark app background). In practice WaniKani's
// mnemonic prose contains no bare "<" or ">" outside its own tags, so a plain
// pass is enough - we only guard stray "&".

.pragma library

var TAGS = ["radical", "kanji", "vocabulary", "reading", "meaning"];

function run(color, inner) {
  return '<font color="' + color + '"><b>' + inner + '</b></font>';
}

// colors: { radical, kanji, vocabulary, reading, meaning }
function toHtml(text, colors) {
  if (!text)
    return "";

  var s = String(text);
  s = s.replace(/&(?!(?:amp|lt|gt|quot|#[0-9]+|#x[0-9a-fA-F]+);)/g, "&amp;");

  var c = colors || {};
  var fallbacks = {
    radical: "#38b6ff",
    kanji: "#ff4fb8",
    vocabulary: "#c06bff",
    reading: "#b79ce0",
    meaning: "#e5c95a"
  };
  for (var i = 0; i < TAGS.length; i++) {
    var name = TAGS[i];
    var color = c[name] || fallbacks[name];
    var re = new RegExp("<" + name + ">([\\s\\S]*?)<\\/" + name + ">", "g");
    s = s.replace(re, (function (col) {
      return function (_, inner) { return run(col, inner); };
    })(color));
  }
  // <ja> wraps Japanese inside English prose - keep it in a CJK face so the
  // kana/kanji render even when the body font has no Japanese glyphs.
  var jp = c.jp || "Noto Sans CJK JP";
  s = s.replace(/<ja>([\s\S]*?)<\/ja>/g, '<font face="' + jp + '">$1</font>');
  s = s.replace(/\r?\n/g, "<br>");
  return s;
}

// The primary meaning, or the first, from a subject's meanings array.
function primaryMeaning(meanings) {
  var list = Array.isArray(meanings) ? meanings : [];
  var primary = null;
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].primary) { primary = list[i]; break; }
  }
  return (primary || list[0] || {}).meaning || "";
}

// "onyomi" -> "On'yomi" and friends, for the reading-type labels.
function readingTypeLabel(type) {
  if (type === "onyomi") return "On'yomi";
  if (type === "kunyomi") return "Kun'yomi";
  if (type === "nanori") return "Nanori";
  return "";
}
