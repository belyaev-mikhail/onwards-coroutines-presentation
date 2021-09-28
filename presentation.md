---
lang: en

theme: metropolis


title: 'Kotlin Coroutines: Design and Implementation'
subtitle:
  - Kotlin Language Research/SPbPU
author:
  - '**Mikhail Belyaev**'
  - Roman Elizarov
  - Marat Akhin
  - Ilmir Usmanov
date: '\today'

aspectratio: 169
csquotes: true
colorlinks: true
urlcolor: SkyBlue
header-includes:
- |
  ```{=latex}
  \usepackage{setspace}
  \usepackage{csquotes}

  \newfontfamily\cyrillicfont{Fira Sans}
  \newfontfamily\cyrillicfonttt{Fira Mono}

  \setsansfont[BoldFont={Fira Sans Bold}, Scale=1.05]{Fira Sans}
  \setmonofont[Scale=0.95]{Fira Mono}

  \metroset{outer/numbering=fraction}
  \metroset{background=dark}
  \metroset{progressbar=frametitle}

  \definecolor{eigengrau}{rgb}{0.08627, 0.08627, 0.1137}
  \definecolor{gold}{rgb}{0.6509, 0.4863, 0.0001}

  \setbeamercolor{normal text}{bg=eigengrau,fg=white}
  \setbeamercolor{title separator}{fg=red}
  \setbeamercolor{frametitle}{bg=eigengrau,fg=gold}
  \setbeamercolor{progress bar}{bg=white,fg=red}

  \newcommand{\scaleCode}[1][0.75]{\linespread{1.0}\setmonofont[Scale=#1]{Fira Mono}}
  ```

---
# Kotlin Coroutines: Design and Implementation

Speaker: Mikhail Belyaev

<belyaev@kspt.icc.spbstu.ru>

Jetbrains Research
Kotlin Language Research Team
Saint-Petersburg Polytechnic University

# Contacts and technical agenda

If you're not familiar with Kotlin:

Language documentation:
<https://kotlinlang.org/docs>

Specification RFC (WIP!):
<https://kotlinlang.org/spec>

To contact the authors:

Just mail me at <belyaev@kspt.icc.spbstu.ru>

<https://kotlinlang.slack.com/>

# The story so far: asynchronisity

- The ideas date back to the 70s
- Got forgotten due to the rise of multithreading
- Going back big time in the recent years

# The story so far: callbacks

- Do not need anything from the language
- Simple and understandable on the low level
- User code susceptible to *callback hell*

\scaleCode

```kotlin
fs.listDirectory(target) { files ->
    for (file in files) {
        file.readText { text ->
            sendMessage(peer, text) { answer ->
                database.store(answer) { result ->
                    if (result.error) error(result.error)
                }
                sendMessage(leader, 'done') { answer ->
                    log(answer)
}   }   }   }   }
```

# The story so far: promises

- Futures/deferreds/tasks
- Now you have an object to hold the _unfinished_ result
- Two operations: check for readiness and get
- Not really async: you have to block to get the object

# The story so far: active/pipelined promises

- Promises with higher-order functions to process asynchronously
- Essentially, a mixture between promises and callbacks
- Haskell teacher speaking: just make the promise a **Monad**

----------------

\scaleCode

```kotlin
fs.listDirectory(dir)
  .thenApply { files ->
      files.map { file ->
          file.readText()
              .thenCompose { text ->
                  sendMessage(peer, text)
              }.thenCompose { answer ->
                  database.store(answer)
              }.thenRun { result ->
                  if (result.error) error(result.error)
              }.thenCompose { result ->
                  sendMessage(leader, 'done')
              }.thenApply { answer ->
                  log(answer)
              }
     }.let { allOf(it) }
  }
```

# The story so far: async/await

- Currently taking over
- Write asynchronous code with `async`
- Call asynchronous code with `await`
- C#, C++, JS/TS, Python, Rust, etc.

\scaleCode

```C#
// C# for doing it justice
public async Task<CultureInfo> GuessWebPageLocale(Uri uri)
{
    string text = await new WebClient()
        .DownloadStringTaskAsync(uri);
    CultureInfo localeGuess = GuessLocaleFromText(text);
    return localeGuess;
}
```

# The story so far: async/await

- Lots of implementations *look like* syntax sugar over pipelined promises
- But most are actually based on **coroutines**
- Kotlin is no exception here

