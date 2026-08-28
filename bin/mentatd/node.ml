(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mentat_routine
open Mentat_github

(* The admission bound on the delivery queue. Overflow refuses at the wire
   before any receipt is written: the pump serializes runs of minutes, so a
   backlog this deep is hours old and the current-head check would refuse
   most of it as moved-on anyway; a still-open head re-enters on every sweep
   pass. The queue itself is structurally unbounded so the enqueue can never
   park the serving fiber — the bound is this admission check alone, and a
   race past it overshoots by an entry, never blocks. *)
let queue_cap = 64

type t = {
  env : Routine_fire.env;
  stop : Stop_signal.t;
  github_base_url : string option;
  git_base : string option;
  queue : (Routine_store.Loaded.t * Event.Pull_request.t) Eio.Stream.t;
  rejected : int ref;
}

let dirs t = t.env.Routine_fire.dirs
let say t line = t.env.Routine_fire.say line

(* Display hygiene for header values reaching the trace log: control bytes
   blanked, length bounded. *)
let clean ?(cap = 100) s =
  let s =
    String.map
      (fun c -> if Char.code c < 32 || Char.code c = 127 then ' ' else c)
      s
  in
  let s = String.trim s in
  if String.length s > cap then String.sub s 0 cap ^ "…" else s

let delivery_suffix = function
  | Some guid -> Printf.sprintf " (delivery %s)" (clean guid)
  | None -> ""

let child_environment base ~github_base_url =
  let base =
    List.filter
      (fun (k, _) -> not (String.equal k "MENTAT_GITHUB_BASE_URL"))
      base
  in
  match github_base_url with
  | None -> base
  | Some url -> base @ [ ("MENTAT_GITHUB_BASE_URL", url) ]

(* The checkout remote, derived per routine: the base names the git host
   prefix, the watched repository names the path — one flag serves a node
   holding routines over many repositories, and an Enterprise base carries
   its checkouts along with its API reads. *)
let checkout_url ~git_base ~repo =
  let base =
    match git_base with
    | Some base ->
        if String.ends_with ~suffix:"/" base then
          String.sub base 0 (String.length base - 1)
        else base
    | None -> "https://github.com"
  in
  Printf.sprintf "%s/%s.git" base repo

let create (shared : Composition.shared) ~broker ~stop ?github_base_url
    ?git_base () =
  match
    Daemon.resolve_sibling ~env:"MENTAT_BIN" ~name:"mentat" ~beside:"mentatd"
  with
  | Error message -> Error message
  | Ok mentat_bin ->
      let env =
        {
          Routine_fire.dirs = shared.Composition.dirs;
          store = shared.Composition.store;
          catalog = Mentat_provider_runtime.catalog shared.Composition.runtime;
          stdenv = shared.Composition.stdenv;
          environment =
            child_environment shared.Composition.environment ~github_base_url;
          mentat_bin;
          broker;
          stop =
            (fun () -> if Stop_signal.requested stop then `Stop else `None);
          say = (fun line -> Eio.traceln "mentatd: %s" line);
        }
      in
      Ok
        {
          env;
          stop;
          github_base_url;
          git_base;
          queue = Eio.Stream.create max_int;
          rejected = ref 0;
        }

let env t ~name = Routine_fire.named_env t.env ~name
let reconcile_env t = t.env

let repo t (loaded : Routine_store.Loaded.t) =
  let watched = loaded.Routine_store.Loaded.routine.Routine.repo in
  match Routine_store.read_secret loaded ~file:"read-token" with
  | Error e -> Error (Routine_store.Error.message e)
  | Ok None ->
      Error
        (Printf.sprintf
           "routine %s has no GitHub read credential at %s (a fine-grained \
            PAT with read access to %s)"
           loaded.Routine_store.Loaded.name
           (Filename.concat
              (Filename.concat loaded.Routine_store.Loaded.dir "secrets")
              "read-token")
           watched)
  | Ok (Some token) -> (
      match
        Github_api.make ?base_url:t.github_base_url ~token
          (Eio.Stdenv.net t.env.Routine_fire.stdenv)
      with
      | Error e -> Error (Github_api.Error.message e)
      | Ok api ->
          let github =
            {
              Routine_fire.Github.current_head =
                (fun ~number ->
                  Github_reads.current_head api ~repo:watched ~number);
              open_prs =
                (fun () ->
                  Result.map
                    (List.map (fun (pr : Github_reads.Open_pr.t) ->
                         {
                           Routine_fire.Github.number =
                             pr.Github_reads.Open_pr.number;
                           head_sha = pr.Github_reads.Open_pr.head_sha;
                           base_ref = pr.Github_reads.Open_pr.base_ref;
                           draft = pr.Github_reads.Open_pr.draft;
                           author_association =
                             pr.Github_reads.Open_pr.author_association;
                         }))
                    (Github_reads.open_prs api ~repo:watched));
              posted =
                (fun ~number -> Github_reads.posted api ~repo:watched ~number);
            }
          in
          let git_url = checkout_url ~git_base:t.git_base ~repo:watched in
          Ok { Routine_fire.Repo.git_url; github })

(* Ingress. *)

let resolution bindings ~ingress_id =
  match
    List.find_opt
      (fun (b : Routine_store.Binding.t) ->
        String.equal b.Routine_store.Binding.id ingress_id)
      bindings
  with
  | Some b ->
      Mentat_server.Ingress.Resolved
        {
          secret = b.Routine_store.Binding.secret;
          enabled = b.Routine_store.Binding.enabled;
        }
  | None -> Mentat_server.Ingress.Unknown

(* The delivery route. The HMAC authenticates the body alone — the
   [X-GitHub-Event] header rides through unverified — so the body is the
   arbiter of what a delivery is: a payload the narrow decode admits is a
   pull-request event whatever its header claims (an intermediary
   relabeling a signed delivery must never turn a 202'd review into a
   silent drop), and the header may only confirm what the body already
   refused — a recognizable ping, or a foreign kind the body's shape agrees
   it is. A body the decode refuses under a pull-request-claiming (or
   absent) header is refused outright. *)
let event_route event ~body =
  match Event.Pull_request.decode body with
  | Ok _ -> `Admit
  | Error e -> (
      if Event.ping body then `Ping
      else
        match event with
        | Some kind when not (String.equal kind "pull_request") ->
            `Foreign kind
        | Some _ | None -> `Malformed (Event.Pull_request.Error.message e))

