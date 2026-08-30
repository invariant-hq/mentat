(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type escalation = Available | Denied of Error.t | Ignored

module Obligation = struct
  type kind = Exists | Directory
  type t = { path : Lpath.Abs.t; kind : kind }

  let path t = t.path
  let kind t = t.kind
  let kind_to_string = function Exists -> "exists" | Directory -> "directory"

  let pp ppf t =
    Format.fprintf ppf "%s %a" (kind_to_string t.kind) Lpath.Abs.pp t.path
end

type route =
  | Unconfined
  | Declared_external
  | Confine of {
      backend : Backend.t;
      policy : Policy.t;
      profile : Profile.t;
      evidence : Evidence.t;
    }
  | Refuse of { policy : Policy.t; error : Error.t }

type t = { route : route; escalation : escalation }

let direct = { route = Unconfined; escalation = Ignored }
let external_ = { route = Declared_external; escalation = Ignored }

let confined ~backend ~mutates policy =
  let escalation =
    if mutates then Available else Denied Error.Escalation_denied
  in
  match backend with
  | Error error -> { route = Refuse { policy; error }; escalation }
  | Ok backend ->
      let profile = Profile.prepare backend policy in
      let evidence =
        Evidence.enforced ~backend ~profile:(Profile.digest profile)
      in
      { route = Confine { backend; policy; profile; evidence }; escalation }

(* Widen one sealed route for a single command. The result is an ordinary
   sealed value, so lowering, evidence, obligation discharge and every observer
   apply to it unchanged — a grant needs no route of its own, only a policy that
   already knows how to be widened.

   An unconfined or externally declared route is returned as it stands: it
   already admits everything the grant asks for, so the request is satisfied
   rather than ignored. A refusing route keeps refusing.

   The identity moves, and should: it fingerprints the lowering, and this
   lowering differs. Nothing publishes it, because the granted value belongs to
   one command — the session keeps the seal it resumed under, which is the
   contract a grant must not move. *)
let grants_write entries =
  List.exists
    (fun (_, access) -> Policy.Access.equal access Policy.Access.Write)
    entries

let grant t entries =
  match (t.route, t.escalation) with
  | (Unconfined | Declared_external | Refuse _), _ -> Ok t
  (* A write grant is a mutation, so it answers to the same promise an
     escalation does. Gating it here rather than in a caller is the point: the
     stance lives on the seal, and a route that promised no mutation must refuse
     every way of asking, not every way a particular tool asks. A read grant
     widens nothing that promise covers and stays available. *)
  | Confine _, Denied error when grants_write entries -> Error error
  | Confine { backend; policy; _ }, (Available | Denied _ | Ignored) -> (
      match Policy.grant policy entries with
      | Error (path, denied) -> Error (Error.Grant_denied { path; denied })
      | Ok policy ->
          let profile = Profile.prepare backend policy in
          Ok
            {
              t with
              route =
                Confine
                  {
                    backend;
                    policy;
                    profile;
                    evidence =
                      Evidence.enforced ~backend
                        ~profile:(Profile.digest profile);
                  };
            })

let policy t =
  match t.route with
  | Confine { policy; _ } | Refuse { policy; _ } -> Some policy
  | Unconfined | Declared_external -> None

let escalation t = t.escalation

let identity t =
  match t.route with
  | Unconfined -> Identity.not_requested
  | Declared_external -> Identity.declared_external
  | Confine { backend; profile; _ } ->
      Identity.enforced ~backend ~profile:(Profile.digest profile)
  | Refuse _ -> Identity.refused

let evidence t =
  match t.route with
  | Unconfined -> Evidence.not_requested
  | Declared_external -> Evidence.declared_external
  | Confine { evidence; _ } -> evidence
  | Refuse { error; _ } -> Evidence.refused error

(* OS argv cannot represent an empty program or a NUL byte. The check mints
   [Error.t] here so every lowering validates; its enforcement home is the
   single launch boundary, which lowers every command through this library. *)
let validated_argv argv =
  match argv with
  | [] | "" :: _ -> Error Error.Empty_program
  | _ ->
      let rec check index = function
        | [] -> Ok argv
        | token :: rest ->
            if String.contains token '\000' then
              Error (Error.Nul_in_argv { index })
            else check (index + 1) rest
      in
      check 0 argv

let cwd_within policy cwd =
  match Policy.reads_default policy with
  | Policy.All -> true
  | Policy.Denied ->
      List.exists
        (fun root -> Lpath.Abs.is_within ~root cwd)
        (Policy.readable_roots policy)

let lower_argv t ~cwd argv =
  match validated_argv argv with
  | Error _ as error -> error
  | Ok argv -> (
      match t.route with
      | Unconfined | Declared_external -> Ok argv
      | Refuse { error; _ } -> Error error
      | Confine { policy; profile; _ } ->
          if cwd_within policy cwd then Ok (Profile.wrap profile ~cwd argv)
          else Error (Error.Cwd_outside_scope cwd))

(* An escalation is a widening like any other, so it mints a seal rather than
   discarding one. The floor it keeps is the deny set: those paths are denied
   because a later unconfined process consumes what is in them as authority —
   the session store carries the confinement identity a resume revalidates
   against, so a command able to write it can approve itself, and one approved
   escalation would otherwise become a standing one.

   Only the denials. The read carveouts are a weaker protection with a different
   purpose, and an escalation that could not write [.git] would surprise the
   person who approved it. What must not survive an approval is the ability to
   rewrite the approval.

   A route with no backend keeps exactly what it had. There is nothing to lower
   a floor through, so the honest answer is the unconfined seal — which is what
   an escalation on a refused route has always been, now said in the vocabulary
   instead of by returning the argv untouched. The floor is enforced wherever a
   backend exists and is best-effort where none does; that is a property worth
   stating rather than one to discover. *)
let floor policy =
  Policy.make
    ~entries:
      ((Lpath.Abs.root, Policy.Access.Write)
      :: List.map
           (fun path -> (path, Policy.Access.Deny))
           (Policy.denied_paths policy))
    ~reads_default:Policy.All ~network:Policy.Network.Enabled

let escalated t =
  match t.escalation with
  | Denied error -> Error error
  | Ignored -> Error Error.Escalation_irrelevant
  | Available -> (
      match t.route with
      | Unconfined | Declared_external -> Ok t
      | Refuse _ -> Ok direct
      | Confine { backend; policy; _ } ->
          let policy = floor policy in
          let profile = Profile.prepare backend policy in
          Ok
            {
              route =
                Confine
                  {
                    backend;
                    policy;
                    profile;
                    evidence =
                      Evidence.enforced ~backend
                        ~profile:(Profile.digest profile);
                  };
              escalation = t.escalation;
            })

let obligations t =
  match t.route with
  | Unconfined | Declared_external | Refuse _ -> []
  | Confine { policy; _ } ->
      (* A denied path needs no existence proof — denying an absent path is
         still correct — so only the granting clauses are obliged. *)
      let readable = Policy.readable_roots policy in
      let directories = Policy.writable_roots policy in
      let is_directory path = List.exists (Lpath.Abs.equal path) directories in
      List.sort_uniq Lpath.Abs.compare readable
      |> List.map (fun path ->
          let kind =
            if is_directory path then Obligation.Directory
            else Obligation.Exists
          in
          { Obligation.path; kind })
