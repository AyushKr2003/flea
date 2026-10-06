.pragma library

// One shared check/log/finish scaffold for the QML test harnesses.
// Each harness keeps a thin wrapper naming its own tag and state, so every
// line it prints is byte-identical to the body the wrapper replaced.

// console.log(tag + line), the shape every harness log() shares.
function log(tag, line) {
    console.log(tag + " " + line)
}

// JSON compare over a state with checks, failures and log, loud on a pass.
// The button and dialog harnesses log each passing check by name.
function checkLoud(state, name, actual, expected) {
    state.checks += 1
    if (JSON.stringify(actual) === JSON.stringify(expected)) {
        state.log("ok " + name)
        return
    }
    state.failures.push(name)
    state.log("FAIL " + name + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
}

// Same compare, silent on a pass. The menu and settings harnesses log failures only.
function checkQuiet(state, name, actual, expected) {
    state.checks += 1
    if (JSON.stringify(actual) === JSON.stringify(expected)) {
        return
    }
    state.failures.push(name)
    state.log("FAIL " + name + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
}

// JSON compare over int counters with its own console line. The preview hunt
// family logs PASS and FAIL itself and never through its log().
function checkHunt(state, tag, label, actual, expected) {
    state.checks += 1
    var ok = JSON.stringify(actual) === JSON.stringify(expected)
    if (!ok) state.failures += 1
    console.log(tag + " " + (ok ? "PASS " : "FAIL ") + label + " got=" + JSON.stringify(actual) + " expected=" + JSON.stringify(expected))
}

// DONE line through the harness log, for the array-counter harnesses.
function logDone(state) {
    state.log("DONE checks=" + state.checks + " failed=" + state.failures.length)
}

// DONE line straight to the console, for the int-counter family.
function logDoneHunt(state, tag) {
    console.log(tag + " DONE " + state.checks + " checks, " + state.failures + " failed")
}

// A stepped run ends past its script, so the driver loop falls out.
function stepPastEnd(state) {
    state.step = state.script.length + 1
}

// The menu and settings report: stop the ticker, then PASS and DONE.
// The tick that reported is the last one: a stopped timer cannot advance an ended run.
function reportCard(state, ticker) {
    ticker.running = false
    state.done = true
    if (state.failures.length === 0) {
        state.log("PASS " + state.checks + " checks")
    }
    state.log("DONE failures=" + state.failures.length)
}
