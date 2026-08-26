(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mentat_charter
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
  env : Charter_fire.env;
  stop : Stop_signal.t;
  github_base_url : string option;
  git_url : string option;
  queue : (Charter_store.Loaded.t * Event.Pull_request.t) Eio.Stream.t;
  rejected : int ref;
}

let dirs t = t.env.Charter_fire.dirs
let say t line = t.env.Charter_fire.say line

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

let create (shared : Composition.shared) ~stop ?github_base_url ?git_url () =
  match
    Daemon.resolve_sibling ~env:"MENTAT_BIN" ~name:"mentat" ~beside:"mentatd"
  with
  | Error message -> Error message
  | Ok mentat_bin ->
      let env =
        {
          Charter_fire.dirs = shared.Composition.dirs;
          store = shared.Composition.store;
          catalog = Mentat_provider_runtime.catalog shared.Composition.runtime;
          stdenv = shared.Composition.stdenv;
          environment =
            child_environment shared.Composition.environment ~github_base_url;
          mentat_bin;
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
          git_url;
          queue = Eio.Stream.create max_int;
          rejected = ref 0;
        }

let env t ~name =
  {
    t.env with
    Charter_fire.say =
      (fun line -> say t (Printf.sprintf "charter %s: %s" name line));
  }

let reconcile_env t = t.env

