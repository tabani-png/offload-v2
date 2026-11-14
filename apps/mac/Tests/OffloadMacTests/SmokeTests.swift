import Testing
@testable import OffloadMac

@Test func smokeMarkerIsPresent() {
    #expect(OffloadMacTodo.marker.hasPrefix("TODO"))
}
