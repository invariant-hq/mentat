(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Review_finding], the typed review-findings document. The
   module is pure — strict decode, schema value, body neutralization, and
   fingerprints — so everything is exercised on string payloads directly.

   The module lives in the private [mentat_connector] library under
   [bin/connector/]. *)

open Windtrap
open Mentat_connector
module Severity = Review_finding.Severity

let str_contains sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  n = 0 || go 0

let remove_all sub s =
  let n = String.length sub and m = String.length s in
  let buffer = Buffer.create m in
  let i = ref 0 in
  while !i < m do
    if !i + n <= m && String.equal (String.sub s !i n) sub then i := !i + n
    else (
      Buffer.add_char buffer s.[!i];
      incr i)
  done;
  Buffer.contents buffer

let conforming =
  {|{"summary":"two findings",
     "findings":[
       {"severity":"P0","path":"lib/a.ml","line":3,"end_line":5,
        "anchor":"let x = 1","title":"Uninitialized read","body":"Full text."},
       {"severity":"P3","path":"bin/b.ml","line":10,
        "anchor":"match y with","title":"Naming nit","body":""}]}|}

(* Schema. *)

let schema_is_admissible () =
  match Mentat_llm.Schema.of_json Review_finding.Document.schema with
  | Ok _ -> ()
  | Error e -> failf "schema rejected: %s" (Mentat_llm.Schema.Error.message e)

let schema_admits_what_decode_admits () =
  let schema =
    match Mentat_llm.Schema.of_json Review_finding.Document.schema with
    | Ok schema -> schema
    | Error e -> failf "schema rejected: %s" (Mentat_llm.Schema.Error.message e)
  in
  match Jsont_bytesrw.decode_string Jsont.json conforming with
  | Error reason -> failf "fixture is not JSON: %s" reason
  | Ok instance -> (
      match Mentat_llm.Schema.validate schema instance with
      | Ok () -> ()
      | Error violations ->
          failf "conforming instance violates the schema: %a"
            Mentat_llm.Schema.Violation.pp (List.hd violations))

(* Decode. *)

let finding members =
  Printf.sprintf {|{"summary":"s","findings":[{%s}]}|} members

let document_decodes () =
  match Review_finding.Document.decode conforming with
  | Error e -> failf "decode: %s" (Review_finding.Error.message e)
  | Ok { Review_finding.Document.summary; findings } -> (
      equal string ~msg:"summary" "two findings" summary;
      match findings with
      | [ first; second ] ->
          equal string ~msg:"first severity" "P0"
            (Severity.to_string first.Review_finding.severity);
          equal string ~msg:"first path" "lib/a.ml" first.Review_finding.path;
          equal int ~msg:"first line" 3 first.Review_finding.line;
          equal (option int) ~msg:"first end_line" (Some 5)
            first.Review_finding.end_line;
          equal string ~msg:"first anchor" "let x = 1"
            first.Review_finding.anchor;
          equal string ~msg:"first title" "Uninitialized read"
            first.Review_finding.title;
          equal string ~msg:"first body" "Full text."
            (Review_finding.Body.text first.Review_finding.body);
          equal string ~msg:"second severity" "P3"
            (Severity.to_string second.Review_finding.severity);
          equal (option int) ~msg:"end_line is optional" None
            second.Review_finding.end_line;
          equal string ~msg:"second body may be empty" ""
            (Review_finding.Body.text second.Review_finding.body)
      | findings -> failf "expected two findings, got %d" (List.length findings)
      )

let end_line_may_equal_line () =
  let payload =
    finding
      {|"severity":"P1","path":"a","line":7,"end_line":7,"anchor":"x",
        "title":"t","body":"b"|}
  in
  match Review_finding.Document.decode payload with
  | Error e -> failf "decode: %s" (Review_finding.Error.message e)
  | Ok { Review_finding.Document.findings = [ f ]; _ } ->
      equal (option int) ~msg:"end_line equal to line is accepted" (Some 7)
        f.Review_finding.end_line
  | Ok _ -> fail "expected exactly one finding"

