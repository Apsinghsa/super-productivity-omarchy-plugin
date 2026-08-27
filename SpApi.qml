import QtQuick
import Quickshell
import Quickshell.Io

// Client for Super Productivity's local REST API (127.0.0.1:3876).
// The Bearer token is read from the app's data folder; it can be
// overridden per-widget with the "apiToken" setting in shell.json.
Item {
  id: root

  property string baseUrl: "http://127.0.0.1:3876"
  property string token: ""
  property bool ready: token !== ""
  property string overrideToken: ""

  onOverrideTokenChanged: {
    if (overrideToken !== "") root.token = overrideToken
  }

  FileView {
    id: tokenFile

    path: "file://" + Quickshell.env("HOME") + "/.config/superProductivity/local-rest-api-token"
    blockLoading: true
    watchChanges: true
    onLoaded: {
      if (root.overrideToken === "") root.token = text().trim()
    }
  }

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

  function request(method, path, payload, tag, callback) {
    if (!ready) {
      console.warn("[super-productivity] no token, skipping", method, path)
      if (callback) callback(tag, false, null)
      return
    }

    var cmd = ["curl", "-sS", "-m", "8", "-X", method,
               "-H", "Authorization: Bearer " + token]
    if (payload !== null && payload !== undefined) cmd.push("-d", JSON.stringify(payload))
    cmd.push(baseUrl + path)

    var proc = requestFactory.createObject(root, { tag: tag, callback: callback })
    proc.command = cmd
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
