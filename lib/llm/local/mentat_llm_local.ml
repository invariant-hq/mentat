(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Mentat_llm
module Chat_completions = Mentat_llm_http.Chat_completions
module Modelfit = Modelfit

let log_src = Logs.Src.create "mentat.llm.local" ~doc:"Managed local provider"

module Log = (val Logs.src_log log_src : Logs.LOG)

let ( let* ) = Result.bind
let provider = Llm.Provider.make "local"
let api = Chat_completions.api
let model id = Llm.Model.make ~provider ~api ~id
let invalid fn message = invalid_arg ("Mentat_llm_local." ^ fn ^ ": " ^ message)

let check_path fn name = function
  | None -> ()
  | Some value ->
      if String.is_empty value then invalid fn (name ^ " must not be empty")

let check_positive fn name value =
  if value <= 0 then invalid fn (name ^ " must be positive")

module Config = struct
  type t = {
    model_dir : string option;
    server_binary : string option;
    ctx_size : int;
    startup_timeout_s : float;
    memory_budget : int option;
  }

  let env_memory_budget () =
    match Sys.getenv_opt "MENTAT_LOCAL_MEMORY_BUDGET" with
    | None -> None
    | Some value -> (
        match int_of_string_opt (String.trim value) with
        | Some bytes when bytes > 0 -> Some bytes
        | Some _ | None -> None)

  let env_server_binary () =
    match Sys.getenv_opt "MENTAT_LOCAL_SERVER_BINARY" with
    | None -> None
    | Some value -> (
        match String.trim value with "" -> None | binary -> Some binary)

  let make ?model_dir ?server_binary ?(ctx_size = 32768)
      ?(startup_timeout_s = 300.) ?memory_budget () =
    check_path "Config.make" "model_dir" model_dir;
    check_path "Config.make" "server_binary" server_binary;
    check_positive "Config.make" "ctx_size" ctx_size;
    if (not (Float.is_finite startup_timeout_s)) || startup_timeout_s <= 0. then
      invalid "Config.make" "startup_timeout_s must be positive and finite";
    Option.iter (check_positive "Config.make" "memory_budget") memory_budget;
    let memory_budget =
      match memory_budget with
      | Some _ as budget -> budget
      | None -> env_memory_budget ()
    in
    let server_binary =
      match server_binary with
      | Some _ as binary -> binary
      | None -> env_server_binary ()
    in
    { model_dir; server_binary; ctx_size; startup_timeout_s; memory_budget }

  let default = make ()
end

module Manifest = struct
  type entry = {
    id : string;
    display_name : string;
    family : string;
    repo : string;
    file : string;
    size : int64;
    sha256 : string;
    context_length : int;
    reasoning : bool;
    (* Memory-guard inputs. [kv_layers] counts KV-bearing layers only:
       hybrid-attention models cache KV for a subset of their layers. *)
    kv_layers : int;
    n_kv_heads : int;
    head_dim : int;
  }

  (* Facts verified against the Hugging Face API (file size and LFS SHA-256)
     and each model's published config.json (attention geometry) on
     2026-07-21. The [file] is the exact repository path and is case-sensitive:
     resolving a mis-cased name returns HTTP 404. *)
  let all =
    [
      {
        id = "qwen3-coder-30b";
        display_name = "Qwen3 Coder 30B (Q4_K_M)";
        family = "qwen3-coder";
        repo = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF";
        file = "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf";
        size = 18_556_689_568L;
        sha256 =
          "fadc3e5f8d42bf7e894a785b05082e47daee4df26680389817e2093056f088ad";
        context_length = 262_144;
        reasoning = false;
        kv_layers = 48;
        n_kv_heads = 4;
        head_dim = 128;
      };
      {
        id = "gpt-oss-20b";
        display_name = "gpt-oss 20B (MXFP4)";
        family = "gpt-oss";
        repo = "ggml-org/gpt-oss-20b-GGUF";
        file = "gpt-oss-20b-MXFP4.gguf";
        size = 12_109_566_624L;
        sha256 =
          "27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901";
        context_length = 131_072;
        reasoning = true;
        kv_layers = 24;
        n_kv_heads = 8;
        head_dim = 64;
      };
      {
        id = "devstral-small-2";
        display_name = "Devstral Small 2 24B (Q4_K_M)";
        family = "devstral";
        repo = "unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF";
        file = "Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf";
        size = 14_334_446_752L;
        sha256 =
          "d14ba9edee1bb4c4996a726deb81e49ae81800a3216f0774634238c380aee496";
        context_length = 393_216;
        reasoning = false;
        kv_layers = 40;
        n_kv_heads = 8;
        head_dim = 128;
      };
      {
        id = "qwen3.6-35b";
        display_name = "Qwen3.6 35B (Q4_K_M)";
        family = "qwen3.6";
        repo = "unsloth/Qwen3.6-35B-A3B-GGUF";
        file = "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
        size = 22_134_528_992L;
        sha256 =
          "ac0e2c1189e055faa36eff361580e79c5bd6f8e76bffb4ce547f167d53e31a61";
        context_length = 262_144;
        reasoning = true;
        (* Hybrid attention: 10 of 40 layers are full attention; the linear
           layers keep constant-size state, not a KV cache. *)
        kv_layers = 10;
        n_kv_heads = 2;
        head_dim = 256;
      };
    ]

  let find id = List.find_opt (fun entry -> String.equal entry.id id) all
  let id entry = entry.id
  let display_name entry = entry.display_name
  let family entry = entry.family
  let file entry = entry.file

  let url entry =
    "https://huggingface.co/" ^ entry.repo ^ "/resolve/main/"
    ^ Uri.pct_encode entry.file

  let size entry = entry.size
  let context_length entry = entry.context_length
  let reasoning entry = entry.reasoning

  let fit entry =
    Modelfit.Model.make ~weights_bytes:(Int64.to_int entry.size)
      ~n_kv_layers:entry.kv_layers ~n_kv_heads:entry.n_kv_heads
      ~head_dim:entry.head_dim ~max_context:entry.context_length
end

let llm_error ?(phase = Llm.Error.Startup) ?status kind message =
  Llm.Error.make ~kind ~phase ~provider ?status message

let unsupported message = Error (llm_error Llm.Error.Unsupported message)

let startup_provider_error message =
  Error (llm_error Llm.Error.Provider message)

let cancelled_error ?(phase = Llm.Error.Startup) () =
  llm_error ~phase Llm.Error.Cancelled "local request cancelled"

let default_xdg_dir env_name ~home_suffix =
  match Sys.getenv_opt env_name with
  | Some dir when not (String.is_empty dir) -> Ok dir
  | Some _ | None -> (
      match Sys.getenv_opt "HOME" with
      | Some home when not (String.is_empty home) ->
          Ok (Filename.concat home home_suffix)
      | Some _ | None ->
          Error
            (Printf.sprintf
               "cannot determine %s; set %s or HOME, or pass an explicit path"
               env_name env_name))

let model_dir = function
  | Some dir -> Ok dir
  | None ->
      let ( / ) = Filename.concat in
      Result.map
        (fun dir -> dir / "mentat" / "models")
        (default_xdg_dir "XDG_DATA_HOME" ~home_suffix:(".local" / "share"))

module Download = struct
  type phase = Checking | Downloading | Verifying | Installed

  type progress = {
    model : string;
    label : string;
    path : string;
    received : int64;
    total : int64 option;
    phase : phase;
  }
end

type artifact_status =
  | Installed of { path : string }
  | Missing of { path : string; url : string; size : int64 }
  | Explicit_path of { path : string; exists : bool }

let artifact_status ?(config = Config.default) id =
  match model_dir config.Config.model_dir with
  | Error message -> Error message
  | Ok dir -> (
      match Manifest.find id with
      | Some entry ->
          let path = Filename.concat dir entry.Manifest.file in
          if Sys.file_exists path then Ok (Installed { path })
          else
            Ok
              (Missing
                 { path; url = Manifest.url entry; size = entry.Manifest.size })
      | None -> Ok (Explicit_path { path = id; exists = Sys.file_exists id }))

let pp_bytes ppf bytes =
  let gib = 1024. *. 1024. *. 1024. in
  Format.fprintf ppf "%.1f GiB" (Int64.to_float bytes /. gib)

let format_bytes bytes = Format.asprintf "%a" pp_bytes bytes

let budget_for config =
  match config.Config.memory_budget with
  | Some budget -> Some budget
  | None -> Option.map Modelfit.Machine.budget (Modelfit.Machine.detect ())

(* Guard inputs for an explicit GGUF path, read from the file's own header.
   GGUF metadata precedes tensor data, so a short prefix usually suffices;
   grow it on [Truncated] up to a cap. [None] when the header cannot be
   parsed — the caller then treats the model's memory need as unknown. *)
let gguf_fit_of_path path =
  match Unix.stat path with
  | exception Unix.Unix_error _ -> None
  | { Unix.st_size; _ } ->
      let read_prefix length =
        In_channel.with_open_bin path (fun ic ->
            really_input_string ic (Int.min length st_size))
      in
      let max_prefix = 33_554_432 in
      let rec attempt length =
        match read_prefix length with
        | exception (Sys_error _ | End_of_file) -> None
        | prefix -> (
            match Modelfit.Gguf.of_prefix prefix with
            | Ok gguf -> (
                match Modelfit.Gguf.model ~weights_bytes:st_size gguf with
                | Ok fit -> Some fit
                | Error reason ->
                    Log.debug (fun m ->
                        m "gguf header of %s has no guard inputs: %a" path
                          Modelfit.Gguf.Model_error.pp reason);
                    None)
            | Error Modelfit.Gguf.Error.Truncated
              when length < max_prefix && length < st_size ->
                attempt (length * 4)
            | Error error ->
                Log.debug (fun m ->
                    m "gguf header of %s: %a" path Modelfit.Gguf.Error.pp error);
                None)
      in
      attempt 524_288

module Fit = struct
  type t = {
    verdict : Modelfit.Verdict.t;
    need_bytes : int;
    budget_bytes : int;
  }

  let of_inputs ~budget inputs =
    let verdict = Modelfit.verdict ~budget inputs in
    let decisive_context =
      match verdict with
      | Modelfit.Verdict.Wont_run -> Modelfit.min_useful_context
      | Modelfit.Verdict.Fits | Modelfit.Verdict.Tight _ ->
          Modelfit.default_context
    in
    let need_bytes =
      Modelfit.Estimate.total_bytes
        (Modelfit.estimate ~context:decisive_context inputs)
    in
    { verdict; need_bytes; budget_bytes = budget }

  let of_entry ~budget entry = of_inputs ~budget (Manifest.fit entry)

  let find ?(config = Config.default) id =
    let inputs =
      match Manifest.find id with
      | Some entry -> Some (Manifest.fit entry)
      | None ->
          if String.ends_with ~suffix:".gguf" id && Sys.file_exists id then
            gguf_fit_of_path id
          else None
    in
    match inputs with
    | None -> None
    | Some inputs ->
        Option.map (fun budget -> of_inputs ~budget inputs) (budget_for config)

  let to_string t =
    let bytes value = format_bytes (Int64.of_int value) in
    match t.verdict with
    | Modelfit.Verdict.Fits ->
        Printf.sprintf "fits (~%s of %s)" (bytes t.need_bytes)
          (bytes t.budget_bytes)
    | Modelfit.Verdict.Tight { max_context } ->
        Printf.sprintf "fits up to ~%dk context" (max_context / 1024)
    | Modelfit.Verdict.Wont_run ->
        Printf.sprintf "needs ~%s, %s usable" (bytes t.need_bytes)
          (bytes t.budget_bytes)

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

(* The download guard: refuse to download a model this machine cannot load
   even at the minimum useful context. Loads are never hard-blocked; hours of
   downloading are. *)
let guard_download ~config ~force entry =
  if force then Ok ()
  else
    match budget_for config with
    | None -> Ok ()
    | Some budget -> (
        let fit = Fit.of_entry ~budget entry in
        match fit.Fit.verdict with
        | Modelfit.Verdict.Fits | Modelfit.Verdict.Tight _ -> Ok ()
        | Modelfit.Verdict.Wont_run ->
            unsupported
              (Printf.sprintf
                 "local model %S needs an estimated %s of memory even at a \
                  %d-token context; this machine's usable budget is %s. It \
                  would download (%s) but never load. Override the guard to \
                  download anyway."
                 entry.Manifest.id
                 (format_bytes (Int64.of_int fit.Fit.need_bytes))
                 Modelfit.min_useful_context
                 (format_bytes (Int64.of_int budget))
                 (format_bytes entry.Manifest.size)))

let emit_download ~observe_download progress =
  Option.iter (fun observe -> observe progress) observe_download

let download_progress ~observe_download ~model ~label ~path ~received ~total
    ~phase =
  emit_download ~observe_download
    { Download.model; label; path; received; total; phase }

let download_artifact ~env ~http ~cancelled ?observe_download entry ~path =
  let id = entry.Manifest.id in
  let label = entry.Manifest.file in
  let size = entry.Manifest.size in
  Log.info (fun m -> m "downloading model=%s size=%Ld" id size);
  let observe phase ~received ~total =
    let phase =
      match phase with
      | Mentat_llm_artifact.Checking -> Download.Checking
      | Mentat_llm_artifact.Downloading -> Download.Downloading
      | Mentat_llm_artifact.Verifying -> Download.Verifying
      | Mentat_llm_artifact.Installed -> Download.Installed
    in
    download_progress ~observe_download ~model:id ~label ~path ~received ~total
      ~phase
  in
  let* () =
    Mentat_llm_artifact.install ~env ~http ~provider ~cancelled ~observe
      ~url:(Manifest.url entry) ~path ~size ~sha256:entry.Manifest.sha256
  in
  Log.info (fun m -> m "model installed model=%s path=%s" id path);
  Ok path

let ensure_model_path ?http ?observe_download ?(force = false) ~sw ~env
    ~cancelled config id =
  Eio.Switch.check sw;
  let* () = if cancelled () then Error (cancelled_error ()) else Ok () in
  match model_dir config.Config.model_dir with
  | Error message -> startup_provider_error message
  | Ok dir -> (
      match Manifest.find id with
      | Some entry -> (
          let path = Filename.concat dir entry.Manifest.file in
          if Sys.file_exists path then Ok path
          else
            match http with
            | None ->
                startup_provider_error
                  (Printf.sprintf
                     "local model %S is not downloaded at %s and automatic \
                      download is unavailable"
                     id path)
            | Some http ->
                let* () = guard_download ~config ~force entry in
                download_artifact ~env ~http ~cancelled ?observe_download entry
                  ~path)
      | None ->
          if Sys.file_exists id then Ok id
          else
            startup_provider_error
              (Printf.sprintf "local model path does not exist: %s" id))

module Artifact = struct
  type status = artifact_status =
    | Installed of { path : string }
    | Missing of { path : string; url : string; size : int64 }
    | Explicit_path of { path : string; exists : bool }

  let status = artifact_status

  let prepare ~sw ~env ~http ~cancelled ?observe_download
      ?(config = Config.default) ?force id =
    Result.map
      (fun (_ : string) -> ())
      (ensure_model_path ~http ?observe_download ?force ~sw ~env ~cancelled
         config id)
end

(* Managed servers outlive individual client values but never their owner
   switch. Clients are rebuilt per turn, while the application switch spans
   those turns; binding residency to that switch preserves model reuse without
   detaching a child from structured cleanup. *)
module Server = struct
  type t = {
    model_path : string;
    ctx : int;
    port : int;
    process : Eio_unix.Process.ty Eio.Resource.t;
    owner : Eio.Switch.t;
    exited : Eio.Process.exit_status option Atomic.t;
    need_bytes : int option;
        (* Estimated memory need; [None] when the GGUF header could not be
           read, in which case the server gets exclusive residency. *)
    mutable last_used : int; (* Monotonic tick for LRU eviction. *)
  }

  let residents : t list ref = ref []
  let use_clock = ref 0
  let mutex = Eio.Mutex.create ()
  let shutdown_grace_s = 1.0

  let touch t =
    incr use_clock;
    t.last_used <- !use_clock

  let pid t = Eio.Process.pid t.process
  let running t = Option.is_none (Atomic.get t.exited)

  let remove t =
    residents := List.filter (fun resident -> resident != t) !residents

  let remove_safely t =
    Eio.Mutex.use_rw ~protect:true mutex (fun () -> remove t)

  let base_url t = Printf.sprintf "http://127.0.0.1:%d" t.port

  let free_port () =
    let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close sock)
      (fun () ->
        Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
        match Unix.getsockname sock with
        | Unix.ADDR_INET (_, port) -> port
        | Unix.ADDR_UNIX _ -> assert false)

  let find_binary = function
    | Some binary when String.contains binary '/' ->
        if Sys.file_exists binary then Ok binary
        else Error (Printf.sprintf "llama-server binary not found at %s" binary)
    | spec -> (
        let name = Option.value spec ~default:"llama-server" in
        let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
        let candidate dir =
          if String.is_empty dir then None
          else
            let candidate = Filename.concat dir name in
            if Sys.file_exists candidate then Some candidate else None
        in
        match List.find_map candidate (String.split_on_char ':' path) with
        | Some binary -> Ok binary
        | None ->
            Error
              (name
             ^ " was not found on PATH; install llama.cpp (for example: brew \
                install llama.cpp) or configure an explicit server binary"))

  let record_exit t status =
    Atomic.set t.exited (Some status);
    remove_safely t

  let await t =
    let status = Eio.Process.await t.process in
    Atomic.set t.exited (Some status);
    status

  let stop ~clock t =
    Eio.Cancel.protect @@ fun () ->
    Log.info (fun m -> m "stopping llama-server pid=%d" (pid t));
    Eio.Process.signal t.process Sys.sigterm;
    match
      Eio.Time.with_timeout clock shutdown_grace_s (fun () -> Ok (await t))
    with
    | Ok _ -> ()
    | Error `Timeout ->
        Log.warn (fun m ->
            m "llama-server ignored SIGTERM; killing pid=%d" (pid t));
        Eio.Process.signal t.process Sys.sigkill;
        ignore (await t : Eio.Process.exit_status)

  let start ~sw ~env ~config ~model_path ~ctx ~need_bytes =
    let* binary = find_binary config.Config.server_binary in
    let port = free_port () in
    let argv =
      [
        binary;
        "-m";
        model_path;
        "--host";
        "127.0.0.1";
        "--port";
        string_of_int port;
        "-c";
        string_of_int ctx;
        "--jinja";
      ]
    in
    let process_mgr = Eio.Stdenv.process_mgr env in
    let fs, _ = Eio.Stdenv.fs env in
    let null_path = (fs, "/dev/null") in
    let spawn () =
      Eio.Path.with_open_out ~create:`Never null_path (fun null ->
          let stdin = Eio.Flow.string_source "" in
          Eio.Process.spawn ~sw process_mgr ~stdin ~stdout:null ~stderr:null
            ~executable:binary argv)
    in
    match spawn () with
    | process ->
        let t =
          {
            model_path;
            ctx;
            port;
            process;
            owner = sw;
            exited = Atomic.make None;
            need_bytes;
            last_used = 0;
          }
        in
        (* The process itself is already attached to [sw]: Eio kills and reaps
           it on release. This hook only removes the corresponding admission
           record; explicit eviction and failed startup use graceful [stop]. *)
        Eio.Switch.on_release sw (fun () -> remove_safely t);
        Eio.Fiber.fork_daemon ~sw (fun () ->
            let status = Eio.Process.await process in
            record_exit t status;
            `Stop_daemon);
        Eio.Switch.check sw;
        Log.info (fun m ->
            m "started llama-server pid=%d port=%d model=%s ctx=%d" (pid t) port
              model_path ctx);
        Ok t
    | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
    | exception ex ->
        Error
          (Printf.sprintf "failed to start %s: %s" binary
             (Printexc.to_string ex))

  let wait_healthy ~env ~cancelled ~config t =
    let clock = Eio.Stdenv.clock env in
    let deadline = Eio.Time.now clock +. config.Config.startup_timeout_s in
    let rec poll () =
      if cancelled () then Error "local server startup cancelled"
      else if not (running t) then
        let status = Option.get (Atomic.get t.exited) in
        Error
          (Format.asprintf
             "llama-server exited during startup (%a); run it by hand to see \
              why (it may be out of memory or the GGUF may be unsupported)"
             Eio.Process.pp_status status)
      else
        match Api.health ~env ~base_url:(base_url t) () with
        | Ok () -> Ok ()
        | Error _ ->
            if Eio.Time.now clock >= deadline then
              Error
                (Printf.sprintf
                   "llama-server did not become healthy within %.0fs"
                   config.Config.startup_timeout_s)
            else begin
              Eio.Time.sleep clock 0.5;
              poll ()
            end
    in
    poll ()

  let evict ~clock ~admitting victim =
    Log.warn (fun m ->
        m
          "evicting llama-server for %s to make room for %s; alternating \
           between these models reloads weights every switch (consider a \
           hosted small model or a larger memory budget)"
          victim.model_path admitting);
    stop ~clock victim;
    remove victim

  let lru () =
    match !residents with
    | [] -> None
    | first :: rest ->
        Some
          (List.fold_left
             (fun oldest t ->
               if t.last_used < oldest.last_used then t else oldest)
             first rest)

  (* Admission: keep every resident whose need is known while the sum fits
     the budget; evict least-recently-used otherwise. Servers with unknown
     needs cannot be accounted for, so they neither share residency with
     others nor survive a new admission. *)
  let make_room ~clock ~budget ~model_path ~need_bytes =
    let over () =
      match (budget, need_bytes) with
      | None, _ | _, None -> not (List.is_empty !residents)
      | Some budget, Some need ->
          List.exists (fun t -> Option.is_none t.need_bytes) !residents
          || List.fold_left
               (fun sum t -> sum + Option.value t.need_bytes ~default:0)
               need !residents
             > budget
    in
    let rec loop () =
      if over () then
        match lru () with
        | None -> ()
        | Some victim ->
            evict ~clock ~admitting:model_path victim;
            loop ()
    in
    loop ()

  let ensure ~sw ~env ~cancelled ~config ~model_path ~ctx ~need_bytes ~budget =
    Eio.Mutex.lock mutex;
    Fun.protect ~finally:(fun () -> Eio.Mutex.unlock mutex) @@ fun () ->
    let clock = Eio.Stdenv.clock env in
    residents := List.filter running !residents;
    match
      List.find_opt
        (fun t ->
          t.owner == sw
          && String.equal t.model_path model_path
          && Int.equal t.ctx ctx)
        !residents
    with
    | Some t ->
        touch t;
        Ok t
    | None -> (
        (* A same-model server with a different context is stale. *)
        List.iter
          (evict ~clock ~admitting:model_path)
          (List.filter
             (fun t -> t.owner == sw && String.equal t.model_path model_path)
             !residents);
        make_room ~clock ~budget ~model_path ~need_bytes;
        let* t = start ~sw ~env ~config ~model_path ~ctx ~need_bytes in
        residents := t :: !residents;
        touch t;
        let cleanup () =
          remove t;
          stop ~clock t
        in
        match wait_healthy ~env ~cancelled ~config t with
        | Ok () ->
            Log.info (fun m ->
                m "llama-server ready pid=%d port=%d model=%s" (pid t) t.port
                  t.model_path);
            Ok t
        | Error message ->
            cleanup ();
            Error message
        | exception ex ->
            let bt = Printexc.get_raw_backtrace () in
            Eio.Cancel.protect cleanup;
            Printexc.raise_with_backtrace ex bt)
end

let server_binary ?(config = Config.default) () =
  Server.find_binary config.Config.server_binary

let fit_inputs id path =
  match Manifest.find id with
  | Some entry -> Some (Manifest.fit entry)
  | None ->
      if String.equal id path || Sys.file_exists path then gguf_fit_of_path path
      else None

(* The requested context clamps to the model's trained maximum and to what
   fits the memory budget: a server asked for more KV cache than the machine
   has fails to load, and the guard's job at load time is to degrade with a
   warning, never to block. *)
let context_for config id inputs =
  match inputs with
  | None -> config.Config.ctx_size
  | Some inputs -> (
      let requested =
        Int.min config.Config.ctx_size (Modelfit.Model.max_context inputs)
      in
      match budget_for config with
      | None -> requested
      | Some budget -> (
          match Modelfit.max_context ~budget inputs with
          | Some fitting when fitting < requested ->
              Log.warn (fun m ->
                  m
                    "model %s: context reduced to %d tokens to fit the memory \
                     budget (requested %d)"
                    id fitting requested);
              fitting
          | Some _ -> requested
          | None ->
              Log.warn (fun m ->
                  m
                    "model %s exceeds the memory budget; the server may fail \
                     to load it"
                    id);
              requested))

let client ~sw ~env ?http ?observe_download ?(config = Config.default) () =
  let run ~cancelled ~on_event request =
    if cancelled () then Error (cancelled_error ())
    else
      let model = Llm.Request.model request in
      let id = Llm.Model.id model in
      let* () = Chat_completions.check_request ~provider request in
      let* path =
        ensure_model_path ?http ?observe_download ~sw ~env ~cancelled config id
      in
      let inputs = fit_inputs id path in
      let ctx = context_for config id inputs in
      let need_bytes =
        Option.map
          (fun inputs ->
            Modelfit.Estimate.total_bytes
              (Modelfit.estimate ~context:ctx inputs))
          inputs
      in
      let* server =
        match
          Server.ensure ~sw ~env ~cancelled ~config ~model_path:path ~ctx
            ~need_bytes ~budget:(budget_for config)
        with
        | Ok _ as ok -> ok
        | Error message ->
            if cancelled () then Error (cancelled_error ())
            else startup_provider_error message
      in
      Eio.Switch.run ~name:"local.request" @@ fun request_sw ->
      let endpoint =
        Chat_completions.make ~provider ~base_url:(Server.base_url server)
          ~sw:request_sw ~env ()
      in
      Chat_completions.run endpoint ~cancelled ~on_event request
  in
  Llm.Client.make ~provider ~apis:[ api ] ~run
