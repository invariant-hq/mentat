(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Severity = struct
  type t = P0 | P1 | P2 | P3

  let of_string = function
    | "P0" -> Some P0
    | "P1" -> Some P1
    | "P2" -> Some P2
    | "P3" -> Some P3
    | _ -> None

  let to_string = function P0 -> "P0" | P1 -> "P1" | P2 -> "P2" | P3 -> "P3"
  let rank = function P0 -> 0 | P1 -> 1 | P2 -> 2 | P3 -> 3
  let compare a b = Int.compare (rank a) (rank b)
end

module Body = struct
  type t = string

  let zero_width_space = "\xe2\x80\x8b"

  (* Break every ["<!--"] and ["-->"] with a zero width space between its two
     hyphens. After a break the scan resumes on the delimiter's last hyphen, so
     an overlapping occurrence (["<!--->"]) is broken too; every unvisited byte
     sits before an insertion that already splits any delimiter through it. The
     inserted bytes are non-ASCII, so no insertion assembles a new delimiter. *)
  let of_model_text s =
    let n = String.length s in
    let matches i pattern =
      let m = String.length pattern in
      i + m <= n && String.equal (String.sub s i m) pattern
    in
    let buffer = Buffer.create (n + 8) in
    let i = ref 0 in
    while !i < n do
      if matches !i "<!--" then (
        Buffer.add_string buffer "<!-";
        Buffer.add_string buffer zero_width_space;
        i := !i + 3)
      else if matches !i "-->" then (
        Buffer.add_char buffer '-';
        Buffer.add_string buffer zero_width_space;
        i := !i + 1)
      else (
        Buffer.add_char buffer s.[!i];
        incr i)
    done;
    Buffer.contents buffer

  let text t = t
end

module Error = struct
  type t = { context : string; reason : string }

  let make ~context reason = { context; reason }

  let message e =
    if String.equal e.context "" then e.reason
    else Printf.sprintf "%s: %s" e.context e.reason

  let pp ppf e = Format.pp_print_string ppf (message e)
end

type t = {
  severity : Severity.t;
  path : string;
  line : int;
  end_line : int option;
  anchor : string;
  title : string;
  body : Body.t;
}

module Fingerprint = struct
  type t = string

  (* [Mentat_digest.key] length-frames the domain and every part, so the input
     is injective over arbitrary member strings: no separator byte lives
     in-band for a crafted member to shift across a boundary. *)
  let of_finding ~path ~anchor ~title =
    Mentat_digest.key ~length:16 ~domain:"mentat.github.finding.v1"
      [ path; anchor; title ]

  let to_hex t = t
  let equal = String.equal
end

module Document = struct
  type nonrec t = { summary : string; findings : t list }

  let ( let* ) = Result.bind
  let error ~context reason = Error (Error.make ~context reason)

  let as_string ~context = function
    | Jsont.String (s, _) -> Ok s
    | _ -> error ~context "must be a string"

  let as_non_empty_string ~context json =
    let* s = as_string ~context json in
    if String.equal s "" then error ~context "must be a non-empty string"
    else Ok s

  (* [Jsont.Number] carries a float; accept only values that are an integer
     round-trip so an out-of-range magnitude cannot alias a valid line. *)
  let as_line ~context = function
    | Jsont.Number (v, _)
      when Float.is_integer v
           && Float.compare v 1.0 >= 0
           && Float.equal (float_of_int (int_of_float v)) v ->
        Ok (int_of_float v)
    | _ -> error ~context "must be a positive integer"

  (* Route each member of [mems] into its slot exactly once; an unlisted or
     repeated member is the caller's strictness error. *)
  let route_members ~context ~slots mems =
    List.fold_left
      (fun acc mem ->
        let* () = acc in
        let name = fst (fst mem) in
        match List.assoc_opt name slots with
        | None -> error ~context (Printf.sprintf "unknown member %S" name)
        | Some slot -> (
            match !slot with
            | Some _ ->
                error ~context (Printf.sprintf "duplicate member %S" name)
            | None ->
                slot := Some (snd mem);
                Ok ()))
      (Ok ()) mems

  let require ~context name slot =
    match !slot with
    | Some json -> Ok json
    | None -> error ~context (Printf.sprintf "missing member %S" name)

  let decode_finding ~index json =
    let context = Printf.sprintf "findings[%d]" index in
    let in_finding name = Printf.sprintf "%s.%s" context name in
    match json with
    | Jsont.Object (mems, _) ->
        let severity = ref None
        and path = ref None
        and line = ref None
        and end_line = ref None
        and anchor = ref None
        and title = ref None
        and body = ref None in
        let slots =
          [
            ("severity", severity);
            ("path", path);
            ("line", line);
            ("end_line", end_line);
            ("anchor", anchor);
            ("title", title);
            ("body", body);
          ]
        in
        let* () = route_members ~context ~slots mems in
        let* severity =
          let* json = require ~context "severity" severity in
          let* s = as_string ~context:(in_finding "severity") json in
          match Severity.of_string s with
          | Some severity -> Ok severity
          | None ->
              error ~context:(in_finding "severity")
                "must be one of P0, P1, P2, or P3"
        in
        let* path =
          let* json = require ~context "path" path in
          as_non_empty_string ~context:(in_finding "path") json
        in
        let* line =
          let* json = require ~context "line" line in
          as_line ~context:(in_finding "line") json
        in
        let* end_line =
          match !end_line with
          | None -> Ok None
          | Some json ->
              let* value = as_line ~context:(in_finding "end_line") json in
              if value < line then
                error ~context:(in_finding "end_line")
                  (Printf.sprintf "must not precede line %d" line)
              else Ok (Some value)
        in
        let* anchor =
          let* json = require ~context "anchor" anchor in
          let* anchor = as_non_empty_string ~context:(in_finding "anchor") json in
          if String.equal (String.trim anchor) "" then
            error ~context:(in_finding "anchor") "must not be only whitespace"
          else Ok anchor
        in
        let* title =
          let* json = require ~context "title" title in
          as_non_empty_string ~context:(in_finding "title") json
        in
        let* body =
          let* json = require ~context "body" body in
          as_string ~context:(in_finding "body") json
        in
        Ok
          {
            severity;
            path;
            line;
            end_line;
            anchor;
            title = Body.text (Body.of_model_text title);
            body = Body.of_model_text body;
          }
    | _ -> error ~context "must be an object"

  let decode bytes =
    match Jsont_bytesrw.decode_string Jsont.json bytes with
    | Error reason -> error ~context:"" reason
    | Ok (Jsont.Object (mems, _)) ->
        let summary = ref None and findings = ref None in
        let slots = [ ("summary", summary); ("findings", findings) ] in
        let* () = route_members ~context:"" ~slots mems in
        let* summary =
          let* json = require ~context:"" "summary" summary in
          as_string ~context:"summary" json
        in
        let* findings =
          let* json = require ~context:"" "findings" findings in
          match json with
          | Jsont.Array (elements, _) ->
              let* _, reversed =
                List.fold_left
                  (fun acc element ->
                    let* index, reversed = acc in
                    let* finding = decode_finding ~index element in
                    Ok (index + 1, finding :: reversed))
                  (Ok (0, []))
                  elements
              in
              Ok (List.rev reversed)
          | _ -> error ~context:"findings" "must be an array"
        in
        Ok { summary; findings }
    | Ok _ -> error ~context:"" "document must be a JSON object"

  let schema =
    let mem name value = Jsont.Json.mem (Jsont.Json.name name) value in
    let obj mems = Jsont.Json.object' mems in
    let str s = Jsont.Json.string s in
    let strings ss = Jsont.Json.list (List.map str ss) in
    let string_schema = obj [ mem "type" (str "string") ] in
    let integer_schema = obj [ mem "type" (str "integer") ] in
    let finding =
      obj
        [
          mem "type" (str "object");
          mem "properties"
            (obj
               [
                 mem "severity"
                   (obj
                      [
                        mem "type" (str "string");
                        mem "enum" (strings [ "P0"; "P1"; "P2"; "P3" ]);
                      ]);
                 mem "path" string_schema;
                 mem "line" integer_schema;
                 mem "end_line" integer_schema;
                 mem "anchor" string_schema;
                 mem "title" string_schema;
                 mem "body" string_schema;
               ]);
          mem "required"
            (strings [ "severity"; "path"; "line"; "anchor"; "title"; "body" ]);
          mem "additionalProperties" (Jsont.Json.bool false);
        ]
    in
    obj
      [
        mem "type" (str "object");
        mem "properties"
          (obj
             [
               mem "summary" string_schema;
               mem "findings"
                 (obj [ mem "type" (str "array"); mem "items" finding ]);
             ]);
        mem "required" (strings [ "summary"; "findings" ]);
        mem "additionalProperties" (Jsont.Json.bool false);
      ]
end
