# Swift & SwiftUI Quick Reference for Polyglots (JS/Python/C++/Java)

## Core Swift

**Variables & Constants:**
*   `var name = "Mutable"` (like JS `let`, Python, Java non-final)
*   `let pi = 3.14` (Immutable, like JS/C++ `const`, Java `final`) - **Prefer `let`!**
*   Type Inference: Usually works (`let count = 10` -> `Int`).
*   Explicit Type: `var value: Double = 5.0`

**Basic Types:**
*   Numbers: `Int`, `Double`, `Float`
*   Text: `String` (use `\(variable)` for interpolation: `"Value: \(value)"`)
*   Logic: `Bool` (`true`, `false`)
*   Collections: `Array<String>`, `[String]` (like Python list, JS Array, Java ArrayList); `Dictionary<String, Int>`, `[String: Int]` (like Python dict, JS Object, Java HashMap)

**Optionals (`nil` / `null` Handling):**
*   Problem: `nil` (like `null`) causes crashes if accessed directly.
*   Declare: `var middleName: String?` (Can hold a `String` or `nil`)
*   Safe Unwrapping (Preferred):
    ```swift
    if let name = middleName {
        print("Middle name: \(name)") // Only runs if not nil
    }

    guard let key = apiKey else {
        print("API Key missing!")
        return // or throw, break, continue
    }
    // 'key' is non-optional here
    ```
*   Optional Chaining: `middleName?.count` (Result is `Int?`, returns `nil` if `middleName` is `nil`)
*   Nil-Coalescing: `let fullName = firstName + (middleName ?? "")` (Use `""` if `middleName` is `nil`)
*   Force Unwrap (`!`): `let firstChar = middleName!.first` (**AVOID! Crashes if `nil`**)

**Control Flow:**
*   `if condition { ... } else if { ... } else { ... }` (Braces required)
*   `switch value { case pattern1: ... case pattern2 where condition: ... default: ... }` (Powerful, must be exhaustive)
*   Loops: `for item in items { ... }`, `while condition { ... }`

**Functions:**
*   `func greet(person name: String) -> String { return "Hi, \(name)" }`
    *   `person`: External parameter name (used when calling: `greet(person: "Ed")`)
    *   `name`: Internal parameter name (used inside the function)
    *   `_`: Use `_` for no external name: `func add(_ a: Int, b: Int)` -> `add(5, b: 3)`
    *   `-> String`: Return type. Use `Void` or omit for no return value.

**Structs vs. Classes:**
*   `struct Point { var x, y: Double }`
    *   **Value Type:** Copied on assignment/pass (like primitives, C++ stack objects).
    *   No inheritance.
    *   Use for simple data containers (e.g., `ChatMessage`, API request/response models).
*   `class ViewModel { var data: String = "" }`
    *   **Reference Type:** Shared instance (like Python/Java objects, JS classes, C++ heap objects/pointers).
    *   Supports inheritance.
    *   Use for objects with state, identity, or complex behavior (`ChatViewModel`).

**Protocols:**
*   `protocol Delegate { func didComplete() }`
    *   Like Java interfaces / C++ abstract base classes. Defines a contract.
    *   Classes/structs/enums can *conform* to protocols: `class MyClass: Delegate { ... }`
    *   Used heavily for delegation (e.g., `AVAudioPlayerDelegate`, `SFSpeechRecognizerDelegate`).

**Closures (Lambdas / Anonymous Functions):**
*   `{ (parameters) -> ReturnType in statements }`
*   Example: `numbers.sorted { $0 < $1 }` (`$0`, `$1` are shorthand for first, second params)
*   **Trailing Closure Syntax:** If the last argument is a closure, you can write it outside `()`:
    ```swift
    someFunction(arg1: 10) { result in // This block is the closure
        print("Completed with \(result)")
    }
    ```
*   **`[weak self]`:** Capture list inside class methods to prevent memory leaks (retain cycles) when the closure references `self`.

**Error Handling:**
*   `enum MyError: Error { case networkFailed, invalidData }` (Define custom errors)
*   `func mightThrow() throws -> Data { ... throw MyError.networkFailed ... }` (Mark throwing functions)
*   ```swift
    do {
        let data = try mightThrow() // Call with 'try'
        let optionalData = try? mightThrow() // Returns optional, nil on error
    } catch MyError.networkFailed {
        print("Network failed")
    } catch {
        print("An unexpected error: \(error)") // Generic catch
    }
    ```

**Concurrency (`async` / `await`):**
*   Like JS/Python `async`/`await`.
*   `func fetchData() async throws -> String { ... }` (Mark async functions)
*   `let result = try await fetchData()` (Call with `await`)
*   `Task { ... }`: Start concurrent work from a synchronous context.
    ```swift
    Task { // On main thread (e.g., button tap)
        await viewModel.processSomething()
    }
    ```
