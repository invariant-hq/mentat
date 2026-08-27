(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Output = Mentat_tools_output
module Tool = Mentat_tool
module Json = Jsont.Json

let json_value = Testable.make ~pp:Json.pp ~equal:Json.equal
let semantic_equal codec a b = Json.equal (encode codec a) (encode codec b)

let expect_round_trip ~msg codec value =
  let live =
    Output.Codec.encode codec ~text:"authoritative body" ~truncated:true value
  in
  let replayed = decode Tool.Output.jsont (encode Tool.Output.jsont live) in
  match Output.Codec.decode codec replayed with
  | None -> failf "%s: semantic value was lost" msg
  | Some decoded ->
      is_true ~msg (semantic_equal codec value decoded);
      equal string ~msg:(msg ^ ": text") "authoritative body"
        (Tool.Output.text replayed);
      is_true ~msg:(msg ^ ": truncation") (Tool.Output.truncated replayed)

let constructors =
  group "constructors"
    [
      test "OCaml query facts enforce their compact bounds" (fun () ->
          expect_invalid_arg "empty type head" (fun () ->
              Output.Ocaml.Type_at.make ~head:"" ~more:0);
          expect_invalid_arg "multiline type head" (fun () ->
              Output.Ocaml.Type_at.make ~head:"int\nstring" ~more:0);
          expect_invalid_arg "oversized type head" (fun () ->
              Output.Ocaml.Type_at.make
                ~head:
                  (String.make (Output.Ocaml.Type_at.max_head_bytes + 1) 'a')
                ~more:0);
          expect_invalid_arg "definition line" (fun () ->
              Output.Ocaml.Definition.make ~path:"a.ml" ~line:0);
          expect_invalid_arg "reference files exceed references" (fun () ->
              Output.Ocaml.References.make ~references:1 ~files:2);
          expect_invalid_arg "documentation values" (fun () ->
              Output.Ocaml.Docs.make ~values:(-1) ~types:0 ~modules:0);
          expect_invalid_arg "rename files exceed occurrences" (fun () ->
              Output.Ocaml.Rename.make ~disposition:Output.Ocaml.Rename.Applied
                ~occurrences:1 ~files:2);
          expect_invalid_arg "empty rename" (fun () ->
              Output.Ocaml.Rename.make ~disposition:Output.Ocaml.Rename.Applied
                ~occurrences:0 ~files:0));
    ]

let codecs =
  group "durable codecs"
    [
      test "every shared semantic family survives Tool.Output storage"
        (fun () ->
          expect_round_trip ~msg:"read" Output.Read.jsont
            (Output.Read.file ~lines:12);
          expect_round_trip ~msg:"search" Output.Search.jsont
            (Output.Search.matches ~total:7 ~files:3);
          expect_round_trip ~msg:"write" Output.Write.jsont
            (Output.Write.wrote ~lines:4);
          expect_round_trip ~msg:"update" Output.Update.jsont
            (Output.Update.make ~disposition:Output.Update.Previewed ~files:2
               ~additions:(Some 8) ~deletions:(Some 3) ~skipped:1);
          expect_round_trip ~msg:"process" Output.Process.jsont
            (Output.Process.make
               ~termination:
                 (Output.Process.Output_limit
                    { stream = Output.Process.Stderr; limit = 65_536 })
               ~duration_ms:15);
          expect_round_trip ~msg:"platform signal" Output.Process.jsont
            (Output.Process.make ~termination:(Output.Process.Signaled 0)
               ~duration_ms:3);
          expect_round_trip ~msg:"type_at" Output.Ocaml.Type_at.jsont
            (Output.Ocaml.Type_at.make ~head:"int -> string" ~more:2);
          expect_round_trip ~msg:"definition" Output.Ocaml.Definition.jsont
            (Output.Ocaml.Definition.make ~path:"lib/a.ml" ~line:7);
          expect_round_trip ~msg:"references" Output.Ocaml.References.jsont
            (Output.Ocaml.References.make ~references:9 ~files:4);
          expect_round_trip ~msg:"docs" Output.Ocaml.Docs.jsont
            (Output.Ocaml.Docs.make ~values:3 ~types:2 ~modules:1);
          expect_round_trip ~msg:"rename" Output.Ocaml.Rename.jsont
            (Output.Ocaml.Rename.make ~disposition:Output.Ocaml.Rename.Previewed
               ~occurrences:7 ~files:3));
      test "decoding rejects absent and unsupported summary facts" (fun () ->
          let plain = Tool.Output.make ~text:"plain" () in
          equal bool ~msg:"absent JSON" true
            (Option.is_none (Output.Codec.decode Output.Read.jsont plain));
          let wrong_version =
            Tool.Output.make ~text:"plain"
              ~json:
                (json_object
                   [
                     ("version", Json.int 2);
                     ("shape", Json.string "file");
                     ("count", Json.int 1);
                   ])
              ()
          in
          equal bool ~msg:"unsupported version" true
            (Option.is_none
               (Output.Codec.decode Output.Read.jsont wrong_version));
          let unknown_member =
            Tool.Output.make ~text:"plain"
              ~json:
                (json_object
                   [
                     ("version", Json.int 1);
                     ("shape", Json.string "unchanged");
                     ("body", Json.string "must not decode");
                   ])
              ()
          in
          equal bool ~msg:"unknown member" true
            (Option.is_none
               (Output.Codec.decode Output.Read.jsont unknown_member)));
      test "read summary facts do not duplicate preview text" (fun () ->
          let output =
            Output.Codec.encode Output.Read.jsont
              ~text:"note.txt lines=1-2\n1\talpha\n2\tbravo\n"
              (Output.Read.file ~lines:2)
          in
          let actual =
            match Tool.Output.json output with
            | Some json -> json
            | None -> fail "encoded read output has no compact JSON"
          in
          let expected =
            json_object
              [
                ("version", Json.int 1);
                ("shape", Json.string "file");
                ("count", Json.int 2);
              ]
          in
          equal json_value ~msg:"compact read JSON" expected actual);
    ]

(* Exhaustive compact-codec laws, merged from the former expect suite
   mentat.tools.output: every variant round-trips, decoders reapply their
   constructor invariants, and the durable Tool.Output envelope never
   duplicates authoritative text. *)

let decode_rejects codec json =
  match Json.decode codec json with Ok _ -> false | Error _ -> true

let map_object_member wanted replace = function
  | Jsont.Object (members, _) ->
      members
      |> List.map (fun (((name, _) as encoded_name), value) ->
          if String.equal name wanted then
            Json.mem (Json.name name) (replace value)
          else (encoded_name, value))
      |> Json.object'
  | Jsont.Array _ | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _
  | Jsont.String _ ->
      failf "compact codec encoded a non-object root"

let replace_int_member name value json =
  map_object_member name (fun _ -> Json.int value) json

let unsupported_version json = replace_int_member "version" 2 json

let add_unknown_member = function
  | Jsont.Object (members, _) ->
      Json.object' (Json.mem (Json.name "unexpected") (Json.int 0) :: members)
  | Jsont.Array _ | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _
  | Jsont.String _ ->
      failf "compact codec encoded a non-object root"

let equal_read left right =
  match (left, right) with
  | Output.Read.File { lines = left }, Output.Read.File { lines = right } ->
      left = right
  | ( Output.Read.Listing { entries = left },
      Output.Read.Listing { entries = right } ) ->
      left = right
  | Output.Read.Image, Output.Read.Image
  | Output.Read.Unchanged, Output.Read.Unchanged ->
      true
  | ( ( Output.Read.File _ | Output.Read.Listing _ | Output.Read.Image
      | Output.Read.Unchanged ),
      _ ) ->
      false

let equal_search left right =
  match (left, right) with
  | Output.Search.Files { total = left }, Output.Search.Files { total = right }
  | ( Output.Search.Matching_lines { total = left },
      Output.Search.Matching_lines { total = right } ) ->
      left = right
  | ( Output.Search.Matches { total = left_total; files = left_files },
      Output.Search.Matches { total = right_total; files = right_files } ) ->
      left_total = right_total && left_files = right_files
  | ( ( Output.Search.Files _ | Output.Search.Matches _
      | Output.Search.Matching_lines _ ),
      _ ) ->
      false

let equal_write left right =
  match (left, right) with
  | Output.Write.Wrote { lines = left }, Output.Write.Wrote { lines = right } ->
      left = right
  | Output.Write.Unchanged, Output.Write.Unchanged -> true
  | (Output.Write.Wrote _ | Output.Write.Unchanged), _ -> false

let equal_update left right =
  Output.Update.disposition left = Output.Update.disposition right
  && Output.Update.files left = Output.Update.files right
  && Output.Update.additions left = Output.Update.additions right
  && Output.Update.deletions left = Output.Update.deletions right
  && Output.Update.skipped left = Output.Update.skipped right

let equal_process left right =
  Output.Process.termination left = Output.Process.termination right
  && Output.Process.duration_ms left = Output.Process.duration_ms right

let equal_definition left right =
  String.equal
    (Output.Ocaml.Definition.path left)
    (Output.Ocaml.Definition.path right)
  && Output.Ocaml.Definition.line left = Output.Ocaml.Definition.line right

let equal_references left right =
  Output.Ocaml.References.references left
  = Output.Ocaml.References.references right
  && Output.Ocaml.References.files left = Output.Ocaml.References.files right

let equal_docs left right =
  Output.Ocaml.Docs.values left = Output.Ocaml.Docs.values right
  && Output.Ocaml.Docs.types left = Output.Ocaml.Docs.types right
  && Output.Ocaml.Docs.modules left = Output.Ocaml.Docs.modules right

let equal_type_at left right =
  String.equal
    (Output.Ocaml.Type_at.head left)
    (Output.Ocaml.Type_at.head right)
  && Output.Ocaml.Type_at.more left = Output.Ocaml.Type_at.more right

type sample =
  | Sample : {
      name : string;
      codec : 'a Jsont.t;
      value : 'a;
      equal : 'a -> 'a -> bool;
    }
      -> sample

type rejected = Reject : 'a Jsont.t * Jsont.json -> rejected

let samples =
  [
    Sample
      {
        name = "read file zero";
        codec = Output.Read.jsont;
        value = Output.Read.file ~lines:0;
        equal = equal_read;
      };
    Sample
      {
        name = "read listing";
        codec = Output.Read.jsont;
        value = Output.Read.listing ~entries:7;
        equal = equal_read;
      };
    Sample
      {
        name = "read unchanged";
        codec = Output.Read.jsont;
        value = Output.Read.unchanged;
        equal = equal_read;
      };
    Sample
      {
        name = "search files";
        codec = Output.Search.jsont;
        value = Output.Search.files ~total:4;
        equal = equal_search;
      };
    Sample
      {
        name = "search empty matches";
        codec = Output.Search.jsont;
        value = Output.Search.matches ~total:0 ~files:0;
        equal = equal_search;
      };
    Sample
      {
        name = "search matches";
        codec = Output.Search.jsont;
        value = Output.Search.matches ~total:8 ~files:3;
        equal = equal_search;
      };
    Sample
      {
        name = "search matching lines";
        codec = Output.Search.jsont;
        value = Output.Search.matching_lines ~total:5;
        equal = equal_search;
      };
    Sample
      {
        name = "write wrote";
        codec = Output.Write.jsont;
        value = Output.Write.wrote ~lines:9;
        equal = equal_write;
      };
    Sample
      {
        name = "write unchanged";
        codec = Output.Write.jsont;
        value = Output.Write.unchanged;
        equal = equal_write;
      };
    Sample
      {
        name = "update applied";
        codec = Output.Update.jsont;
        value =
          Output.Update.make ~disposition:Output.Update.Applied ~files:2
            ~additions:(Some 4) ~deletions:(Some 1) ~skipped:0;
        equal = equal_update;
      };
    Sample
      {
        name = "update preview unknown deltas";
        codec = Output.Update.jsont;
        value =
          Output.Update.make ~disposition:Output.Update.Previewed ~files:0
            ~additions:None ~deletions:None ~skipped:3;
        equal = equal_update;
      };
    Sample
      {
        name = "process exited";
        codec = Output.Process.jsont;
        value =
          Output.Process.make ~termination:(Output.Process.Exited 0)
            ~duration_ms:1;
        equal = equal_process;
      };
    Sample
      {
        name = "process signed signal";
        codec = Output.Process.jsont;
        value =
          Output.Process.make ~termination:(Output.Process.Signaled (-9))
            ~duration_ms:2;
        equal = equal_process;
      };
    Sample
      {
        name = "process timed out";
        codec = Output.Process.jsont;
        value =
          Output.Process.make ~termination:Output.Process.Timed_out
            ~duration_ms:3;
        equal = equal_process;
      };
    Sample
      {
        name = "process stopped";
        codec = Output.Process.jsont;
        value =
          Output.Process.make ~termination:Output.Process.Stopped ~duration_ms:4;
        equal = equal_process;
      };
    Sample
      {
        name = "process stdout limit";
        codec = Output.Process.jsont;
        value =
          Output.Process.make
            ~termination:
              (Output.Process.Output_limit
                 { stream = Output.Process.Stdout; limit = 0 })
            ~duration_ms:5;
        equal = equal_process;
      };
    Sample
      {
        name = "process stderr limit";
        codec = Output.Process.jsont;
        value =
          Output.Process.make
            ~termination:
              (Output.Process.Output_limit
                 { stream = Output.Process.Stderr; limit = 64 })
            ~duration_ms:6;
        equal = equal_process;
      };
    Sample
      {
        name = "process supervision failure";
        codec = Output.Process.jsont;
        value =
          Output.Process.make ~termination:Output.Process.Supervision_failed
            ~duration_ms:7;
        equal = equal_process;
      };
    Sample
      {
        name = "definition";
        codec = Output.Ocaml.Definition.jsont;
        value = Output.Ocaml.Definition.make ~path:"lib/example.ml" ~line:1;
        equal = equal_definition;
      };
    Sample
      {
        name = "references empty";
        codec = Output.Ocaml.References.jsont;
        value = Output.Ocaml.References.make ~references:0 ~files:0;
        equal = equal_references;
      };
    Sample
      {
        name = "references";
        codec = Output.Ocaml.References.jsont;
        value = Output.Ocaml.References.make ~references:7 ~files:2;
        equal = equal_references;
      };
    Sample
      {
        name = "docs";
        codec = Output.Ocaml.Docs.jsont;
        value = Output.Ocaml.Docs.make ~values:3 ~types:2 ~modules:1;
        equal = equal_docs;
      };
    Sample
      {
        name = "type at";
        codec = Output.Ocaml.Type_at.jsont;
        value = Output.Ocaml.Type_at.make ~head:"'a list" ~more:2;
        equal = equal_type_at;
      };
    Sample
      {
        name = "type at byte bound";
        codec = Output.Ocaml.Type_at.jsont;
        value =
          Output.Ocaml.Type_at.make
            ~head:(String.make Output.Ocaml.Type_at.max_head_bytes 'x')
            ~more:0;
        equal = equal_type_at;
      };
    (* Appended so the position-indexed [representatives] below keep pointing at
       their intended samples. *)
    Sample
      {
        name = "read image";
        codec = Output.Read.jsont;
        value = Output.Read.image;
        equal = equal_read;
      };
  ]

let representatives =
  [
    List.nth samples 0;
    List.nth samples 3;
    List.nth samples 7;
    List.nth samples 9;
    List.nth samples 11;
    List.nth samples 18;
    List.nth samples 19;
    List.nth samples 21;
    List.nth samples 22;
  ]

let invalid_decodes =
  [
    ("read negative count", List.nth representatives 0, "count", -1);
    ("search negative total", List.nth representatives 1, "total", -1);
    ("write negative lines", List.nth representatives 2, "lines", -1);
    ("update negative files", List.nth representatives 3, "files", -1);
    ("process negative duration", List.nth representatives 4, "duration_ms", -1);
    ("definition line zero", List.nth representatives 5, "line", 0);
    ("references negative count", List.nth representatives 6, "references", -1);
    ("docs negative count", List.nth representatives 7, "values", -1);
    ("type-at negative count", List.nth representatives 8, "more", -1);
  ]

let compact_codecs =
  group "compact output codecs (exhaustive)"
    [
      test "every compact variant has a semantic and canonical JSON round-trip"
        (fun () ->
          List.iter
            (fun (Sample sample) ->
              let encoded = encode sample.codec sample.value in
              let decoded = decode sample.codec encoded in
              if not (sample.equal sample.value decoded) then
                failf "%s changed meaning across a JSON round-trip" sample.name;
              let encoded_again = encode sample.codec decoded in
              if not (Json.equal encoded encoded_again) then
                failf "%s changed canonical JSON across a round-trip"
                  sample.name)
            samples);
      test "every compact codec rejects unknown members and other versions"
        (fun () ->
          List.iter
            (fun (Sample sample) ->
              let encoded = encode sample.codec sample.value in
              if not (decode_rejects sample.codec (add_unknown_member encoded))
              then failf "%s accepted an unknown member" sample.name;
              if not (decode_rejects sample.codec (unsupported_version encoded))
              then failf "%s accepted version 2" sample.name)
            representatives);
      test "codec decoders reapply constructor invariants" (fun () ->
          List.iter
            (fun (label, Sample sample, member, value) ->
              let encoded = encode sample.codec sample.value in
              let invalid = replace_int_member member value encoded in
              if not (decode_rejects sample.codec invalid) then
                failf "%s was accepted" label)
            invalid_decodes);
      test "constructors reject every invalid count and cross-field relation"
        (fun () ->
          let cases =
            [
              ("read file", fun () -> ignore (Output.Read.file ~lines:(-1)));
              ( "read listing",
                fun () -> ignore (Output.Read.listing ~entries:(-1)) );
              ( "search files",
                fun () -> ignore (Output.Search.files ~total:(-1)) );
              ( "search match total",
                fun () -> ignore (Output.Search.matches ~total:(-1) ~files:0) );
              ( "search match files",
                fun () -> ignore (Output.Search.matches ~total:0 ~files:(-1)) );
              ( "search files exceed matches",
                fun () -> ignore (Output.Search.matches ~total:1 ~files:2) );
              ( "search matching lines",
                fun () -> ignore (Output.Search.matching_lines ~total:(-1)) );
              ("write lines", fun () -> ignore (Output.Write.wrote ~lines:(-1)));
              ( "update files",
                fun () ->
                  ignore
                    (Output.Update.make ~disposition:Output.Update.Applied
                       ~files:(-1) ~additions:None ~deletions:None ~skipped:0)
              );
              ( "update additions",
                fun () ->
                  ignore
                    (Output.Update.make ~disposition:Output.Update.Applied
                       ~files:0 ~additions:(Some (-1)) ~deletions:None
                       ~skipped:0) );
              ( "update deletions",
                fun () ->
                  ignore
                    (Output.Update.make ~disposition:Output.Update.Applied
                       ~files:0 ~additions:None ~deletions:(Some (-1))
                       ~skipped:0) );
              ( "update skipped",
                fun () ->
                  ignore
                    (Output.Update.make ~disposition:Output.Update.Applied
                       ~files:0 ~additions:None ~deletions:None ~skipped:(-1))
              );
              ( "process duration",
                fun () ->
                  ignore
                    (Output.Process.make ~termination:Output.Process.Timed_out
                       ~duration_ms:(-1)) );
              ( "process exit",
                fun () ->
                  ignore
                    (Output.Process.make
                       ~termination:(Output.Process.Exited (-1)) ~duration_ms:0)
              );
              ( "process output limit",
                fun () ->
                  ignore
                    (Output.Process.make
                       ~termination:
                         (Output.Process.Output_limit
                            { stream = Output.Process.Stdout; limit = -1 })
                       ~duration_ms:0) );
              ( "definition path",
                fun () -> ignore (Output.Ocaml.Definition.make ~path:"" ~line:1)
              );
              ( "definition line",
                fun () ->
                  ignore (Output.Ocaml.Definition.make ~path:"a.ml" ~line:0) );
              ( "reference count",
                fun () ->
                  ignore
                    (Output.Ocaml.References.make ~references:(-1) ~files:0) );
              ( "reference files",
                fun () ->
                  ignore
                    (Output.Ocaml.References.make ~references:0 ~files:(-1)) );
              ( "reference files exceed references",
                fun () ->
                  ignore (Output.Ocaml.References.make ~references:1 ~files:2)
              );
              ( "docs values",
                fun () ->
                  ignore
                    (Output.Ocaml.Docs.make ~values:(-1) ~types:0 ~modules:0) );
              ( "docs types",
                fun () ->
                  ignore
                    (Output.Ocaml.Docs.make ~values:0 ~types:(-1) ~modules:0) );
              ( "docs modules",
                fun () ->
                  ignore
                    (Output.Ocaml.Docs.make ~values:0 ~types:0 ~modules:(-1)) );
              ( "type-at empty head",
                fun () -> ignore (Output.Ocaml.Type_at.make ~head:"" ~more:0) );
              ( "type-at oversized head",
                fun () ->
                  ignore
                    (Output.Ocaml.Type_at.make
                       ~head:
                         (String.make
                            (Output.Ocaml.Type_at.max_head_bytes + 1)
                            'x')
                       ~more:0) );
              ( "type-at malformed UTF-8",
                fun () ->
                  ignore (Output.Ocaml.Type_at.make ~head:"\255" ~more:0) );
              ( "type-at line feed",
                fun () ->
                  ignore (Output.Ocaml.Type_at.make ~head:"a\nb" ~more:0) );
              ( "type-at carriage return",
                fun () ->
                  ignore (Output.Ocaml.Type_at.make ~head:"a\rb" ~more:0) );
              ( "type-at remaining frames",
                fun () ->
                  ignore (Output.Ocaml.Type_at.make ~head:"int" ~more:(-1)) );
            ]
          in
          List.iter (fun (label, make) -> expect_invalid_arg label make) cases);
      test "variant codecs reject inconsistent arm members" (fun () ->
          let invalid =
            [
              Reject
                ( Output.Read.jsont,
                  json_object
                    [
                      ("version", Json.int 1);
                      ("shape", Json.string "unchanged");
                      ("count", Json.int 1);
                    ] );
              Reject
                ( Output.Read.jsont,
                  json_object
                    [
                      ("version", Json.int 1);
                      ("shape", Json.string "image");
                      ("count", Json.int 1);
                    ] );
              Reject
                ( Output.Search.jsont,
                  json_object
                    [
                      ("version", Json.int 1);
                      ("shape", Json.string "files");
                      ("total", Json.int 1);
                      ("files", Json.int 1);
                    ] );
              Reject
                ( Output.Write.jsont,
                  json_object
                    [
                      ("version", Json.int 1);
                      ("shape", Json.string "unchanged");
                      ("lines", Json.int 1);
                    ] );
            ]
          in
          List.iter
            (fun (Reject (codec, json)) ->
              if not (decode_rejects codec json) then
                failf "a variant codec accepted members from another arm")
            invalid;
          let process_json =
            json_object
              [
                ("version", Json.int 1);
                ( "termination",
                  json_object
                    [ ("kind", Json.string "timed_out"); ("code", Json.int 0) ]
                );
                ("duration_ms", Json.int 1);
              ]
          in
          if not (decode_rejects Output.Process.jsont process_json) then
            failf "process timed_out accepted an exit code");
      test
        "codec preserves durable output and never duplicates authoritative text"
        (fun () ->
          let sentinel = "AUTHORITY_BODY_SENTINEL" in
          let semantic = Output.Read.file ~lines:3 in
          let output =
            Output.Codec.encode Output.Read.jsont ~text:sentinel ~truncated:true
              semantic
          in
          let semantic_json =
            match Tool.Output.json output with
            | Some json -> json
            | None -> failf "Codec.encode omitted semantic JSON"
          in
          let rec contains_sentinel = function
            | Jsont.String (value, _) -> String.equal value sentinel
            | Jsont.Object (members, _) ->
                List.exists (fun (_, value) -> contains_sentinel value) members
            | Jsont.Array (values, _) -> List.exists contains_sentinel values
            | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ -> false
          in
          if contains_sentinel semantic_json then
            failf "semantic JSON duplicated authoritative output text";
          let durable = encode Tool.Output.jsont output in
          let replay = decode Tool.Output.jsont durable in
          if not (Tool.Output.equal output replay) then
            failf "durable Output.jsont round-trip changed an output";
          if not (Tool.Output.truncated replay) then
            failf "durable Output.jsont round-trip lost truncation";
          match Output.Codec.decode Output.Read.jsont replay with
          | Some replay_semantic when equal_read semantic replay_semantic -> ()
          | Some _ -> failf "durable replay changed compact semantics"
          | None -> failf "durable replay lost compact semantics");
      test "codec fallback and construction failures remain explicit" (fun () ->
          let text_only = Tool.Output.make ~text:"text only" () in
          if Option.is_some (Output.Codec.decode Output.Read.jsont text_only)
          then failf "Codec.decode invented semantics for text-only output";
          let unsupported =
            Tool.Output.make ~text:"fallback"
              ~json:
                (json_object
                   [
                     ("version", Json.int 2); ("shape", Json.string "unchanged");
                   ])
              ()
          in
          if Option.is_some (Output.Codec.decode Output.Read.jsont unsupported)
          then failf "Codec.decode accepted unsupported semantics";
          expect_invalid_arg "empty authoritative text" (fun () ->
              Output.Codec.encode Output.Read.jsont ~text:""
                Output.Read.unchanged));
    ]

(* Web-fetch compact facts, merged from the former expect suite
   mentat.tools.output.web-fetch: closed-codec laws for [Web.Fetch]. *)

let equal_fetch left right =
  Output.Web.Fetch.disposition left = Output.Web.Fetch.disposition right
  && Output.Web.Fetch.status left = Output.Web.Fetch.status right
  && Output.Web.Fetch.bytes left = Output.Web.Fetch.bytes right

let fetch_rejects ~disposition ~status ~bytes =
  match Output.Web.Fetch.make ~disposition ~status ~bytes with
  | _ -> false
  | exception Invalid_argument _ -> true

let fetch_accepts json =
  match Json.decode Output.Web.Fetch.jsont json with
  | Ok _ -> true
  | Error _ -> false

let web_fetch =
  group "web fetch compact facts"
    [
      test "all web fetch dispositions have exact canonical round-trips"
        (fun () ->
          let check name value expected_json =
            let encoded = encode Output.Web.Fetch.jsont value in
            equal json_value
              ~msg:(name ^ ": canonical JSON")
              expected_json encoded;
            let decoded = decode Output.Web.Fetch.jsont encoded in
            is_true ~msg:(name ^ ": round-trip") (equal_fetch value decoded);
            is_true
              ~msg:(name ^ ": canonical stable")
              (Json.equal encoded (encode Output.Web.Fetch.jsont decoded))
          in
          check "fetched"
            (Output.Web.Fetch.make ~disposition:Output.Web.Fetch.Fetched
               ~status:200 ~bytes:17)
            (json_object
               [
                 ("version", Json.int 1);
                 ("disposition", Json.string "fetched");
                 ("status", Json.int 200);
                 ("bytes", Json.int 17);
               ]);
          check "redirected"
            (Output.Web.Fetch.make ~disposition:Output.Web.Fetch.Redirected
               ~status:308 ~bytes:0)
            (json_object
               [
                 ("version", Json.int 1);
                 ("disposition", Json.string "redirected");
                 ("status", Json.int 308);
                 ("bytes", Json.int 0);
               ]);
          check "http error"
            (Output.Web.Fetch.make ~disposition:Output.Web.Fetch.Http_error
               ~status:404 ~bytes:9)
            (json_object
               [
                 ("version", Json.int 1);
                 ("disposition", Json.string "http_error");
                 ("status", Json.int 404);
                 ("bytes", Json.int 9);
               ]));
      test "constructors enforce status, byte, and disposition laws" (fun () ->
          let open Output.Web.Fetch in
          is_false ~msg:"fetched lower bound"
            (fetch_rejects ~disposition:Fetched ~status:200 ~bytes:0);
          is_false ~msg:"fetched upper bound"
            (fetch_rejects ~disposition:Fetched ~status:299 ~bytes:0);
          is_true ~msg:"fetched non-2xx"
            (fetch_rejects ~disposition:Fetched ~status:404 ~bytes:0);
          is_false ~msg:"redirect lower bound"
            (fetch_rejects ~disposition:Redirected ~status:300 ~bytes:0);
          is_false ~msg:"redirect upper bound"
            (fetch_rejects ~disposition:Redirected ~status:399 ~bytes:0);
          is_true ~msg:"redirect non-3xx"
            (fetch_rejects ~disposition:Redirected ~status:200 ~bytes:0);
          is_true ~msg:"redirect nonzero bytes"
            (fetch_rejects ~disposition:Redirected ~status:302 ~bytes:1);
          is_false ~msg:"HTTP error informational"
            (fetch_rejects ~disposition:Http_error ~status:100 ~bytes:0);
          is_false ~msg:"HTTP error redirect"
            (fetch_rejects ~disposition:Http_error ~status:302 ~bytes:0);
          is_false ~msg:"HTTP error server"
            (fetch_rejects ~disposition:Http_error ~status:599 ~bytes:0);
          is_true ~msg:"HTTP error success"
            (fetch_rejects ~disposition:Http_error ~status:204 ~bytes:0);
          is_true ~msg:"status below HTTP range"
            (fetch_rejects ~disposition:Http_error ~status:99 ~bytes:0);
          is_true ~msg:"status above HTTP range"
            (fetch_rejects ~disposition:Http_error ~status:600 ~bytes:0);
          is_true ~msg:"negative bytes"
            (fetch_rejects ~disposition:Fetched ~status:200 ~bytes:(-1));
          is_false ~msg:"maximum safe bytes"
            (fetch_rejects ~disposition:Fetched ~status:200
               ~bytes:9_007_199_254_740_991);
          is_true ~msg:"unsafe bytes"
            (fetch_rejects ~disposition:Fetched ~status:200
               ~bytes:9_007_199_254_740_992));
      test "codec is closed and reapplies every constructor invariant"
        (fun () ->
          let valid =
            [
              ("version", Json.int 1);
              ("disposition", Json.string "fetched");
              ("status", Json.int 200);
              ("bytes", Json.int 3);
            ]
          in
          let with_member name value =
            json_object
              (List.map
                 (fun ((candidate, _) as member) ->
                   if String.equal name candidate then (name, value) else member)
                 valid)
          in
          is_true ~msg:"valid" (fetch_accepts (json_object valid));
          is_false ~msg:"version zero"
            (fetch_accepts (with_member "version" (Json.int 0)));
          is_false ~msg:"version two"
            (fetch_accepts (with_member "version" (Json.int 2)));
          is_false ~msg:"fractional version"
            (fetch_accepts (with_member "version" (Json.number 1.5)));
          is_false ~msg:"unsafe version"
            (fetch_accepts
               (with_member "version" (Json.number 9_007_199_254_740_992.)));
          is_false ~msg:"unknown disposition"
            (fetch_accepts (with_member "disposition" (Json.string "body")));
          is_false ~msg:"status below range"
            (fetch_accepts (with_member "status" (Json.int 99)));
          is_false ~msg:"status above range"
            (fetch_accepts (with_member "status" (Json.int 600)));
          is_false ~msg:"fractional status"
            (fetch_accepts (with_member "status" (Json.number 200.5)));
          is_false ~msg:"unsafe status"
            (fetch_accepts
               (with_member "status" (Json.number 9_007_199_254_740_992.)));
          is_false ~msg:"fetched non-2xx"
            (fetch_accepts (with_member "status" (Json.int 404)));
          is_false ~msg:"redirect nonzero bytes"
            (fetch_accepts
               (json_object
                  [
                    ("version", Json.int 1);
                    ("disposition", Json.string "redirected");
                    ("status", Json.int 302);
                    ("bytes", Json.int 1);
                  ]));
          is_false ~msg:"negative bytes"
            (fetch_accepts (with_member "bytes" (Json.int (-1))));
          is_false ~msg:"fractional bytes"
            (fetch_accepts (with_member "bytes" (Json.number 1.5)));
          is_false ~msg:"unsafe bytes"
            (fetch_accepts
               (with_member "bytes" (Json.number 9_007_199_254_740_992.)));
          is_false ~msg:"unknown member"
            (fetch_accepts
               (json_object (("unexpected", Json.bool true) :: valid)));
          is_false ~msg:"missing version"
            (fetch_accepts (json_object (List.tl valid)));
          is_false ~msg:"missing disposition"
            (fetch_accepts
               (json_object
                  (List.filter (fun (name, _) -> name <> "disposition") valid)));
          is_false ~msg:"missing status"
            (fetch_accepts
               (json_object
                  (List.filter (fun (name, _) -> name <> "status") valid)));
          is_false ~msg:"missing bytes"
            (fetch_accepts
               (json_object
                  (List.filter (fun (name, _) -> name <> "bytes") valid))));
      test "compact fetch facts contain no fetched or authority text" (fun () ->
          let fetched =
            Output.Web.Fetch.make ~disposition:Output.Web.Fetch.Fetched
              ~status:200 ~bytes:17
          in
          let encoded = encode Output.Web.Fetch.jsont fetched in
          let names =
            match encoded with
            | Jsont.Object (members, _) ->
                List.map (fun ((name, _), _) -> name) members
            | Jsont.Array _ | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _
            | Jsont.String _ ->
                fail "web fetch codec encoded a non-object root"
          in
          equal (list string) ~msg:"member names"
            [ "version"; "disposition"; "status"; "bytes" ]
            names;
          equal int ~msg:"status" 200 (Output.Web.Fetch.status fetched);
          equal int ~msg:"bytes" 17 (Output.Web.Fetch.bytes fetched);
          is_true ~msg:"disposition is fetched"
            (Output.Web.Fetch.disposition fetched = Output.Web.Fetch.Fetched));
    ]

(* Header-argument projection for built-in tool calls. Each built-in projects
   its salient input member by name; unknown tools and undecodable input project
   nothing, and an over-long projection is clipped to a bounded prefix. *)

let arrow = " \u{2192} "

let argument_projections =
  [
    ( "read file path",
      "read_file",
      json_object [ ("path", Json.string "lib/tui/app.ml") ],
      Some "lib/tui/app.ml" );
    ( "edit file path",
      "edit_file",
      json_object
        [
          ("path", Json.string "lib/tui/home.ml");
          ("old_string", Json.string "a");
          ("new_string", Json.string "b");
        ],
      Some "lib/tui/home.ml" );
    ( "write file path",
      "write_file",
      json_object
        [ ("path", Json.string "doc/notes.md"); ("contents", Json.string "x") ],
      Some "doc/notes.md" );
    ( "ocaml ast edit path",
      "ocaml_ast_edit",
      json_object [ ("path", Json.string "lib/a.ml"); ("edits", Json.list []) ],
      Some "lib/a.ml" );
    ( "search pattern and paths",
      "search_text",
      json_object
        [
          ("pattern", Json.string "notice_block");
          ("paths", Json.list [ Json.string "lib/tui" ]);
        ],
      Some "\"notice_block\" in lib/tui" );
    ( "search pattern only",
      "search_text",
      json_object [ ("pattern", Json.string "foo") ],
      Some "\"foo\"" );
    ( "ocaml search pattern and paths",
      "ocaml_search_expressions",
      json_object
        [
          ("pattern", Json.string "List.map __");
          ("paths", Json.list [ Json.string "lib"; Json.string "bin" ]);
        ],
      Some "\"List.map __\" in lib, bin" );
    ( "glob pattern",
      "glob",
      json_object [ ("pattern", Json.string "**/12-home.md") ],
      Some "**/12-home.md" );
    ( "glob pattern in path",
      "glob",
      json_object
        [ ("pattern", Json.string "*.ml"); ("path", Json.string "lib/tui") ],
      Some "*.ml in lib/tui" );
    ( "shell command",
      "shell",
      json_object [ ("command", Json.string "dune build lib/tui") ],
      Some "dune build lib/tui" );
    ( "shell output handle",
      "shell_output",
      json_object [ ("handle", Json.string "job-1") ],
      Some "job-1" );
    ( "shell kill handle",
      "shell_kill",
      json_object [ ("handle", Json.string "job-2") ],
      Some "job-2" );
    ( "web fetch url",
      "web_fetch",
      json_object [ ("url", Json.string "https://example.com/a") ],
      Some "https://example.com/a" );
    ( "web search query",
      "web_search",
      json_object [ ("query", Json.string "ocaml eio") ],
      Some "\"ocaml eio\"" );
    ( "ocaml replace pattern and template",
      "ocaml_replace_expressions",
      json_object
        [
          ("pattern", Json.string "old_fn __x");
          ("template", Json.string "new_fn __x");
        ],
      Some ("old_fn __x" ^ arrow ^ "new_fn __x") );
    ( "ocaml rename location and name",
      "ocaml_rename",
      json_object
        [
          ("path", Json.string "lib/a.ml");
          ("line", Json.int 42);
          ("column", Json.int 8);
          ("new_name", Json.string "render_home");
        ],
      Some ("lib/a.ml:42:8" ^ arrow ^ "render_home") );
    ( "ocaml eval code",
      "ocaml_eval",
      json_object [ ("code", Json.string "1 + 1") ],
      Some "1 + 1" );
    ( "ocaml docs query",
      "ocaml_docs",
      json_object [ ("query", Json.string "Mentat_llm.Event") ],
      Some "Mentat_llm.Event" );
    ( "ocaml type at location",
      "ocaml_type_at",
      json_object
        [
          ("path", Json.string "lib/a.ml");
          ("line", Json.int 3);
          ("column", Json.int 5);
        ],
      Some "lib/a.ml:3:5" );
    ( "ocaml find references location",
      "ocaml_find_references",
      json_object
        [
          ("path", Json.string "lib/a.ml");
          ("line", Json.int 7);
          ("column", Json.int 2);
        ],
      Some "lib/a.ml:7:2" );
    ( "ocaml find definitions identifier",
      "ocaml_find_definitions",
      json_object
        [
          ("path", Json.string "lib/a.ml");
          ("line", Json.int 7);
          ("column", Json.int 2);
          ("identifier", Json.string "render_home");
        ],
      Some "render_home" );
    ( "ocaml find definitions location fallback",
      "ocaml_find_definitions",
      json_object
        [
          ("path", Json.string "lib/a.ml");
          ("line", Json.int 7);
          ("column", Json.int 2);
        ],
      Some "lib/a.ml:7:2" );
    ( "skill name",
      "skill",
      json_object [ ("name", Json.string "ocaml-testing") ],
      Some "ocaml-testing" );
    ( "spawn description",
      "spawn",
      json_object
        [
          ("task", Json.string "explore the whole auth flow end to end");
          ("description", Json.string "explore auth");
        ],
      Some "explore auth" );
    ( "spawn task fallback",
      "spawn",
      json_object [ ("task", Json.string "explore the auth flow") ],
      Some "explore the auth flow" );
    ( "wait children",
      "wait",
      json_object
        [ ("children", Json.list [ Json.string "a"; Json.string "b" ]) ],
      Some "a, b" );
    ( "send message recipient",
      "send",
      json_object
        [
          ("to", Json.string "child:worker-1");
          ("message", Json.string "hi");
        ],
      Some "child:worker-1" );
    ( "follow up recipient",
      "follow_up",
      json_object
        [ ("child", Json.string "worker-2"); ("message", Json.string "more") ],
      Some "worker-2" );
    ( "apply patch has no member argument",
      "apply_patch",
      json_object [ ("patch", Json.string "*** Begin Patch\n*** End Patch\n") ],
      None );
    ( "todo write renders elsewhere",
      "todo_write",
      json_object [ ("tasks", Json.list []) ],
      None );
    ( "propose plan renders elsewhere",
      "propose_plan",
      json_object [ ("body", Json.string "plan body") ],
      None );
    ( "ask user renders elsewhere",
      "ask_user",
      json_object [ ("prompt", Json.string "which?") ],
      None );
    ( "unknown extension tool",
      "mcp__custom_do",
      json_object [ ("path", Json.string "lib/a.ml") ],
      None );
    ("non-object input", "read_file", Json.string "oops", None);
    ("missing required member", "read_file", json_object [], None);
    ( "empty string member is absent",
      "read_file",
      json_object [ ("path", Json.string "") ],
      None );
  ]

let argument_headlines =
  group "argument headlines"
    [
      test "each built-in projects its salient argument" (fun () ->
          List.iter
            (fun (msg, tool, input, expected) ->
              equal (option string) ~msg expected
                (Output.Argument.headline ~tool ~input))
            argument_projections);
      test "an over-long projection is clipped to a bounded prefix" (fun () ->
          let command = String.make 300 'a' in
          let input = json_object [ ("command", Json.string command) ] in
          match Output.Argument.headline ~tool:"shell" ~input with
          | None -> failf "shell command projected no argument"
          | Some projected ->
              is_true ~msg:"shorter than the input"
                (String.length projected < String.length command);
              is_true ~msg:"ends with an ellipsis"
                (String.length projected >= 3
                && String.equal
                     (String.sub projected (String.length projected - 3) 3)
                     "\u{2026}"));
    ]

let () =
  run "mentat.tools.output"
    [ constructors; codecs; compact_codecs; web_fetch; argument_headlines ]
