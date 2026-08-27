import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "apsingh.super-productivity"

  property string apiTokenOverride: setting("apiToken", "")
  readonly property int syncIntervalSec: 30
  readonly property int maxTitleLength: Math.max(10, parseInt(setting("maxTitleLength", 32), 10) || 32)

  property string currentTaskTitle: ""
  property int currentTimeSpent: 0
  property int currentTimeEstimate: 0
  property bool hasCurrentTask: currentTaskTitle !== ""

  property int localStartTime: 0
  property int localStartElapsed: 0
  property bool isTimerRunningLocally: false
  
  property bool showRemainingTime: false

  function formatTime(ms) {
    var isNegative = ms < 0
    var absMs = Math.abs(ms)
    var totalSecs = Math.floor(absMs / 1000)
    var hours = Math.floor(totalSecs / 3600)
    var mins = Math.floor((totalSecs % 3600) / 60)
    var secs = totalSecs % 60
    var prefix = isNegative ? "-" : ""
    if (hours > 0) {
      return prefix + hours + ":" + (mins < 10 ? "0" : "") + mins + ":" + (secs < 10 ? "0" : "") + secs
    }
    return prefix + mins + ":" + (secs < 10 ? "0" : "") + secs
  }

  readonly property string displayText: {
    if (!spApi.ready) return "󰄹 SP"
    if (hasCurrentTask) {
      var title = currentTaskTitle.replace(/\n/g, " ")
      if (title.length > maxTitleLength) title = title.substring(0, maxTitleLength - 1) + "…"
      var timeToShow = showRemainingTime && currentTimeEstimate > 0 
        ? (currentTimeEstimate - currentTimeSpent) 
        : currentTimeSpent
      return "▶ " + root.formatTime(timeToShow) + " " + title
    }
    return "󰄹"
  }

  SpApi {
    id: spApi
    overrideToken: root.apiTokenOverride

    onReadyChanged: root.refresh()
  }

  Timer {
    interval: 1000
    running: root.isTimerRunningLocally
    repeat: true
    onTriggered: {
      currentTimeSpent = root.localStartElapsed + (Date.now() - root.localStartTime)
    }
  }

  Timer {
    interval: root.syncIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.syncState()
  }

  function syncState() {
    if (!spApi.ready) return
    spApi.getStatus(function(tag, ok, data) {
      if (ok && data && data.currentTask && data.currentTask.title) {
        var taskRunning = data.currentTask.timeSpent > 0 || root.isTimerRunningLocally
        if (taskRunning && !root.isTimerRunningLocally) {
          root.startLocalTimer(Number(data.currentTask.timeSpent) || 0)
        }
        currentTaskTitle = String(data.currentTask.title)
        currentTimeEstimate = Number(data.currentTask.timeEstimate) || 0
        if (!root.isTimerRunningLocally) {
          currentTimeSpent = Number(data.currentTask.timeSpent) || 0
        }
      } else {
        if (root.isTimerRunningLocally) {
          root.isTimerRunningLocally = false
        }
        currentTaskTitle = ""
        currentTimeSpent = 0
        currentTimeEstimate = 0
      }
      if (panelLoader.item && panelLoader.item.onStatusUpdate) panelLoader.item.onStatusUpdate(ok, data)
    })
  }

  function startLocalTimer(elapsed) {
    root.localStartElapsed = elapsed
    root.localStartTime = Date.now()
    root.isTimerRunningLocally = true
    root.currentTimeSpent = elapsed
  }

  function refresh() {
    if (!spApi.ready) return
    spApi.getStatus(function(tag, ok, data) {
      if (ok && data && data.currentTask && data.currentTask.title) {
        currentTaskTitle = String(data.currentTask.title)
        currentTimeSpent = Number(data.currentTask.timeSpent) || 0
        if (currentTimeSpent > 0 && !root.isTimerRunningLocally) {
          root.startLocalTimer(currentTimeSpent)
        }
      } else {
        currentTaskTitle = ""
        currentTimeSpent = 0
        root.isTimerRunningLocally = false
      }
      if (panelLoader.item && panelLoader.item.onStatusUpdate) panelLoader.item.onStatusUpdate(ok, data)
    })
  }

  function toggleTimeDisplay() {
    showRemainingTime = !showRemainingTime
  }

  function loadTodayTasks(includeDone, callback) {
    spApi.getTodayTasks(includeDone, callback)
  }

  function loadAllTasks(includeDone, callback) {
    spApi.getAllTasks(includeDone, callback)
  }

  function loadCompletedTasks(callback) {
    spApi.getCompletedTasks(callback)
  }

  function stopTimer() {
    root.isTimerRunningLocally = false
    currentTimeSpent = 0
    spApi.stopTimer(function(tag, ok, data) { syncState() })
  }

  function startTask(taskId) {
    spApi.getTask(taskId, function(tag, ok, data) {
      var taskElapsed = 0
      if (ok && data) {
        taskElapsed = Number(data.timeSpent) || 0
      }
      root.startLocalTimer(taskElapsed)
      currentTaskTitle = ok && data ? String(data.title || "") : ""
      spApi.startTask(taskId, function(tag, ok, data) { syncState() })
    })
  }

  function completeTask(taskId) {
    spApi.completeTask(taskId, function(tag, ok, data) { refresh() })
  }

  function deleteTask(taskId) {
    spApi.deleteTask(taskId, function(tag, ok, data) { refresh() })
  }

  function addTask(title) {
    spApi.addTask(title, function(tag, ok, data) { refresh() })
  }

  // ---- Panel lifecycle contract (Bar.findPanelWidget requires
  //      open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  IpcHandler {
    target: "apsingh.super-productivity"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: true
    tooltipText: root.hasCurrentTask ? root.currentTaskTitle : "Super Productivity"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.stopTimer()
      else root.togglePanel()
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
}