(* The custody-side fold: the resolver answered on its own snapshot, and
   custody re-reads — the file is the registration, so the name is looked up
   again rather than remembered across the verification. *)
let binding_name t ~ingress_id =
  match Routine_store.ingress_index (dirs t) with
  | Error e -> Error (Routine_store.Error.message e)
  | Ok (bindings, _failures) -> (
      match
        List.find_opt
          (fun (b : Routine_store.Binding.t) ->
            String.equal b.Routine_store.Binding.id ingress_id)
          bindings
      with
      | Some b -> Ok b.Routine_store.Binding.name
      | None -> Error "the ingress id no longer resolves to a routine")

let receipt_now ~identity ~digest kind =
  { Receipt.at = Unix.gettimeofday (); identity; digest; kind }

let skip_disabled t (loaded : Routine_store.Loaded.t) event =
  let identity =
    Event.Identity.to_string (Event.Identity.of_pull_request event)
  in
  let receipt =
    receipt_now ~identity ~digest:loaded.Routine_store.Loaded.digest
      (Receipt.Kind.Disposition (Receipt.Disposition.Skipped "disabled"))
  in
  match
    Routine_store.append_receipt (dirs t)
      ~name:loaded.Routine_store.Loaded.name receipt
  with
  | Ok () -> Ok identity
  | Error e -> Error (Routine_store.Error.message e)

