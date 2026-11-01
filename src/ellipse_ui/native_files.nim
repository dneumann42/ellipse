## Native SDL3 file pickers. Call from the UI thread. Completion also runs
## on the UI thread; cancellation has an empty path and no error.
import ellipse/platform/platform

type
  NativeFileResult* = object
    path*: string
    error*: string
  NativeFileDone* = proc(result: NativeFileResult) {.closure.}

when withSdl:
  import sdl3
  import std/tables
  {.compile: "native_files.c".}

  var nextRequest: cint
  var pending: Table[cint, NativeFileDone]

  proc deliver(id: cint; path, error: cstring) {.cdecl.} =
    let done = pending[id]
    pending.del(id)
    done(NativeFileResult(path: (if path == nil: "" else: $path),
                          error: (if error == nil: "" else: $error)))

  proc newRequest(id: cint; done: proc(id: cint; path, error: cstring) {.cdecl.}): pointer
    {.importc: "ellipse_file_request".}
  proc fileCallback(userdata: pointer; files: cstringArray; filter: cint)
    {.cdecl, importc: "ellipse_file_callback".}

proc nativeFileDialog*(done: NativeFileDone; save = false; defaultPath = "") {.gcsafe.} =
  ## `save` chooses a destination; it does not write the file. SDL provides
  ## the platform's overwrite confirmation. One selected file is returned.
  # Requests and completions are confined to the SDL main thread.
  {.cast(gcsafe).}:
    when withSdl:
      if videoDriver().len == 0:
        done(NativeFileResult(error: "Native file dialogs require the SDL video backend"))
        return
      inc nextRequest
      let request = newRequest(nextRequest, deliver)
      if request == nil:
        done(NativeFileResult(error: "Could not allocate native file dialog"))
        return
      pending[nextRequest] = done
      let parent = cast[sdl3.Window](sdlWindow())
      let location = if defaultPath.len == 0: nil else: defaultPath.cstring
      if save:
        sdl3.showSaveFileDialog(fileCallback, request, parent, nil, 0, location)
      else:
        sdl3.showOpenFileDialog(fileCallback, request, parent, nil, 0, location, false)
    else:
      done(NativeFileResult(error: "Native file dialogs require SDL3 support"))
