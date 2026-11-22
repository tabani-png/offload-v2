import Foundation

// Every string of the Build progress screen (SPEC m3-13 "BuildCopy"). Numbers are put in by code from the build, the
// fix, the outcome or the labelled sample fixture; no string here holds a number of its own except the glossary's
// "4 weeks" of measuring and the $4.00 cap the build loop enforces.

public enum BuildCopy {
  // MARK: Steps

  public static let planLocked = "Plan locked"
  public static let planLockedDetail = "what it builds and what it must not touch"
  public static let checksFrozen = "Checks frozen first"
  public static let checksFrozenDetail = "checks written before any code"
  public static let workersTesting = "Workers testing"
  public static let workersWaiting = "one worker first, more only if a check fails"
  public static let matches = "Matches what you asked for"
  public static let matchesDetail = "compared against your words, not just the tests"
  public static let heldOutPassed = "held-out check passed"
  public static let heldOutFailed = "held-out check failed"
  public static let readyToShip = "Ready to ship"
  public static let readyToShipDetail = "install asks you once more"
  public static let installedDetail = "installed"

  public static func fingerprint(_ short: String) -> String { "fingerprint \(short)" }
  /// "2 of 3 attempts passing".
  public static func attemptsPassing(_ passing: Int, of count: Int) -> String { "\(passing) of \(count) attempts passing" }
  /// "1 failed · builder is fixing it".
  public static func failedFixing(_ failed: Int) -> String { "\(failed) failed · builder is fixing it" }
  /// An unknown stage under row 3: "recovered · failed".
  public static func otherStage(_ name: String, state: String) -> String { "\(name) · \(state)" }

  // MARK: Sample

  public static let sampleRowName = "Sample build"
  public static let sampleRowLine = "sample data"
  /// "8 workers testing in parallel".
  public static func workersInParallel(_ n: Int) -> String { "\(n) workers testing in parallel" }
  /// "47 tests written before any code · fingerprint 7c41e2".
  public static func testsWritten(_ n: Int, fingerprint short: String) -> String {
    "\(n) tests written before any code · fingerprint \(short)"
  }
  /// "30 of 47 passing".
  public static func checksPassing(_ passed: Int, of total: Int) -> String { "\(passed) of \(total) passing" }
  public static let replay = "Replay"

  // MARK: Header and headlines

  /// "Building · PR pre-read tool".
  public static func title(_ name: String) -> String { "Building · \(name)" }
  public static let unnamed = "a build"
  public static let headlineQueued = "Waiting to start."
  public static let headlineBuilding = "Building. Tests first."
  public static let headlineVerifying = "Checking it in a fresh sandbox."
  public static let headlineFixing = "One check failed. Fixing it."
  public static let headlineReady = "It's built and every check passed."
  public static let headlineFailed = "It didn't pass. Nothing was installed."
  public static let headlineCapped = "It reached the $4.00 cap. Nothing was installed."
  public static let headlineTampered = "A worker changed the checks. The build was stopped."
  public static let headlineCancelled = "Cancelled. Nothing was installed."
  public static let headlineInfraFailed = "The build service had a problem. This is not billed to your cap."
  public static func headlineUnknown(_ raw: String) -> String { "Status: \(raw)" }
  /// "6m 12s · $0.84 of $4.00".
  public static func meter(elapsed: String, spent: String, cap: String) -> String { "\(elapsed) · \(spent) of \(cap)" }

  // MARK: Workers

  public static let workersTitle = "Workers · each in its own sandbox"
  public static func workerName(_ ordinal: Int) -> String { "worker \(ordinal)" }
  public static let frozenLabel = "frozen checks"
  public static let heldOutLabel = "held-out check"
  public static let markPassed = "✓"
  public static let markFailed = "✗"
  public static let notRun = "not run"

  // MARK: Actions

  public static let install = "Install"
  public static let seeWhatChanged = "See what changed"
  public static let whatItWillDo = "What it will do"
  public static let cancelBuild = "Cancel build"
  public static let removeFromList = "Remove from list"
  public static let okBuild = "OK, build"
  public static let notNow = "Not now"
  public static let installNeedsCloud = "Installing needs the cloud."
  public static let installNeedsEnrollment = "Installing needs this Mac to be enrolled."
  public static let buildNeedsEnrollment = "Building needs this Mac to be enrolled."
  /// "Installed · version 1".
  public static func installed(version: Int) -> String { "Installed · version \(version)" }
  public static let installChanged = "It changed since you read it. Read it again."
  public static let definitionMissing = "What it will do can't be shown yet."
  public static let readFirst = "Read what it will do first."