let deliver t ~ingress_id ~enabled ~event ~delivery_id ~body =
  match binding_name t ~ingress_id with
  | Error reason -> `Refused reason
  | Ok name -> (
      match Routine_store.load (dirs t) ~name with
      | Error e -> `Refused (Routine_store.Error.message e)
      | Ok loaded -> (
          match event_route event ~body with
          | `Ping ->
              say t
                (Printf.sprintf "routine %s: ignoring ping delivery%s" name
                   (delivery_suffix delivery_id));
              `Accepted
          | `Foreign kind ->
              say t
                (Printf.sprintf "routine %s: ignoring %s delivery%s" name
                   (clean kind)
                   (delivery_suffix delivery_id));
              `Accepted
          | `Malformed reason ->
              `Refused (Printf.sprintf "routine %s: event: %s" name reason)
          | `Admit ->
              if enabled && Eio.Stream.length t.queue >= queue_cap then
                `Refused
                  (Printf.sprintf "routine %s: the delivery queue is full" name)
              else (
                match Routine_fire.admit_delivery (env t ~name) loaded ~body with
                | Error reason ->
                    `Refused (Printf.sprintf "routine %s: %s" name reason)
                | Ok ev ->
                    if not enabled then (
                      match skip_disabled t loaded ev with
                      | Error reason ->
                          `Refused (Printf.sprintf "routine %s: %s" name reason)
                      | Ok identity ->
                          say t
                            (Printf.sprintf "routine %s: skipped %s: disabled"
                               name identity);
                          `Accepted)
                    else (
                      Eio.Stream.add t.queue (loaded, ev);
                      say t
                        (Printf.sprintf "routine %s: queued %s%s" name
                           (Event.Identity.to_string
                              (Event.Identity.of_pull_request ev))
                           (delivery_suffix delivery_id));
                      `Accepted))))

let ingress t =
  {
    (* The resolver runs on unauthenticated input, so it is side-effect
       minimal: a broken routine is not narrated here — one line per broken
       routine per request would let any sender with the URL spend log
       I/O — but on the cookie-gated dashboard and the reconcile beat,
       which read the same roster. The one narrated failure is the roster
       itself being unreadable, a host fault no request rate amplifies
       beyond the log's own line. *)
    Mentat_server.Ingress.resolve =
      (fun ~ingress_id ->
        match Routine_store.ingress_index (dirs t) with
        | Error e ->
            say t
              (Printf.sprintf "ingress: %s" (Routine_store.Error.message e));
            Mentat_server.Ingress.Unknown
        | Ok (bindings, _failures) -> resolution bindings ~ingress_id);
    deliver =
      (fun ~ingress_id ~enabled ~event ~delivery_id ~body ->
        deliver t ~ingress_id ~enabled ~event ~delivery_id ~body);
    rejected =
      Some
        (fun ~ingress_id ->
          incr t.rejected;
          say t
            (Printf.sprintf
               "ingress: rejected delivery %d for id %s (bad or missing \
                signature)"
               !(t.rejected) (clean ingress_id)));
  }

(* The pump. *)

(* [drive] is whether the dispose reaped a run child: the pump owes the
   after-reap re-entry then, and the durable receipt — not the pipeline's
   return, which a failed publication turns into [Error] after the money
   is already spent — is what the signal rides. *)
let drive t (loaded : Routine_store.Loaded.t) event =
  let name = loaded.Routine_store.Loaded.name in
  let env = env t ~name in
  match repo t loaded with
  | Error reason ->
      (* A durable refusal, never a claim — the head re-enters on a later
         sweep pass, when the owner has repaired what refused it. *)
      let identity =
        Event.Identity.to_string (Event.Identity.of_pull_request event)
      in
      let receipt =
        receipt_now ~identity ~digest:loaded.Routine_store.Loaded.digest
          (Receipt.Kind.Disposition (Receipt.Disposition.Refused reason))
      in
      (match Routine_store.append_receipt (dirs t) ~name receipt with
      | Ok () -> ()
      | Error e -> env.Routine_fire.say (Routine_store.Error.message e));
      env.Routine_fire.say (Printf.sprintf "refused %s: %s" identity reason);
      false
  | Ok repo ->
      let reaped = ref false in
      (match
         Routine_fire.dispose env ~repo
           ~on_reap:(fun () -> reaped := true)
           loaded ~event ~check_head:true
       with
      | Ok Routine_fire.Disposed | Ok Routine_fire.Interrupted -> ()
      | Error message -> env.Routine_fire.say message);
      !reaped

let pump t ~after_reap =
  let rec loop () =
    let loaded, event = Eio.Stream.take t.queue in
    let name = loaded.Routine_store.Loaded.name in
    (if Stop_signal.requested t.stop then
       say t
         (Printf.sprintf "routine %s: stop requested; leaving %s to a later \
                          pass"
            name
            (Event.Identity.to_string (Event.Identity.of_pull_request event)))
     else
       try
         if drive t loaded event && not (Stop_signal.requested t.stop) then
           after_reap loaded
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e ->
           say t
             (Printf.sprintf "routine %s: pump: %s" name
                (Printexc.to_string e)));
    loop ()
  in
  loop ()
