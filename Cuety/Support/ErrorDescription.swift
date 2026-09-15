import Foundation

nonisolated protocol OperatorReadableError: Error, CustomStringConvertible {}

nonisolated extension Error {
    var operatorDescription: String {
        (self as? any OperatorReadableError)?.description ?? localizedDescription
    }
}

nonisolated extension OSCDecodingError: OperatorReadableError {}
nonisolated extension SLIPFramingError: OperatorReadableError {}
extension PasscodeStore.Failure: OperatorReadableError {}
nonisolated extension QLabReplyParser.Failure: OperatorReadableError {}
extension QLabConnection.SendFailure: OperatorReadableError {}
extension QLabClient.RequestFailure: OperatorReadableError {}