let rejects ~msg ?expect payload =
  match Review_finding.Document.decode payload with
  | Ok _ -> failf "%s: decode accepted the payload" msg
  | Error e -> (
      let message = Review_finding.Error.message e in
      match expect with
      | None -> ()
      | Some needle ->
          if not (str_contains needle message) then
            failf "%s: message %S does not name %S" msg message needle)

let decode_is_strict () =
  rejects ~msg:"malformed JSON" "{";
  rejects ~msg:"non-object document" ~expect:"JSON object" "[]";
  rejects ~msg:"unknown document member" ~expect:{|unknown member "verdict"|}
    {|{"summary":"s","findings":[],"verdict":"red"}|};
  rejects ~msg:"missing summary" ~expect:{|missing member "summary"|}
    {|{"findings":[]}|};
  rejects ~msg:"missing findings" ~expect:{|missing member "findings"|}
    {|{"summary":"s"}|};
  rejects ~msg:"summary must be a string" ~expect:"summary: must be a string"
    {|{"summary":3,"findings":[]}|};
  rejects ~msg:"findings must be an array" ~expect:"findings: must be an array"
    {|{"summary":"s","findings":{}}|};
  rejects ~msg:"finding must be an object"
    ~expect:"findings[0]: must be an object" {|{"summary":"s","findings":[3]}|};
  rejects ~msg:"unknown finding member"
    ~expect:{|findings[0]: unknown member "note"|}
    (finding
       {|"severity":"P1","path":"a","line":1,"anchor":"x","title":"t",
         "body":"b","note":"n"|});
  rejects ~msg:"missing severity"
    ~expect:{|findings[0]: missing member "severity"|}
    (finding {|"path":"a","line":1,"anchor":"x","title":"t","body":"b"|});
  rejects ~msg:"missing anchor" ~expect:{|findings[0]: missing member "anchor"|}
    (finding {|"severity":"P1","path":"a","line":1,"title":"t","body":"b"|});
  rejects ~msg:"missing body" ~expect:{|findings[0]: missing member "body"|}
    (finding {|"severity":"P1","path":"a","line":1,"anchor":"x","title":"t"|});
  rejects ~msg:"unrecognized severity" ~expect:"findings[0].severity"
    (finding
       {|"severity":"P4","path":"a","line":1,"anchor":"x","title":"t",
         "body":"b"|});
  rejects ~msg:"severity is case-sensitive" ~expect:"findings[0].severity"
    (finding
       {|"severity":"p0","path":"a","line":1,"anchor":"x","title":"t",
         "body":"b"|});
  rejects ~msg:"severity must be a string"
    ~expect:"findings[0].severity: must be a string"
    (finding
       {|"severity":0,"path":"a","line":1,"anchor":"x","title":"t",
         "body":"b"|});
  rejects ~msg:"line zero"
    ~expect:"findings[0].line: must be a positive integer"
    (finding
       {|"severity":"P1","path":"a","line":0,"anchor":"x","title":"t",
         "body":"b"|});
  rejects ~msg:"line negative" ~expect:"findings[0].line"
    (finding
       {|"severity":"P1","path":"a","line":-2,"anchor":"x","title":"t",
         "body":"b"|});
  rejects ~msg:"line fractional" ~expect:"findings[0].line"
    (finding
       {|"severity":"P1","path":"a","line":2.5,"anchor":"x","title":"t",
         "body":"b"|});
  rejects ~msg:"line must be a number" ~expect:"findings[0].line"
    (finding
       {|"severity":"P1","path":"a","line":"3","anchor":"x","title":"t",
         "body":"b"|});
  rejects ~msg:"end_line below line"
    ~expect:"findings[0].end_line: must not precede line 3"
    (finding
       {|"severity":"P1","path":"a","line":3,"end_line":2,"anchor":"x",
         "title":"t","body":"b"|});
  rejects ~msg:"end_line must be an integer" ~expect:"findings[0].end_line"
    (finding
       {|"severity":"P1","path":"a","line":3,"end_line":"x","anchor":"x",
         "title":"t","body":"b"|});
  rejects ~msg:"empty path"
    ~expect:"findings[0].path: must be a non-empty string"
    (finding
       {|"severity":"P1","path":"","line":1,"anchor":"x","title":"t",
         "body":"b"|});
  rejects ~msg:"empty anchor" ~expect:"findings[0].anchor"
    (finding
       {|"severity":"P1","path":"a","line":1,"anchor":"","title":"t",
         "body":"b"|});
  rejects ~msg:"whitespace-only anchor"
    ~expect:"findings[0].anchor: must not be only whitespace"
    (finding
       {|"severity":"P1","path":"a","line":1,"anchor":"  ","title":"t",
         "body":"b"|});
  rejects ~msg:"empty title" ~expect:"findings[0].title"
    (finding
       {|"severity":"P1","path":"a","line":1,"anchor":"x","title":"",
         "body":"b"|});
  rejects ~msg:"duplicate member" ~expect:{|duplicate member "summary"|}
    {|{"summary":"a","summary":"b","findings":[]}|};
  rejects ~msg:"the error names the later finding" ~expect:"findings[1].line"
    {|{"summary":"s","findings":[
        {"severity":"P1","path":"a","line":1,"anchor":"x","title":"t",
         "body":"b"},
        {"severity":"P2","path":"a","line":0,"anchor":"x","title":"t",
         "body":"b"}]}|}

