import gleam/erlang/process
import gleam/function
import gleam/list
import gleam/string
import gleeunit
import simplifile
import watchexec.{Create, FileEvent, Modify, Remove}

pub fn main() -> Nil {
  gleeunit.main()
}

fn normalise_path(event: watchexec.FileEvent) -> watchexec.FileEvent {
  let assert Ok(#(_, path)) = string.split_once(event.path, "/tmp")
  FileEvent(..event, path: "./tmp" <> path)
}

fn normalise_events(
  events: List(watchexec.FileEvent),
) -> List(watchexec.FileEvent) {
  events
  |> list.map(normalise_path)
  |> list.sort(fn(a, b) {
    string.compare(
      a.path <> " " <> string.inspect(a.action),
      b.path <> " " <> string.inspect(b.action),
    )
  })
}

fn reset_test_state() {
  let assert Ok(_) = simplifile.delete_all(["tmp"])
  let assert Ok(_) = simplifile.create_directory_all("tmp")
  process.sleep(200)
  process.flush_messages()
}

pub fn hello_world_test() {
  reset_test_state()

  // Start watching
  let assert Ok(watchexec) = watchexec.start(".")
  let selector =
    process.new_selector() |> watchexec.select(watchexec, function.identity)

  // Trigger some file system events
  let assert Ok(_) = simplifile.create_file("tmp/one")
  let assert Ok(_) = simplifile.create_file("tmp/two")
  let assert Ok(_) = simplifile.rename("tmp/two", "tmp/three")
  let assert Ok(_) = simplifile.delete("tmp/one")

  // Verify
  let assert Ok(data) = process.selector_receive(selector, 500)
  let assert Ok(#(watchexec2, events)) = watchexec.parse_data(watchexec, data)

  assert normalise_events(events)
    == [
      FileEvent(Create, "./tmp/one"),
      FileEvent(Remove, "./tmp/one"),
      FileEvent(Modify, "./tmp/three"),
      FileEvent(Create, "./tmp/two"),
      FileEvent(Modify, "./tmp/two"),
    ]
  assert watchexec == watchexec2
}

pub fn multiple_messages_test() {
  reset_test_state()

  // Start watching
  let assert Ok(watchexec) = watchexec.start(".")
  let selector =
    process.new_selector() |> watchexec.select(watchexec, function.identity)

  // Trigger so many events that it'll have to be sent in multiple messages
  let loops = 1000
  list.repeat(Nil, loops)
  |> list.each(fn(_) {
    let assert Ok(_) = simplifile.create_file("tmp/one")
    let assert Ok(_) = simplifile.delete("tmp/one")
  })

  // Verify
  let data = receive_all(selector, [])

  assert list.length(data) > 1
    as "must have multiple data for test to be meaningful"

  let assert Ok(#(watchexec2, events)) =
    list.try_fold(data, #(watchexec, []), fn(acc, data) {
      case watchexec.parse_data(watchexec, data) {
        Ok(#(watchexec, data)) -> Ok(#(watchexec, [data, ..acc.1]))
        Error(e) -> Error(e)
      }
    })
  let events = events |> list.reverse |> list.flatten

  assert list.length(events) > loops
  assert list.length(events) < loops * 2
  assert watchexec2 == watchexec
}

fn receive_all(selector, acc) {
  case process.selector_receive(selector, 500) {
    Ok(data) -> receive_all(selector, [data, ..acc])
    Error(_) -> list.reverse(acc)
  }
}
