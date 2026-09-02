import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "apsingh.super-productivity"
  ipcTarget: "apsingh.super-productivity"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property var tasks: []
  property string currentTitle: ""
  property string currentTaskId: ""
  property int currentTimeSpent: 0
  property int currentTimeEstimate: 0
  property string errorText: ""
  property bool loading: false
  property string filterMode: "today"
  
  // Keyboard navigation state
  property int selectedIndex: 0
  property bool cursorActive: false
  
  readonly property real currentProgress: currentTimeEstimate > 0 ? Math.min(1, currentTimeSpent / currentTimeEstimate) : 0
  readonly property int remainingTime: currentTimeEstimate - currentTimeSpent
  
  // Flattened task list for keyboard navigation (parents + subtasks)
  readonly property var flatTasks: {
    var result = []
    for (var i = 0; i < tasks.length; i++) {
      var task = tasks[i]
      result.push({ task: task, isSubtask: false, parentIndex: i })
      if (task.subtasks && task.subtasks.length > 0) {
        for (var j = 0; j < task.subtasks.length; j++) {
          result.push({ task: task.subtasks[j], isSubtask: true, parentIndex: i })
        }
      }
    }
    return result
  }

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

  function open() {
    refresh()
    root.controller.show()
  }

  function close() {
    if (newTaskField.text !== "") newTaskField.text = ""
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    loading = true
    if (hostWidget && typeof hostWidget.refresh === "function") {
      hostWidget.refresh()
    } else {
      loadTasks()
    }
  }

  function loadTasks() {
    if (!root.opened) {
      loading = false
      return
    }
    if (!hostWidget) {
      loading = false
      return
    }
    
    if (filterMode === "today") {
      hostWidget.loadTodayTasks(false, onTasksLoaded)
    } else if (filterMode === "all") {
      hostWidget.loadAllTasks(false, onTasksLoaded)
    } else if (filterMode === "completed") {
      hostWidget.loadCompletedTasks(onTasksLoaded)
    }
  }

  function setFilter(mode) {
    filterMode = mode
    loadTasks()
  }

  function onStatusUpdate(ok, data) {
    if (ok && data && data.currentTask) {
      currentTaskId = String(data.currentTask.id || "")
      currentTitle = String(data.currentTask.title || "")
      currentTimeSpent = Number(data.currentTask.timeSpent) || 0
      currentTimeEstimate = Number(data.currentTask.timeEstimate) || 0
    } else {
      currentTaskId = ""
      currentTitle = ""
      currentTimeSpent = 0
      currentTimeEstimate = 0
    }
    loadTasks()
  }

  function onTasksLoaded(tag, ok, data) {
    loading = false
    if (!ok) {
      tasks = []
      errorText = "Cannot reach Super Productivity.\nEnable it under Settings > Misc > Enable local REST API."
      return
    }
    errorText = ""
    var list = Array.isArray(data) ? data : []
    
    // Build a map of all tasks by ID for subtask lookup
    var taskMap = {}
    for (var i = 0; i < list.length; i++) {
      taskMap[list[i].id] = list[i]
    }
    
    // Filter and organize tasks
    var filtered = []
    for (var i = 0; i < list.length; i++) {
      var task = list[i]
      // Skip current task
      if (currentTaskId !== "" && String(task.id) === currentTaskId) continue
      // Skip subtasks (they'll be attached to parents)
      if (task.parentId !== null && task.parentId !== undefined) continue
      // Apply filter
      if (filterMode === "completed" && !task.isDone) continue
      
      // Attach subtasks if any
      if (task.subTaskIds && task.subTaskIds.length > 0) {
        task.subtasks = []
        for (var j = 0; j < task.subTaskIds.length; j++) {
          var subtask = taskMap[task.subTaskIds[j]]
          if (subtask) {
            // Skip current task if it's a subtask
            if (currentTaskId !== "" && String(subtask.id) === currentTaskId) continue
            // Apply filter to subtasks too
            if (filterMode === "completed" && !subtask.isDone) continue
            task.subtasks.push(subtask)
          }
        }
      } else {
        task.subtasks = []
      }
      
      filtered.push(task)
    }
    
    filtered.sort(function(a, b) {
      if (a.isDone !== b.isDone) return a.isDone ? 1 : -1
      return 0
    })
    tasks = filtered
  }

  function toggleDone(task) {
    if (!hostWidget || task.isDone) return
    if (root.currentTaskId !== "" && String(task.id) === root.currentTaskId) {
      hostWidget.stopTimer()
      currentTitle = ""
      currentTaskId = ""
    }
    hostWidget.completeTask(task.id)
    delayReload.restart()
  }

  function deleteTask(task) {
    if (!hostWidget) return
    hostWidget.deleteTask(task.id)
    delayReload.restart()
  }

  function startTask(task) {
    if (!hostWidget || task.isDone) return
    hostWidget.startTask(task.id)
    currentTitle = task.title
    currentTaskId = task.id
    delayReload.restart()
  }

  function stopTimer() {
    if (!hostWidget) return
    hostWidget.stopTimer()
    currentTitle = ""
    currentTaskId = ""
    delayReload.restart()
  }

  function commitNewTask() {
    var title = newTaskField.text.trim()
    if (title === "" || !hostWidget) return
    newTaskField.text = ""
    hostWidget.addTask(title)
    delayReload.restart()
  }

  // Keyboard navigation functions
  function moveCursor(delta) {
    if (flatTasks.length === 0) return
    cursorActive = true
    selectedIndex = (selectedIndex + delta + flatTasks.length) % flatTasks.length
  }

  function activateSelected() {
    if (!cursorActive || flatTasks.length === 0) return
    var item = flatTasks[selectedIndex]
    if (!item) return
    var task = item.task
    if (task.isDone) return
    
    // If this is the currently running task, complete it
    if (currentTaskId !== "" && String(task.id) === currentTaskId) {
      toggleDone(task)
    } else {
      startTask(task)
    }
  }

  function deleteSelected() {
    if (!cursorActive || flatTasks.length === 0) return
    var item = flatTasks[selectedIndex]
    if (!item) return
    deleteTask(item.task)
    // Adjust selection if needed
    if (selectedIndex >= flatTasks.length) {
      selectedIndex = Math.max(0, flatTasks.length - 1)
    }
  }

  function toggleDoneSelected() {
    if (!cursorActive || flatTasks.length === 0) return
    var item = flatTasks[selectedIndex]
    if (!item) return
    toggleDone(item.task)
  }

  function stopTimerSelected() {
    if (currentTaskId !== "") {
      stopTimer()
    }
  }

  Timer {
    id: delayReload
    interval: 400
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: newTaskField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.activateSelected()
      onDeleteRequested: root.deleteSelected()
      onTextKey: function(t) {
        if (newTaskField.activeFocus) return
        
        if (t === "r" || t === "R") {
          root.refresh()
        } else if (t === "n" || t === "N") {
          newTaskField.forceActiveFocus()
        } else if (t === "q" || t === "Q") {
          root.close()
        } else if (t === "d" || t === "D") {
          root.toggleDoneSelected()
        } else if (t === "x" || t === "X") {
          root.deleteSelected()
        } else if (t === "1") {
          root.setFilter("today")
        } else if (t === "2") {
          root.setFilter("all")
        } else if (t === "3") {
          root.setFilter("completed")
        } else if (t === " ") {
          root.stopTimerSelected()
        }
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: headerLabel.implicitHeight

          Text {
            id: headerLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "SUPER PRODUCTIVITY"
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          PanelActionButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Refresh"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.refresh()
          }
        }

        Text {
          width: parent.width
          visible: errorText !== ""
          text: errorText
          color: root.contentForeground
          opacity: 0.7
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: hostWidget && hostWidget.hasCurrentTask

          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroTimeContainer.implicitHeight + (currentTimeEstimate > 0 ? timeModeLabel.implicitHeight + Style.space(2) : 0))

            Text {
              id: heroIcon
              text: "▶"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: heroTimeContainer.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: hostWidget ? hostWidget.currentTaskTitle : ""
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
                textFormat: Text.PlainText
              }

              Text {
                text: "RUNNING"
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Item {
              id: heroTimeContainer
              width: heroTime.implicitWidth
              height: heroTime.implicitHeight + (currentTimeEstimate > 0 ? timeModeLabel.implicitHeight + Style.space(2) : 0)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                anchors.fill: parent
                visible: currentTimeEstimate > 0
                cursorShape: visible ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  if (hostWidget) {
                    hostWidget.toggleTimeDisplay()
                  }
                }
              }

              Text {
                id: heroTime
                text: {
                  if (!hostWidget) return "0:00"
                  var timeSpent = hostWidget.currentTimeSpent
                  var isRemaining = hostWidget.showRemainingTime
                  var timeToShow = isRemaining ? (currentTimeEstimate - timeSpent) : timeSpent
                  return root.formatTime(timeToShow)
                }
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.displayLarge
                font.bold: true
              }

              Text {
                id: timeModeLabel
                visible: currentTimeEstimate > 0
                text: (hostWidget && hostWidget.showRemainingTime) ? "REMAINING" : "ELAPSED"
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.0
                anchors.top: heroTime.bottom
                anchors.topMargin: Style.space(2)
                anchors.right: parent.right
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: Style.space(8)
            visible: currentTimeEstimate > 0

            Rectangle {
              id: progressTrack
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
            }

            Rectangle {
              id: progressFill
              anchors.left: progressTrack.left
              anchors.verticalCenter: progressTrack.verticalCenter
              height: progressTrack.height
              radius: progressTrack.radius
              color: root.contentForeground
              width: Math.max(progressTrack.height, progressTrack.width * root.currentProgress)

              Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            }
          }

          Row {
            anchors.right: parent.right
            spacing: Style.space(8)

            PanelActionButton {
              iconText: "󰄲"
              tooltipText: "Complete task"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: {
                var id = root.currentTaskId
                root.stopTimer()
                if (id !== "" && root.hostWidget) root.hostWidget.completeTask(id)
              }
            }

            PanelActionButton {
              iconText: "󰆴"
              tooltipText: "Delete task"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: {
                var id = root.currentTaskId
                root.stopTimer()
                if (id !== "" && root.hostWidget) root.hostWidget.deleteTask(id)
              }
            }

            PanelActionButton {
              iconText: "󰓛"
              tooltipText: "Stop timer"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.stopTimer()
            }
          }
        }

        Text {
          width: parent.width
          visible: (!hostWidget || !hostWidget.hasCurrentTask) && errorText === ""
          text: "No task running."
          color: Qt.darker(root.contentForeground, 1.8)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "TASKS"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Row {
            id: filterRow
            width: parent.width
            spacing: Style.space(6)

            readonly property int count: 3
            readonly property real cellWidth: (width - spacing * (count - 1)) / count

            FilterPill {
              filter: "today"
              index: 0
              text: "Today"
              width: filterRow.cellWidth
              onClicked: root.setFilter("today")
            }

            FilterPill {
              filter: "all"
              index: 1
              text: "All"
              width: filterRow.cellWidth
              onClicked: root.setFilter("all")
            }

            FilterPill {
              filter: "completed"
              index: 2
              text: "Completed"
              width: filterRow.cellWidth
              onClicked: root.setFilter("completed")
            }
          }
        }

        // Keyboard hints
        Text {
          width: parent.width
          visible: root.tasks.length > 0
          text: "↑↓ Navigate  •  Enter Start  •  d Done  •  x Delete  •  Space Stop  •  1-3 Filter  •  n New  •  r Refresh  •  q Close"
          color: Qt.darker(root.contentForeground, 1.6)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }

        Flickable {
          width: parent.width
          height: Math.min(taskListColumn.implicitHeight, Style.space(400))
          contentWidth: width
          contentHeight: taskListColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
          }

          Column {
            id: taskListColumn
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.tasks

              delegate: Column {
                required property int index
                required property var modelData

                width: parent.width

                // Parent task row
                Rectangle {
                  id: taskRow
                  width: parent.width
                  height: Math.max(taskTitle.implicitHeight, Style.space(28)) + Style.space(8)
                  radius: Style.cornerRadius
                  
                  // Check if this parent task is selected
                  readonly property bool isSelected: {
                    if (!root.cursorActive || root.flatTasks.length === 0) return false
                    var selected = root.flatTasks[root.selectedIndex]
                    return selected && !selected.isSubtask && selected.parentIndex === taskRow.parent.index
                  }
                  
                  color: isSelected
                    ? Style.selectedFillFor(root.contentForeground, Color.accent)
                    : rowMouse.containsMouse
                      ? Style.hoverFillFor(root.contentForeground, Color.accent)
                      : "transparent"

                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.startTask(taskRow.parent.modelData)
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(6)

                    Item {
                      id: playSlot
                      width: Style.space(24)
                      height: parent.height

                      Text {
                        anchors.centerIn: parent
                        visible: !rowMouse.containsMouse && !taskRow.isSelected
                        text: String(taskRow.parent.index + 1)
                        color: taskRow.parent.modelData.isDone
                          ? Qt.darker(root.contentForeground, 2.2)
                          : Qt.darker(root.contentForeground, 1.8)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      
                      Text {
                        anchors.centerIn: parent
                        visible: taskRow.isSelected
                        text: "▸"
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                      }

                      PanelActionButton {
                        anchors.centerIn: parent
                        visible: (rowMouse.containsMouse || taskRow.isSelected) && !taskRow.parent.modelData.isDone
                        iconText: "󰐊"
                        tooltipText: "Start timer"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                        onClicked: root.startTask(taskRow.parent.modelData)
                      }
                    }

                    Text {
                      id: taskTitle
                      width: parent.width
                        - playSlot.width - deleteSlot.width - doneSlot.width
                        - parent.spacing * 3
                      anchors.verticalCenter: parent.verticalCenter
                      text: taskRow.parent.modelData.title
                      color: taskRow.parent.modelData.isDone
                        ? Qt.darker(root.contentForeground, 2)
                        : root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.strikeout: taskRow.parent.modelData.isDone
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      textFormat: Text.PlainText
                    }

                    Item {
                      id: deleteSlot
                      width: Style.space(24)
                      height: parent.height

                      PanelActionButton {
                        anchors.centerIn: parent
                        visible: rowMouse.containsMouse || taskRow.isSelected
                        iconText: "󰆴"
                        tooltipText: "Delete task"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                        onClicked: root.deleteTask(taskRow.parent.modelData)
                      }
                    }

                    Item {
                      id: doneSlot
                      width: Style.space(24)
                      height: parent.height

                      PanelActionButton {
                        anchors.centerIn: parent
                        iconText: taskRow.parent.modelData.isDone ? "󰄬" : "󰄱"
                        tooltipText: taskRow.parent.modelData.isDone ? "Done" : "Mark done"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                        opacity: taskRow.parent.modelData.isDone ? 0.5 : 1
                        visible: rowMouse.containsMouse || taskRow.isSelected
                        onClicked: root.toggleDone(taskRow.parent.modelData)
                      }
                    }
                  }
                }

                // Subtasks (if any)
                Repeater {
                  model: taskRow.parent.modelData.subtasks || []

                  delegate: Rectangle {
                    required property var modelData

                    width: parent.width
                    height: Math.max(subtaskTitle.implicitHeight, Style.space(28)) + Style.space(8)
                    radius: Style.cornerRadius
                    
                    // Check if this subtask is selected
                    readonly property bool isSelected: {
                      if (!root.cursorActive || root.flatTasks.length === 0) return false
                      var selected = root.flatTasks[root.selectedIndex]
                      return selected && selected.isSubtask && selected.task.id === subtaskMouse.parent.modelData.id
                    }
                    
                    color: isSelected
                      ? Style.selectedFillFor(root.contentForeground, Color.accent)
                      : subtaskMouse.containsMouse
                        ? Style.hoverFillFor(root.contentForeground, Color.accent)
                        : "transparent"

                    MouseArea {
                      id: subtaskMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.startTask(subtaskMouse.parent.modelData)
                    }

                    Row {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(30)
                      anchors.rightMargin: Style.space(6)
                      spacing: Style.space(6)

                      Item {
                        id: subtaskPlaySlot
                        width: Style.space(24)
                        height: parent.height

                        Text {
                          anchors.centerIn: parent
                          visible: !subtaskMouse.containsMouse && !subtaskMouse.parent.isSelected
                          text: "•"
                          color: subtaskMouse.parent.modelData.isDone
                            ? Qt.darker(root.contentForeground, 2.2)
                            : Qt.darker(root.contentForeground, 1.8)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                        }
                        
                        Text {
                          anchors.centerIn: parent
                          visible: subtaskMouse.parent.isSelected
                          text: "▸"
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                        }

                        PanelActionButton {
                          anchors.centerIn: parent
                          visible: (subtaskMouse.containsMouse || subtaskMouse.parent.isSelected) && !subtaskMouse.parent.modelData.isDone
                          iconText: "󰐊"
                          tooltipText: "Start timer"
                          foreground: root.contentForeground
                          fontFamily: root.contentFontFamily
                          onClicked: root.startTask(subtaskMouse.parent.modelData)
                        }
                      }

                      Text {
                        id: subtaskTitle
                        width: parent.width
                          - subtaskPlaySlot.width - subtaskDeleteSlot.width - subtaskDoneSlot.width
                          - parent.spacing * 3
                        anchors.verticalCenter: parent.verticalCenter
                        text: subtaskMouse.parent.modelData.title
                        color: subtaskMouse.parent.modelData.isDone
                          ? Qt.darker(root.contentForeground, 2)
                          : Qt.darker(root.contentForeground, 1.3)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.strikeout: subtaskMouse.parent.modelData.isDone
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                        textFormat: Text.PlainText
                      }

                      Item {
                        id: subtaskDeleteSlot
                        width: Style.space(24)
                        height: parent.height

                        PanelActionButton {
                          anchors.centerIn: parent
                          visible: subtaskMouse.containsMouse || subtaskMouse.parent.isSelected
                          iconText: "󰆴"
                          tooltipText: "Delete task"
                          foreground: root.contentForeground
                          fontFamily: root.contentFontFamily
                          onClicked: root.deleteTask(subtaskMouse.parent.modelData)
                        }
                      }

                      Item {
                        id: subtaskDoneSlot
                        width: Style.space(24)
                        height: parent.height

                        PanelActionButton {
                          anchors.centerIn: parent
                          iconText: subtaskMouse.parent.modelData.isDone ? "󰄬" : "󰄱"
                          tooltipText: subtaskMouse.parent.modelData.isDone ? "Done" : "Mark done"
                          foreground: root.contentForeground
                          fontFamily: root.contentFontFamily
                          opacity: subtaskMouse.parent.modelData.isDone ? 0.5 : 1
                          visible: subtaskMouse.containsMouse || subtaskMouse.parent.isSelected
                          onClicked: root.toggleDone(subtaskMouse.parent.modelData)
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.tasks.length === 0 && !root.loading && errorText === ""
            text: root.filterMode === "today" ? "No tasks planned for today." :
                  root.filterMode === "all" ? "No tasks found." :
                  "No completed tasks."
            color: Qt.darker(root.contentForeground, 1.8)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
        }

        TextField {
          id: newTaskField
          width: parent.width
          placeholderText: "Add a task for today…"
          foreground: root.contentForeground
          font.family: root.contentFontFamily
          maximumLength: 500

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.commitNewTask()
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              newTaskField.text = ""
              keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }
        }
      }
    }
  }

  component FilterPill: Button {
    id: pill
    required property string filter
    required property int index

    fontSize: Style.font.bodySmall
    foreground: root.contentForeground
    fontFamily: root.contentFontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true

    active: root.filterMode === filter
    hasCursor: false

    onHovered: function(isHovered) {
      // Could add cursor tracking here later
    }
  }
}