(* Body neutralization. *)

let zero_width_space = "\xe2\x80\x8b"

let body_neutralizes_delimiters () =
  let neutralize input =
    Review_finding.Body.text (Review_finding.Body.of_model_text input)
  in
  let check ~msg input =
    let text = neutralize input in
    if str_contains "<!--" text then failf "%s: %S keeps an opener" msg text;
    if str_contains "-->" text then failf "%s: %S keeps a closer" msg text
  in
  check ~msg:"comment marker" "pre <!-- mentat-review 0123abcd --> post";
  check ~msg:"opener alone" "<!--";
  check ~msg:"closer alone" "-->";
  check ~msg:"overlapping opener and closer" "<!--->";
  check ~msg:"hyphen runs" "----> <!----- --> ---><!--";
  check ~msg:"adjacent delimiters" "<!--<!---->-->";
  equal string ~msg:"plain text passes through unchanged"
    "no comment here: <! - -> - <-"
    (neutralize "no comment here: <! - -> - <-");
  let original = "a <!-- b --> c" in
  equal string ~msg:"only zero width spaces are inserted" original
    (remove_all zero_width_space (neutralize original))

let body_neutralized_through_decode () =
  let payload =
    finding
      {|"severity":"P2","path":"a","line":1,"anchor":"x",
        "title":"Evil <!-- forged --> title",
        "body":"pre <!-- mentat-review --> post"|}
  in
  match Review_finding.Document.decode payload with
  | Error e -> failf "decode: %s" (Review_finding.Error.message e)
  | Ok { Review_finding.Document.findings = [ f ]; _ } ->
      let text = Review_finding.Body.text f.Review_finding.body in
      is_true ~msg:"no opener survives decode" (not (str_contains "<!--" text));
      is_true ~msg:"no closer survives decode" (not (str_contains "-->" text));
      is_true ~msg:"the visible content survives"
        (str_contains "mentat-review" text);
      let title = f.Review_finding.title in
      is_true ~msg:"no opener survives in the title"
        (not (str_contains "<!--" title));
      is_true ~msg:"no closer survives in the title"
        (not (str_contains "-->" title));
      is_true ~msg:"the visible title content survives"
        (str_contains "forged" title)
  | Ok _ -> fail "expected exactly one finding"

(* Fingerprints. *)

