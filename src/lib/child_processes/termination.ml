(* termination.ml -- maintain a set of child pids
   when a child terminates, terminate the current process
*)

open Async
open Core_kernel
include Hashable.Make_binable (Pid)

type process_kind = Prover | Verifier
[@@deriving show {with_path= false}, yojson]

type data = {kind: process_kind; termination_expected: bool}
[@@deriving yojson]

type t = data Pid.Table.t

let create_pid_table () : t = Pid.Table.create ()

let register_process ?(termination_expected = false) (t : t) process kind =
  let data = {kind; termination_expected} in
  Pid.Table.add_exn t ~key:(Process.pid process) ~data

let mark_termination_as_expected t child_pid =
  Pid.Table.change t child_pid
    ~f:(Option.map ~f:(fun r -> {r with termination_expected= true}))

let remove : t -> Pid.t -> unit = Pid.Table.remove

(* for some signals that cause termination, offer a possible explanation *)
let get_signal_cause_opt =
  let open Signal in
  let signal_causes_tbl : string Table.t = Table.create () in
  List.iter
    [ (kill, "Process killed because out of memory")
    ; (int, "Process interrupted by user or other program") ]
    ~f:(fun (signal, msg) ->
      Base.ignore (Table.add signal_causes_tbl ~key:signal ~data:msg) ) ;
  fun signal -> Signal.Table.find signal_causes_tbl signal

let get_child_data (t : t) child_pid = Pid.Table.find t child_pid

let check_terminated_child (t : t) child_pid logger =
  if Pid.Table.mem t child_pid then
    let data = Pid.Table.find_exn t child_pid in
    if not data.termination_expected then (
      [%log error]
        "Child process of kind $process_kind with pid $child_pid has terminated"
        ~metadata:
          [ ("child_pid", `Int (Pid.to_int child_pid))
          ; ("process_kind", `String (show_process_kind data.kind)) ] ;
      Core_kernel.exit 99 )

let wait_for_process_log_errors ~logger process ~module_ ~location =
  (* Handle implicit raciness in the wait syscall by calling [Process.wait]
     early, so that its value will be correctly cached when we actually need
     it.
  *)
  match
    Or_error.try_with (fun () ->
        (* Eagerly force [Process.wait], so that it won't be captured
           elsewhere on exit.
        *)
        let waiting = Process.wait process in
        don't_wait_for
          ( match%map Monitor.try_with_or_error (fun () -> waiting) with
          | Ok _ ->
              ()
          | Error err ->
              Logger.error logger ~module_ ~location
                "Saw a deferred exception $exn while waiting for process"
                ~metadata:[("exn", Error_json.error_to_yojson err)] ) )
  with
  | Ok _ ->
      ()
  | Error err ->
      Logger.error logger ~module_ ~location
        "Saw an immediate exception $exn while waiting for process"
        ~metadata:[("exn", Error_json.error_to_yojson err)]
