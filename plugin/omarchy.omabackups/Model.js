.pragma library

function parseDetect(raw) {
  try {
    return JSON.parse(raw)
  } catch (e) {
    return null
  }
}

function diskLabel(d) {
  if (!d) return ""
  var labels = (d.labels || []).filter(function (x) { return x && x.length })
  var bits = [d.path, d.size || "", d.model || ""].filter(function (x) { return x && String(x).length })
  if (labels.length) bits.push(labels.join(","))
  if (d.protected) bits.push("live system")
  return bits.join("  ")
}

function candidateDisks(detect) {
  if (!detect || !detect.disks) return []
  return detect.disks.filter(function (d) { return !d.protected })
}

function capsuleDisk(detect) {
  if (!detect || !detect.disks) return null
  for (var i = 0; i < detect.disks.length; i++) {
    if (detect.disks[i].capsule) return detect.disks[i]
  }
  return null
}

function parseSnapshots(text) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line.indexOf("VALID") === 0) {
      var parts = line.split(/\s+/)
      out.push({ valid: true, timestamp: parts[1] || "", raw: line })
    }
  }
  return out
}
