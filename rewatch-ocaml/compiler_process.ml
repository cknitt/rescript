let retain_critical_external_warnings stderr =
  let marker = "`(. ...)` uncurried syntax" in
  if not (String_util.contains stderr marker) then ""
  else
    stderr
    |> Str.global_replace (Str.regexp_string "\r\n") "\n"
    |> Str.split_delim (Str.regexp_string "\n\n\n")
    |> List.filter (fun block -> String_util.contains block marker)
    |> String.concat "\n\n\n"

let build_identity = Rescript_compiler_driver.build_identity

type request = {args: string list; cwd: string}

let compiler_phase args =
  let input =
    match List.rev args with
    | input :: _ -> input
    | [] -> "<missing>"
  in
  let phase =
    if List.mem "-bs-ast" args then "parse"
    else if Filename.check_suffix input ".mlmap" then "namespace"
    else if Filename.check_suffix input ".iast" then "interface"
    else "implementation"
  in
  (phase, input)

let log_compiler_request (request : request) =
  match Sys.getenv_opt "REWATCH_COMPILER_CALL_LOG" with
  | None -> ()
  | Some path ->
    let phase, input = compiler_phase request.args in
    let channel =
      open_out_gen [Open_creat; Open_append; Open_text] 0o644 path
    in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> Printf.fprintf channel "%s\t%s\t%s\n" phase request.cwd input)

let exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> 128 + signal

let run_locally ?poll (request : request) =
  match List.rev request.args with
  | [] ->
    {
      Process.status = Unix.WEXITED 2;
      stdout = "";
      stderr = "missing compiler input";
    }
  | input :: reversed_argv -> (
    match
      Rescript_compiler_driver.run_request ~cwd:request.cwd
        ~argv:(List.rev reversed_argv) ~input
        ~run_external:
          (Some
             (fun command ->
               let command = Platform.shell_command command in
               let result =
                 Process.run ?poll ~cwd:request.cwd command.program command.args
               in
               (exit_code result.status, result.stdout, result.stderr)))
    with
    | result ->
      {
        Process.status = Unix.WEXITED result.exit_code;
        stdout = result.stdout;
        stderr = result.stderr;
      }
    | exception
        Compiler_request_output.Failed {error = Process.Interrupted _ as error}
      ->
      raise error
    | exception Compiler_request_output.Failed {error; stdout; stderr} ->
      (* Keep the warnings written before the failure. *)
      {
        Process.status = Unix.WEXITED 2;
        stdout;
        stderr = stderr ^ Printexc.to_string error ^ "\n";
      })

(* Prototype: run requests in persistent worker processes, so each compiles
   with its own GC instead of sharing OCaml 5's stop-the-world minor
   collections with the other workers. A worker is this executable, started
   with [worker_variable] set. Requests and results travel as marshalled
   values over its stdin and stdout; both ends are the same binary. Not yet
   handled: cancelling a running request, and restarting a crashed worker. *)
let worker_variable = "REWATCH_COMPILER_WORKER"

let use_worker_processes =
  Sys.getenv_opt "REWATCH_COMPILER_WORKERS" = Some "processes"

type worker = {worker_pid: int; to_worker: out_channel; from_worker: in_channel}

let idle_workers = ref []
let all_workers = ref []
let workers_mutex = Mutex.create ()

