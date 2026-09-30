import Foundation

nonisolated extension TimeInterval {
    /// A round trip as an operator reads it: "3.2 ms".
    var millisecondsText: String {
        Duration.seconds(self).formatted(
            .units(allowed: [.milliseconds], width: .abbreviated, fractionalPart: .show(length: 1))
        )
    }

    /// A cue's duration or wait: tenths under ten seconds, whole seconds under
    /// a minute, then minutes and seconds.
    var cueDurationText: String {
        let duration = Duration.seconds(self)
        guard self < 60 else { return duration.formatted(.time(pattern: .minuteSecond)) }
        return duration.formatted(
            .units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: self < 10 ? 1 : 0))
        )
    }
}
