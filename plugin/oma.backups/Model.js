.pragma library

function diskLabel(d) {
  if (!d) return ""
  var labels = (d.labels || []).filter(function (x) { return x && x.length })
  var bits = [d.path, d.size || "", d.model || ""].filter(function (x) { return x && String(x).length })
  if (d.tran) bits.push(d.tran)
  if (labels.length) bits.push(labels.join(","))
  if (d.protected) bits.push("this computer’s own disk — can’t be erased while running")
  else {
    if (d.kind === "internal") bits.push("internal drive")
    // What is already on it (backup disk, rescue stick, a system). Advisory:
    // the disk is still offered, it just stops looking blank.
    if (d.content) bits.push(d.content)
    else if (d.kind === "capsule") bits.push("backup disk")
  }
  return bits.join("  ")
}

function prettyStamp(ts) {
  var s = String(ts || "")
  var m = s.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/)
  if (!m) return s
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var mi = +m[2] - 1
  if (mi < 0 || mi > 11) return s
  return (+m[3]) + " " + months[mi] + " " + m[1] + "  " + m[4] + ":" + m[5]
}

function parseSnapshots(text) {
  var raw = String(text || "").trim()
  if (!raw || raw.indexOf("No restore points") === 0) return []
  if (raw.charAt(0) === "[") {
    try {
      var rows = JSON.parse(raw)
      if (Array.isArray(rows))
        return rows.filter(function (s) { return s && s.timestamp })
    } catch (e) {}
  }
  var lines = raw.split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var stamp = ""
    var title = ""
    var pipe = line.lastIndexOf(" | ")
    if (pipe !== -1) {
      title = line.slice(0, pipe).trim()
      stamp = line.slice(pipe + 3).trim()
    } else if (line.indexOf("VALID") === 0 || line.indexOf("INVAL") === 0) {
      var parts = line.indexOf("\t") !== -1 ? line.split("\t") : line.split(/\s+/)
      stamp = (parts[1] || "").trim()
      title = parts.slice(2).join(" ").trim()
    }
    if (!stamp) {
      var m = line.match(/(\d{8}T\d{6}Z)/)
      if (m) stamp = m[1]
    }
    if (!stamp) continue
    if (!title || /^\d{8}T\d{6}Z$/.test(title)) title = prettyStamp(stamp)
    out.push({ timestamp: stamp, label: title })
  }
  return out
}

function snapshotTitle(s) {
  if (!s) return ""
  if (typeof s === "string") return prettyStamp(s)
  return s.label || prettyStamp(s.timestamp || "")
}

function formatSize(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) return ""
  var units = ["B", "K", "M", "G", "T"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024
    i++
  }
  var digits = (i === 0 || n >= 10) ? 0 : 1
  return n.toFixed(digits) + units[i]
}

function phaseLabel(phase) {
  var p = String(phase || "")
  if (p === "os") return "OS"
  if (p === "home") return "Home"
  if (p === "esp") return "Boot"
  if (p === "rescue") return "Rescue"
  if (p === "snapshot") return "Snapshot"
  if (p === "finalize") return "Finish"
  if (p === "tidy") return "Tidying up"
  if (p === "unlock") return "Unlock"
  if (p === "setup") return "Setting up USB"
  if (p === "waiting-input") return "Waiting for you — enter the new disk password"
  if (p === "error") return "Failed"
  if (p === "done") return "Done"
  return p || "Backup"
}

// "3 days ago", "today", from a Unix time.
function ago(sec, nowSec) {
  var days = Math.floor((nowSec - sec) / 86400)
  if (!(sec > 0) || days < 1) return "today"
  if (days === 1) return "yesterday"
  return days + " days ago"
}

// The disk health line (lib/health.py's record) for the home view:
// { text, urgent }. An empty text hides the line.
function healthLine(h, on, nowSec) {
  h = h || {}
  var state = String(h.state || "unknown")
  var files = Array.isArray(h.files) ? h.files : []
  if (state === "damaged") {
    var names = files.slice(0, 3).map(function (f) { return String(f).split("/").pop() })
    var more = files.length > 3 ? " and " + (files.length - 3) + " more" : ""
    return {
      urgent: true,
      text: "Disk health: DAMAGED. "
        + (files.length ? files.length + (files.length === 1 ? " file" : " files")
          + " no longer match what was backed up (" + names.join(", ") + more + "). "
          : "The disk has corrupted data. ")
        + "Don't rely on this disk: back up to another one."
    }
  }
  if (state === "warning")
    return { urgent: true, text: "Disk health: the disk has reported read or write errors. "
      + "Check its cable and power. No damaged files found so far." }
  if (state === "unknown")
    return { urgent: false, text: on ? "Disk health: not checked yet. It is checked a little each night." : "" }
  var total = Number(h.total_bytes) || 0
  var pct = total > 0 ? Math.min(100, Math.floor(100 * (Number(h.done_bytes) || 0) / total)) : 0
  var text = h.running
    ? "Disk health: checking now, nothing wrong so far (" + pct + "% of this pass)"
    : (h.full_pass_at ? "Disk health: good · whole disk checked " + ago(h.full_pass_at, nowSec)
      : "Disk health: good so far · " + pct + "% of the disk checked")
  var last = Number(h.checked_at) || 0
  if (on && !h.running && last > 0 && nowSec - last > 7 * 86400)
    text += ". Last checked " + ago(last, nowSec) + ": leave the laptop on overnight to keep checking"
  return { urgent: false, text: text }
}