let fingerprint_identity () =
  let of_finding = Review_finding.Fingerprint.of_finding in
  let fp = of_finding ~path:"lib/a.ml" ~anchor:"let x = 1" ~title:"T" in
  let hex = Review_finding.Fingerprint.to_hex fp in
  (* The derivation is a wire format: fingerprints persist in posted GitHub
     comments, so a silent change to the recipe would repost every thread. *)
  equal string ~msg:"pinned derivation" "60649336d5bc5a16" hex;
  equal int ~msg:"16 characters" 16 (String.length hex);
  is_true ~msg:"lowercase hexadecimal"
    (String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       hex);
  let again = of_finding ~path:"lib/a.ml" ~anchor:"let x = 1" ~title:"T" in
  is_true ~msg:"equal inputs are equal"
    (Review_finding.Fingerprint.equal fp again);
  equal string ~msg:"equal inputs render equally" hex
    (Review_finding.Fingerprint.to_hex again);
  let differs ~msg other =
    is_true ~msg (not (Review_finding.Fingerprint.equal fp other))
  in
  differs ~msg:"path moves the fingerprint"
    (of_finding ~path:"lib/b.ml" ~anchor:"let x = 1" ~title:"T");
  differs ~msg:"anchor moves the fingerprint"
    (of_finding ~path:"lib/a.ml" ~anchor:"let x = 2" ~title:"T");
  differs ~msg:"title moves the fingerprint"
    (of_finding ~path:"lib/a.ml" ~anchor:"let x = 1" ~title:"U")

let fingerprint_framing () =
  let of_finding = Review_finding.Fingerprint.of_finding in
  is_true ~msg:"bytes cannot shift from path into anchor"
    (not
       (Review_finding.Fingerprint.equal
          (of_finding ~path:"a|b" ~anchor:"c" ~title:"t")
          (of_finding ~path:"a" ~anchor:"b|c" ~title:"t")));
  is_true ~msg:"bytes cannot shift from anchor into title"
    (not
       (Review_finding.Fingerprint.equal
          (of_finding ~path:"p" ~anchor:"x|y" ~title:"z")
          (of_finding ~path:"p" ~anchor:"x" ~title:"y|z")));
  is_true ~msg:"empty members still separate"
    (not
       (Review_finding.Fingerprint.equal
          (of_finding ~path:"ab" ~anchor:"" ~title:"t")
          (of_finding ~path:"a" ~anchor:"b" ~title:"t")))

(* Severity. *)

let severity_ladder () =
  List.iter
    (fun name ->
      match Severity.of_string name with
      | Some severity ->
          equal string ~msg:(name ^ " round-trips") name
            (Severity.to_string severity)
      | None -> failf "%s did not parse" name)
    [ "P0"; "P1"; "P2"; "P3" ];
  is_true ~msg:"P4 does not parse" (Option.is_none (Severity.of_string "P4"));
  is_true ~msg:"lowercase does not parse"
    (Option.is_none (Severity.of_string "p0"));
  is_true ~msg:"empty does not parse" (Option.is_none (Severity.of_string ""));
  is_true ~msg:"P0 sorts first"
    (Severity.compare Severity.P0 Severity.P1 < 0
    && Severity.compare Severity.P1 Severity.P2 < 0
    && Severity.compare Severity.P2 Severity.P3 < 0);
  equal int ~msg:"compare is reflexive" 0
    (Severity.compare Severity.P2 Severity.P2)

(* Suite. *)

let () =
  run "mentat.review_finding"
    [
      test "the document schema is an admissible structured-output schema"
        schema_is_admissible;
      test "the schema admits what decode admits"
        schema_admits_what_decode_admits;
      test "a conforming document decodes fully" document_decodes;
      test "end_line may equal line" end_line_may_equal_line;
      test "decode rejects every departure from the contract" decode_is_strict;
      test "bodies neutralize HTML comment delimiters"
        body_neutralizes_delimiters;
      test "decode neutralizes bodies and titles"
        body_neutralized_through_decode;
      test "fingerprints are stable 16-hex identities" fingerprint_identity;
      test "fingerprint framing forbids cross-member collisions"
        fingerprint_framing;
      test "the severity ladder orders gravest first" severity_ladder;
    ]