(* Closing a worker's stdin ends its loop; waiting for it also counts its CPU
   time towards this process's children. *)
let stop_workers () =
  let workers =
    Process_child.with_lock workers_mutex (fun () ->
        let workers = !all_workers in
        all_workers := [];
        idle_workers := [];
        workers)
  in
  List.iter (fun worker -> close_out_noerr worker.to_worker) workers;
  List.iter
    (fun worker ->
      try ignore (Unix.waitpid [] worker.worker_pid : int * Unix.process_status)
      with Unix.Unix_error _ -> ())
    workers

let () = if use_worker_processes then at_exit stop_workers

let spawn_worker () =
  let request_read, request_write = Unix.pipe ~cloexec:true () in
  let result_read, result_write = Unix.pipe ~cloexec:true () in
  let environment =
    Array.append [|worker_variable ^ "=1"|] (Unix.environment ())
  in
  let worker_pid =
    Unix.create_process_env Sys.executable_name [|Sys.executable_name|]
      environment request_read result_write Unix.stderr
  in
  Unix.close request_read;
  Unix.close result_write;
  let to_worker = Unix.out_channel_of_descr request_write in
  let from_worker = Unix.in_channel_of_descr result_read in
  set_binary_mode_out to_worker true;
  set_binary_mode_in from_worker true;
  let worker = {worker_pid; to_worker; from_worker} in
  Process_child.with_lock workers_mutex (fun () ->
      all_workers := worker :: !all_workers);
  worker

let acquire_worker () =
  let idle =
    Process_child.with_lock workers_mutex (fun () ->
        match !idle_workers with
        | worker :: rest ->
          idle_workers := rest;
          Some worker
        | [] -> None)
  in
  match idle with
  | Some worker -> worker
  | None -> spawn_worker ()

let release_worker worker =
  Process_child.with_lock workers_mutex (fun () ->
      idle_workers := worker :: !idle_workers)

let run_in_worker (request : request) =
  let worker = acquire_worker () in
  match
    output_value worker.to_worker request;
    flush worker.to_worker;
    (input_value worker.from_worker : (Process.result, string) result)
  with
  | Ok result ->
    release_worker worker;
    result
  | Error message ->
    release_worker worker;
    {Process.status = Unix.WEXITED 2; stdout = ""; stderr = message ^ "\n"}
  | exception (End_of_file | Sys_error _) ->
    {
      Process.status = Unix.WEXITED 2;
      stdout = "";
      stderr =
        Printf.sprintf "compiler worker %d exited unexpectedly\n"
          worker.worker_pid;
    }

(* The worker side: answer requests until the build system closes stdin. *)
let serve_worker () =
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  let minor_heap_size =
    match Sys.getenv_opt "REWATCH_WORKER_MINOR_HEAP_WORDS" with
    | Some words -> int_of_string words
    | None -> 2 * 1024 * 1024
  in
  Gc.set {(Gc.get ()) with minor_heap_size};
  let rec loop () =
    match (input_value stdin : request) with
    | exception End_of_file -> exit 0
    | request ->
      let result =
        match run_locally request with
        | result -> Ok result
        | exception exn -> Error (Printexc.to_string exn)
      in
      output_value stdout result;
      flush stdout;
      loop ()
  in
  loop ()

let run_in_process ?poll (request : request) =
  log_compiler_request request;
  if use_worker_processes then run_in_worker request
  else run_locally ?poll request

let run ?poll request =
  Option.iter (fun poll -> poll ()) poll;
  let result = run_in_process ?poll request in
  Option.iter (fun poll -> poll ()) poll;
  result

let task request =
  let cancelled = Atomic.make false in
  Process.concurrent_task
    ~cancel:(fun () -> Atomic.set cancelled true)
    (fun () ->
      run_in_process
        ~poll:(fun () ->
          if Atomic.get cancelled then raise (Process.Interrupted 15))
        request)

let run_requests ?poll ?on_complete requests =
  requests |> List.map task
  |> Process.run_tasks
       ~max_jobs:(Compiler_execution_mode.configured_count ())
       ?poll ?on_complete

let parse_request ~build_dir ~(config : Config.t) path =
  let ast = Source.ast_path path in
  File_util.ensure_dir (Filename.concat build_dir (Filename.dirname ast));
  let contents =
    if config.ppx_flags = [] then ""
    else File_util.read_file (Filename.concat config.root path)
  in
  let args = Compiler_args.parser_arguments ~config ~contents ~path in
  {args; cwd = build_dir}

let ast_dependencies ~build_dir ast =
  (Ast_header.read (Filename.concat build_dir ast)).dependencies

type compiler_artifact = Cmi | Required of string | Optional of string

let publish_compiler_artifacts ~artifact_dir ~ocaml_dir ~basename artifacts =
  let cmi_change = ref Compiler_scheduler.Cmi_change_unknown in
  try
    List.iter
      (fun artifact ->
        let extension =
          match artifact with
          | Cmi -> "cmi"
          | Required name | Optional name -> name
        in
        let source =
          Filename.concat artifact_dir (basename ^ "." ^ extension)
        in
        let destination =
          Filename.concat ocaml_dir (basename ^ "." ^ extension)
        in
        match artifact with
        | Cmi ->
          cmi_change :=
            if File_util.copy_file_if_different source destination then
              Compiler_scheduler.Cmi_changed
            else Compiler_scheduler.Cmi_unchanged
        | Required _ -> File_util.copy_existing_file source destination
        | Optional _ -> File_util.copy_optional_existing_file source destination)
      artifacts;
    !cmi_change
  with error ->
    raise (Compiler_scheduler.Publication_failure (error, !cmi_change))

let namespace_task ~runtime ~build_dir ~ocaml_dir ~entry ~package_dirty ~force
    namespace modules =
  let mlmap = Filename.concat build_dir (namespace ^ ".mlmap") in
  let contents =
    let buffer = Buffer.create 128 in
    Buffer.add_string buffer "randjbuildsystem\n";
    Source.namespace_members ~entry modules
    |> List.map (fun module_ -> module_.Source.name)
    |> List.sort String.compare
    |> List.iter (fun name ->
        Buffer.add_string buffer name;
        Buffer.add_char buffer '\n');
    Buffer.contents buffer
  in
  let previous_contents =
    try Some (File_util.read_file mlmap)
    with Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> None
  in
  let mlmap_changed = previous_contents <> Some contents in
  if mlmap_changed then
    File_util.write_file_atomic ~ensure_parent:false mlmap contents;
  let outputs_exist =
    ["cmi"; "cmj"; "cmt"; "mlmap"]
    |> List.for_all (fun extension ->
        File_util.is_regular_file
          (Filename.concat ocaml_dir (namespace ^ "." ^ extension)))
  in
  let published_mlmap_matches =
    try
      File_util.read_file (Filename.concat ocaml_dir (namespace ^ ".mlmap"))
      = contents
    with Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> false
  in
  if
    not
      (force || package_dirty || mlmap_changed
      || (not published_mlmap_matches)
      || not outputs_exist)
  then None
  else
    Some
      Compiler_scheduler.
        {
          task =
            task
              {
                args =
                  [
                    "-runtime-path";
                    runtime;
                    "-w";
                    "-49";
                    "-color";
                    "always";
                    "-no-alias-deps";
                    Filename.basename mlmap;
                  ];
                cwd = build_dir;
              };
          publish =
            (fun result ->
              if not (Process.succeeded result) then
                raise
                  (Compiler_scheduler.Build_failure
                     (result.Process.stderr ^ result.stdout));
              let cmi_change =
                publish_compiler_artifacts ~artifact_dir:build_dir ~ocaml_dir
                  ~basename:namespace
                  [Cmi; Required "cmj"; Required "cmt"; Required "mlmap"]
              in
              Compiler_scheduler.{stderr = result.stderr; cmi_change});
        }

let post_build_tasks (config : Config.t) path =
  match config.js_post_build with
  | None -> []
  | Some command ->
    List.map
      (fun spec ->
        let output = Build_artifacts.generated_js_path config path spec in
        let command = Platform.post_build_command ~command ~output in
        Compiler_scheduler.
          {
            output;
            task =
              Process.task ?env:command.env
                Process.
                  {
                    program = command.program;
                    args = command.args;
                    cwd = config.root;
                  };
          })
      config.package_specs

let compile_request ~build_dir ~(config : Config.t) ~common_args
    (module_ : Source.module_) ~source_kind path =
  let args =
    Compiler_args.compiler_arguments_with_common ~config ~common_args
      ~module_name:module_.name ~source_kind
      ~has_interface:(Option.is_some module_.interface)
      ~path
  in
  {args; cwd = build_dir}

let publish ~build_dir ~ocaml_dir ~is_local ~(config : Config.t) ~has_interface
    ~source_kind path result =
  let stderr =
    if is_local then result.Process.stderr
    else retain_critical_external_warnings result.stderr
  in
  let basename = Source.compiler_asset_basename config path in
  let artifact_dir = Filename.concat build_dir (Filename.dirname path) in
  let cmi_change = ref Compiler_scheduler.Cmi_change_unknown in
  try
    (cmi_change :=
       match source_kind with
       | Source.Interface ->
         publish_compiler_artifacts ~artifact_dir ~ocaml_dir ~basename
           [Cmi; Optional "cmti"]
       | Source.Implementation when has_interface ->
         (* The implementation is compiled with -bs-read-cmi, so its .cmi is
           the one already published after compiling the interface. *)
         ignore
           (publish_compiler_artifacts ~artifact_dir ~ocaml_dir ~basename
              [Required "cmj"; Optional "cmt"]);
         Compiler_scheduler.Cmi_unchanged
       | Source.Implementation ->
         publish_compiler_artifacts ~artifact_dir ~ocaml_dir ~basename
           [Cmi; Required "cmj"; Optional "cmt"]);
    let source = Filename.concat config.root path in
    let build_source = Filename.concat build_dir path in
    File_util.ensure_dir (Filename.dirname build_source);
    File_util.copy_existing_file source build_source;
    File_util.copy_existing_file source
      (Filename.concat ocaml_dir (Filename.basename path));
    (match source_kind with
    | Source.Interface -> ()
    | Source.Implementation ->
      List.iter
        (fun spec ->
          if spec.Config.in_source then (
            let output = Build_artifacts.generated_js_path config path spec in
            let build_output =
              Build_artifacts.generated_build_js_path ~build_dir config path
                spec
            in
            File_util.ensure_dir (Filename.dirname build_output);
            if File_util.exists output then
              File_util.copy_existing_file output build_output;
            if File_util.exists (output ^ ".map") then
              File_util.copy_existing_file (output ^ ".map")
                (build_output ^ ".map")
            else File_util.remove_file (build_output ^ ".map")))
        config.package_specs);
    Compiler_scheduler.{stderr; cmi_change = !cmi_change}
  with
  | Compiler_scheduler.Publication_failure _ as error -> raise error
  | error -> raise (Compiler_scheduler.Publication_failure (error, !cmi_change))
