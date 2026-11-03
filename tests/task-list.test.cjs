const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8");
const onTasksLoaded = source.match(/^  function onTasksLoaded\([^]*?^  }/m);
assert.ok(onTasksLoaded, "Panel.qml must expose onTasksLoaded");

function task(id, extra = {}) {
  return { id, parentId: null, isDone: false, subTaskIds: [], subtasks: [], ...extra };
}

// Run the actual QML callback with the sanitized task shape supplied by SpApi.
function load(tasks, { mode = "today", currentTaskId = "" } = {}) {
  const context = vm.createContext({
    tasks: [], loading: true, errorText: "", filterMode: mode, currentTaskId
  });
  vm.runInContext(onTasksLoaded[0], context);
  context.onTasksLoaded("tasks", true, tasks);
  const rows = Array.from(context.tasks);
  const ids = rows.flatMap(parent => [parent.id, ...parent.subtasks.map(child => child.id)]);
  assert.equal(ids.length, new Set(ids).size, "Tasks must not appear twice");
  return { rows, ids: ids.sort() };
}

test("Today shows a subtask when its parent is not planned for today", () => {
  assert.deepEqual(load([task("child", { parentId: "parent" })]).ids, ["child"]);
});

test("Children stay nested when their parent is displayed", () => {
  const result = load([
    task("parent", { subTaskIds: ["child"] }), task("child", { parentId: "parent" })
  ]);
  assert.deepEqual(result.ids, ["child", "parent"]);
  assert.equal(result.rows.length, 1);
  assert.equal(result.rows[0].subtasks[0].id, "child");
});

test("A running parent does not hide its children", () => {
  const result = load([
    task("parent", { subTaskIds: ["child"] }), task("child", { parentId: "parent" })
  ], { currentTaskId: "parent" });
  assert.deepEqual(result.ids, ["child"]);
});

test("A running child stays excluded while its parent and sibling remain", () => {
  const result = load([
    task("parent", { subTaskIds: ["running", "sibling"] }),
    task("running", { parentId: "parent" }), task("sibling", { parentId: "parent" })
  ], { currentTaskId: "running" });
  assert.deepEqual(result.ids, ["parent", "sibling"]);
});

test("Completed shows a finished child when its parent is incomplete", () => {
  const result = load([
    task("parent", { subTaskIds: ["child"] }), task("child", { parentId: "parent", isDone: true })
  ], { mode: "completed" });
  assert.deepEqual(result.ids, ["child"]);
});

test("Completed keeps finished children nested and excludes incomplete children", () => {
  const result = load([
    task("parent", { isDone: true, subTaskIds: ["child", "incomplete"] }),
    task("child", { parentId: "parent", isDone: true }), task("incomplete", { parentId: "parent" })
  ], { mode: "completed" });
  assert.deepEqual(result.ids, ["child", "parent"]);
  assert.equal(result.rows.length, 1);
});

test("An empty parent ID does not hide a top-level task", () => {
  assert.deepEqual(load([task("parent", { parentId: "" })]).ids, ["parent"]);
});

test("A child missing from its parent's subTaskIds remains visible", () => {
  const result = load([task("parent"), task("child", { parentId: "parent" })]);
  assert.deepEqual(result.ids, ["child", "parent"]);
});

test("All shows retained subtasks when the existing task cap excludes their parent", () => {
  const retained = [task("child", { parentId: "excluded-parent" }),
    ...Array.from({ length: 199 }, (_, i) => task("task-" + i))];
  const result = load(retained, { mode: "all" });
  assert.equal(result.ids.length, 200);
  assert.ok(result.ids.includes("child"));
});

test("Children beyond the existing subTaskIds cap are not silently hidden", () => {
  const children = Array.from({ length: 51 }, (_, i) => task("child-" + i, { parentId: "parent" }));
  const result = load([task("parent", { subTaskIds: children.slice(0, 50).map(t => t.id) }), ...children]);
  assert.equal(result.ids.length, 52);
  assert.ok(result.ids.includes("child-50"));
});