# Honourable mention: green threads/fibers

- Essentially threads, but with cooperative switching
- Need huge support from the runtime

\scaleCode[0.9]

```go
func fetchUrlAsString(url string, ch chan string) {
	res, _ := http.Get(url)
	defer res.Body.Close()
	body, _ := ioutil.ReadAll(res.Body)
	ch <- string(body)
}

func guessWebPageLocale(url string) string {
	text := make(chan string)
	go fetchUrlAsString(url, text)
	return guessLocaleFromText(<-text)
}
```

# The story so far: coroutines

- We still have no universally accepted definition!
- Something along: a function that can suspend and resume it's execution

# The story so far: coroutines

- Symmetric vs asymmetric coroutines
    - A **symmetric** coroutine may resume to any other coroutine, not just the caller
- Symmetric coroutines are more powerful, but hard to reason about

# The story so far: coroutines

- Stackful vs stackless coroutines
    - Stackful: can suspend anywhere it wants no matter how deep
    - Stackless: can only suspend itself and return to the caller, nested suspendable calls are coroutines too
- Stackful coroutines are obviously more powerful, but need runtime support

# The story so far: continuations

- A **continuation** is a value representing the whole execution state point that can be manually resumed from that point
- Go back to CPS in Algol 60 and `call/cc` in Scheme
- In fact, most modern coroutine implementations use CPS under the hood, so a continuation may be viewed as a low-level implementation mechanism

# Coroutine problems

- Code colouring
    - Let's call asynchronous functions **red** and synchronous functions **blue**
    - Can you call a red function from a blue one?
    - It's not only a matter of restrictions, but code understanding as well
- Error handling
    - Modern programmers are used to exceptions that propagate **upwards**
    - For coroutines, you sometimes need to propagate error **downwards** or even **sideways**
    - Welcome structured concurrency principles (see paper for details)

# Kotlin coroutines: goals

- Independence from low-level platform-specific implementations
- Adaptability to existing implementations
- Support for pragmatic asynchronous programming
- Support for structured concurrency

# Kotlin coroutines: classification

- `async`/`await` family, but with a twist
- Asynchronous and stackless
- Colourful: red functions cannot be called from blue functions
- A very small and flexible low-level API

# `async`/`await` family, but with a twist

- Observation: most of the time, you `await`
- This is even sometimes refered to as "await hell"

\scaleCode

```C#
public async Task<Name> GetPersonInfoFromSite(Uri uri) {
    File file = await new WebClient()
        .DownloadToFile(uri, tempFile());
    Document html = await parseHtmlFile(file);
    Person person = findPersonInDocument(html);
    Name name = await getPersonNameFromDatabase(person.id);
    if (name == null) {
        await storePersonName(person, "");
        await reportErrorToUser(person);
    }
    return name;
}
```

# `async`/`await` family, but with a twist

- There is no `await` keyword, you just always `await`
- You can do more fine-grained logic using the API

\scaleCode

```kotlin
suspend fun getPersonInfoFromSite(uri: Uri): Name {
    val file = new WebClient()
        .downloadToFile(uri, tempFile())
    val html = parseHtmlFile(file)
    val person = findPersonInDocument(html)
    val name = getPersonNameFromDatabase(person.id)
    if (name == null) {
        storePersonName(person, "")
        reportErrorToUser(person)
    }
    return name
}
```

# Low-level coroutine API

Four main components:

- Low-level coroutine intrinsics
- Suspending functions CPS/State machine transform
- Coroutine interception
- Coroutine context

# The low-level API

\scaleCode

```kotlin
interface Continuation<in T> {
   val context: CoroutineContext
   fun resumeWith(result: Result<T>)
}
```

```kotlin
fun <T> (suspend () -> T).createCoroutineUnintercepted(
    completion: Continuation<T>
): Continuation<Unit>
```

```kotlin
suspend fun <T> suspendCoroutineUninterceptedOrReturn(
    block: (Continuation<T>) -> Any?
): T
```

```kotlin
fun <T> (suspend () -> T).startCoroutineUninterceptedOrReturn(
    completion: Continuation<T>
): Any?
```

# Compiling functions to continuations

```kotlin
suspend fun foo(i: Int): A
```

```kotlin
fun foo(i: Int, cont: Continuation<A>): Any?
```

--------------------------------------

\scaleCode

```kotlin
val a = foo(2)
val b = bar(a)
```

