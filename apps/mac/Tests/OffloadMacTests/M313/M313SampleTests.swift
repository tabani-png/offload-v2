import Foundation
import Testing
@testable import OffloadMac

// The labelled sample build in `.local` backend mode (SPEC m3-13 red test SAMPLE): the mockup's build played once over
// 92 ticks of 100 ms, Reduce Motion showing the final state, Replay, Install disabled, never stored, never unlabelled.

extension M313 {
  @Test("SAMPLE: .local shows only the sample, with the Sample data label first")
  @MainActor func sampleOnlyInLocal() async {
    let store = MemoryBuildRecordStore([M313F.record()])
    let model = M313M.local(store: store)
    await model.refresh()
    #expect(model.builds.count == 1)
    #expect(model.builds.first?.id == SampleBuild.rowID)
    #expect(model.builds.first?.name == "Sample build")
    #expect(model.builds.first?.isSample == true)
    #expect(model.selected == SampleBuild.rowID)
    #expect(model.provenance == .sample)
    #expect(model.provenance.label == "Sample data: cloud not connected")
    #expect(model.detail?.provenance == .sample)
    #expect(model.detail?.title == "Building · PR pre-read tool")
  }

  @Test("SAMPLE: the timeline at tick 0 waits on every worker and plans; tick 14 has the checks frozen")
  func sampleEarlyTicks() {
    let t0 = SampleTimeline.state(at: 0)
    #expect(t0.workers.count == 8)
    #expect(t0.workers.allSatisfy { $0.state == .waiting && $0.done == 0 })
    #expect(t0.passed == 0 && t0.total == 47)
    let d0 = BuildDetail.sample(tick: 0)
    #expect(d0.steps.map(\.status) == [.working, .waiting, .waiting, .waiting, .waiting])
    #expect(d0.meter.text == "0m 00s · $0.00 of $4.00")
    #expect(d0.headline == "Building. Tests first.")
    let d14 = BuildDetail.sample(tick: 14)
    #expect(d14.steps.map(\.status) == [.done, .done, .working, .waiting, .waiting])
    #expect(d14.steps[1] == StepRow(title: "Checks frozen first", detail: "47 tests written before any code · fingerprint 7c41e2", status: .done))
    #expect(d14.steps[2] == StepRow(title: "8 workers testing in parallel", detail: "0 of 47 passing", status: .working))
    #expect(d14.meter.text == "0m 57s · $0.13 of $4.00")
  }

  @Test("SAMPLE: at tick 40 one worker has failed a check and the builder is fixing it")
  func sampleTick40() {
    let s = SampleTimeline.state(at: 40)
    #expect(s.failing)
    #expect(!s.allPass)
    #expect(s.passed == 30)
    let risky = s.workers[2]
    #expect(risky.name == "risky-files rule")
    #expect(risky.state == .failed)
    #expect(risky.done == 3)
    #expect(risky.boxes == [.passed, .passed, .passed, .failed, .empty, .empty, .empty])
    #expect(risky.countText == "3/7")
    #expect(s.workers.filter { $0.state == .failed }.count == 1)
    let d = BuildDetail.sample(tick: 40)
    #expect(d.headline == "One check failed. Fixing it.")
    #expect(d.steps[2].detail == "1 failed · builder is fixing it")
    #expect(d.dot == .needsYou)
  }

