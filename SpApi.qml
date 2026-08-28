import QtQuick
import Quickshell
import Quickshell.Io

// Client for Super Productivity's local REST API (127.0.0.1:3876).
// The Bearer token is read from the app's data folder; it can be
// overridden per-widget with the "apiToken" setting in shell.json.
//
// Security:
//  - The token never appears in any process argv (procfs-visible). curl reads
//    it from a config file written by write-auth-conf.sh: private 0700 dir,
//    randomly named 0600 file, fsync, atomic rename, refuses unsafe locations.
//  - The token is strictly validated (8-128 chars of [A-Za-z0-9_.-]), so no
//    newline, quote or control can inject curl config directives.
//  - Every read (token file, API response) is size- and time-bounded, and API
//    responses are additionally sanitized into a bounded schema (task/subtask
//    counts, id/title lengths, control-char and markup stripping) before they
//    reach QML models.
Item {
  id: root

  property string baseUrl: "http://127.0.0.1:3876"
  property string token: ""
  property bool ready: token !== ""
  property string overrideToken: ""

  readonly property string tokenFilePath: Quickshell.env("HOME") + "/.config/superProductivity/local-rest-api-token"
  readonly property string authBaseDir: Quickshell.env("XDG_RUNTIME_DIR") || Quickshell.env("HOME") + "/.cache"
  readonly property string authConfDir: root.authBaseDir + "/apsingh-super-productivity"
  readonly property string authConfPath: root.authConfDir + "/curl.conf"
  readonly property string authScriptPath: decodeURIComponent(Qt.resolvedUrl("write-auth-conf.sh").toString().replace(/^file:\/\//, ""))

  onOverrideTokenChanged: {
    if (overrideToken !== "" && root.validToken(overrideToken)) {
      root.token = overrideToken
      writeAuthConf()
    } else if (overrideToken !== "") {
      console.warn("[super-productivity] apiToken override rejected: expected 8-128 chars of [A-Za-z0-9_.-]")
    }
    if (overrideToken === "") root.readToken()
  }

  function validToken(value) {
    return /^[A-Za-z0-9_.-]{8,128}$/.test(value)
  }

  // ---- Bounded token read ----
  // Reads the token file through a time- and size-limited process instead of
  // an unbounded FileView: a FIFO or oversized token file can neither block
  // the shell (async, killed after 2s) nor exhaust its memory (capped at 4KiB).
  component TokenReader: Process {
    id: tok

    stdout: StdioCollector {
      onStreamFinished: {
        root.applyToken(text)
        tok.destroy()
      }
    }
  }

  Component {
    id: tokenReaderFactory

    TokenReader {}
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.readToken()
  }

  function readToken() {
    if (root.overrideToken !== "") return
    var proc = tokenReaderFactory.createObject(root)
    proc.command = ["timeout", "2", "head", "-c", "4096", root.tokenFilePath]
    proc.running = true
  }

  function applyToken(text) {
    var value = text.trim()
    if (value === "" || root.overrideToken !== "") return
    if (!root.validToken(value)) {
      console.warn("[super-productivity] token file rejected: expected 8-128 chars of [A-Za-z0-9_.-]")
      return
    }
    if (value !== root.token) {
      root.token = value
      writeAuthConf()
    }
  }

  // ---- curl auth config file ----
  // write-auth-conf.sh receives the token on stdin (never argv), validates
  // it, and writes it atomically into a verified-private directory.
  component AuthWriter: Process {
    id: w

    stdinEnabled: true
    property string errText: ""

    stderr: StdioCollector {
      onStreamFinished: w.errText = text
    }

    onStarted: w.write(root.token + "\n")

    onExited: function(code) {
      if (code !== 0) {
        console.warn("[super-productivity] auth config write failed:", w.errText.trim())
      }
      w.destroy()
    }
  }

  Component {
    id: authWriterFactory

    AuthWriter {}
  }

  function writeAuthConf() {
    if (!root.validToken(root.token)) return
    var proc = authWriterFactory.createObject(root)
    proc.command = [root.authScriptPath, root.authConfDir, root.authConfPath]
    proc.running = true
  }

  // ---- Bounded API requests ----
  component RequestProcess: Process {
    id: proc

    property string tag: ""
    property var callback: null
    property string responseText: ""

    stdout: StdioCollector {
      onStreamFinished: proc.responseText = text
    }

    onExited: function(code) {
      var ok = code === 0 && responseText.length > 0
      var data = null
      try {
        var parsed = JSON.parse(responseText)
        if (parsed.ok === true) {
          var clean = root.sanitizeResponse(tag, parsed.data)
          if (clean === null) {
            ok = false
            console.warn("[super-productivity] API response rejected: malformed or out of bounds")
          } else {
            data = clean
          }
        } else {
          ok = false
          console.warn("[super-productivity] API error:", JSON.stringify(parsed.error))
        }
      } catch (e) {
        ok = false
      }
      if (callback) callback(tag, ok, data)
      destroy()
    }
  }

  Component {
    id: requestFactory

    RequestProcess {}
  }

  // The command runs through sh with static script text; method, config
  // path, url and payload are positional args, so no credential lands in
  // argv. `head -c` caps how much of the response the shell buffers.
  readonly property string reqScriptNoBody: "curl -sS -m 8 -X \"$1\" -K \"$2\" \"$3\" | head -c 1048576"
  readonly property string reqScriptBody: "curl -sS -m 8 -X \"$1\" -K \"$2\" -d \"$4\" \"$3\" | head -c 1048576"

  function request(method, path, payload, tag, callback) {
    if (!ready) {
      console.warn("[super-productivity] no token, skipping", method, path)
      if (callback) callback(tag, false, null)
      return
    }

    var hasPayload = payload !== null && payload !== undefined
    var args = ["sp", method, root.authConfPath, baseUrl + path]
    if (hasPayload) args.push(JSON.stringify(payload))

    var proc = requestFactory.createObject(root, { tag: tag, callback: callback })
    proc.command = ["sh", "-c", hasPayload ? root.reqScriptBody : root.reqScriptNoBody].concat(args)
    proc.running = true
  }

  // ---- Response sanitization ----
  // Bounds the data assigned to QML models: capped task/subtask counts, capped
  // and control-stripped strings, < > removed so no API text can trigger rich
  // text rendering, and malformed shapes rejected (null => request error).
  readonly property int maxTasks: 200
  readonly property int maxSubTasks: 50
  readonly property int maxIdLen: 64
  readonly property int maxTitleLen: 300

  function cleanText(value, max) {
    if (typeof value !== "string") return ""
    var s = value.replace(/[\u0000-\u001F\u007F<>]/g, "")
    if (s.length > max) s = s.substring(0, max)
    return s
  }

  function cleanId(value) {
    if (value === null || value === undefined) return ""
    return root.cleanText(String(value), root.maxIdLen)
  }

  function cleanTask(raw) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null
    var task = {
      id: root.cleanId(raw.id),
      title: root.cleanText(raw.title, root.maxTitleLen),
      isDone: raw.isDone === true,
      timeSpent: Math.max(0, Number(raw.timeSpent) || 0),
      timeEstimate: Math.max(0, Number(raw.timeEstimate) || 0),
      parentId: raw.parentId === null || raw.parentId === undefined ? null : root.cleanId(raw.parentId),
      subTaskIds: [],
      subtasks: []
    }
    if (Array.isArray(raw.subTaskIds)) {
      for (var i = 0; i < raw.subTaskIds.length && task.subTaskIds.length < root.maxSubTasks; i++) {
        var sid = root.cleanId(raw.subTaskIds[i])
        if (sid !== "") task.subTaskIds.push(sid)
      }
    }
    return task
  }

  function sanitizeTaskList(raw) {
    if (!Array.isArray(raw)) return null
    var out = []
    for (var i = 0; i < raw.length && out.length < root.maxTasks; i++) {
      var task = root.cleanTask(raw[i])
      if (task !== null) out.push(task)
    }
    return out
  }

  function sanitizeStatus(raw) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null
    var status = {
      currentTask: null,
      currentTaskId: raw.currentTaskId === null || raw.currentTaskId === undefined
        ? "" : root.cleanId(raw.currentTaskId),
      taskCount: Math.max(0, Number(raw.taskCount) || 0)
    }
    if (raw.currentTask !== null && raw.currentTask !== undefined) {
      status.currentTask = root.cleanTask(raw.currentTask)
    }
    return status
  }

  function sanitizeResponse(tag, raw) {
    if (tag === "tasks") return root.sanitizeTaskList(raw)
    if (tag === "status") return root.sanitizeStatus(raw)
    if (tag === "task" || tag === "add") return root.cleanTask(raw)
    return raw
  }

  function getStatus(callback) {
    request("GET", "/status", null, "status", callback)
  }

  function getTask(taskId, callback) {
    request("GET", "/tasks/" + taskId, null, "task", callback)
  }

  function getTodayTasks(includeDone, callback) {
    request("GET", "/tasks?tagId=TODAY&includeDone=" + (includeDone ? "true" : "false"), null, "tasks", callback)
  }

  function getAllTasks(includeDone, callback) {
    request("GET", "/tasks?includeDone=" + (includeDone ? "true" : "false"), null, "tasks", callback)
  }

  function getCompletedTasks(callback) {
    request("GET", "/tasks?includeDone=true", null, "tasks", callback)
  }

  function addTask(title, callback) {
    request("POST", "/tasks", { title: title }, "add", callback)
  }

  function completeTask(taskId, callback) {
    request("PATCH", "/tasks/" + taskId, { isDone: true }, "done", callback)
  }

  function deleteTask(taskId, callback) {
    request("DELETE", "/tasks/" + taskId, null, "delete", callback)
  }

  function startTask(taskId, callback) {
    request("POST", "/tasks/" + taskId + "/start", {}, "start", callback)
  }

  function stopTimer(callback) {
    request("POST", "/task-control/stop", {}, "stop", callback)
  }
}