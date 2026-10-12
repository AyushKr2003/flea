.import "../../ui/js/Contrast.js" as Contrast

var AA = 4.5

function run(check) {
    check("white on black is the maximum", Math.round(Contrast.ratio("#ffffff", "#000000")), 21)
    check("a colour against itself is 1", Math.round(Contrast.ratio("#808080", "#808080")), 1)

    // The live vernier palette, so the numbers in the plan can be re-derived from the suite.
    var bg = "#14181a"
    var zebra = Contrast.over("#b3b9bd", 8 / 255, bg)
    var cursor = Contrast.over("#c8ccd0", 36 / 255, zebra)

    check("muted fails AA on the cursor row",
          Contrast.ratioOf(Contrast.parse("#868d93"), cursor) < AA, true)
    check("symlink fails AA on the cursor row",
          Contrast.ratioOf(Contrast.parse("#27a6a2"), cursor) < AA, true)
    check("foreground clears AA on the cursor row",
          Contrast.ratioOf(Contrast.parse("#c8ccd0"), cursor) >= AA, true)
    check("muted still clears AA on the zebra row",
          Contrast.ratioOf(Contrast.parse("#868d93"), zebra) >= AA, true)

    check("ensureRatio leaves a passing pair alone",
          Contrast.ensureRatio("#000000", "#ffffff", AA), "#000000")
    var lightMuted = Contrast.ensureRatio("#acb0be", "#eff1f5", AA)
    check("ensureRatio lifts live light muted to AA",
          Contrast.ratio(lightMuted, "#eff1f5") >= AA, true)
    var lightLink = Contrast.ensureRatio("#179299", "#eff1f5", AA)
    check("ensureRatio lifts live light symlink to AA",
          Contrast.ratio(lightLink, "#eff1f5") >= AA, true)

    // washAlpha: the least wash that stands 3:1 off the surface once drawn, never under the floor, and 1 where the whole foreground cannot.
    var a = Contrast.washAlpha("#dfe8e0", "#26302d", 3, 0.08)
    check("washAlpha lands the wash at 3:1 off a dark surface",
          Contrast.ratio(Contrast.hexOf(Contrast.over("#dfe8e0", a, "#26302d")), "#26302d") >= 3, true)
    check("washAlpha is the least such alpha",
          Contrast.ratio(Contrast.hexOf(Contrast.over("#dfe8e0", a - 0.01, "#26302d")), "#26302d") < 3, true)
    check("washAlpha lands the wash at 3:1 off a light surface",
          Contrast.ratio(Contrast.hexOf(Contrast.over("#202020", Contrast.washAlpha("#202020", "#eff1f5", 3, 0.08), "#eff1f5")), "#eff1f5") >= 3, true)
    check("washAlpha keeps the floor where the floor already clears", Contrast.washAlpha("#ffffff", "#000000", 3, 0.5), 0.5)
    check("washAlpha answers 1 where the foreground cannot stand off the surface", Contrast.washAlpha("#101010", "#0e0e0e", 3, 0.08), 1)
}