  @Test("SAMPLE: at tick 80 every worker passed and it matches what you asked for; at tick 92 it is ready")
  func sampleLateTicks() {
    let s80 = SampleTimeline.state(at: 80)
    #expect(s80.allPass && s80.intent && !s80.ready)
    #expect(s80.passed == 47)
    #expect(BuildDetail.sample(tick: 80).steps.map(\.status) == [.done, .done, .done, .done, .working])
    let d = BuildDetail.sample(tick: 92)
    #expect(SampleTimeline.state(at: 92).ready)
    #expect(d.steps.map(\.status) == [.done, .done, .done, .done, .done])
    #expect(d.headline == "It's built and every check passed.")
    #expect(d.meter.text == "6m 12s · $0.84 of $4.00")
    #expect(d.workers.map(\.name) == ["parse PR diff", "missing-tests rule", "risky-files rule", "summary card", "GitHub read-only",
                                      "masking", "menu bar entry", "intent check"])
    #expect(d.workers.map(\.total) == [6, 5, 7, 4, 6, 5, 8, 6])
    #expect(d.workers.allSatisfy { $0.state == .passed && $0.done == $0.total })
    #expect(d.saving?.text == "saves 1.4 h/wk, estimated · measured for 4 weeks after you install")
    #expect(d.heldOut == .passed)
    #expect(SampleTimeline.state(at: 500) == SampleTimeline.state(at: 92))
  }

  @Test("SAMPLE: it plays once over 92 ticks of 100 ms")
  @MainActor func samplePlaysOnce() async {
    let sleeper = M313Sleeper()
    let model = M313M.local(sleeper: sleeper)
    await model.refresh()
    #expect(model.sampleTick == 0)
    await model.runSampleLoop()
    #expect(model.sampleTick == 92)
    #expect(sleeper.delays == Array(repeating: 0.1, count: 92))
    #expect(model.detail == BuildDetail.sample(tick: 92))
    #expect(model.sampleStep() == nil)
  }

  @Test("SAMPLE: Reduce Motion shows tick 92 at once")
  @MainActor func sampleReduceMotion() async {
    let sleeper = M313Sleeper()
    let model = M313M.local(sleeper: sleeper)
    model.reduceMotion = true
    await model.refresh()
    model.replaySample()
    #expect(model.sampleTick == 92)
    await model.runSampleLoop()
    #expect(sleeper.delays.isEmpty)
    #expect(model.detail?.headline == "It's built and every check passed.")
  }

  @Test("SAMPLE: Install is disabled with \"Installing needs the cloud.\" and nothing can be read or sent")
  @MainActor func sampleInstallDisabled() async {
    let model = M313M.local()
    await model.refresh()
    await model.runSampleLoop()
    #expect(model.detail?.actions.offerInstall == true)
    #expect(!model.canInstall)
    #expect(!model.canReadDefinition)
    #expect(model.installLine == "Installing needs the cloud.")
    await model.readDefinition()
    await model.install()
    #expect(model.installState.definition == nil)
    #expect(model.installState.installed == nil)
    #expect(model.installLine == "Installing needs the cloud.")
  }

  @Test("SAMPLE: the sample is never stored or counted, and never shown without the label")
  @MainActor func sampleNeverStored() async {
    let suite = "m313-sample-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsBuildRecordStore(defaults: defaults)
    let model = BuildProgressModel(mode: .local, client: nil, store: store, sleeper: M313Sleeper(), timeZone: M313F.utc)
    model.activate()
    await model.refresh()
    await model.runSampleLoop()
    model.replaySample()
    await model.runSampleLoop()
    #expect(store.records().isEmpty)
    #expect(defaults.data(forKey: UserDefaultsBuildRecordStore.key) == nil)
    for tick in 0...SampleTimeline.endTick {
      #expect(BuildDetail.sample(tick: tick).provenance == .sample)
    }
    // In .cloud there is no sample at all.
    let cloud = M313M.cloud(M313Client())
    await cloud.refresh()
    #expect(cloud.builds.isEmpty)
    #expect(cloud.provenance == .cloud)
    #expect(cloud.detail == nil)
  }

  @Test("SAMPLE: Replay restarts it from tick 0")
  @MainActor func sampleReplay() async {
    let sleeper = M313Sleeper()
    let model = M313M.local(sleeper: sleeper)
    await model.refresh()
    await model.runSampleLoop()
    #expect(model.sampleTick == 92)
    model.replaySample()
    #expect(model.sampleTick == 0)
    #expect(model.detail == BuildDetail.sample(tick: 0))
    await model.runSampleLoop()
    #expect(model.sampleTick == 92)
    #expect(sleeper.delays.count == 184)
  }
}
