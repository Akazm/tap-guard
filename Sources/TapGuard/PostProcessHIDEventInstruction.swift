/// Instructs the ``HIDEventDispatcher``how to postprocess a received event
public enum PostProcessHIDEventInstruction: Sendable {
    /// Instructs the ``HIDEventDispatcher`` to retain an event, preventing it from further processing by the  pipeline and the OS
    case retain
    /// Instructs the ``HIDEventDispatcher`` to pass an event, enabling further processing by the pipeline and the OS
    case pass
    /// Instructs the ``HIDEventDispatcher`` to pass an event, enabling further processing by the OS, but bypassing further processing by the pipeline
    case bypass
}
