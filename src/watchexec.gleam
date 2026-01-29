import gleam/bit_array
import gleam/erlang/process
import gleam/function
import gleam/list
import gleam/result
import sceall

// TODO: document
pub opaque type WatchexecInstance {
  WatchexecInstance(program: sceall.ProgramHandle, buffer: BitArray)
}

// TODO: document
pub type WatchexecError {
  /// The watchexec binary was not found on the `PATH`.
  WatchexecExecutableNotFound

  /// There are not enough beam ports available.
  NotEnoughBeamPorts

  /// There is insufficient memory to spawn the executable.
  NotEnoughMemory

  /// There are not enough OS processes available.
  NotEnoughOsProcesses

  /// The external command is too long to execute.
  ExternalCommandTooLong

  /// There are not enough file descriptors available.
  NotEnoughFileDescriptors

  /// The OS file table is full.
  OsFileTableFull

  /// The file at the given path could not be executed.
  FileNotExecutable

  /// No file exists at the given path.
  FileDoesNotExist

  /// The watchexec program exited.
  WatchexecInstanceExited(status_code: Int, output: BitArray)
  /// The watchexec program emitted data in an unexpected format.
  WatchexecUnexpectedOutput(output: BitArray)
}

// TODO: document
pub type FileEvent {
  FileEvent(action: FileAction, path: String)
}

pub type FileAction {
  /// An event describing non-mutating access operations on files.
  ///
  /// This event is about opening and closing file handles, as well as executing files, and any
  /// other such event that is about accessing files, folders, or other structures rather than
  /// mutating them.
  ///
  /// Only some platforms are capable of generating these.
  Access

  /// An event describing creation operations on files.
  ///
  /// This event is about the creation of files, folders, or other structures but not about e.g.
  /// writing new content into them.
  Create

  /// An event describing mutation of content, name, or metadata.
  ///
  /// This event is about the mutation of files', folders', or other structures' content, name
  /// (path), or associated metadata (attributes).
  Modify

  /// An event describing removal operations on files.
  ///
  /// This event is about the removal of files, folders, or other structures but not e.g. erasing
  /// content from them. This may also be triggered for renames/moves that move files _out of the
  /// watched subpath_.
  ///
  /// Some editors also trigger Remove events when saving files as they may opt for removing (or
  /// renaming) the original then creating a new file in-place.
  Remove

  /// Anything else!
  Other
}

// TODO: document
pub opaque type WatchexecData {
  WatchexecData(message: sceall.ProgramMessage)
}

// TODO: test
// TODO: document
pub fn start(
  watching directory: String,
) -> Result(WatchexecInstance, WatchexecError) {
  use path <- result.try(
    sceall.find_executable("watchexec")
    |> result.replace_error(WatchexecExecutableNotFound),
  )
  let program =
    sceall.spawn_program(
      executable_path: path,
      working_directory: directory,
      command_line_arguments: [
        "--only-emit-events",
        "--emit-events-to=stdio",
        "--no-discover-ignore",
      ],
      environment_variables: [],
    )
  case program {
    Ok(program) -> {
      let watchexec = WatchexecInstance(program, <<>>)
      // Flush the initial newline
      let initial =
        process.new_selector()
        |> select(watchexec, function.identity)
        |> process.selector_receive(100)
      case initial {
        Ok(WatchexecData(message: sceall.Data(data:, ..))) ->
          Ok(WatchexecInstance(program, drop_newlines(data)))
        Ok(WatchexecData(message: sceall.Exited(status_code:, ..))) ->
          Error(WatchexecInstanceExited(status_code, <<>>))
        Error(_) -> Ok(watchexec)
      }
    }
    Error(sceall.NotEnoughBeamPorts) -> Error(NotEnoughBeamPorts)
    Error(sceall.NotEnoughMemory) -> Error(NotEnoughMemory)
    Error(sceall.NotEnoughOsProcesses) -> Error(NotEnoughOsProcesses)
    Error(sceall.ExternalCommandTooLong) -> Error(ExternalCommandTooLong)
    Error(sceall.NotEnoughFileDescriptors) -> Error(NotEnoughFileDescriptors)
    Error(sceall.OsFileTableFull) -> Error(OsFileTableFull)
    Error(sceall.FileNotExecutable) -> Error(FileNotExecutable)
    Error(sceall.FileDoesNotExist) -> Error(FileDoesNotExist)
  }
}

// TODO: test
// TODO: document
pub fn stop(watchexec: WatchexecInstance) -> Bool {
  sceall.exit_program(watchexec.program)
}

// TODO: test
// TODO: document
pub fn select(
  selector: process.Selector(message),
  watchexec: WatchexecInstance,
  mapper: fn(WatchexecData) -> message,
) -> process.Selector(message) {
  sceall.select(selector, watchexec.program, fn(message) {
    mapper(WatchexecData(message))
  })
}

// TODO: test
// TODO: document
pub fn parse_data(
  watchexec: WatchexecInstance,
  data: WatchexecData,
) -> Result(#(WatchexecInstance, List(FileEvent)), WatchexecError) {
  use data <- result.try(case data.message {
    sceall.Exited(status_code:, ..) ->
      Error(WatchexecInstanceExited(status_code:, output: watchexec.buffer))

    sceall.Data(data:, ..) -> Ok(data)
  })

  let data = <<watchexec.buffer:bits, data:bits>>
  use #(parsed, remaining) <- result.try(parse(data, []))
  let watchexec = WatchexecInstance(..watchexec, buffer: remaining)
  Ok(#(watchexec, parsed))
}

fn parse(
  data: BitArray,
  events: List(FileEvent),
) -> Result(#(List(FileEvent), BitArray), WatchexecError) {
  let data = drop_newlines(data)
  case parse_line(data) {
    Ok(#(event, <<>>)) -> Ok(#(list.reverse([event, ..events]), <<>>))

    Error(_) if events != [] -> Ok(#(list.reverse(events), data))

    Ok(#(event, data)) -> parse(data, [event, ..events])

    Error(e) -> Error(e)
  }
}

fn parse_line(data: BitArray) -> Result(#(FileEvent, BitArray), WatchexecError) {
  use #(action, data) <- result.try(case data {
    <<"create:", data:bits>> -> Ok(#(Create, data))
    <<"modify:", data:bits>> -> Ok(#(Modify, data))
    <<"remove:", data:bits>> -> Ok(#(Remove, data))
    <<"access:", data:bits>> -> Ok(#(Access, data))
    <<"other:", data:bits>> -> Ok(#(Access, data))
    _ -> Error(WatchexecUnexpectedOutput(data))
  })

  use #(path, data) <- result.try(
    split_line(data, data, 0)
    |> result.replace_error(WatchexecUnexpectedOutput(data)),
  )

  use path <- result.try(
    bit_array.to_string(path)
    |> result.replace_error(WatchexecUnexpectedOutput(path)),
  )

  Ok(#(FileEvent(action, path), data))
}

fn drop_newlines(data: BitArray) -> BitArray {
  case data {
    <<"\n", data:bits>> | <<"\r\n", data:bits>> -> drop_newlines(data)
    data -> data
  }
}

fn split_line(
  rest: BitArray,
  whole: BitArray,
  index: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  case rest {
    <<"\n", rest:bits>> | <<"\r\n", rest:bits>> -> {
      use before <- result.try(bit_array.slice(whole, 0, index))
      Ok(#(before, rest))
    }
    <<_, rest:bits>> -> split_line(rest, whole, index + 1)
    _ -> Error(Nil)
  }
}
