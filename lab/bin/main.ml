(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
module Eval = Mentat_eval

let exits = CCmd.Exit.defaults
let stdout_printf format = Format.printf (format ^^ "%!")
let stderr_printf format = Format.eprintf (format ^^ "%!")

(* Filesystem *)

let ensure_dir path =
  let rec loop path =
    if path = "" || path = Filename.dirname path then ()
    else if Sys.file_exists path then (
      if not (Sys.is_directory path) then
        invalid_arg (path ^ " exists and is not a directory"))
    else (
      loop (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  loop path

let write_file path text =
  ensure_dir (Filename.dirname path);
  let output = open_out path in
  output_string output text;
  close_out output

let append_line path line =
  ensure_dir (Filename.dirname path);
  let output = open_out_gen [ Open_creat; Open_text; Open_append ] 0o644 path in
  output_string output line;
  output_char output '\n';
  close_out output

let read_file path =
  let input = open_in_bin path in
  let length = in_channel_length input in
  let text = really_input_string input length in
  close_in input;
  text

(* Timestamps: local time, matching the eval runner's result-dir naming for
   directories and a readable form for JSON fields. *)

let local_tm () = Unix.localtime (Unix.time ())

let dir_timestamp () =
  let tm = local_tm () in
  Printf.sprintf "%04d%02d%02d-%02d%02d%02d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let now_string () =
  let tm = local_tm () in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

(* Subprocesses. Every decision-relevant invocation checks the exit status
   explicitly; pipelines never mask a failing child. *)

let process_success = function Unix.WEXITED 0 -> true | _ -> false

let status_message = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped by signal %d" signal

(* Run a child with the current process's stdio, streaming its output to the
   terminal. Returns the raw status so callers decide what a non-zero exit
   means (a build failure and an analysis failure are handled differently). *)
let run_streaming argv =
  let pid =
    Unix.create_process argv.(0) argv Unix.stdin Unix.stdout Unix.stderr
  in
  let _, status = Unix.waitpid [] pid in
  status

(* Capture a child's stdout; stderr is discarded. Used for git queries. *)
let capture argv =
  let read_fd, write_fd = Unix.pipe () in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let pid = Unix.create_process argv.(0) argv Unix.stdin write_fd devnull in
  Unix.close write_fd;
  Unix.close devnull;
  let buffer = Buffer.create 256 in
  let bytes = Bytes.create 4096 in
  let rec loop () =
    match Unix.read read_fd bytes 0 (Bytes.length bytes) with
    | 0 -> ()
    | count ->
        Buffer.add_subbytes buffer bytes 0 count;
        loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ();
  Unix.close read_fd;
  let _, status = Unix.waitpid [] pid in
  (status, Buffer.contents buffer)

(* Git *)

let git_head_commit () =
  match capture [| "git"; "rev-parse"; "HEAD" |] with
  | Unix.WEXITED 0, out -> (
      match String.trim out with "" -> None | rev -> Some rev)
  | _ -> None

let git_dirty () =
  match capture [| "git"; "status"; "--porcelain" |] with
  | Unix.WEXITED 0, out -> String.trim out <> ""
  | _ -> false

(* Content digest of the instrument (eval/ and lab/, tracked or not), pinned at
   calibration and re-checked before every experiment. This is what enforces
   "the instrument is frozen during a campaign". It is stronger than
   [git diff <start_ref>], which the spec sketches: comparing to a commit
   reports a false change whenever the campaign legitimately starts from an
   uncommitted, work-in-progress instrument, and misses untracked files. The
   digest walks the working tree directly, so it detects any modification since
   calibration and none that predate it. *)
let rec instrument_files root acc =
  if not (Sys.file_exists root) then acc
  else if Sys.is_directory root then
    Sys.readdir root |> Array.to_list |> List.sort String.compare
    |> List.fold_left
         (fun acc name ->
           if name = "_build" || name = ".git" then acc
           else instrument_files (Filename.concat root name) acc)
         acc
  else root :: acc

let instrument_digest () =
  let files =
    List.sort String.compare
      (instrument_files "eval" (instrument_files "lab" []))
  in
  let buffer = Buffer.create 8192 in
  List.iter
    (fun path ->
      Buffer.add_string buffer path;
      Buffer.add_char buffer '\000';
      Buffer.add_string buffer (Digest.to_hex (Digest.file path));
      Buffer.add_char buffer '\n')
    files;
  Digest.to_hex (Digest.string (Buffer.contents buffer))

(* Well-known paths (mentat-lab always runs from the repository root). *)

let mentat_bin =
  Filename.concat "_build" (Filename.concat "default" "bin/mentat/main.exe")

let eval_bin =
  Filename.concat "_build" (Filename.concat "default" "eval/bin/main.exe")

let lab_root = "_lab"
let campaign_dir tag = Filename.concat lab_root tag
let campaign_json_path tag = Filename.concat (campaign_dir tag) "campaign.json"
let calibration_dir tag = Filename.concat (campaign_dir tag) "calibration"

let exp_dir tag name =
  Filename.concat (Filename.concat (campaign_dir tag) "exp") name

let exp_results_dir tag name = Filename.concat (exp_dir tag name) "results"
let rows_file dir = Filename.concat dir "rows.jsonl"
let ledger_jsonl_path tag = Filename.concat (campaign_dir tag) "ledger.jsonl"
let ledger_md_path tag = Filename.concat (campaign_dir tag) "ledger.md"

let ensure_repo_root () =
  if not (Sys.file_exists "dune-project") then (
    stderr_printf
      "mentat-lab: run from the repository root (no dune-project found here)\n";
    exit 2)

(* JSON codecs for the campaign artifacts. Written pretty for humans and, where
   read back (campaign.json, ledger.jsonl), decoded through the same codec. *)

let encode_json ?(format = Jsont.Indent) codec value =
  match Jsont_bytesrw.encode_string ~format codec value with
  | Ok text -> text
  | Error message -> failwith ("mentat-lab: JSON encode failed: " ^ message)

let write_json path codec value =
  write_file path (encode_json codec value ^ "\n")

type campaign = {
  tag : string;
  start_ref : string;
  model : string option;
  suite : string;
  created_at : string;
  baseline_digest : string;
  baseline_dir : string;
  instrument_digest : string;
}

let campaign_jsont =
  Jsont.Object.map ~kind:"campaign"
    (fun
      tag
      start_ref
      model
      suite
      created_at
      baseline_digest
      baseline_dir
      instrument_digest
    ->
      {
        tag;
        start_ref;
        model;
        suite;
        created_at;
        baseline_digest;
        baseline_dir;
        instrument_digest;
      })
  |> Jsont.Object.mem "tag" Jsont.string ~enc:(fun c -> c.tag)
  |> Jsont.Object.mem "start_ref" Jsont.string ~enc:(fun c -> c.start_ref)
  |> Jsont.Object.opt_mem "model" Jsont.string ~enc:(fun c -> c.model)
  |> Jsont.Object.mem "suite" Jsont.string ~enc:(fun c -> c.suite)
  |> Jsont.Object.mem "created_at" Jsont.string ~enc:(fun c -> c.created_at)
  |> Jsont.Object.mem "baseline_digest" Jsont.string ~enc:(fun c ->
      c.baseline_digest)
  |> Jsont.Object.mem "baseline_dir" Jsont.string ~enc:(fun c -> c.baseline_dir)
  |> Jsont.Object.mem "instrument_digest" Jsont.string ~enc:(fun c ->
      c.instrument_digest)
  |> Jsont.Object.finish

let load_campaign tag =
  let path = campaign_json_path tag in
  if not (Sys.file_exists path) then
    Error
      (Printf.sprintf "no campaign %S (expected %s); run calibrate first" tag
         path)
  else
    match Jsont_bytesrw.decode_string campaign_jsont (read_file path) with
    | Ok campaign -> Ok campaign
    | Error message -> Error (path ^ ": " ^ message)

(* [`Frozen] iff eval/ and lab/ are byte-identical to their calibration-time
   state; [`Changed] once any instrument file differs. *)
let instrument_freeze campaign =
  if instrument_digest () = campaign.instrument_digest then `Frozen
  else `Changed

type stat3 = { median : float; min : float; max : float }

let stat3_jsont =
  Jsont.Object.map ~kind:"stat" (fun median min max -> { median; min; max })
  |> Jsont.Object.mem "median" Jsont.number ~enc:(fun s -> s.median)
  |> Jsont.Object.mem "min" Jsont.number ~enc:(fun s -> s.min)
  |> Jsont.Object.mem "max" Jsont.number ~enc:(fun s -> s.max)
  |> Jsont.Object.finish

type noise_task = {
  nt_task : string;
  nt_runs : int;
  nt_successes : int;
  nt_completed : int;
  nt_tokens : stat3 option;
  nt_duration : stat3 option;
}

let noise_task_jsont =
  Jsont.Object.map ~kind:"noise-task"
    (fun nt_task nt_runs nt_successes nt_completed nt_tokens nt_duration ->
      { nt_task; nt_runs; nt_successes; nt_completed; nt_tokens; nt_duration })
  |> Jsont.Object.mem "task" Jsont.string ~enc:(fun t -> t.nt_task)
  |> Jsont.Object.mem "runs" Jsont.int ~enc:(fun t -> t.nt_runs)
  |> Jsont.Object.mem "successes" Jsont.int ~enc:(fun t -> t.nt_successes)
  |> Jsont.Object.mem "completed" Jsont.int ~enc:(fun t -> t.nt_completed)
  |> Jsont.Object.opt_mem "tokens" stat3_jsont ~enc:(fun t -> t.nt_tokens)
  |> Jsont.Object.opt_mem "duration_s" stat3_jsont ~enc:(fun t -> t.nt_duration)
  |> Jsont.Object.finish

type noise = {
  n_suite : string;
  n_runs : int;
  n_created_at : string;
  n_mean_wall_clock_s : float;
  n_tasks : noise_task list;
}

let noise_jsont =
  Jsont.Object.map ~kind:"noise"
    (fun n_suite n_runs n_created_at n_mean_wall_clock_s n_tasks ->
      { n_suite; n_runs; n_created_at; n_mean_wall_clock_s; n_tasks })
  |> Jsont.Object.mem "suite" Jsont.string ~enc:(fun n -> n.n_suite)
  |> Jsont.Object.mem "runs" Jsont.int ~enc:(fun n -> n.n_runs)
  |> Jsont.Object.mem "created_at" Jsont.string ~enc:(fun n -> n.n_created_at)
  |> Jsont.Object.mem "mean_wall_clock_s" Jsont.number ~enc:(fun n ->
      n.n_mean_wall_clock_s)
  |> Jsont.Object.mem "tasks" (Jsont.list noise_task_jsont) ~enc:(fun n ->
      n.n_tasks)
  |> Jsont.Object.finish

type usage_sum = {
  u_input : int;
  u_output : int;
  u_cache_read : int;
  u_cache_write : int;
  u_reasoning : int;
  u_input_total : int;
  u_output_total : int;
}

let usage_sum_jsont =
  Jsont.Object.map ~kind:"usage"
    (fun
      u_input
      u_output
      u_cache_read
      u_cache_write
      u_reasoning
      u_input_total
      u_output_total
    ->
      {
        u_input;
        u_output;
        u_cache_read;
        u_cache_write;
        u_reasoning;
        u_input_total;
        u_output_total;
      })
  |> Jsont.Object.mem "input" Jsont.int ~enc:(fun u -> u.u_input)
  |> Jsont.Object.mem "output" Jsont.int ~enc:(fun u -> u.u_output)
  |> Jsont.Object.mem "cache_read" Jsont.int ~enc:(fun u -> u.u_cache_read)
  |> Jsont.Object.mem "cache_write" Jsont.int ~enc:(fun u -> u.u_cache_write)
  |> Jsont.Object.mem "reasoning" Jsont.int ~enc:(fun u -> u.u_reasoning)
  |> Jsont.Object.mem "input_total" Jsont.int ~enc:(fun u -> u.u_input_total)
  |> Jsont.Object.mem "output_total" Jsont.int ~enc:(fun u -> u.u_output_total)
  |> Jsont.Object.finish

type manifest = {
  m_name : string;
  m_commit : string;
  m_dirty : bool;
  m_digest : string;
  m_model : string option;
  m_suite : string;
  m_runs : int;
  m_aa : bool;
  m_started_at : string;
  m_finished_at : string;
  m_usage : usage_sum;
}

let manifest_jsont =
  Jsont.Object.map ~kind:"manifest"
    (fun
      m_name
      m_commit
      m_dirty
      m_digest
      m_model
      m_suite
      m_runs
      m_aa
      m_started_at
      m_finished_at
      m_usage
    ->
      {
        m_name;
        m_commit;
        m_dirty;
        m_digest;
        m_model;
        m_suite;
        m_runs;
        m_aa;
        m_started_at;
        m_finished_at;
        m_usage;
      })
  |> Jsont.Object.mem "name" Jsont.string ~enc:(fun m -> m.m_name)
  |> Jsont.Object.mem "commit" Jsont.string ~enc:(fun m -> m.m_commit)
  |> Jsont.Object.mem "dirty" Jsont.bool ~enc:(fun m -> m.m_dirty)
  |> Jsont.Object.mem "digest" Jsont.string ~enc:(fun m -> m.m_digest)
  |> Jsont.Object.opt_mem "model" Jsont.string ~enc:(fun m -> m.m_model)
  |> Jsont.Object.mem "suite" Jsont.string ~enc:(fun m -> m.m_suite)
  |> Jsont.Object.mem "runs" Jsont.int ~enc:(fun m -> m.m_runs)
  |> Jsont.Object.mem "aa" Jsont.bool ~enc:(fun m -> m.m_aa)
  |> Jsont.Object.mem "started_at" Jsont.string ~enc:(fun m -> m.m_started_at)
  |> Jsont.Object.mem "finished_at" Jsont.string ~enc:(fun m -> m.m_finished_at)
  |> Jsont.Object.mem "usage" usage_sum_jsont ~enc:(fun m -> m.m_usage)
  |> Jsont.Object.finish

type compare_task = {
  ct_task : string;
  ct_ref_runs : int;
  ct_ref_successes : int;
  ct_cand_runs : int;
  ct_cand_successes : int;
  ct_ref_tokens : float option;
  ct_cand_tokens : float option;
  ct_tokens_delta_pct : float option;
  ct_ref_duration : float option;
  ct_cand_duration : float option;
  ct_duration_delta_pct : float option;
}

let compare_task_jsont =
  Jsont.Object.map ~kind:"compare-task"
    (fun
      ct_task
      ct_ref_runs
      ct_ref_successes
      ct_cand_runs
      ct_cand_successes
      ct_ref_tokens
      ct_cand_tokens
      ct_tokens_delta_pct
      ct_ref_duration
      ct_cand_duration
      ct_duration_delta_pct
    ->
      {
        ct_task;
        ct_ref_runs;
        ct_ref_successes;
        ct_cand_runs;
        ct_cand_successes;
        ct_ref_tokens;
        ct_cand_tokens;
        ct_tokens_delta_pct;
        ct_ref_duration;
        ct_cand_duration;
        ct_duration_delta_pct;
      })
  |> Jsont.Object.mem "task" Jsont.string ~enc:(fun t -> t.ct_task)
  |> Jsont.Object.mem "ref_runs" Jsont.int ~enc:(fun t -> t.ct_ref_runs)
  |> Jsont.Object.mem "ref_successes" Jsont.int ~enc:(fun t ->
      t.ct_ref_successes)
  |> Jsont.Object.mem "cand_runs" Jsont.int ~enc:(fun t -> t.ct_cand_runs)
  |> Jsont.Object.mem "cand_successes" Jsont.int ~enc:(fun t ->
      t.ct_cand_successes)
  |> Jsont.Object.opt_mem "ref_tokens_median" Jsont.number ~enc:(fun t ->
      t.ct_ref_tokens)
  |> Jsont.Object.opt_mem "cand_tokens_median" Jsont.number ~enc:(fun t ->
      t.ct_cand_tokens)
  |> Jsont.Object.opt_mem "tokens_delta_pct" Jsont.number ~enc:(fun t ->
      t.ct_tokens_delta_pct)
  |> Jsont.Object.opt_mem "ref_duration_median" Jsont.number ~enc:(fun t ->
      t.ct_ref_duration)
  |> Jsont.Object.opt_mem "cand_duration_median" Jsont.number ~enc:(fun t ->
      t.ct_cand_duration)
  |> Jsont.Object.opt_mem "duration_delta_pct" Jsont.number ~enc:(fun t ->
      t.ct_duration_delta_pct)
  |> Jsont.Object.finish

type compare = {
  c_campaign : string;
  c_candidate : string;
  c_reference : string;
  c_threshold_pct : float;
  c_verdict : string;
  c_rule : string;
  c_primary_available : bool;
  c_primary_delta_pct : float option;
  c_sign_improved : int;
  c_sign_total : int;
  c_partial : bool;
  c_only_candidate : string list;
  c_only_reference : string list;
  c_drift_warning : bool;
  c_tasks : compare_task list;
}

let compare_jsont =
  Jsont.Object.map ~kind:"compare"
    (fun
      c_campaign
      c_candidate
      c_reference
      c_threshold_pct
      c_verdict
      c_rule
      c_primary_available
      c_primary_delta_pct
      c_sign_improved
      c_sign_total
      c_partial
      c_only_candidate
      c_only_reference
      c_drift_warning
      c_tasks
    ->
      {
        c_campaign;
        c_candidate;
        c_reference;
        c_threshold_pct;
        c_verdict;
        c_rule;
        c_primary_available;
        c_primary_delta_pct;
        c_sign_improved;
        c_sign_total;
        c_partial;
        c_only_candidate;
        c_only_reference;
        c_drift_warning;
        c_tasks;
      })
  |> Jsont.Object.mem "campaign" Jsont.string ~enc:(fun c -> c.c_campaign)
  |> Jsont.Object.mem "candidate" Jsont.string ~enc:(fun c -> c.c_candidate)
  |> Jsont.Object.mem "reference" Jsont.string ~enc:(fun c -> c.c_reference)
  |> Jsont.Object.mem "threshold_pct" Jsont.number ~enc:(fun c ->
      c.c_threshold_pct)
  |> Jsont.Object.mem "verdict" Jsont.string ~enc:(fun c -> c.c_verdict)
  |> Jsont.Object.mem "rule" Jsont.string ~enc:(fun c -> c.c_rule)
  |> Jsont.Object.mem "primary_metric_available" Jsont.bool ~enc:(fun c ->
      c.c_primary_available)
  |> Jsont.Object.opt_mem "primary_delta_pct" Jsont.number ~enc:(fun c ->
      c.c_primary_delta_pct)
  |> Jsont.Object.mem "sign_improved" Jsont.int ~enc:(fun c ->
      c.c_sign_improved)
  |> Jsont.Object.mem "sign_total" Jsont.int ~enc:(fun c -> c.c_sign_total)
  |> Jsont.Object.mem "partial" Jsont.bool ~enc:(fun c -> c.c_partial)
  |> Jsont.Object.mem "only_candidate" (Jsont.list Jsont.string) ~enc:(fun c ->
      c.c_only_candidate)
  |> Jsont.Object.mem "only_reference" (Jsont.list Jsont.string) ~enc:(fun c ->
      c.c_only_reference)
  |> Jsont.Object.mem "drift_warning" Jsont.bool ~enc:(fun c ->
      c.c_drift_warning)
  |> Jsont.Object.mem "tasks" (Jsont.list compare_task_jsont) ~enc:(fun c ->
      c.c_tasks)
  |> Jsont.Object.finish

type ledger_row = {
  l_ts : string;
  l_name : string;
  l_hypothesis : string option;
  l_tier : string option;
  l_treatment : string option;
  l_primary_metric : string option;
  l_expected : string option;
  l_verdict : string;
  l_reason : string option;
  l_evidence : string;
  l_commit : string option;
}

let ledger_row_jsont =
  Jsont.Object.map ~kind:"ledger-row"
    (fun
      l_ts
      l_name
      l_hypothesis
      l_tier
      l_treatment
      l_primary_metric
      l_expected
      l_verdict
      l_reason
      l_evidence
      l_commit
    ->
      {
        l_ts;
        l_name;
        l_hypothesis;
        l_tier;
        l_treatment;
        l_primary_metric;
        l_expected;
        l_verdict;
        l_reason;
        l_evidence;
        l_commit;
      })
  |> Jsont.Object.mem "ts" Jsont.string ~enc:(fun r -> r.l_ts)
  |> Jsont.Object.mem "name" Jsont.string ~enc:(fun r -> r.l_name)
  |> Jsont.Object.opt_mem "hypothesis" Jsont.string ~enc:(fun r ->
      r.l_hypothesis)
  |> Jsont.Object.opt_mem "tier" Jsont.string ~enc:(fun r -> r.l_tier)
  |> Jsont.Object.opt_mem "treatment" Jsont.string ~enc:(fun r -> r.l_treatment)
  |> Jsont.Object.opt_mem "primary_metric" Jsont.string ~enc:(fun r ->
      r.l_primary_metric)
  |> Jsont.Object.opt_mem "expected" Jsont.string ~enc:(fun r -> r.l_expected)
  |> Jsont.Object.mem "verdict" Jsont.string ~enc:(fun r -> r.l_verdict)
  |> Jsont.Object.opt_mem "reason" Jsont.string ~enc:(fun r -> r.l_reason)
  |> Jsont.Object.mem "evidence" Jsont.string ~enc:(fun r -> r.l_evidence)
  |> Jsont.Object.opt_mem "commit" Jsont.string ~enc:(fun r -> r.l_commit)
  |> Jsont.Object.finish

(* Reading eval rows *)

let read_rows dir =
  let path = rows_file dir in
  match open_in path with
  | exception exn -> Error (path ^ ": " ^ Printexc.to_string exn)
  | input ->
      let rec loop line_no acc =
        match input_line input with
        | exception End_of_file ->
            close_in input;
            Ok (List.rev acc)
        | line when String.trim line = "" -> loop (line_no + 1) acc
        | line -> (
            match Jsont_bytesrw.decode_string Eval.Result.jsont line with
            | Ok row -> loop (line_no + 1) (row :: acc)
            | Error message ->
                close_in_noerr input;
                Error (Printf.sprintf "%s:%d: %s" path line_no message))
      in
      loop 1 []

let row_task row = (Eval.Result.series row).Eval.Result.task
let row_success row = (Eval.Result.score row).Eval.Result.success
let row_duration row = (Eval.Result.metrics_of row).Eval.Result.duration_s

let row_completed row =
  match Eval.Result.status row with Eval.Result.Completed -> true | _ -> false

(* Total tokens for a completed run, or [None] when the adapter reported no
   usage (the cmd/noop adapters, or any run that did not complete). *)
let row_tokens row =
  if not (row_completed row) then None
  else
    match (Eval.Result.metrics_of row).Eval.Result.usage with
    | None -> None
    | Some usage ->
        Some (Eval.Usage.input_total usage + Eval.Usage.output_total usage)

(* Statistics *)

let median values =
  let sorted = List.sort Float.compare values in
  let arr = Array.of_list sorted in
  let n = Array.length arr in
  if n = 0 then invalid_arg "mentat-lab: median of empty list"
  else if n mod 2 = 1 then arr.(n / 2)
  else (arr.((n / 2) - 1) +. arr.(n / 2)) /. 2.

let stat3_of values =
  match values with
  | [] -> None
  | first :: _ ->
      let lo = List.fold_left Float.min first values in
      let hi = List.fold_left Float.max first values in
      Some { median = median values; min = lo; max = hi }

let mean values =
  match values with
  | [] -> 0.
  | _ -> List.fold_left ( +. ) 0. values /. float_of_int (List.length values)

(* Group rows by task id, preserving first-seen (corpus) order. *)
let group_by_task rows =
  let order = ref [] in
  let table = Hashtbl.create 32 in
  List.iter
    (fun row ->
      let task = row_task row in
      if not (Hashtbl.mem table task) then order := task :: !order;
      Hashtbl.replace table task
        (row :: (try Hashtbl.find table task with Not_found -> [])))
    rows;
  List.rev_map (fun task -> (task, List.rev (Hashtbl.find table task))) !order

(* Build gate. Never run an eval against a stale binary. *)

let build_gate () =
  stderr_printf "mentat-lab: building bin/mentat/main.exe eval/bin/main.exe\n";
  let status = run_streaming [| "dune"; "build"; "bin/mentat/main.exe"; eval_bin |] in
  process_success status

let binary_digest () = Digest.to_hex (Digest.file mentat_bin)

let run_eval ~suite ~runs ~model ~agent ~output =
  let args =
    [ eval_bin; "run"; "--suite"; suite; "--runs"; string_of_int runs ]
    @ (match model with None -> [] | Some model -> [ "--model"; model ])
    @ (match agent with None -> [] | Some agent -> [ "--agent"; agent ])
    @ [ "--output"; output ]
  in
  run_streaming (Array.of_list args)

(* [analyze] is diagnostic and is being added to mentat-eval concurrently:
   invoke it tolerantly so a missing or failing analysis never derails a
   measurement. *)
let run_analyze dir =
  match run_streaming [| eval_bin; "analyze"; dir |] with
  | status when process_success status -> ()
  | status ->
      stderr_printf
        "mentat-lab: warning: mentat-eval analyze failed (%s); continuing \
         without trace analysis\n"
        (status_message status)
  | exception exn ->
      stderr_printf
        "mentat-lab: warning: could not run mentat-eval analyze (%s); continuing\n"
        (Printexc.to_string exn)

(* Ledger *)

let md_cell text =
  String.to_seq text
  |> Seq.map (function '\n' | '\r' -> ' ' | c -> c)
  |> String.of_seq
  |> fun s -> String.concat "\\|" (String.split_on_char '|' s)

let ledger_verdict_cell row =
  match row.l_reason with
  | None -> row.l_verdict
  | Some reason -> Printf.sprintf "%s (%s)" row.l_verdict reason

let short_commit = function
  | None -> "-"
  | Some commit ->
      if String.length commit > 12 then String.sub commit 0 12 else commit

let read_ledger_rows tag =
  let path = ledger_jsonl_path tag in
  if not (Sys.file_exists path) then Ok []
  else
    match open_in path with
    | exception exn -> Error (path ^ ": " ^ Printexc.to_string exn)
    | input ->
        let rec loop acc =
          match input_line input with
          | exception End_of_file ->
              close_in input;
              Ok (List.rev acc)
          | line when String.trim line = "" -> loop acc
          | line -> (
              match Jsont_bytesrw.decode_string ledger_row_jsont line with
              | Ok row -> loop (row :: acc)
              | Error message ->
                  close_in_noerr input;
                  Error (path ^ ": " ^ message))
        in
        loop []

let ledger_md_of_rows tag rows =
  let buffer = Buffer.create 1024 in
  Buffer.add_string buffer (Printf.sprintf "# Ledger — campaign %s\n\n" tag);
  Buffer.add_string buffer
    "| Timestamp | Name | Verdict | Tier | Hypothesis | Primary metric | \
     Evidence | Commit |\n";
  Buffer.add_string buffer "| --- | --- | --- | --- | --- | --- | --- | --- |\n";
  (* newest first *)
  List.iter
    (fun row ->
      Buffer.add_string buffer
        (Printf.sprintf "| %s | %s | %s | %s | %s | %s | %s | %s |\n"
           (md_cell row.l_ts) (md_cell row.l_name)
           (md_cell (ledger_verdict_cell row))
           (md_cell (Option.value row.l_tier ~default:"-"))
           (md_cell (Option.value row.l_hypothesis ~default:"-"))
           (md_cell (Option.value row.l_primary_metric ~default:"-"))
           (md_cell row.l_evidence)
           (md_cell (short_commit row.l_commit))))
    (List.rev rows);
  Buffer.contents buffer

let regenerate_ledger_md tag =
  match read_ledger_rows tag with
  | Error message ->
      stderr_printf "mentat-lab: warning: could not render ledger.md: %s\n"
        message
  | Ok rows -> write_file (ledger_md_path tag) (ledger_md_of_rows tag rows)

let append_ledger_row tag row =
  append_line (ledger_jsonl_path tag)
    (encode_json ~format:Jsont.Minify ledger_row_jsont row);
  regenerate_ledger_md tag

(* calibrate *)

let calibrate_command =
  let campaign =
    CArg.(
      required
      & opt (some string) None
      & info [ "campaign" ] ~docv:"TAG" ~doc:"Campaign tag (directory name).")
  in
  let suite =
    CArg.(
      value & opt string "smoke"
      & info [ "suite" ] ~docv:"SUITE"
          ~doc:"Eval corpus suite (all, smoke, core, long, robustness).")
  in
  let runs =
    CArg.(
      value & opt int 3
      & info [ "runs" ] ~docv:"N" ~doc:"Baseline replicates per task.")
  in
  let model =
    CArg.(
      value
      & opt (some string) None
      & info [ "model" ] ~docv:"MODEL" ~doc:"Model identifier (provider/model).")
  in
  let agent =
    CArg.(
      value
      & opt (some string) None
      & info [ "agent" ] ~docv:"AGENT"
          ~doc:"Agent adapter passed to mentat-eval (defaults to mentat).")
  in
  let run campaign suite runs model agent =
    ensure_repo_root ();
    ensure_dir (campaign_dir campaign);
    if not (build_gate ()) then (
      stderr_printf "mentat-lab: build gate failed; not calibrating\n";
      1)
    else
      let start_ref =
        match git_head_commit () with Some rev -> rev | None -> "unknown"
      in
      let digest = binary_digest () in
      let results_dir =
        Filename.concat (calibration_dir campaign) (dir_timestamp ())
      in
      let campaign_record =
        {
          tag = campaign;
          start_ref;
          model;
          suite;
          created_at = now_string ();
          baseline_digest = digest;
          baseline_dir = results_dir;
          instrument_digest = instrument_digest ();
        }
      in
      write_json (campaign_json_path campaign) campaign_jsont campaign_record;
      stdout_printf "mentat-lab: campaign %s at %s\n" campaign
        (campaign_dir campaign);
      stdout_printf "  start ref: %s\n  baseline digest: %s\n" start_ref digest;
      let status = run_eval ~suite ~runs ~model ~agent ~output:results_dir in
      if not (process_success status) then (
        stderr_printf "mentat-lab: eval run failed (%s)\n"
          (status_message status);
        1)
      else (
        run_analyze results_dir;
        match read_rows results_dir with
        | Error message ->
            stderr_printf "mentat-lab: %s\n" message;
            1
        | Ok rows ->
            let tasks =
              group_by_task rows
              |> List.map (fun (task, task_rows) ->
                  let completed = List.filter row_completed task_rows in
                  let token_values =
                    List.filter_map row_tokens completed
                    |> List.map float_of_int
                  in
                  let duration_values = List.map row_duration completed in
                  {
                    nt_task = task;
                    nt_runs = List.length task_rows;
                    nt_successes =
                      List.length (List.filter row_success task_rows);
                    nt_completed = List.length completed;
                    nt_tokens = stat3_of token_values;
                    nt_duration = stat3_of duration_values;
                  })
            in
            let mean_wall_clock = mean (List.map row_duration rows) in
            let noise_record =
              {
                n_suite = suite;
                n_runs = runs;
                n_created_at = now_string ();
                n_mean_wall_clock_s = mean_wall_clock;
                n_tasks = tasks;
              }
            in
            write_json
              (Filename.concat (calibration_dir campaign) "noise.json")
              noise_jsont noise_record;
            stdout_printf "\nCalibration noise (suite %s, %d runs/task)\n" suite
              runs;
            let show_stat = function
              | None -> "n/a"
              | Some { median; min; max } ->
                  Printf.sprintf "%.0f (%.0f..%.0f)" median min max
            in
            let show_dur = function
              | None -> "n/a"
              | Some { median; min; max } ->
                  Printf.sprintf "%.1fs (%.1f..%.1f)" median min max
            in
            List.iter
              (fun t ->
                stdout_printf "  %-24s runs=%d ok=%d  tokens=%s  duration=%s\n"
                  t.nt_task t.nt_runs t.nt_successes (show_stat t.nt_tokens)
                  (show_dur t.nt_duration))
              tasks;
            stdout_printf "\nPer-run mean wall-clock: %.1fs\n" mean_wall_clock;
            stdout_printf "noise: %s\n"
              (Filename.concat (calibration_dir campaign) "noise.json");
            0)
  in
  CCmd.v
    (CCmd.info "calibrate" ~doc:"Calibrate a campaign baseline." ~exits)
    CTerm.(const run $ campaign $ suite $ runs $ model $ agent)

(* experiment run *)

let usage_sum_of_rows rows =
  let add sum row =
    match (Eval.Result.metrics_of row).Eval.Result.usage with
    | None -> sum
    | Some u ->
        {
          u_input = sum.u_input + u.Eval.Usage.input;
          u_output = sum.u_output + u.Eval.Usage.output;
          u_cache_read = sum.u_cache_read + u.Eval.Usage.cache_read;
          u_cache_write = sum.u_cache_write + u.Eval.Usage.cache_write;
          u_reasoning = sum.u_reasoning + u.Eval.Usage.reasoning;
          u_input_total = sum.u_input_total + Eval.Usage.input_total u;
          u_output_total = sum.u_output_total + Eval.Usage.output_total u;
        }
  in
  List.fold_left add
    {
      u_input = 0;
      u_output = 0;
      u_cache_read = 0;
      u_cache_write = 0;
      u_reasoning = 0;
      u_input_total = 0;
      u_output_total = 0;
    }
    rows

let experiment_run_command =
  let campaign =
    CArg.(
      required
      & opt (some string) None
      & info [ "campaign" ] ~docv:"TAG" ~doc:"Campaign tag.")
  in
  let name =
    CArg.(
      required
      & opt (some string) None
      & info [ "name" ] ~docv:"NAME" ~doc:"Experiment name.")
  in
  let suite =
    CArg.(
      value & opt string "smoke"
      & info [ "suite" ] ~docv:"SUITE" ~doc:"Eval corpus suite.")
  in
  let runs =
    CArg.(value & opt int 3 & info [ "runs" ] ~docv:"N" ~doc:"Runs per task.")
  in
  let model =
    CArg.(
      value
      & opt (some string) None
      & info [ "model" ] ~docv:"MODEL" ~doc:"Model identifier.")
  in
  let agent =
    CArg.(
      value
      & opt (some string) None
      & info [ "agent" ] ~docv:"AGENT" ~doc:"Agent adapter for mentat-eval.")
  in
  let aa =
    CArg.(
      value & flag
      & info [ "aa" ]
          ~doc:
            "Baseline-vs-baseline canary: skip the identical-binary refusal \
             and record the arm as an A/A run.")
  in
  let allow_identical =
    CArg.(
      value & flag
      & info
          [ "allow-identical-binary" ]
          ~doc:"Proceed even if the binary digest equals the baseline.")
  in
  let run campaign name suite runs model agent aa allow_identical =
    ensure_repo_root ();
    match load_campaign campaign with
    | Error message ->
        stderr_printf "mentat-lab: %s\n" message;
        1
    | Ok campaign_record -> (
        let evidence = exp_dir campaign name in
        let crash_ledger reason =
          append_ledger_row campaign
            {
              l_ts = now_string ();
              l_name = name;
              l_hypothesis = None;
              l_tier = None;
              l_treatment = None;
              l_primary_metric = None;
              l_expected = None;
              l_verdict = "crash";
              l_reason = Some reason;
              l_evidence = evidence;
              l_commit = git_head_commit ();
            }
        in
        match instrument_freeze campaign_record with
        | `Changed ->
            stderr_printf
              "mentat-lab: instrument (eval/ lab/) changed since campaign \
               start (%s); refusing. Reset the instrument or start a new \
               campaign.\n"
              campaign_record.start_ref;
            1
        | `Frozen ->
            if not (build_gate ()) then (
              stderr_printf
                "mentat-lab: build gate failed; recording crash and aborting \
                 (never measure a stale binary)\n";
              crash_ledger "build failure";
              1)
            else
              let digest = binary_digest () in
              if
                (not aa) && (not allow_identical)
                && digest = campaign_record.baseline_digest
              then (
                stderr_printf
                  "mentat-lab: binary digest %s equals the baseline; the \
                   treatment did not change the subject. Pass --aa for a \
                   canary or --allow-identical-binary to override.\n"
                  digest;
                1)
              else
                let results_dir = exp_results_dir campaign name in
                let started_at = now_string () in
                let status =
                  run_eval ~suite ~runs ~model ~agent ~output:results_dir
                in
                if not (process_success status) then (
                  stderr_printf "mentat-lab: eval run failed (%s)\n"
                    (status_message status);
                  1)
                else (
                  run_analyze results_dir;
                  match read_rows results_dir with
                  | Error message ->
                      stderr_printf "mentat-lab: %s\n" message;
                      1
                  | Ok rows ->
                      let manifest =
                        {
                          m_name = name;
                          m_commit =
                            (match git_head_commit () with
                            | Some rev -> rev
                            | None -> "unknown");
                          m_dirty = git_dirty ();
                          m_digest = digest;
                          m_model = model;
                          m_suite = suite;
                          m_runs = runs;
                          m_aa = aa;
                          m_started_at = started_at;
                          m_finished_at = now_string ();
                          m_usage = usage_sum_of_rows rows;
                        }
                      in
                      write_json
                        (Filename.concat evidence "manifest.json")
                        manifest_jsont manifest;
                      stdout_printf "mentat-lab: experiment %s -> %s\n" name
                        evidence;
                      stdout_printf "  digest=%s aa=%b tokens(in/out)=%d/%d\n"
                        digest aa manifest.m_usage.u_input_total
                        manifest.m_usage.u_output_total;
                      0))
  in
  CCmd.v
    (CCmd.info "run" ~doc:"Run one experiment arm." ~exits)
    CTerm.(
      const run $ campaign $ name $ suite $ runs $ model $ agent $ aa
      $ allow_identical)

(* experiment compare *)

type verdict = Candidate | Discard | Partial

let verdict_string = function
  | Candidate -> "candidate"
  | Discard -> "discard"
  | Partial -> "partial"

let verdict_exit = function Candidate -> 0 | Discard -> 1 | Partial -> 2

let compute_compare ~campaign ~candidate_label ~reference_label ~threshold
    ~cand_rows ~ref_rows ~drift_warning =
  let cand_by_task = group_by_task cand_rows in
  let ref_by_task = group_by_task ref_rows in
  let cand_tasks = List.map fst cand_by_task in
  let ref_tasks = List.map fst ref_by_task in
  let intersection =
    List.filter (fun task -> List.mem task ref_tasks) cand_tasks
  in
  let only_candidate =
    List.filter (fun task -> not (List.mem task ref_tasks)) cand_tasks
  in
  let only_reference =
    List.filter (fun task -> not (List.mem task cand_tasks)) ref_tasks
  in
  let subset =
    List.length intersection < List.length cand_tasks
    || List.length intersection < List.length ref_tasks
  in
  (* The per-task, per-arm estimand: the median over all of a task's runs.
     A completed run contributes its observed value; a non-completed (or
     usage-less) run is imputed at the worst value observed for the task
     across both arms. When no run on either arm has an observed value the
     metric is unavailable ([None]). *)
  let observed_values extract runs =
    List.filter_map
      (fun row -> if row_completed row then extract row else None)
      runs
  in
  let median_with_imputation extract cand_runs ref_runs =
    let pooled =
      observed_values extract cand_runs @ observed_values extract ref_runs
    in
    match pooled with
    | [] -> (None, None)
    | first :: _ ->
        let worst = List.fold_left Float.max first pooled in
        let arm_median runs =
          match runs with
          | [] -> None
          | _ ->
              let values =
                List.map
                  (fun row ->
                    if row_completed row then
                      match extract row with Some v -> v | None -> worst
                    else worst)
                  runs
              in
              Some (median values)
        in
        (arm_median ref_runs, arm_median cand_runs)
  in
  let token_extract row = Option.map float_of_int (row_tokens row) in
  let duration_extract row =
    if row_completed row then Some (row_duration row) else None
  in
  let delta_pct ref_v cand_v =
    match (ref_v, cand_v) with
    | Some r, Some c when r > 0. -> Some ((r -. c) /. r *. 100.)
    | _ -> None
  in
  let tasks =
    List.map
      (fun task ->
        let cand_runs = List.assoc task cand_by_task in
        let ref_runs = List.assoc task ref_by_task in
        let ref_tokens, cand_tokens =
          median_with_imputation token_extract cand_runs ref_runs
        in
        let ref_duration, cand_duration =
          median_with_imputation duration_extract cand_runs ref_runs
        in
        {
          ct_task = task;
          ct_ref_runs = List.length ref_runs;
          ct_ref_successes = List.length (List.filter row_success ref_runs);
          ct_cand_runs = List.length cand_runs;
          ct_cand_successes = List.length (List.filter row_success cand_runs);
          ct_ref_tokens = ref_tokens;
          ct_cand_tokens = cand_tokens;
          ct_tokens_delta_pct = delta_pct ref_tokens cand_tokens;
          ct_ref_duration = ref_duration;
          ct_cand_duration = cand_duration;
          ct_duration_delta_pct = delta_pct ref_duration cand_duration;
        })
      intersection
  in
  let token_deltas = List.filter_map (fun t -> t.ct_tokens_delta_pct) tasks in
  let primary_available = token_deltas <> [] in
  let primary_delta =
    if primary_available then Some (median token_deltas) else None
  in
  let sign_total = List.length token_deltas in
  let sign_improved =
    List.length (List.filter (fun d -> d > 0.) token_deltas)
  in
  let tripwire =
    List.filter
      (fun t ->
        t.ct_ref_runs > 0
        && t.ct_ref_successes = t.ct_ref_runs
        && t.ct_cand_runs > 0 && t.ct_cand_successes = 0)
      tasks
  in
  let success_drops =
    List.filter (fun t -> t.ct_cand_successes < t.ct_ref_successes) tasks
  in
  let base_verdict, rule =
    if tripwire <> [] then
      ( Discard,
        Printf.sprintf
          "tripwire: %s all-pass in reference and all-fail in candidate"
          (String.concat ", " (List.map (fun t -> t.ct_task) tripwire)) )
    else if List.length success_drops >= 2 then
      ( Discard,
        Printf.sprintf "success regressed on %d tasks"
          (List.length success_drops) )
    else
      match primary_delta with
      | Some delta when delta >= threshold ->
          ( Candidate,
            Printf.sprintf "primary metric improved %.1f%% >= %.1f%% threshold"
              delta threshold )
      | Some delta ->
          ( Discard,
            Printf.sprintf "primary metric improved %.1f%% < %.1f%% threshold"
              delta threshold )
      | None ->
          ( Discard,
            "primary metric unavailable (no token usage on either arm); \
             success-only comparison shows no regression and no improvement" )
  in
  let verdict =
    if subset && base_verdict = Candidate then Partial else base_verdict
  in
  let rule =
    if subset && base_verdict = Candidate then
      rule ^ "; downgraded to partial (task set is a proper subset)"
    else rule
  in
  {
    c_campaign = campaign;
    c_candidate = candidate_label;
    c_reference = reference_label;
    c_threshold_pct = threshold;
    c_verdict = verdict_string verdict;
    c_rule = rule;
    c_primary_available = primary_available;
    c_primary_delta_pct = primary_delta;
    c_sign_improved = sign_improved;
    c_sign_total = sign_total;
    c_partial = subset;
    c_only_candidate = only_candidate;
    c_only_reference = only_reference;
    c_drift_warning = drift_warning;
    c_tasks = tasks;
  }

let opt_num = function None -> "n/a" | Some v -> Printf.sprintf "%.0f" v
let opt_dur = function None -> "n/a" | Some v -> Printf.sprintf "%.1f" v
let opt_pct = function None -> "n/a" | Some v -> Printf.sprintf "%+.1f%%" v

let compare_markdown compare =
  let buffer = Buffer.create 2048 in
  Buffer.add_string buffer
    (Printf.sprintf "# Compare — %s vs %s\n\n" compare.c_candidate
       compare.c_reference);
  Buffer.add_string buffer
    (Printf.sprintf "- Campaign: %s\n- Threshold: %.1f%%\n" compare.c_campaign
       compare.c_threshold_pct);
  if compare.c_drift_warning then
    Buffer.add_string buffer
      "- **Drift warning:** reference rows are older than 24h; refresh the \
       baseline before trusting this delta.\n";
  Buffer.add_string buffer "\n## Per-task\n\n";
  Buffer.add_string buffer
    "| Task | Ref runs | Ref ok | Cand runs | Cand ok | Ref tokens | Cand \
     tokens | Δ tokens | Ref dur | Cand dur | Δ dur |\n";
  Buffer.add_string buffer
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | \
     ---: |\n";
  List.iter
    (fun t ->
      Buffer.add_string buffer
        (Printf.sprintf
           "| %s | %d | %d | %d | %d | %s | %s | %s | %s | %s | %s |\n"
           (md_cell t.ct_task) t.ct_ref_runs t.ct_ref_successes t.ct_cand_runs
           t.ct_cand_successes (opt_num t.ct_ref_tokens)
           (opt_num t.ct_cand_tokens)
           (opt_pct t.ct_tokens_delta_pct)
           (opt_dur t.ct_ref_duration)
           (opt_dur t.ct_cand_duration)
           (opt_pct t.ct_duration_delta_pct)))
    compare.c_tasks;
  (match compare.c_only_candidate with
  | [] -> ()
  | tasks ->
      Buffer.add_string buffer
        (Printf.sprintf "\nTasks only in candidate: %s\n"
           (String.concat ", " tasks)));
  (match compare.c_only_reference with
  | [] -> ()
  | tasks ->
      Buffer.add_string buffer
        (Printf.sprintf "\nTasks only in reference: %s\n"
           (String.concat ", " tasks)));
  Buffer.add_string buffer "\n## Verdict\n\n";
  Buffer.add_string buffer
    (Printf.sprintf "- Primary metric (median of per-task token deltas): %s\n"
       (if compare.c_primary_available then
          Printf.sprintf "%+.1f%%"
            (Option.value compare.c_primary_delta_pct ~default:0.)
        else "unavailable (no token usage recorded)"));
  Buffer.add_string buffer
    (Printf.sprintf "- Sign test: improved in %d of %d tasks\n"
       compare.c_sign_improved compare.c_sign_total);
  Buffer.add_string buffer
    (Printf.sprintf "- **Verdict: %s** (%s)\n" compare.c_verdict compare.c_rule);
  Buffer.contents buffer

let experiment_compare_command =
  let campaign =
    CArg.(
      required
      & opt (some string) None
      & info [ "campaign" ] ~docv:"TAG" ~doc:"Campaign tag.")
  in
  let name =
    CArg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"NAME" ~doc:"Experiment to evaluate.")
  in
  let against =
    CArg.(
      value
      & opt (some string) None
      & info [ "against" ] ~docv:"NAME2"
          ~doc:"Reference experiment (defaults to the campaign calibration).")
  in
  let threshold =
    CArg.(
      value & opt CArg.float 10.
      & info [ "threshold" ] ~docv:"PCT"
          ~doc:"Primary-metric improvement required for a candidate verdict.")
  in
  let run campaign name against threshold =
    ensure_repo_root ();
    match load_campaign campaign with
    | Error message ->
        stderr_printf "mentat-lab: %s\n" message;
        2
    | Ok campaign_record -> (
        let cand_dir = exp_results_dir campaign name in
        let reference_dir, reference_label =
          match against with
          | Some other -> (exp_results_dir campaign other, other)
          | None -> (campaign_record.baseline_dir, "calibration")
        in
        match (read_rows cand_dir, read_rows reference_dir) with
        | Error message, _ | _, Error message ->
            stderr_printf "mentat-lab: %s\n" message;
            2
        | Ok cand_rows, Ok ref_rows ->
            let drift_warning =
              match Unix.stat (rows_file reference_dir) with
              | { Unix.st_mtime; _ } -> Unix.time () -. st_mtime > 24. *. 3600.
              | exception _ -> false
            in
            List.iter
              (fun task ->
                stderr_printf
                  "mentat-lab: task %s present only in candidate (unpaired)\n"
                  task)
              (List.filter
                 (fun task -> not (List.mem task (List.map row_task ref_rows)))
                 (List.sort_uniq String.compare (List.map row_task cand_rows)));
            List.iter
              (fun task ->
                stderr_printf
                  "mentat-lab: task %s present only in reference (unpaired)\n"
                  task)
              (List.filter
                 (fun task -> not (List.mem task (List.map row_task cand_rows)))
                 (List.sort_uniq String.compare (List.map row_task ref_rows)));
            if drift_warning then
              stderr_printf
                "mentat-lab: warning: reference rows are older than 24h \
                 (provider drift can manufacture candidates)\n";
            let compare =
              compute_compare ~campaign ~candidate_label:name ~reference_label
                ~threshold ~cand_rows ~ref_rows ~drift_warning
            in
            write_json
              (Filename.concat (exp_dir campaign name) "compare.json")
              compare_jsont compare;
            write_file
              (Filename.concat (exp_dir campaign name) "compare.md")
              (compare_markdown compare);
            stdout_printf "%s" (compare_markdown compare);
            let verdict =
              match compare.c_verdict with
              | "candidate" -> Candidate
              | "partial" -> Partial
              | _ -> Discard
            in
            verdict_exit verdict)
  in
  CCmd.v
    (CCmd.info "compare" ~doc:"Compare an experiment against a reference arm."
       ~exits)
    CTerm.(const run $ campaign $ name $ against $ threshold)

(* ledger *)

let ledger_add_command =
  let campaign =
    CArg.(
      required
      & opt (some string) None
      & info [ "campaign" ] ~docv:"TAG" ~doc:"Campaign tag.")
  in
  let name =
    CArg.(
      required
      & opt (some string) None
      & info [ "name" ] ~docv:"NAME" ~doc:"Experiment name (evidence path).")
  in
  let verdict =
    CArg.(
      required
      & opt (some string) None
      & info [ "verdict" ] ~docv:"V"
          ~doc:"Verdict: keep, discard, candidate, crash, or infra.")
  in
  let hypothesis =
    CArg.(
      required
      & opt (some string) None
      & info [ "hypothesis" ] ~docv:"H" ~doc:"Hypothesis under test.")
  in
  let tier =
    CArg.(
      required
      & opt (some string) None
      & info [ "tier" ] ~docv:"T" ~doc:"Treatment tier (T1, T2, T3).")
  in
  let primary_metric =
    CArg.(
      required
      & opt (some string) None
      & info [ "primary-metric" ] ~docv:"M"
          ~doc:"Pre-registered primary metric.")
  in
  let treatment =
    CArg.(
      value
      & opt (some string) None
      & info [ "treatment" ] ~docv:"TEXT" ~doc:"Description of the treatment.")
  in
  let expected =
    CArg.(
      value
      & opt (some string) None
      & info [ "expected" ] ~docv:"TEXT" ~doc:"Expected effect size/direction.")
  in
  let run campaign name verdict hypothesis tier primary_metric treatment
      expected =
    ensure_repo_root ();
    if not (Sys.file_exists (campaign_dir campaign)) then (
      stderr_printf "mentat-lab: no campaign %S; run calibrate first\n" campaign;
      1)
    else (
      append_ledger_row campaign
        {
          l_ts = now_string ();
          l_name = name;
          l_hypothesis = Some hypothesis;
          l_tier = Some tier;
          l_treatment = treatment;
          l_primary_metric = Some primary_metric;
          l_expected = expected;
          l_verdict = verdict;
          l_reason = None;
          l_evidence = exp_dir campaign name;
          l_commit = git_head_commit ();
        };
      stdout_printf "mentat-lab: ledger row appended (%s / %s)\n" verdict name;
      0)
  in
  CCmd.v
    (CCmd.info "add" ~doc:"Append a ledger row and re-render ledger.md." ~exits)
    CTerm.(
      const run $ campaign $ name $ verdict $ hypothesis $ tier $ primary_metric
      $ treatment $ expected)

let ledger_list_command =
  let campaign =
    CArg.(
      required
      & opt (some string) None
      & info [ "campaign" ] ~docv:"TAG" ~doc:"Campaign tag.")
  in
  let run campaign =
    ensure_repo_root ();
    match read_ledger_rows campaign with
    | Error message ->
        stderr_printf "mentat-lab: %s\n" message;
        1
    | Ok rows ->
        stdout_printf "%s" (ledger_md_of_rows campaign rows);
        0
  in
  CCmd.v
    (CCmd.info "list" ~doc:"Print the campaign ledger." ~exits)
    CTerm.(const run $ campaign)

(* Command groups *)

let experiment_group =
  CCmd.group
    (CCmd.info "experiment" ~doc:"Run and compare experiment arms." ~exits)
    [ experiment_run_command; experiment_compare_command ]

let ledger_group =
  CCmd.group
    (CCmd.info "ledger" ~doc:"Append to and render the campaign ledger." ~exits)
    [ ledger_add_command; ledger_list_command ]

let command =
  let man =
    [
      `S CManpage.s_description;
      `P
        "mentat-lab orchestrates the mentat research loop on top of \
         mentat-eval: it calibrates a campaign baseline, runs experiment arms \
         behind a freeze check and a build gate, compares them under a \
         pre-registered estimand, and keeps an append-only ledger. It shells \
         out to mentat-eval and never touches the instrument during a \
         campaign.";
      `P "Run it from the repository root; campaign state lives under _lab/.";
    ]
  in
  CCmd.group
    (CCmd.info "mentat-lab" ~version:"dev"
       ~doc:"Autoresearch harness for mentat." ~man ~exits)
    [ calibrate_command; experiment_group; ledger_group ]

let () = exit (CCmd.eval' command)
