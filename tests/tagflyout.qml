//@ pragma ShellId flea-tagflyout-test
import QtQuick
import QtTest
import Quickshell
import "flea" as Flea
import "flea/js/Tags.js" as Tags

// tests/tagflyout.sh: the real pane over the real backend toggles tags from an open flyout, which stays open with its cursor and redraws each box in place.
ShellRoot {
    id: root
    readonly property var pane: body.currentPane
    readonly property var menu: pane ? pane.contextMenu() : null
    readonly property string fixture: Quickshell.env("FLEA_PATH")
    readonly property int fixtureRows: 2
    readonly property int pollMs: 20
    readonly property int stepLimitMs: 8000
    // Ticks a finished step rests, so a late close or a late answer shows before its check.
    readonly property int restTicks: 10
    readonly property int blueRow: 4
    readonly property int maxKeys: 12

    property var steps: []
    property int stepIndex: -1
    property int rest: 0
    property bool acted: false
    property bool finished: false
    property double started: Date.now()
    property int landed: 0
    property int landedBefore: 0
    property int windows: 0
    property int windowsBefore: 0
    property var refusals: []
    property int checks: 0
    property int failures: 0

    function log(line) { console.log("TAGFLYOUT " + line) }
    function check(name, ok) {
        checks += 1
        if (ok) return
        failures += 1
        log("FAIL " + name)
    }
    function finish() {
        finished = true
        log((failures === 0 ? "PASS " : "FAIL ") + checks + " checks")
        log("DONE failures=" + failures)
        body.quitBackends()
    }
    function leaf(id) {
        var rows = menu.submenuEntries
        for (var i = 0; i < rows.length; i++)
            if (rows[i].id === id) return rows[i]
        return null
    }
    function state(id) { var row = leaf(id); return row && row.tagRow ? row.tagRow.state : "missing" }
    function indexOfLeaf(id) {
        var rows = menu.submenuEntries
        for (var i = 0; i < rows.length; i++)
            if (rows[i].id === id) return i
        return -1
    }
    function flyoutStands() { return menu.opened && menu.submenuOpen }
    function allAbsent() {
        for (var i = 0; i < Tags.NAMES.length; i++)
            if (state(Tags.NAMES[i]) !== Tags.ABSENT) return false
        return true
    }
    function moveTo(id) {
        var target = indexOfLeaf(id)
        for (var n = 0; n < maxKeys && menu.submenuCursor !== target; n++)
            driver.keyClick(menu.submenuCursor < target ? Qt.Key_Down : Qt.Key_Up, Qt.NoModifier, -1)
    }
    // One toggle lands when its settagged answer has come back and the held window has answered after it.
    function toggleLanded() { return landed > landedBefore && windows > windowsBefore }
    function toggled() { landedBefore = landed; windowsBefore = windows }

    function build() {
        return [
            { name: "open the flyout over two files, one carrying Blue",
              act: function () {
                  pane.selectAll()
                  pane.listArea.forceActiveFocus()
                  driver.keyClickChar("T", Qt.ShiftModifier, -1)
              },
              ready: function () { return flyoutStands() },
              verify: function () {
                  check("two files selected", pane.selectedIndices().length === 2)
                  check("Blue reads mixed over one of two files", state("Blue") === Tags.MIXED)
                  check("Red reads empty", state("Red") === Tags.ABSENT)
              } },
            { name: "digit 5 applies the mixed Blue and leaves the flyout up",
              act: function () {
                  moveTo("Blue")
                  toggled()
                  driver.keyClickChar("5", Qt.NoModifier, -1)
              },
              ready: toggleLanded,
              verify: function () {
                  check("5: the menu stays open", menu.opened)
                  check("5: the flyout stays open", menu.submenuOpen && menu.openSubmenuRow >= 0 && menu.entries[menu.openSubmenuRow].action === "tags")
                  check("5: Blue reads applied on its own row", state("Blue") === Tags.APPLIED && indexOfLeaf("Blue") === blueRow)
                  check("5: the cursor stays on Blue", menu.submenuCursor === blueRow)
                  check("5: nothing was refused", refusals.length === 0)
              } },
            { name: "digit 1 applies Red with no refusal",
              act: function () { toggled(); driver.keyClickChar("1", Qt.NoModifier, -1) },
              ready: toggleLanded,
              verify: function () {
                  check("1: the flyout stays open", flyoutStands())
                  check("1: Red reads applied", state("Red") === Tags.APPLIED)
                  check("1: Blue still reads applied", state("Blue") === Tags.APPLIED)
                  check("1: the cursor stays on Blue", menu.submenuCursor === blueRow)
                  check("1: the second choice was not refused as moved", refusals.length === 0)
              } },
            { name: "a click on the Red row removes it",
              act: function () {
                  var row = menu.submenuItemFor(indexOfLeaf("Red"))
                  toggled()
                  driver.mouseClick(row, row.width / 2, row.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
              },
              ready: toggleLanded,
              verify: function () {
                  check("click: the flyout stays open", flyoutStands())
                  check("click: Red reads empty", state("Red") === Tags.ABSENT)
                  check("click: Blue still reads applied", state("Blue") === Tags.APPLIED)
                  check("click: nothing was refused", refusals.length === 0)
              } },
            { name: "keypad Enter applies Purple",
              act: function () { moveTo("Purple"); toggled(); driver.keyClick(Qt.Key_Enter, Qt.KeypadModifier, -1) },
              ready: toggleLanded,
              verify: function () {
                  check("Enter: the flyout stays open", flyoutStands())
                  check("Enter: Purple reads applied", state("Purple") === Tags.APPLIED)
                  check("Enter: the cursor stays on Purple", menu.submenuCursor === indexOfLeaf("Purple"))
              } },
            { name: "Return on Remove all tags empties every box",
              act: function () { moveTo(Tags.CLEAR_ID); toggled(); driver.keyClick(Qt.Key_Return, Qt.NoModifier, -1) },
              ready: toggleLanded,
              verify: function () {
                  check("Remove all: the flyout stays open", flyoutStands())
                  check("Remove all: every box reads empty", allAbsent())
                  check("Remove all: the cursor stays on its row", menu.submenuCursor === indexOfLeaf(Tags.CLEAR_ID))
                  check("Remove all: nothing was refused", refusals.length === 0)
              } },
            { name: "Escape closes the flyout and keeps the menu",
              act: function () { driver.keyClick(Qt.Key_Escape, Qt.NoModifier, -1) },
              verify: function () {
                  check("Escape: the flyout closed", !menu.submenuOpen)
                  check("Escape: the menu stays open", menu.opened)
              } },
            { name: "a second Escape closes the menu",
              act: function () { driver.keyClick(Qt.Key_Escape, Qt.NoModifier, -1) },
              verify: function () {
                  check("Escape: the menu closed", !menu.opened)
                  check("Escape: focus returned to the listing", pane.listArea.activeFocus)
              } },
            { name: "T then digit 2 then a click on the ground closes everything",
              act: function () {
                  pane.listArea.forceActiveFocus()
                  driver.keyClickChar("T", Qt.ShiftModifier, -1)
              },
              ready: function () { return flyoutStands() },
              verify: function () { check("T reopens the flyout", flyoutStands()) } },
            { name: "digit 2 applies Orange",
              act: function () { toggled(); driver.keyClickChar("2", Qt.NoModifier, -1) },
              ready: toggleLanded,
              verify: function () {
                  check("2: Orange reads applied", state("Orange") === Tags.APPLIED)
                  check("2: the flyout stays open", flyoutStands())
              } },
            { name: "a click on the ground closes the whole menu",
              act: function () {
                  var frame = menu.frameItem
                  var farX = frame.x > 20 ? 2 : menu.width - 2
                  var farY = frame.y > 20 ? 2 : menu.height - 2
                  driver.mouseClick(menu, farX, farY, Qt.LeftButton, Qt.NoModifier, -1)
              },
              verify: function () {
                  check("ground: the menu closed", !menu.opened)
                  check("ground: the flyout closed", !menu.submenuOpen)
                  check("ground: focus returned to the listing", pane.listArea.activeFocus)
              } },
            { name: "Copy as still closes on a choice",
              act: function () {
                  pane.listArea.forceActiveFocus()
                  driver.keyClickChar("c", Qt.NoModifier, -1)
              },
              ready: function () { return flyoutStands() && menu.loneFlyoutAction === "copyAs" },
              verify: function () {
                  check("c opens the Copy as flyout", flyoutStands())
                  menu.chooseSub("copyName")
                  check("Copy as: a choice closes the menu", !menu.opened)
                  check("Copy as: a choice closes the flyout", !menu.submenuOpen)
              } }
        ]
    }

    function enter(index) {
        stepIndex = index
        started = Date.now()
        rest = 0
        acted = false
    }
    function advance() {
        if (finished) return
        try { run() }
        catch (error) { check("harness error " + String(error), false); finish() }
    }
    function run() {
        if (stepIndex < 0) {
            if (Date.now() - started > stepLimitMs) { check("fixture listed", false); finish(); return }
            if (pane.listInFlight || pane.path !== fixture || pane.total < fixtureRows || !pane.visibleItemFor(fixtureRows - 1)) return
            steps = build()
            enter(0)
            return
        }
        var step = steps[stepIndex]
        if (!acted) {
            acted = true
            step.act()
            return
        }
        var ready = step.ready === undefined || step.ready()
        if (!ready) {
            if (Date.now() - started > stepLimitMs) {
                check("step never finished: " + step.name, false)
                finish()
            }
            return
        }
        if (rest++ < restTicks) return
        step.verify()
        if (stepIndex + 1 >= steps.length) finish()
        else enter(stepIndex + 1)
    }

    Connections {
        target: root.pane ? root.pane.backend : null
        function onSettagged(message) { root.landed += 1 }
    }
    Connections {
        target: root.pane
        function onRowsChanged() { root.windows += 1 }
    }
    Connections {
        target: root.menu
        function onRefused(reason) { root.refusals = root.refusals.concat([reason]); root.log("INFO refused: " + reason) }
    }

    FloatingWindow {
        id: window
        implicitWidth: 1000
        implicitHeight: 800
        Flea.WindowBody { id: body; host: window }
        Item { anchors.fill: parent; TestEvent { id: driver } }
    }
    Timer { interval: root.pollMs; repeat: true; running: !root.finished; onTriggered: root.advance() }
}
