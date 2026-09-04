/// Retains the source expression so an already-visible error or action result
/// follows language changes instead of keeping its original translation.
struct LocalizedMessage {
    private let render: () -> String

    init(_ text: @autoclosure @escaping () -> String) {
        render = text
    }

    var text: String { render() }
}
