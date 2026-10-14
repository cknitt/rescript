(* Measurement-only instrumentation, enabled by RESCRIPT_PERF=<file>.
   Records calls, CPU time and minor-heap words per phase, both inclusive and
   exclusive of nested phases. CPU time is process-wide (Sys.time), so phase
   numbers are only meaningful with a single compiler domain. *)

type slot = {
  mutable calls: int;
  mutable incl_time: float;
  mutable excl_time: float;
  mutable incl_words: float;
  mutable excl_words: float;
}

type frame = {
  start_time: float;
  start_words: float;
  mutable child_time: float;
  mutable child_words: float;
}

let output_file = Sys.getenv_opt "RESCRIPT_PERF"

(* Sys.time by default; the driver installs a wall clock for
   RESCRIPT_PERF_WALL. *)
let clock = ref Sys.time
let enabled = output_file <> None
let table : (string, slot) Hashtbl.t = Hashtbl.create 64
let lock = Mutex.create ()
let stack_key : frame list ref Domain.DLS.key =
  Domain.DLS.new_key (fun () -> ref [])

let record name ~time ~words ~excl_time ~excl_words =
  Mutex.lock lock;
  let slot =
    match Hashtbl.find_opt table name with
    | Some slot -> slot
    | None ->
      let slot =
        {
          calls = 0;
          incl_time = 0.;
          excl_time = 0.;
          incl_words = 0.;
          excl_words = 0.;
        }
      in
      Hashtbl.add table name slot;
      slot
  in
  slot.calls <- slot.calls + 1;
  slot.incl_time <- slot.incl_time +. time;
  slot.excl_time <- slot.excl_time +. excl_time;
  slot.incl_words <- slot.incl_words +. words;
  slot.excl_words <- slot.excl_words +. excl_words;
  Mutex.unlock lock

let time name f =
  if not enabled then f ()
  else
    let stack = Domain.DLS.get stack_key in
    let frame =
      {
        start_time = !clock ();
        start_words = Gc.minor_words ();
        child_time = 0.;
        child_words = 0.;
      }
    in
    stack := frame :: !stack;
    let finish () =
      let time = !clock () -. frame.start_time in
      let words = Gc.minor_words () -. frame.start_words in
      (match !stack with
      | _ :: rest -> (
        stack := rest;
        match rest with
        | parent :: _ ->
          parent.child_time <- parent.child_time +. time;
          parent.child_words <- parent.child_words +. words
        | [] -> ())
      | [] -> ());
      record name ~time ~words ~excl_time:(time -. frame.child_time)
        ~excl_words:(words -. frame.child_words)
    in
    Fun.protect ~finally:finish f

let count name =
  if enabled then record name ~time:0. ~words:0. ~excl_time:0. ~excl_words:0.

let dump () =
  match output_file with
  | None -> ()
  | Some file ->
    Mutex.lock lock;
    let rows =
      Hashtbl.fold (fun name slot acc -> (name, slot) :: acc) table []
    in
    Mutex.unlock lock;
    let rows =
      List.sort (fun (_, a) (_, b) -> compare b.excl_time a.excl_time) rows
    in
    let oc = open_out file in
    Printf.fprintf oc "%-28s %9s %10s %10s %12s %12s\n" "phase" "calls" "incl_s"
      "excl_s" "incl_Mw" "excl_Mw";
    List.iter
      (fun (name, s) ->
        Printf.fprintf oc "%-28s %9d %10.3f %10.3f %12.1f %12.1f\n" name s.calls
          s.incl_time s.excl_time (s.incl_words /. 1e6) (s.excl_words /. 1e6))
      rows;
    close_out oc

let () = if enabled then at_exit dump

(* Wall-clock laps between consecutive calls, for the build system's stages.
   The caller supplies the clock, since this library doesn't link Unix. *)
let last_lap = ref None

let lap ~now name =
  if enabled then (
    (match !last_lap with
    | Some last ->
      record name ~time:(now -. last) ~words:0. ~excl_time:(now -. last)
        ~excl_words:0.
    | None -> ());
    last_lap := Some now)
