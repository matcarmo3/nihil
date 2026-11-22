// a small highlighter for the Nihil samples: comments, strings, numbers and the symbols that replace keywords
document.querySelectorAll("pre.nihil").forEach(function (pre) {
  var text = pre.textContent;
  var out = "";
  var esc = function (s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); };
  var re = /(\/\/[^\n]*)|("(?:\\.|[^"\\])*")|(\b\d+(?:\.\d+)?\b)|(@\{\d*\}>>|@\{\d*\}|@>>|@\+>>|@\[|@|>>|<<|::|\|\||\*(?= )|\b_\b|#(?=\w))/g;
  var last = 0, m;
  while ((m = re.exec(text)) !== null) {
    out += esc(text.slice(last, m.index));
    var cls = m[1] ? "c" : m[2] ? "s" : m[3] ? "n" : "y";
    out += '<span class="' + cls + '">' + esc(m[0]) + "</span>";
    last = re.lastIndex;
  }
  out += esc(text.slice(last));
  pre.innerHTML = out;
});
