import QtQuick
import Quickshell
import Quickshell.Io

// Client for Super Productivity's local REST API (127.0.0.1:3876).
// The Bearer token is read from the app's data folder; it can be
// overridden per-widget with the "apiToken" setting in shell.json.
//
// Security: the token is never placed in any process argv (visible to
// other local processes via procfs). curl reads it from a private
// config file instead, and every read (token file, API response) is
// size- and time-bounded.
Item {
  id: root

  property string baseUrl: "http://127.0.0.1:3876"
  property string token: ""
  property bool ready: token !== ""
  property string overrideToken: ""

  readonly property string tokenFilePath: Quickshell.env("HOME") + "/.config/superProductivity/local-rest-api-token"
  readonly property string authConfPath: (Quickshell.env("XDG_RUNTIME_DIR") || Quickshell.env("HOME") + "/.cache")
    + "/apsingh-super-productivity-curl.conf"

  onOverrideTokenChanged: {
    if (overrideToken !== "") root.token = overrideToken
    writeAuthConf()
    if (overrideToken === "") root.readToken()
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
    if (value !== root.token) {
      root.token = value
      writeAuthConf()
    }
  }

  // ---- curl auth config file ----
  // curl reads the Authorization header from this file (-K), so the token
  // never appears in argv. Written 0600 inside $XDG_RUNTIME_DIR (0700).
  FileView {
    id: authConf

    path: root.authConfPath
    preload: false
    blockWrites: true
    printErrors: false
  }

  Process {
    id: chmodProc
  }

  function writeAuthConf() {
    var escaped = root.token.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
    authConf.setText('header = "Authorization: Bearer ' + escaped + '"\n')
    chmodProc.command = ["chmod", "600", root.authConfPath]
    chmodProc.running = true
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
          data = parsed.data
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