let repo t (loaded : Charter_store.Loaded.t) =
  let watched = loaded.Charter_store.Loaded.charter.Charter.repo in
  match Charter_store.read_secret loaded ~file:"read-token" with
  | Error e -> Error (Charter_store.Error.message e)
  | Ok None ->
      Error
        (Printf.sprintf
           "charter %s has no GitHub read credential at %s (a fine-grained \
            PAT with read access to %s)"
           loaded.Charter_store.Loaded.name
           (Filename.concat
              (Filename.concat loaded.Charter_store.Loaded.dir "secrets")
              "read-token")
           watched)
  | Ok (Some token) -> (
      match
        Github_api.make ?base_url:t.github_base_url ~token
          (Eio.Stdenv.net t.env.Charter_fire.stdenv)
      with
      | Error e -> Error (Github_api.Error.message e)
      | Ok api ->
          let github =
            {
              Charter_fire.Github.current_head =
                (fun ~number ->
                  Github_reads.current_head api ~repo:watched ~number);
              open_prs =
                (fun () ->
                  Result.map
                    (List.map (fun (pr : Github_reads.Open_pr.t) ->
                         {
                           Charter_fire.Github.number =
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
          let git_url =
            match t.git_url with
            | Some url -> url
            | None -> Printf.sprintf "https://github.com/%s.git" watched
          in
          Ok { Charter_fire.Repo.git_url; github })

(* Ingress. *)

let resolution bindings ~ingress_id =
  match
    List.find_opt
      (fun (b : Charter_store.Binding.t) ->
        String.equal b.Charter_store.Binding.id ingress_id)
      bindings
  with
  | Some b ->
      Mentat_server.Ingress.Resolved
        {
          secret = b.Charter_store.Binding.secret;
          enabled = b.Charter_store.Binding.enabled;
        }
  | None -> Mentat_server.Ingress.Unknown

let event_route = function
  | None -> `Admit
  | Some kind ->
      if String.equal kind "pull_request" then `Admit else `Foreign kind

(* The custody-side fold: the resolver answered on its own snapshot, and
   custody re-reads — the file is the registration, so the name is looked up
   again rather than remembered across the verification. *)
let binding_name t ~ingress_id =
  match Charter_store.ingress_index (dirs t) with
  | Error e -> Error (Charter_store.Error.message e)
  | Ok (bindings, _failures) -> (
      match
        List.find_opt
          (fun (b : Charter_store.Binding.t) ->
            String.equal b.Charter_store.Binding.id ingress_id)
          bindings
      with
      | Some b -> Ok b.Charter_store.Binding.name
      | None -> Error "the ingress id no longer resolves to a charter")

let receipt_now ~identity ~digest kind =
  { Receipt.at = Unix.gettimeofday (); identity; digest; kind }

let skip_disabled t (loaded : Charter_store.Loaded.t) event =
  let identity =
    Event.Identity.to_string (Event.Identity.of_pull_request event)
  in
  let receipt =
    receipt_now ~identity ~digest:loaded.Charter_store.Loaded.digest
      (Receipt.Kind.Disposition (Receipt.Disposition.Skipped "disabled"))
  in
  match
    Charter_store.append_receipt (dirs t)
      ~name:loaded.Charter_store.Loaded.name receipt
  with
  | Ok () -> Ok identity
  | Error e -> Error (Charter_store.Error.message e)

let deliver t ~ingress_id ~enabled ~event ~delivery_id ~body =
  match binding_name t ~ingress_id with
  | Error reason -> `Refused reason
  | Ok name -> (
      match Charter_store.load (dirs t) ~name with
      | Error e -> `Refused (Charter_store.Error.message e)
      | Ok loaded -> (
          match event_route event with
          | `Foreign kind ->
              say t
                (Printf.sprintf "charter %s: ignoring %s delivery%s" name
                   (clean kind)
                   (delivery_suffix delivery_id));
              `Accepted
          | `Admit ->
              if enabled && Eio.Stream.length t.queue >= queue_cap then
                `Refused
                  (Printf.sprintf "charter %s: the delivery queue is full" name)
              else (
                match Charter_fire.admit_delivery (env t ~name) loaded ~body with
                | Error reason ->
                    `Refused (Printf.sprintf "charter %s: %s" name reason)
                | Ok ev ->
                    if not enabled then (
                      match skip_disabled t loaded ev with
                      | Error reason ->
                          `Refused (Printf.sprintf "charter %s: %s" name reason)
                      | Ok identity ->
                          say t
                            (Printf.sprintf "charter %s: skipped %s: disabled"
                               name identity);
                          `Accepted)
                    else (
                      Eio.Stream.add t.queue (loaded, ev);
                      say t
                        (Printf.sprintf "charter %s: queued %s%s" name
                           (Event.Identity.to_string
                              (Event.Identity.of_pull_request ev))
                           (delivery_suffix delivery_id));
                      `Accepted))))

let ingress t =
  {
    Mentat_server.Ingress.resolve =
      (fun ~ingress_id ->
        match Charter_store.ingress_index (dirs t) with
        | Error e ->
            say t
              (Printf.sprintf "ingress: %s" (Charter_store.Error.message e));
            Mentat_server.Ingress.Unknown
        | Ok (bindings, failures) ->
            List.iter
              (fun (name, e) ->
                say t
                  (Printf.sprintf "ingress: charter %s answers to no id: %s"
                     name
                     (Charter_store.Error.message e)))
              failures;
            resolution bindings ~ingress_id);
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
let drive t (loaded : Charter_store.Loaded.t) event =
  let name = loaded.Charter_store.Loaded.name in
  let env = env t ~name in
  match repo t loaded with
  | Error reason ->
      (* A durable refusal, never a claim — the head re-enters on a later
         sweep pass, when the owner has repaired what refused it. *)
      let identity =
        Event.Identity.to_string (Event.Identity.of_pull_request event)
      in
      let receipt =
        receipt_now ~identity ~digest:loaded.Charter_store.Loaded.digest
          (Receipt.Kind.Disposition (Receipt.Disposition.Refused reason))
      in
      (match Charter_store.append_receipt (dirs t) ~name receipt with
      | Ok () -> ()
      | Error e -> env.Charter_fire.say (Charter_store.Error.message e));
      env.Charter_fire.say (Printf.sprintf "refused %s: %s" identity reason);
      false
  | Ok repo ->
      let reaped = ref false in
      (match
         Charter_fire.dispose env ~repo
           ~on_reap:(fun () -> reaped := true)
           loaded ~event ~check_head:true
       with
      | Ok Charter_fire.Disposed | Ok Charter_fire.Interrupted -> ()
      | Error message -> env.Charter_fire.say message);
      !reaped

let pump t ~after_reap =
  let rec loop () =
    let loaded, event = Eio.Stream.take t.queue in
    let name = loaded.Charter_store.Loaded.name in
    (if Stop_signal.requested t.stop then
       say t
         (Printf.sprintf "charter %s: stop requested; leaving %s to a later \
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
             (Printf.sprintf "charter %s: pump: %s" name
                (Printexc.to_string e)));
    loop ()
  in
  loop ()
