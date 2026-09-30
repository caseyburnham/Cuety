/// Runs `operation` over `items` with at most `limit` in flight, handing each
/// result to `collect` as it finishes.
///
/// `shouldContinue` is checked as each result arrives; once it is false the
/// remaining work is cancelled and nothing more is collected.
///
/// - Returns: Whether every item ran to completion.
@discardableResult
func withBoundedConcurrency<Item: Sendable, Output: Sendable>(
    over items: [Item],
    limit: Int,
    while shouldContinue: () -> Bool = { !Task.isCancelled },
    run operation: @escaping @Sendable (Item) async -> Output,
    collect: (Output) -> Void = { _ in }
) async -> Bool {
    await withTaskGroup(of: Output.self) { group in
        var remaining = items[...]

        for item in remaining.prefix(limit) {
            group.addTask { await operation(item) }
        }
        remaining = remaining.dropFirst(limit)

        while let output = await group.next() {
            guard shouldContinue() else {
                group.cancelAll()
                return false
            }
            collect(output)

            if let item = remaining.popFirst() {
                group.addTask { await operation(item) }
            }
        }
        return true
    }
}