  // MARK: Saving

  /// "saves 1.4 h/wk, estimated".
  public static func savesEstimated(_ hours: String) -> String { "saves \(hours) h/wk, estimated" }
  public static let measuredAfter = "measured for 4 weeks after you install"
  /// "measuring · week 2 of 4".
  public static func measuring(week: Int) -> String { "measuring · week \(week) of 4" }
  /// "saved 1.2 h/wk measured · 1.4 h estimated".
  public static func savedMeasured(_ measured: String, estimated: String) -> String {
    "saved \(measured) h/wk measured · \(estimated) h estimated"
  }
  public static let notMeasured = "not measured"
  public static let measuredFromM4 = "measured after install, from M4"

  // MARK: Plan (OK, build)

  public static let planTitle = "The plan"
  public static let answering = "Asking Offload to design the fix…"
  public static let designing = "Designing the fix…"
  public static let stillDesigning = "Still designing. Check back later."
  public static let planChanged = "The plan changed. Read it again."
  public static let alreadyRunning = "A build of this plan is already running."
  public static let noFixYet = "This suggestion has no fix to build yet."
  public static let starting = "Starting the build…"
  /// "build cap $4.00".
  public static func buildCap(_ cap: String) -> String { "build cap \(cap)" }
  /// "Connect Google Sheets and Github first."
  public static func connectFirst(_ apps: [String]) -> String { "Connect \(joined(apps.map(appName))) first." }