```kotlin
class <anonymous>
private constructor(completion: Continuation<Any?>):
  SuspendLambda<...>(completion) {
    var label = 0
    var a: A? = null
    var b: B? = null

    fun invokeSuspend(result: Any?): Any? { /* state machine */ }

    fun create(completion: Continuation<Any?>): Continuation<Any?> =
    	<anonymous>(completion)

    fun invoke(completion: Continuation<Any?>): Any? =
        create(completion).invokeSuspend(Unit)
}
```

------------------

\scaleCode

```kotlin
if (label == 0) goto L0
if (label == 1) goto L1
if (label == 2) goto L2
else throw IllegalStateException()

L0: label = 1
result = foo(2, this)
if (result == COROUTINE_SUSPENDED) return COROUTINE_SUSPENDED
L1: label = 2
result.throwOnFailure()
a = result as A
result = bar(a, this)
if (result == COROUTINE_SUSPENDED) return COROUTINE_SUSPENDED
L2: result.throwOnFailure()
b = result as B
label = -1 // No more steps are allowed
return Unit
```

# Interception

- A Coroutine context may contain an **interceptor**
- `startCoroutine` and `suspendCoroutine` check if there is one and wrap every Continuation using it
- This allows precise control on how coroutine is run:
    - Directly
    - In an event loop
    - In a separate thread
    - In a scheduled executor
    - etc.
- Please refer to the paper text for details

# Design evaluation

- Did we achieve the flexibility goal?
    - If you have an existing asynchronous API, how hard it is to adapt to coroutines?
    - How hard it is to adapt coroutines to a different style of async computations?

# The flexibility goal: callbacks

\scaleCode

```kotlin
// callback-based version
fun someLongComputation(params: Params,
                        callback: (Value) -> Unit)
```
```kotlin
// suspendable version
suspend fun someLongComputation(params: Params): Value =
    suspendCoroutine { cont ->
        someLongComputation(
            params,
            { result -> cont.resume(it) }
        )
    }
```

# The flexibilty goal: promises

\scaleCode

```kotlin
// promise-based version
fun someLongComputation(params: Params): CompletableFuture<Value>
```
```kotlin
// suspendable version
suspend fun someLongComputation(params: Params): Value =
    suspendCoroutine { cont ->
        someLongComputation(params)
            .whenComplete { result, exception ->
            if (exception == null) // completed normally
                cont.resume(result)
            else // completed with an exception
                cont.resumeWithException(exception)
        }
    }
```

# The flexibility goal: different styles of computations

\scaleCode

```kotlin
val future = future {
    // create a Future
    val original = loadImageAsync("...original...")
    // create a Future
    val overlay = loadImageAsync("...overlay...")
    ...
    // suspend while awaiting the loading of the images
    // then run `applyOverlay(...)` when both are loaded
    applyOverlay(original.await(), overlay.await())
}
```

(the complete implementation is in the paper appendix)

# The flexibility goal: different styles of computations

\scaleCode

```kotlin
suspend fun fibonacci(n: Int, c: SendChannel<Int>) {
    var x = 0
    var y = 1
    for (i in 0..n - 1) {
        c.send(x)
        val next = x + y
        x = y
        y = next
    }
    c.close()
}
```

(the complete implementation is in the paper appendix)

# The flexibility goal: generators

Note: generators are usually a completely separate language feature, see JS/TS or Python as examples. In kotlin, however, it is implemented using coroutines without language support.

\scaleCode

```kotlin
fun infinitePalindromes(): Sequence<Int> = sequence {
    var num = 0
    while (true) {
        if (isPalindrome(num)) yield(num)
        ++num
    }
}
```

(the complete implementation is in the paper appendix)

# Known limitations and future work

- Structured concurrency is now implemented as a library feature, may be worth being supported in the language itself
- Function coloring in presence of more than two colors
- "Color-transparent" higher-order functions
- Serializable continuations?
    - Suspension across **machines**, not just threads
- Interaction with OOP:
    - Suspendable constructors?
- Interoperability with platform-provided coroutines
    - Project Loom
    - LLVM coroutines

# Summing up

- Asynchronous programming is still a largely unsolved problem
    - Ideal design and ideal implementation still do not exist
- Code colouring/error handling still vary across implementations
- New problems arise with new ideas
- Kotlin a solution that has proven its worth in
    - Code readability
    - Flexibility of interaction with other frameworks
    - A number of user success stories