*   `@MainActor`: Ensures code runs on the main UI thread. Apply to classes or functions interacting with UI.
    ```swift
    @MainActor class MyViewModel: ObservableObject { ... }
    @MainActor func updateUI() { ... }
    ```
*   `nonisolated`: Allows a method (often delegate methods) within an actor-isolated type (like `@MainActor` class) to run off that actor (e.g., on a background thread).
*   `AsyncThrowingStream`: For handling sequences arriving over time, potentially with errors (used for LLM streaming). `for try await item in stream { ... }`

**Attributes (`@...`):**
*   Provide metadata: `@Published`, `@State`, `@Binding`, `@StateObject`, `@MainActor`, `@ViewBuilder`, `nonisolated`.

## SwiftUI (Declarative UI)

*   **`View` Protocol:** Anything displayed conforms to `View`. Usually a `struct`.
*   **`body` Property:** `var body: some View { ... }` - Defines the view's content and layout. Recomputed when state changes.
*   **Layout:**
    *   `VStack`: Vertical layout (column).
    *   `HStack`: Horizontal layout (row).
    *   `ZStack`: Layered layout (views on top of each other).
    *   `Spacer()`: Pushes views apart.
*   **Common Elements:** `Text("Label")`, `Image("imageName")`, `Button("Title") { action }`, `Slider(...)`, `Toggle(...)`.
*   **Modifiers:** Chain methods to customize views: `.padding()`, `.background(Color.blue)`, `.foregroundColor(.white)`, `.frame(width: 100, height: 50)`, `.onTapGesture { ... }`, `.onAppear { ... }`. Return a *new* modified view.

**State Management:**
*   **Source of Truth:** Usually in a ViewModel (`ObservableObject`).
*   **`ObservableObject`:** Protocol for classes holding shareable UI state (`class ChatViewModel: NSObject, ObservableObject`).
*   **`@Published`:** Put *inside* `ObservableObject`. Automatically notifies views when the property changes: `@Published var messages: [ChatMessage] = []`.
*   **`@StateObject`:** *Creates and owns* an `ObservableObject` instance for the view's lifetime.
    ```swift
    // In ContentView
    @StateObject private var viewModel = ChatViewModel()
    ```
*   **`@ObservedObject`:** *References* an `ObservableObject` created elsewhere (passed into the view).
*   **`@State`:** Simple *local* view state (value types like `Bool`, `Int`, `String`). Owned by the view. `@State private var isShowingAlert = false`.
*   **`@Binding`:** Creates a *two-way connection* to a state owned by a parent view or ViewModel. Used to pass state down *mutably*.
    ```swift
    // In VoiceIndicatorView (child)
    @Binding var isListening: Bool // Connects to viewModel.isListening

    // In ContentView (parent)
    VoiceIndicatorView(isListening: $viewModel.isListening, ...) // '$' passes a Binding
    ```

## Project Frameworks

*   **`AVFoundation`:** Audio/Video.
    *   `AVAudioEngine`: Mic input node (`inputNode`).
    *   `AVAudioSession`: Configure app audio behavior (`.playAndRecord`, `.duckOthers`, `overrideOutputAudioPort(.speaker)`).
    *   `AVAudioPlayer`: Play audio data (TTS). `AVAudioPlayerDelegate` for events (`audioPlayerDidFinishPlaying`).
    *   `AVAudioPCMBuffer`: Raw audio data (for level calculation, speech input).
*   **`Speech`:** Speech Recognition.
    *   `SFSpeechRecognizer`: Engine.
    *   `SFSpeechAudioBufferRecognitionRequest`: Request from mic buffer. `shouldReportPartialResults = true` for live updates.
    *   `SFSpeechRecognitionTask`: The running recognition job, provides results via closure.
    *   `SFSpeechRecognizerDelegate`: Handle availability changes.
*   **`URLSession`:** Networking. `URLRequest`, `data(for:)`, `bytes(for:)`, `AsyncBytes`. For calling Claude/Gemini/OpenAI APIs.
*   **`OSLog`:** Efficient logging (`Logger`). `logger.info("Message")`, `logger.error(...)`.
*   **`Combine`:** Framework for processing values over time (used implicitly by `@Published`).

## Key Patterns in this App

*   **MVVM (Model-View-ViewModel):**
    *   Model: Data structures (`ChatMessage`, API structs).
    *   View: SwiftUI structs (`ContentView`, `VoiceIndicatorView`). Display state, send user actions.
    *   ViewModel: `ChatViewModel` (`ObservableObject`). Holds UI state (`@Published`), contains business logic, interacts with frameworks/APIs.
*   **Delegation:** `ChatViewModel` acts as delegate for `AVAudioPlayer` and `SFSpeechRecognizer`.
*   **Asynchronous Operations:** Heavy use of `async`/`await` and `Task` for network calls, speech recognition, and audio playback.
*   **State-Driven UI:** SwiftUI views update automatically based on changes to `@Published` properties in `ChatViewModel`.