  /// A provider id in words: "google_sheets" is "Google Sheets".
  public static func appName(_ raw: String) -> String {
    raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  /// "A", "A and B", "A, B and C".
  public static func joined(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
  }

  // MARK: List and states

  public static let noBuilds = "No builds yet. Press OK, build on a suggested fix in Today."
  public static let offline = "Can't reach Offload. Retrying."
  public static let gone = "This build is no longer available."
  public static let checking = "checking"
  /// "started 22 Nov, 11:50".
  public static func started(_ when: String) -> String { "started \(when)" }
  public static func repeatNeedsCloud(_ name: String) -> String {
    "Building “\(name)” needs the cloud. This sample shows what a build looks like."
  }
  public static let opportunityNeedsCloud = "Building needs the cloud. This sample shows what a build looks like."
  public static func repeatCountedHere(_ name: String) -> String {
    "“\(name)” was counted on this Mac. Build it from a suggestion in Today once Offload has seen it."
  }

  /// The list's words for a build's state.
  public static func stateWord(_ state: BuildState, deployed: Bool) -> String {
    switch state {
    case .queued: return "waiting to start"
    case .building, .verifying, .fanningOut, .repairing: return "building"
    case .ready: return deployed ? "installed" : "ready to install"
    case .failed: return "didn't pass"
    case .capped: return "reached the cap"
    case .tampered: return "stopped"
    case .cancelled: return "cancelled"
    case .infraFailed: return "not billed: service problem"
    case .unknown(let raw): return "status: \(raw)"
    }
  }

  // MARK: Errors in words

  /// One plain sentence per `APIError`. A `policy_denied` shows the server's message as given (the client has
  /// already removed the member token from it); nothing shows a request id or a hash.
  public static func sentence(for error: APIError) -> String {
    switch error {
    case .notFound: return "Offload doesn't have this."
    case .signingUnavailable: return "This needs this Mac to be enrolled."
    case .refusedPath: return "Offload's address can't be used, so nothing was sent."
    case .notSignedIn: return "This Mac isn't signed in, so nothing was sent."
    case .invalidBody: return "This Mac couldn't write the request, so nothing was sent."
    case .transport: return "Can't reach Offload."
    case .badResponse: return "Offload's answer couldn't be read."
    case .server(let status, let code, let message, _, _):
      switch code {
      case .policyDenied:
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? "A rule on your account says no." : m
      case .hashMismatch: return installChanged
      case .alreadyRunning: return alreadyRunning
      case .stateConflict: return "It changed on Offload. Showing the latest."
      case .approvalUsed, .approvalExpired: return "That approval was already used. Read it again."
      case .unauthenticated, .tokenExpired: return "This Mac needs to sign in again."
      case .forbidden, .featureNotLicensed: return "This account can't do that."
      case .budgetExceeded: return "This would go over this month's budget."
      case .rateLimited: return "Offload is busy. Try again in a minute."
      case .serverError: return "Offload had a problem. Try again later."
      default: return status >= 500 ? "Offload had a problem. Try again later." : "Offload couldn't do that."
      }
    }
  }

  // MARK: For the copy tests

  /// Every fixed string and one of each built string.
  public static var all: [String] {
    let fixed: [String] = [
      planLocked, planLockedDetail, checksFrozen, checksFrozenDetail, workersTesting, workersWaiting, matches,
      matchesDetail, heldOutPassed, heldOutFailed, readyToShip, readyToShipDetail, installedDetail, sampleRowName,
      sampleRowLine, replay, unnamed, headlineQueued, headlineBuilding, headlineVerifying, headlineFixing, headlineReady,
      headlineFailed, headlineCapped, headlineTampered, headlineCancelled, headlineInfraFailed, workersTitle, frozenLabel,
      heldOutLabel, notRun, install, seeWhatChanged, whatItWillDo, cancelBuild, removeFromList, okBuild, notNow,
      installNeedsCloud, installNeedsEnrollment, buildNeedsEnrollment, installChanged, definitionMissing, readFirst,
      measuredAfter, notMeasured, measuredFromM4, planTitle, answering, designing, stillDesigning, planChanged,
      alreadyRunning, noFixYet, starting, noBuilds, offline, gone, checking, opportunityNeedsCloud,
    ]
    let built: [String] = [
      fingerprint("7c41e2"), attemptsPassing(2, of: 3), failedFixing(1), otherStage("recovered", state: "failed"),
      workersInParallel(8), testsWritten(47, fingerprint: "7c41e2"), checksPassing(30, of: 47), title("PR pre-read tool"),
      headlineUnknown("teleporting"), meter(elapsed: "6m 12s", spent: "$0.84", cap: "$4.00"), workerName(1),
      installed(version: 1), savesEstimated("1.4"), measuring(week: 2), savedMeasured("1.2", estimated: "1.4"),
      buildCap("$4.00"), connectFirst(["google_sheets", "github"]), started("22 Nov, 11:50"),
      repeatNeedsCloud("Weekly report"), repeatCountedHere("Weekly report"),
    ]
    let states: [BuildState] = [.queued, .building, .ready, .failed, .capped, .tampered, .cancelled, .infraFailed,
                                .unknown("x")]
    let errors: [APIError] = [
      .notFound, .signingUnavailable, .refusedPath, .notSignedIn, .invalidBody, .transport(code: -1009),
      .badResponse(status: 502),
    ] + ["policy_denied", "hash_mismatch", "already_running", "state_conflict", "approval_used", "unauthenticated",
         "forbidden", "budget_exceeded", "rate_limited", "server_error", "schema_invalid"].map {
      APIError.server(status: 400, code: APIErrorCode(raw: $0), message: "", requestID: nil, ruleID: nil)
    }
    return fixed + built + states.map { stateWord($0, deployed: false) } + [stateWord(.ready, deployed: true)]
      + errors.map { sentence(for: $0) }
  }

  /// Captions (lowercase; facts separated by "·" are drawn as separate items). The start time is a date, not a
  /// caption: its month keeps its capital.
  public static var captions: [String] {
    [
      planLockedDetail, checksFrozenDetail, workersWaiting, matchesDetail, heldOutPassed, heldOutFailed,
      readyToShipDetail, installedDetail, sampleRowLine, notRun, measuredAfter, notMeasured, measuredFromM4, checking,
      planLockedDetail + " · " + fingerprint("7c41e2"), attemptsPassing(2, of: 3), failedFixing(1),
      otherStage("recovered", state: "failed"), testsWritten(47, fingerprint: "7c41e2"), checksPassing(30, of: 47),
      meter(elapsed: "6m 12s", spent: "$0.84", cap: "$4.00"), workerName(1),
      savesEstimated("1.4") + " · " + measuredAfter, measuring(week: 2), savedMeasured("1.2", estimated: "1.4"),
      buildCap("$4.00"),
    ] + [BuildState.queued, .building, .ready, .failed, .capped, .tampered, .cancelled, .infraFailed]
      .map { stateWord($0, deployed: false) }
  }
}
