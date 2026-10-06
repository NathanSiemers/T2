import XCTest

/// Drives the app through its main flows in the simulator, against the live data service,
/// and keeps a screenshot of every step.
///
/// Run by `mac_setup.sh --ui-tests` (and by CI). The pictures are attachments of the test
/// result, and are also written as PNG files to the folder named by the environment
/// variable T2_SCREENSHOT_DIR (mac_setup.sh passes it as TEST_RUNNER_T2_SCREENSHOT_DIR).
///
/// These tests check that the flows WORK (an element appears, a count changes); whether a
/// screen looks right is judged by looking at the pictures.
final class T2UITests: XCTestCase {
    var app: XCUIApplication!
    /// generous: a cold simulator on a shared CI machine, and a first request to the service
    let dataTimeout: TimeInterval = 120

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: helpers

    private func launch(tab: String = "select", _ extra: [String] = []) {
        app.launchArguments = ["-t2Reset", "YES", "-t2Tab", tab] + extra
        app.launch()
    }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["T2_SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: url)
        }
    }

    /// the element with this accessibility identifier, whatever kind it is
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func waitFor(_ id: String, _ what: String, timeout: TimeInterval? = nil) {
        if !element(id).waitForExistence(timeout: timeout ?? dataTimeout) {
            shot("FAILED-waiting-for-\(id)")
            XCTFail("\(what) did not appear (\(id))")
        }
    }

    /// scroll down until the element is on screen
    @discardableResult
    private func scrollTo(_ id: String, maxSwipes: Int = 10) -> XCUIElement {
        let e = element(id)
        var swipes = 0
        while !(e.exists && e.isHittable) && swipes < maxSwipes {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        // not below: it may be above (the list was left scrolled down by an earlier step)
        swipes = 0
        while !(e.exists && e.isHittable) && swipes < 2 * maxSwipes {
            app.swipeDown(velocity: .slow)
            swipes += 1
        }
        if !(e.exists && e.isHittable) {
            shot("FAILED-scrolling-to-\(id)")
            XCTFail("could not scroll to \(id)")
        }
        // an element at the very bottom lies under the floating tab bar: "hittable", but a tap
        // lands on the bar (seen on the iPhone 17 Pro Max). Bring it further up.
        let screen = app.windows.firstMatch.frame
        if e.frame.maxY > screen.maxY - 150 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        // likewise at the very top, under the navigation bar (seen on the iPhone SE, where a
        // list left scrolled by an earlier step puts a row there): bring it further down
        if e.frame.minY < screen.minY + 120 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        }
        return e
    }

    private func openTab(_ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "no \(name) tab")
        button.tap()
    }

    /// the text of a label ("11,005 samples plotted; ...")
    private func text(of id: String) -> String { element(id).label }

    /// open the picker called `title`, type `query`, choose `name`
    private func pick(_ title: String, search query: String, choose name: String, shotName: String? = nil) {
        let row = scrollTo("pick-\(title)")
        row.tap()
        let field = app.textFields["variable-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field in the \(title) picker")
        field.tap()
        field.typeText(query)
        let result = app.buttons[name]
        if !result.waitForExistence(timeout: dataTimeout) {
            shot("FAILED-search-\(query)")
            XCTFail("search for \(query) did not offer \(name)")
        }
        if let shotName { shot(shotName) }
        result.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the picker did not close")
    }

    // MARK: flows

    /// first launch: the dataset, its default plot (cohort x CD8A coloured by sample type),
    /// the statistics and sample counts under it, the options
    func test01_DefaultDatasetAndPlot() {
        launch()
        waitFor("dataset-summary", "the dataset's sample count")
        shot("01-select-default")
        scrollTo("plot-button").tap()
        waitFor("plot-count", "the plot's sample count")
        XCTAssertTrue(text(of: "plot-count").contains("samples plotted"), text(of: "plot-count"))
        shot("02-plot-default-boxes")
        // the plot alone, full screen, and back
        element("plot-fullscreen").tap()
        waitFor("plot-full", "the full-screen plot", timeout: 20)
        shot("02b-plot-full-screen")
        element("plot-fullscreen-close").tap()
        waitFor("plot-count", "the plot's sample count")
        app.swipeUp(velocity: .slow)
        shot("03-plot-statistics-and-counts")
        app.swipeUp(velocity: .slow)
        shot("04-plot-options")
        // About: description, attribution, the data types of the dataset
        openTab("Select")
        element("about").tap()
        XCTAssertTrue(app.staticTexts["About T2"].waitForExistence(timeout: 20), "the About sheet did not open")
        shot("04b-about")
        app.swipeUp(velocity: .slow)
        shot("04c-about-data-types")
        app.buttons["Done"].tap()
    }

    /// search for probes (a gene, a mutation, a clinical column) and plot them
    func test02_SearchPickAndPlot() {
        launch()
        waitFor("dataset-summary", "the dataset's sample count")
        pick("X", search: "FOXP3", choose: "FOXP3", shotName: "05-search-gene")
        pick("Color", search: "TP53.mu", choose: "TP53.mut", shotName: "06-search-mutation")
        shot("07-select-after-picking")
        openTab("Plot")
        waitFor("plot-count", "the plot's sample count")
        shot("08-plot-scatter-colour-by-mutation")
        app.swipeUp(velocity: .slow)
        shot("09-plot-scatter-statistics")
        // a numeric colour and a size variable
        openTab("Select")
        pick("Color", search: "PDCD1", choose: "PDCD1")
        pick("Size", search: "GZMB", choose: "GZMB")
        openTab("Plot")
        waitFor("plot-count", "the plot's sample count")
        app.swipeDown(velocity: .fast)
        shot("10-plot-scatter-numeric-colour-and-size")
        // a clinical column on X: boxes; then a mutation on X
        openTab("Select")
        pick("X", search: "gender", choose: "gender", shotName: "11-search-clinical")
        pick("Color", search: "sample_type", choose: "sample_type")
        openTab("Plot")
        waitFor("plot-count", "the plot's sample count")
        app.swipeDown(velocity: .fast)
        shot("12-plot-boxes-by-gender")
        openTab("Select")
        pick("X", search: "TP53.mu", choose: "TP53.mut")
        openTab("Plot")
        waitFor("plot-count", "the plot's sample count")
        app.swipeDown(velocity: .fast)
        shot("13-plot-boxes-by-mutation")
        // a search that finds nothing
        openTab("Select")
        scrollTo("pick-Y").tap()      // on a small screen the row can be out of view after the picks above
        let field = app.textFields["variable-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("zzqqxx")
        waitFor("search-empty", "the no-match message", timeout: 60)
        shot("14-search-no-match")
    }

    /// the dataset's ready-made subsets, then the cross-filter, down to no samples at all
    func test03_PresetsAndFilter() {
        launch()
        waitFor("dataset-summary", "the dataset's sample count")
        // the first of the dataset's presets: tap the switch itself (its right-hand side)
        let all = text(of: "dataset-summary")
        let preset = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'preset-'")).firstMatch
        var swipes = 0
        while !(preset.exists && preset.isHittable) && swipes < 8 { app.swipeUp(velocity: .slow); swipes += 1 }
        XCTAssertTrue(preset.exists, "no preset switches for this dataset (\(all))")
        preset.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        scrollTo("select-count")
        shot("15-select-presets-first-one-on")
        XCTAssertFalse(text(of: "select-count").hasPrefix("12,804 of"), "the preset did not change the samples in use: " + text(of: "select-count"))
        openTab("Filter")
        waitFor("filter-count", "the filter's sample count")
        let before = text(of: "filter-count")
        shot("16-filter")
        // leave one cohort out: the count must change
        let level = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'level-'")).firstMatch
        XCTAssertTrue(level.waitForExistence(timeout: 20), "no level rows on the Filter tab")
        level.tap()
        XCTAssertNotEqual(text(of: "filter-count"), before, "leaving a level out did not change the count")
        shot("17-filter-one-level-out")
        app.swipeUp(velocity: .slow)
        shot("18-filter-scrolled")
        app.swipeUp(velocity: .slow)
        shot("19-filter-scrolled-more")
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        // none of the cohorts: only the samples with no cohort at all are left (a missing value
        // passes a filter unless "include samples with no value" is switched off) ...
        let none = app.buttons["None"].firstMatch
        XCTAssertTrue(none.waitForExistence(timeout: 20), "no None button")
        none.tap()
        // ... and without those, no sample is left
        if !element("filter-none").waitForExistence(timeout: 3) {
            shot("19b-filter-none-of-the-levels")
            scrollTo("include-missing-cohort").coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
        waitFor("filter-none", "the nothing-selected warning", timeout: 20)
        shot("20-filter-no-samples")
        openTab("Plot")
        waitFor("plot-count", "the plot's sample count")
        shot("21-plot-no-samples")
        let reset = element("reset-filters")
        XCTAssertTrue(reset.waitForExistence(timeout: 20), "no way back from an empty plot")
        reset.tap()
        XCTAssertTrue(text(of: "plot-count").contains("samples plotted"), text(of: "plot-count"))
        app.swipeDown(velocity: .fast)
        shot("22-plot-after-removing-filters")
    }

    /// a figure of a real size: the two page presets, PNG and PDF, the share sheet
    func test04_Publish() {
        launch(tab: "publish")
        waitFor("publish-preview", "the figure preview")
        shot("23-publish-half-page-third-high")
        element("publish-preset").tap()
        let full = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Full page wide'")).firstMatch
        if full.waitForExistence(timeout: 10) {
            shot("24-publish-presets")
            full.tap()
        } else {
            shot("ISSUE-publish-preset-list")
            XCTFail("the list of figure sizes did not open")
        }
        waitFor("publish-preview", "the figure preview", timeout: 30)
        shot("25-publish-full-width-half-high")
        scrollTo("export-png").tap()
        waitFor("publish-share", "the share link", timeout: 60)
        shot("26-publish-png-exported")
        scrollTo("export-tiff").tap()
        waitFor("publish-share", "the share link", timeout: 60)
        XCTAssertTrue(text(of: "publish-message").hasPrefix("TIFF"), text(of: "publish-message"))
        shot("26b-publish-tiff-exported")
        scrollTo("export-pdf").tap()
        waitFor("publish-share", "the share link", timeout: 60)
        shot("27-publish-pdf-exported")
        scrollTo("publish-share").tap()
        // the system's share sheet (it belongs to another process: just give it time)
        _ = app.otherElements["ActivityListView"].waitForExistence(timeout: 15)
        shot("28-publish-share-sheet")
    }

    /// survival curves, one graph per level, counts, the cohort choice, the table behind a plot
    func test06_SurvivalFacetsCountsCohortsTable() {
        launch(tab: "plot", ["-t2X", "OS", "-t2Y", "CD8A"])
        waitFor("plot-count", "the plot's sample count")
        shot("37-survival-tertiles")
        app.swipeUp(velocity: .slow)
        shot("38-survival-statistics")
        scrollTo("km-groups")
        shot("39-survival-options")

        app.terminate()
        launch(tab: "plot", ["-t2X", "OS", "-t2Y", "TP53.mut"])
        waitFor("plot-count", "the plot's sample count")
        shot("40-survival-by-mutation")

        app.terminate()
        launch(tab: "plot", ["-t2X", "CD8A", "-t2Y", "FOXP3", "-t2Facet", "gender"])
        waitFor("plot-count", "the plot's sample count")
        shot("41-graph-for-each-gender")

        app.terminate()
        launch(tab: "plot", ["-t2X", "gender", "-t2Y", "TP53.mut"])
        waitFor("plot-count", "the plot's sample count")
        shot("42-counts-two-categories")

        // choose two cohorts, plot them, make the table
        app.terminate()
        launch()
        waitFor("dataset-summary", "the dataset's sample count")
        scrollTo("cohorts").tap()
        waitFor("cohorts-none", "the cohort list", timeout: 20)
        element("cohorts-none").tap()
        element("cohort-BRCA").tap()
        scrollTo("cohort-LUAD").tap()
        shot("43-cohorts-two-chosen")
        app.navigationBars.buttons.firstMatch.tap()
        openTab("Plot")
        waitFor("plot-count", "the plot's sample count")
        shot("44-plot-two-cohorts")
        scrollTo("table-make").tap()
        scrollTo("table-share")
        shot("45-table-made")

        // two probes combined on Y, and the influence of a third removed
        app.terminate()
        launch()
        waitFor("dataset-summary", "the dataset's sample count")
        pick("Add to Y", search: "CD8B", choose: "CD8B")
        pick("Remove influences of", search: "PTPRC", choose: "PTPRC")
        shot("46-select-combined-and-adjusted")
        openTab("Plot")
        waitFor("plot-count", "the plot's sample count")
        shot("47-plot-combined-and-adjusted")
    }

    /// the other datasets (chosen with the picker), and what the app says when things go wrong
    func test05_DatasetsAndProblems() {
        launch()
        waitFor("dataset-summary", "the dataset's sample count")
        element("dataset-picker").tap()
        let gtex = app.buttons["TCGA-TARGET-GTEx (Toil)"]
        if gtex.waitForExistence(timeout: 10) {
            shot("29-dataset-menu")
            gtex.tap()
            let opened = NSPredicate(format: "label CONTAINS '19,131'")
            expectation(for: opened, evaluatedWith: element("dataset-summary"))
            waitForExpectations(timeout: dataTimeout)
            shot("30-select-tcgatargetgtex")
            app.swipeUp(velocity: .slow)
            shot("31-select-tcgatargetgtex-presets")
            openTab("Plot")
            waitFor("plot-count", "the plot's sample count")
            shot("32-plot-tcgatargetgtex")
            // one collection of that dataset as a data source of its own: fewer samples, its own cohorts
            openTab("Select")
            scrollTo("dataset-picker").tap()
            let gtexOnly = app.buttons["TCGA-TARGET-GTEx (Toil): GTEx normal tissues"]
            XCTAssertTrue(gtexOnly.waitForExistence(timeout: 10), "the GTEx collection is not offered as a data set")
            gtexOnly.tap()
            let narrowed = NSPredicate(format: "label CONTAINS '7,429'")
            expectation(for: narrowed, evaluatedWith: element("dataset-summary"))
            waitForExpectations(timeout: dataTimeout)
            shot("32b-select-gtex-only")
            openTab("Plot")
            waitFor("plot-count", "the plot's sample count")
            XCTAssertTrue(text(of: "plot-count").contains("7,429"), text(of: "plot-count"))
            shot("32c-plot-gtex-only")
        } else {
            shot("ISSUE-dataset-menu")
            XCTFail("the dataset menu did not open")
        }
        // the synthetic test dataset is not offered: asking for it at launch opens the first real one
        app.terminate()
        launch(tab: "select", ["-t2Dataset", "DEMO"])
        waitFor("dataset-summary", "the dataset's sample count")
        XCTAssertFalse(text(of: "dataset-summary").localizedCaseInsensitiveContains("synthetic"), text(of: "dataset-summary"))
        shot("33-select-no-demo")
        // a variable the dataset does not have
        app.terminate()
        launch(["-t2Y", "NO_SUCH_PROBE"])
        waitFor("dataset-summary", "the dataset's sample count")
        scrollTo("status")
        XCTAssertTrue(text(of: "status").contains("NO_SUCH_PROBE"), text(of: "status"))
        shot("34-unknown-probe-select")
        openTab("Plot")
        waitFor("plot-count", "the plot's sample count")
        shot("35-unknown-probe-plot")
        // no connection: a service address where nothing listens
        app.terminate()
        launch(["-t2Service", "http://127.0.0.1:9"])
        waitFor("no-connection", "the cannot-reach message")
        shot("36-no-connection")
    }
}
