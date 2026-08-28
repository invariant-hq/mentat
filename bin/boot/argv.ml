(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let usage message = Error (Exit_status.usage message)

let id_char c =
  (c >= 'A' && c <= 'Z')
  || (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')
  || Char.equal c '.' || Char.equal c '_' || Char.equal c '-'

let session_id raw =
  if String.length raw = 0 then usage "session id must not be empty"
  else if String.length raw > 128 then
    usage "session id must be at most 128 characters"
  else if not (String.for_all id_char raw) then
    usage "session id must contain only letters, digits, '.', '_', or '-'"
  else Ok (Mentat_session.Id.of_string raw)

let title raw =
  if String.length (String.trim raw) = 0 then usage "title must not be empty"
  else if String.exists (fun c -> Char.equal c '\n' || Char.equal c '\r') raw
  then usage "title must not contain newlines"
  else Ok raw

let title_opt = function
  | None -> Ok None
  | Some raw -> Result.map (fun t -> Some t) (title raw)

let limit n = if n < 0 then usage "limit must not be negative" else Ok n

let model_selector raw =
  match Mentat_provider.Selector.of_string raw with
  | Ok _ -> Ok raw
  | Error e -> usage (Mentat_provider.Selector.Error.message e)

let workflow_mode = function
  | "build" -> Ok Mentat_session.Contract.Mode.Build
  | "plan" -> Ok Mentat_session.Contract.Mode.Plan
  | "review" -> Ok Mentat_session.Contract.Mode.Review
  | other ->
      usage
        (Printf.sprintf "unknown mode %S; expected build, plan, or review" other)

let review_behavior = function
  | "default" -> Ok Mentat_permission.Review_behavior.Enforce
  | "bypass" -> Ok Mentat_permission.Review_behavior.Bypass
  | other ->
      usage
        (Printf.sprintf "unknown permission mode %S; expected default or bypass"
           other)

(* Trigger provenance, parsed strictly from <source>@<digest>:<key>: the
   trigger source a token — the routine name as mentatd mints it — the digest
   the 16 lowercase hex characters of the routine policy digest
   ([Mentat_routine.Routine.policy_digest] renders exactly 16; the two
   lengths move together), the key non-empty. A key may itself contain '@' or
   ':', so the first '@' and the first ':' after it are the delimiters. The
   flag is minted by trigger hosts; a sloppy value means the host is
   wrong. *)
let triggered raw =
  let malformed () =
    usage
      (Printf.sprintf
         "invalid --triggered value %s: expected <source>@<digest>:<key>" raw)
  in
  let hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') in
  match String.index_opt raw '@' with
  | None -> malformed ()
  | Some at -> (
      let source = String.sub raw 0 at in
      let rest = String.sub raw (at + 1) (String.length raw - at - 1) in
      match String.index_opt rest ':' with
      | None -> malformed ()
      | Some colon ->
          let digest = String.sub rest 0 colon in
          let key =
            String.sub rest (colon + 1) (String.length rest - colon - 1)
          in
          if
            String.length source = 0
            || not (String.for_all id_char source)
            || String.length digest <> 16
            || not (String.for_all hex digest)
            || String.length key = 0
          then malformed ()
          else Ok { Mentat_protocol.Command.source; digest; key })

let routine_name raw =
  if String.length raw = 0 then usage "routine name must not be empty"
  else if not (String.for_all id_char raw) then
    usage "routine name must contain only letters, digits, '.', '_', or '-'"
  else if Char.equal raw.[0] '.' then
    usage "routine name must not open with a dot"
  else Ok raw

let config_key raw =
  match Mentat_config.Field.of_string raw with
  | Ok field -> Ok field
  | Error e ->
      Error
        (Exit_status.usage
           (Mentat_diagnostic.to_string (Mentat_config.Error.diagnostic e)))

let provider ~known raw =
  let want = Mentat_llm.Provider.make raw in
  if List.exists (Mentat_llm.Provider.equal want) known then Ok want
  else
    usage
      (Printf.sprintf "unknown provider %S; known providers: %s" raw
         (String.concat ", " (List.map Mentat_llm.Provider.id known)))
