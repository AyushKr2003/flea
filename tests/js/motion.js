.import "../../ui/js/Motion.js" as Motion
.import "sourcefixture.js" as Source

// mo1: the structural transitions use OutCubic, 180 ms to reveal and 140 ms to hide.

function run(check) {
    check("a reveal reads 180", Motion.durMs.open, 180)
    check("a hide reads 140", Motion.durMs.close, 140)
    check("reveal slower than hide", Motion.durMs.open > Motion.durMs.close, true)
    check("no bezier curve to drift back to", Motion.bezierCurve, undefined)
    check("the rise stays 10 px", Motion.translateUpPx, 10)
    runStructural(check)
}

// The transitions a fullscreen take or a dialog open runs through, so a curve change here is a product change.
function runStructural(check) {
    var files = ["ui/Preview.qml", "ui/Reveal.qml", "ui/EmptyState.qml", "ui/FleaMark.qml"]
    for (var i = 0; i < files.length; i++) {
        var src = Source.source(files[i])
        check(files[i] + " carries OutCubic", src.indexOf("Easing.OutCubic") >= 0, true)
        check(files[i] + " carries no BezierSpline", src.indexOf("BezierSpline") < 0, true)
    }
    var shared = ["ui/ShareBrowser.qml", "ui/NetworkDialog.qml"]
    for (var j = 0; j < shared.length; j++) {
        var own = Source.source(shared[j])
        check(shared[j] + " fades through Reveal", own.indexOf("Reveal") >= 0, true)
        check(shared[j] + " carries no easing of its own", own.indexOf("easing.type") < 0, true)
    }
}
