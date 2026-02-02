# watchexec

Use watchexec as a cross-platform file event watcher on the BEAM!

[![Package Version](https://img.shields.io/hexpm/v/watchexec)](https://hex.pm/packages/watchexec)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/watchexec/)

The watchexec program needs to be installed for this code to be usable.

Watchexec is run on the command line with an Erlang port, so no NIF is
required. This means there's no complex native-code compilation build-step, and
there's no chance of a bug in the native code breaking down the virtual
machine.

```sh
gleam add watchexec@1
```
```gleam
import watchexec.{FileEvent, Modify}

pub fn main() -> Nil {
  // Start the watchexec command line program as an Erlang port
  let assert Ok(watchexec) =
    watchexec.new(watching: "/home/lucy/stuff") |> watchexec.start

  // The port sends messages back to the process that starts it,
  // so a selector is used to receive these messages.
  let selector =
    process.new_selector() |> watchexec.select(watchexec, function.identity)

  // Receive messages! In a real application we would likely want to use
  // this selector inside the `init` callback of an actor instead of running
  // it directly.
  let assert Ok(data) = process.selector_receive(selector, 500)

  // watchexec messages can spread over multiple messages (say if they are
  // too large for a single message), so there are separate receive and
  // parse stages.
  let assert Ok(#(watchexec, events)) = watchexec.parse_data(watchexec, data)
  assert events == [FileEvent(Modify, "/home/lucy/stuff/pokedex.txt")]

  // Parsing data returns an updated `watchexec` instance. Be sure to always
  // use the latest one when parsing a message. Assigning the new instance
  // to the same variable as the old one is good as it will prevent the old
  // one from being used my mistake.
}
```

Documentation can be found at <https://hexdocs.pm/watchexec>.
