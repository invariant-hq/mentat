(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Mentat_llm
module Json = Jsont.Json
module Stop = Response.Stop

(* Assertion and codec helpers *)

let opaque name =
  Testable.make ~pp:(fun ppf _ -> Format.pp_print_string ppf name) ~equal:( = )

(* Only checks that [Invalid_argument] is raised, not its message, so tests do
   not couple to diagnostic wording. *)
let expect_invalid_arg msg f =
  match f () with
  | _ -> failf "%s: expected Invalid_argument" msg
  | exception Invalid_argument _ -> ()

let json_object fields =
  fields
  |> List.map (fun (name, value) -> Json.mem (Json.name name) value)
  |> Json.object'

let json_array values = Json.list values

let decode codec json =
  match Json.decode codec json with
  | Ok value -> value
  | Error message -> failf "decode failed: %s" message

let encode codec value =
  match Json.encode codec value with
  | Ok json -> json
  | Error message -> failf "encode failed: %s" message

(* A real text round-trip through Jsont's serializer, stronger than the generic
   JSON-tree round-trip: it serialises to a string and parses it back. *)
let encode_text codec value =
  match Jsont_bytesrw.encode_string codec value with
  | Ok s -> s
  | Error message -> failf "text encode failed: %s" message

let decode_text codec s =
  match Jsont_bytesrw.decode_string codec s with
  | Ok value -> value
  | Error message -> failf "text decode failed: %s" message

(* Like {!decode_text} but stamps JSON source locations onto the decoded tree
   ([~locs:true]). This is the decode a diagnostic-rich audit path would use,
   and it is what makes [input] JSON metadata observable: it distinguishes a
   decoded value from a constructed one under structural [(=)], so equality that
   claims to compare payloads must ignore it. *)
let decode_text_locs codec s =
  match Jsont_bytesrw.decode_string ~locs:true codec s with
  | Ok value -> value
  | Error message -> failf "text decode failed: %s" message

let roundtrip msg t codec value =
  equal ~msg t value (decode codec (encode codec value))

let expect_error msg result check =
  match result with
  | Ok _ -> failf "%s: expected Error" msg
  | Error error -> check error

let expect_decode_error msg codec json =
  match Json.decode codec json with
  | Ok _ -> failf "%s: expected decode error" msg
  | Error _ -> ()

let equal_json msg expected actual = is_true ~msg (Json.equal expected actual)

(* Testables *)

let provider_t = Testable.make ~pp:Provider.pp ~equal:Provider.equal
let api_t = Testable.make ~pp:Model.Api.pp ~equal:Model.Api.equal
let model_t = Testable.make ~pp:Model.pp ~equal:Model.equal
let usage_t = Testable.make ~pp:Usage.pp ~equal:Usage.equal
let error_t = Testable.make ~pp:Error.pp ~equal:Error.equal
let stop_t = Testable.make ~pp:Stop.pp ~equal:( = )

let call_t =
  Testable.make
    ~pp:(fun ppf _ -> Format.pp_print_string ppf "<call>")
    ~equal:Tool.Call.equal

let result_t =
  Testable.make
    ~pp:(fun ppf _ -> Format.pp_print_string ppf "<result>")
    ~equal:Tool.Result.equal

let message_t =
  Testable.make
    ~pp:(fun ppf _ -> Format.pp_print_string ppf "<message>")
    ~equal:Message.equal

let response_t =
  Testable.make
    ~pp:(fun ppf _ -> Format.pp_print_string ppf "<response>")
    ~equal:Response.equal

let digest_t = Testable.make ~pp:Mentat_digest.pp ~equal:Mentat_digest.equal
let transcript_error_t = Testable.make ~pp:Transcript.Error.pp ~equal:( = )
let request_error_t = Testable.make ~pp:Request.Error.pp ~equal:( = )
let phase_t = opaque "phase"

(* Fixtures *)

let schema =
  json_object
    [
      ("type", Json.string "object");
      ( "properties",
        json_object [ ("path", json_object [ ("type", Json.string "string") ]) ]
      );
      ("required", json_array [ Json.string "path" ]);
      ("additionalProperties", Json.bool false);
    ]

let empty_object = Json.object' []
let openai = Provider.make "openai"
let anthropic = Provider.make "anthropic"
let responses = Model.Api.make "responses"

let model ?(provider = openai) ?(api = responses) id =
  Model.make ~provider ~api ~id

let gpt = model "gpt-5"

let tool ?(name = "read_file") () =
  Tool.make ~name ~description:"Read a file." ~input_schema:schema ()

let call ?(id = "call_1") ?(name = "read_file") () =
  Tool.Call.make ~id ~name
    ~input:(json_object [ ("path", Json.string "a.ml") ])
    ()

let assistant_with_calls calls =
  Message.Assistant.make
    (Message.Assistant.text_part "I will use a tool."
    :: List.map Message.Assistant.tool_call calls)

let ready_transcript () =
  Transcript.of_list_exn
    [ Message.developer "You are Mentat."; Message.user_text "Refactor a.ml." ]

let response ?(assistant = Message.Assistant.text "Done.") () =
  Response.make ~model:gpt assistant

let user_request s =
  Request.make_exn ~model:gpt (Transcript.of_list_exn [ Message.user_text s ])

(* [Event.t] has no [equal] or [jsont]: events are non-durable, so
   they are compared through this projection to a tag+payload string. *)
let event_desc = function
  | Event.Text_delta s -> "text:" ^ s
  | Event.Reasoning_summary_delta s -> "reason:" ^ s
  | Event.Tool_input_delta d -> "tool_input:" ^ Event.Tool_input.key d
  | Event.Tool_call c -> "tool_call:" ^ Tool.Call.id c
  | Event.Usage u -> "usage:" ^ string_of_int u.Usage.input
  | Event.Retry r ->
      Printf.sprintf "retry:%d/%d in %gs (%s)" (Event.Retry.attempt r)
        (Event.Retry.limit r) (Event.Retry.delay r) (Event.Retry.reason r)

(* Generators.

   The let-syntax below builds [Gen.t] values without opening [Gen] (which would
   shadow the testable combinators [list], [string], etc.). *)

let ( let+ ) = Gen.( let+ )
let ( and+ ) = Gen.( and+ )
let ( let* ) = Gen.( let* )
let lower = Gen.char_range 'a' 'z'
let digit = Gen.char_range '0' '9'
let printable = Gen.char_range ' ' '~'

(* Non-empty, valid-UTF-8 (ASCII) text: safe for both JSON-tree and text
   round-trips. Byte-sensitivity over NUL and high bytes is exercised by
   dedicated example tests, not by generators, so serialisation cannot break. *)
let free_text = Gen.string_of ~size:(Gen.int_range 1 12) printable
let word = Gen.string_of ~size:(Gen.int_range 1 8) printable

(* NUL-weighted text, used only where the digest is computed directly (no JSON
   serialisation): windtrap's default char generator effectively never emits
   NUL, so it is given explicit weight here (repo convention for byte-sensitive
   properties). *)
let nul_text =
  Gen.string_of ~size:(Gen.int_range 1 12)
    (Gen.frequency [ (1, Gen.pure '\000'); (9, printable) ])

let provider_gen =
  let+ first = lower
  and+ rest =
    Gen.string_of ~size:(Gen.int_range 0 6)
      (Gen.frequency [ (5, lower); (2, digit); (1, Gen.pure '-') ])
  in
  Provider.make (String.make 1 first ^ rest)

let api_component =
  let+ first = lower
  and+ rest =
    Gen.string_of ~size:(Gen.int_range 0 4)
      (Gen.frequency [ (5, lower); (2, digit); (1, Gen.pure '-') ])
  in
  String.make 1 first ^ rest

let api_gen =
  let+ components = Gen.list ~size:(Gen.int_range 1 3) api_component in
  Model.Api.make (String.concat "." components)

let model_gen =
  let+ provider = provider_gen and+ api = api_gen and+ id = word in
  Model.make ~provider ~api ~id

let media_type = Gen.of_list [ "image/png"; "image/jpeg"; "application/pdf" ]

let content_gen =
  Gen.frequency
    [
      ( 3,
        let+ s = free_text in
        Content.text s );
      ( 1,
        let+ mt = media_type and+ u = word in
        Content.media ~media_type:mt (`Uri u) );
      ( 1,
        let+ mt = media_type and+ b = word in
        Content.media ~media_type:mt (`Base64 b) );
      ( 1,
        let+ mt = media_type and+ s = free_text in
        Content.media ~media_type:mt
          (`Ref (Mentat_digest.Content_ref.of_contents s)) );
    ]

let content_t =
  Testable.make
    ~pp:(fun ppf _ -> Format.pp_print_string ppf "<content>")
    ~equal:( = )

let tool_first = Gen.frequency [ (6, lower); (1, Gen.pure '_') ]

let tool_rest =
  Gen.frequency [ (6, lower); (1, digit); (1, Gen.pure '-'); (1, Gen.pure '_') ]

let tool_name_gen =
  let+ first = tool_first
  and+ rest = Gen.string_of ~size:(Gen.int_range 0 8) tool_rest in
  String.make 1 first ^ rest

let input_json_gen =
  Gen.frequency
    [
      (1, Gen.pure empty_object);
      ( 2,
        let+ i = Gen.int_range 0 9 in
        json_object [ ("i", Json.int i) ] );
      ( 2,
        let+ s = word in
        json_object [ ("path", Json.string s) ] );
    ]

let call_gen =
  let+ id = word
  and+ name = tool_name_gen
  and+ input = input_json_gen
  and+ signature = Gen.option word in
  Tool.Call.make ~id ~name ~input ?signature ()

let result_gen =
  let+ c = call_gen
  and+ error = Gen.bool
  and+ content = Gen.list ~size:(Gen.int_range 0 3) content_gen in
  Tool.Result.make ~error c content

let tool_gen =
  let+ name = tool_name_gen and+ description = Gen.option word in
  Tool.make ~name ?description ~input_schema:Tool.no_input_schema ()

let reasoning_gen =
  let field g present =
    if present then Gen.map Option.some g else Gen.pure None
  in
  let* mask = Gen.int_range 1 31 in
  let+ id = field word (mask land 1 <> 0)
  and+ summary = field free_text (mask land 2 <> 0)
  and+ text = field free_text (mask land 4 <> 0)
  and+ encrypted = field word (mask land 8 <> 0)
  and+ signature = field word (mask land 16 <> 0) in
  Message.Assistant.Reasoning.make ?id ?summary ?text ?encrypted ?signature ()

let assistant_part_gen =
  Gen.frequency
    [
      ( 3,
        let+ s = free_text in
        Message.Assistant.text_part s );
      ( 1,
        let+ c = call_gen in
        Message.Assistant.tool_call c );
      ( 1,
        let+ r = reasoning_gen in
        Message.Assistant.reasoning_part r );
    ]

let assistant_gen =
  Gen.frequency
    [
      (1, Gen.pure Message.Assistant.empty);
      ( 5,
        let+ parts = Gen.list ~size:(Gen.int_range 1 4) assistant_part_gen in
        Message.Assistant.make parts );
    ]

let message_gen =
  Gen.frequency
    [
      ( 2,
        let+ s = free_text in
        Message.system s );
      ( 2,
        let+ s = free_text in
        Message.developer s );
      ( 2,
        let+ content = Gen.list ~size:(Gen.int_range 1 3) content_gen in
        Message.user content );
      ( 2,
        let+ a = assistant_gen in
        Message.assistant a );
      ( 2,
        let+ r = result_gen in
        Message.tool_result r );
    ]

let usage_gen =
  let lane = Gen.int_range 0 1000 in
  let+ input = lane
  and+ output = lane
  and+ reasoning = lane
  and+ cache_read = lane
  and+ cache_write = lane in
  Usage.make ~input ~output ~reasoning ~cache_read ~cache_write ()

let usage_gen_t = Testable.make ~pp:Usage.pp ~equal:Usage.equal
let usage_gen = Gen.with_pp Usage.pp usage_gen

(* An unknown-but-valid label distinct from every dedicated stop/error label. *)
let unknown_label =
  let+ rest =
    Gen.string_of ~size:(Gen.int_range 0 6)
      (Gen.frequency [ (6, lower); (1, digit); (1, Gen.pure '_') ])
  in
  "x" ^ rest

let stop_gen =
  Gen.one_of
    [
      Gen.of_list
        [
          Stop.end_turn;
          Stop.tool_call;
          Stop.length;
          Stop.content_filter;
          Stop.refusal;
        ];
      (let+ l = unknown_label in
       Stop.other l);
    ]

let stop_gen = Gen.with_pp Stop.pp stop_gen

let kind_gen =
  Gen.one_of
    [
      Gen.of_list
        [
          Error.Cancelled;
          Error.Auth;
          Error.Quota;
          Error.Rate_limited;
          Error.Context_overflow;
          Error.Invalid_request;
          Error.Unsupported;
          Error.Content_policy;
          Error.Transport;
          Error.Timeout;
          Error.Decode;
          Error.Malformed_stream;
          Error.Provider;
        ];
      (let+ l = unknown_label in
       Error.Other l);
    ]

let error_gen =
  let+ kind = kind_gen
  and+ phase = Gen.of_list [ Error.Startup; Error.Stream ]
  and+ message = word
  and+ provider = Gen.option provider_gen
  and+ status = Gen.option (Gen.int_range 100 599)
  and+ request_id = Gen.option word
  and+ redacted_body = Gen.option word in
  Error.make ~kind ~phase ?provider ?status ?request_id ?redacted_body message

let error_gen = Gen.with_pp Error.pp error_gen
let provider_gen = Gen.with_pp Provider.pp provider_gen
let api_gen = Gen.with_pp Model.Api.pp api_gen
let model_gen = Gen.with_pp Model.pp model_gen

(* A valid transcript generator built from grammar-respecting "turns": an
   ordinary message, or an assistant tool-call turn immediately followed by one
   matching result per call. Concatenation is always a ready, valid transcript,
   so [of_list_exn] never raises. *)

let assistant_no_calls_gen =
  Gen.frequency
    [
      (1, Gen.pure Message.Assistant.empty);
      ( 4,
        let+ parts =
          Gen.list ~size:(Gen.int_range 1 3)
            (Gen.frequency
               [
                 ( 3,
                   let+ s = free_text in
                   Message.Assistant.text_part s );
                 ( 1,
                   let+ r = reasoning_gen in
                   Message.Assistant.reasoning_part r );
               ])
        in
        Message.Assistant.make parts );
    ]

let tool_turn_gen =
  let* n = Gen.int_range 1 3 in
  let+ names = Gen.list ~size:(Gen.pure n) tool_name_gen
  and+ lead = free_text
  and+ result_texts = Gen.list ~size:(Gen.pure n) free_text in
  let calls =
    List.mapi
      (fun i name ->
        Tool.Call.make
          ~id:("call_" ^ string_of_int i)
          ~name
          ~input:(json_object [ ("i", Json.int i) ])
          ())
      names
  in
  let assistant =
    Message.assistant
      (Message.Assistant.make
         (Message.Assistant.text_part lead
         :: List.map Message.Assistant.tool_call calls))
  in
  let results =
    List.map2
      (fun c t -> Message.tool_result (Tool.Result.text c t))
      calls result_texts
  in
  assistant :: results

let turn_gen =
  Gen.frequency
    [
      ( 2,
        let+ s = free_text in
        [ Message.system s ] );
      ( 2,
        let+ s = free_text in
        [ Message.developer s ] );
      ( 2,
        let+ content = Gen.list ~size:(Gen.int_range 1 3) content_gen in
        [ Message.user content ] );
      ( 2,
        let+ a = assistant_no_calls_gen in
        [ Message.assistant a ] );
      (2, tool_turn_gen);
    ]

let transcript_gen =
  let+ turns = Gen.list ~size:(Gen.int_range 0 5) turn_gen in
  Transcript.of_list_exn (List.concat turns)

let nonempty_transcript_gen =
  let+ head = turn_gen
  and+ tail = Gen.list ~size:(Gen.int_range 0 4) turn_gen in
  Transcript.of_list_exn (List.concat (head :: tail))

let prelude_msg_gen =
  Gen.frequency
    [
      ( 1,
        let+ s = free_text in
        Message.system s );
      ( 1,
        let+ s = free_text in
        Message.developer s );
      ( 1,
        let+ content = Gen.list ~size:(Gen.int_range 1 2) content_gen in
        Message.user content );
    ]

let prelude_gen =
  let+ messages = Gen.list ~size:(Gen.int_range 0 3) prelude_msg_gen in
  match Request.Prelude.make messages with
  | Ok prelude -> prelude
  | Error _ -> Request.Prelude.empty

let options_gen =
  let response_format =
    Gen.frequency
      [
        (3, Gen.pure Request.Options.Text);
        ( 1,
          let+ name = word and+ strict = Gen.bool in
          Request.Options.Json_schema { name; schema; strict } );
      ]
  in
  (* [tool_choice] stays [Auto]/[No_tools] so the request is valid regardless of
     the generated tool list; [temperature] draws from clean floats that survive
     a text round-trip under any number format. *)
  let+ tool_choice =
    Gen.of_list [ Request.Options.Auto; Request.Options.No_tools ]
  and+ max_output_tokens = Gen.option (Gen.int_range 1 100_000)
  and+ temperature = Gen.option (Gen.of_list [ 0.; 0.2; 0.5; 1.; 1.5; 2. ])
  and+ reasoning_effort =
    Gen.option (Gen.of_list Request.Options.Reasoning_effort.all)
  and+ response_format = response_format in
  Request.Options.make ~tool_choice ?max_output_tokens ?temperature
    ?reasoning_effort ~response_format ()

let options_gen_t =
  Testable.make
    ~pp:(fun ppf _ -> Format.pp_print_string ppf "<options>")
    ~equal:( = )

let tools_gen =
  let+ n = Gen.int_range 0 3 in
  List.init n (fun i ->
      Tool.make
        ~name:("tool_" ^ string_of_int i)
        ~input_schema:Tool.no_input_schema ())

let request_gen =
  let+ model = model_gen
  and+ transcript = nonempty_transcript_gen
  and+ prelude = prelude_gen
  and+ tools = tools_gen
  and+ options = options_gen
  and+ cache_key = Gen.option word in
  Request.make_exn ~model ~prelude ~tools ~options ?cache_key transcript

let request_gen_t =
  Testable.make
    ~pp:(fun ppf _ -> Format.pp_print_string ppf "<request>")
    ~equal:( = )

(* Independent reimplementation of the request digest's canonical encoder. It
   is kept here so the digest golden is
   a genuine cross-check of the canonical framing and the "mentat.llm.request.v1"
   version tag, rather than the digest function compared against itself. *)

let digest_domain = "mentat.llm.request.v1"

let write_number buffer f =
  if not (Float.is_finite f) then Buffer.add_string buffer "null"
  else
    let rec shortest precision =
      if precision >= 17 then Printf.sprintf "%.17g" f
      else
        let candidate = Printf.sprintf "%.*g" precision f in
        if Float.equal (float_of_string candidate) f then candidate
        else shortest (precision + 1)
    in
    Buffer.add_string buffer (shortest 1)

let write_string buffer s =
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | '\b' -> Buffer.add_string buffer "\\b"
      | '\012' -> Buffer.add_string buffer "\\f"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer '"'

let member_name ((name, _), _) = name

let rec write_canonical buffer = function
  | Jsont.Null _ -> Buffer.add_string buffer "null"
  | Jsont.Bool (b, _) ->
      Buffer.add_string buffer (if b then "true" else "false")
  | Jsont.Number (f, _) -> write_number buffer f
  | Jsont.String (s, _) -> write_string buffer s
  | Jsont.Array (elements, _) ->
      Buffer.add_char buffer '[';
      List.iteri
        (fun index element ->
          if index > 0 then Buffer.add_char buffer ',';
          write_canonical buffer element)
        elements;
      Buffer.add_char buffer ']'
  | Jsont.Object (members, _) ->
      let members =
        List.stable_sort
          (fun a b -> String.compare (member_name a) (member_name b))
          members
      in
      Buffer.add_char buffer '{';
      List.iteri
        (fun index ((name, _), value) ->
          if index > 0 then Buffer.add_char buffer ',';
          write_string buffer name;
          Buffer.add_char buffer ':';
          write_canonical buffer value)
        members;
      Buffer.add_char buffer '}'

let oracle_digest request =
  let root =
    json_object
      [
        ( "messages",
          encode (Jsont.list Message.jsont) (Request.messages request) );
        ("model", encode Model.jsont (Request.model request));
        ("options", encode Request.Options.jsont (Request.options request));
        ("tools", encode (Jsont.list Tool.jsont) (Request.tools request));
      ]
  in
  let buffer = Buffer.create 256 in
  Buffer.add_string buffer (string_of_int (String.length digest_domain));
  Buffer.add_char buffer ':';
  Buffer.add_string buffer digest_domain;
  write_canonical buffer root;
  Mentat_digest.string (Buffer.contents buffer)

(* Value contracts *)

let provider_contracts =
  group "Provider"
    [
      test "id round-trips construction" (fun () ->
          equal string "openai" (Provider.id openai));
      test "jsont round-trips" (fun () ->
          roundtrip "provider" provider_t Provider.jsont openai);
      test "accepts valid slugs" (fun () ->
          List.iter
            (fun id -> equal string ~msg:id id (Provider.id (Provider.make id)))
            [ "a"; "openai"; "x-ai"; "a1"; "z9-z" ]);
      test "rejects invalid slugs" (fun () ->
          List.iter
            (fun id ->
              expect_invalid_arg (String.escaped id) (fun () ->
                  Provider.make id))
            [ ""; "OpenAI"; "-openai"; "open_ai"; "open.ai"; "1x" ]);
      prop "jsont round-trips (property)" provider_gen (fun p ->
          roundtrip "provider" provider_t Provider.jsont p);
    ]

let model_contracts =
  group "Model"
    [
      test "accessors and jsont" (fun () ->
          let chat = Model.Api.make "chat.completions" in
          equal string "chat.completions" (Model.Api.id chat);
          equal string ~msg:"model id" "gpt-5" (Model.id gpt);
          equal provider_t ~msg:"provider" openai (Model.provider gpt);
          equal api_t ~msg:"api" responses (Model.api gpt);
          roundtrip "api" api_t Model.Api.jsont chat;
          roundtrip "model" model_t Model.jsont gpt);
      test "rejects invalid apis" (fun () ->
          List.iter
            (fun id ->
              expect_invalid_arg (String.escaped id) (fun () ->
                  Model.Api.make id))
            [
              "";
              "Responses";
              ".responses";
              "responses.";
              "chat..completions";
              "chat_completions";
            ]);
      test "rejects empty model id" (fun () ->
          expect_invalid_arg "empty id" (fun () -> model ""));
      prop "api jsont round-trips (property)" api_gen (fun a ->
          roundtrip "api" api_t Model.Api.jsont a);
      prop "model jsont round-trips (property)" model_gen (fun m ->
          roundtrip "model" model_t Model.jsont m);
    ]

let content_contracts =
  group "Content"
    [
      test "text and media accessors" (fun () ->
          (match Content.text "hello" with
          | Content.Text v -> equal string ~msg:"text" "hello" v
          | Content.Media _ -> failf "unexpected media");
          match
            Content.media ~media_type:"image/png" (`Uri "file:///tmp/a.png")
          with
          | Content.Media { media_type; source = `Uri uri } ->
              equal string ~msg:"media type" "image/png" media_type;
              equal string ~msg:"uri" "file:///tmp/a.png" uri
          | _ -> failf "unexpected content");
      test "Ref media source is accepted and round-trips" (fun () ->
          let r = Mentat_digest.Content_ref.of_contents "attachment bytes" in
          let content = Content.media ~media_type:"image/png" (`Ref r) in
          (match content with
          | Content.Media { source = `Ref r'; _ } ->
              is_true ~msg:"ref preserved"
                (Mentat_digest.Content_ref.equal r r')
          | _ -> failf "expected a ref media source");
          roundtrip "ref content" content_t Content.jsont content);
      test "jsont round-trips text and media" (fun () ->
          roundtrip "text" content_t Content.jsont (Content.text "hi");
          roundtrip "media" content_t Content.jsont
            (Content.media ~media_type:"image/png" (`Base64 "AAAA")));
      test "rejects empty strings" (fun () ->
          expect_invalid_arg "empty text" (fun () -> Content.text "");
          expect_invalid_arg "empty media type" (fun () ->
              Content.media ~media_type:"" (`Uri "x"));
          expect_invalid_arg "empty uri" (fun () ->
              Content.media ~media_type:"image/png" (`Uri ""));
          expect_invalid_arg "empty base64" (fun () ->
              Content.media ~media_type:"image/png" (`Base64 "")));
      prop "jsont round-trips (property)" content_gen (fun c ->
          roundtrip "content" content_t Content.jsont c);
    ]

let image_contracts =
  let format = Testable.make ~pp:Image.Format.pp ~equal:Image.Format.equal in
  let dimension =
    Testable.make
      ~pp:(fun ppf { Image.width; height } ->
        Format.fprintf ppf "%dx%d" width height)
      ~equal:(fun a b ->
        a.Image.width = b.Image.width && a.Image.height = b.Image.height)
  in
  let dim width height = { Image.width; height } in
  (* Minimal but real headers built with explicit bytes: each carries width 100,
     height 50 (jpeg 64x48, gif 32x24) at its format's header offsets. *)
  let png =
    "\x89PNG\r\n\
     \x1a\n\
     \x00\x00\x00\x0dIHDR\x00\x00\x00\x64\x00\x00\x00\x32\x08\x06\x00\x00\x00"
  in
  let jpeg = "\xff\xd8\xff\xc0\x00\x11\x08\x00\x30\x00\x40" in
  let jpeg_with_app0 =
    "\xff\xd8\xff\xe0\x00\x04\xaa\xbb\xff\xc0\x00\x11\x08\x00\x30\x00\x40"
  in
  let gif = "GIF89a\x20\x00\x18\x00" in
  let webp_vp8x =
    "RIFF\x00\x00\x00\x00WEBPVP8X\x00\x00\x00\x00\x00\x00\x00\x00\x63\x00\x00\x31\x00\x00"
  in
  let webp_vp8 =
    "RIFF\x00\x00\x00\x00WEBPVP8 \
     \x00\x00\x00\x00\x00\x00\x00\x9d\x01\x2a\x64\x00\x32\x00"
  in
  let webp_vp8l =
    "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00\x2f\x63\x40\x0c\x00"
  in
  group "Image"
    [
      test "sniff recognizes each format by its magic bytes" (fun () ->
          equal (option format) ~msg:"png" (Some Image.Format.Png)
            (Image.sniff png);
          equal (option format) ~msg:"jpeg" (Some Image.Format.Jpeg)
            (Image.sniff jpeg);
          equal (option format) ~msg:"gif" (Some Image.Format.Gif)
            (Image.sniff gif);
          equal (option format) ~msg:"webp" (Some Image.Format.Webp)
            (Image.sniff webp_vp8x));
      test "sniff rejects non-image and truncated bytes" (fun () ->
          equal (option format) ~msg:"garbage" None (Image.sniff "not an image");
          equal (option format) ~msg:"empty" None (Image.sniff "");
          equal (option format) ~msg:"short prefix" None (Image.sniff "\x89PN"));
      test "dimensions read each format header without decoding" (fun () ->
          equal (option dimension) ~msg:"png"
            (Some (dim 100 50))
            (Image.dimensions png);
          equal (option dimension) ~msg:"jpeg"
            (Some (dim 64 48))
            (Image.dimensions jpeg);
          equal (option dimension) ~msg:"jpeg past app0"
            (Some (dim 64 48))
            (Image.dimensions jpeg_with_app0);
          equal (option dimension) ~msg:"gif"
            (Some (dim 32 24))
            (Image.dimensions gif);
          equal (option dimension) ~msg:"webp vp8x"
            (Some (dim 100 50))
            (Image.dimensions webp_vp8x);
          equal (option dimension) ~msg:"webp vp8"
            (Some (dim 100 50))
            (Image.dimensions webp_vp8);
          equal (option dimension) ~msg:"webp vp8l"
            (Some (dim 100 50))
            (Image.dimensions webp_vp8l));
      test "dimensions are None when the header is truncated" (fun () ->
          (* The 8-byte PNG signature sniffs as PNG but has no IHDR yet. *)
          equal (option format) ~msg:"signature sniffs" (Some Image.Format.Png)
            (Image.sniff "\x89PNG\r\n\x1a\n");
          equal (option dimension) ~msg:"png signature only" None
            (Image.dimensions "\x89PNG\r\n\x1a\n");
          equal (option dimension) ~msg:"non-image" None
            (Image.dimensions "not an image"));
      test "Format media types round-trip and parse case-insensitively"
        (fun () ->
          List.iter
            (fun f ->
              equal (option format) ~msg:"round-trip" (Some f)
                (Image.Format.of_media_type (Image.Format.media_type f)))
            [
              Image.Format.Png;
              Image.Format.Jpeg;
              Image.Format.Gif;
              Image.Format.Webp;
            ];
          equal (option format) ~msg:"uppercase" (Some Image.Format.Png)
            (Image.Format.of_media_type "IMAGE/PNG");
          equal (option format) ~msg:"jpg alias" (Some Image.Format.Jpeg)
            (Image.Format.of_media_type "image/jpg");
          equal (option format) ~msg:"unknown" None
            (Image.Format.of_media_type "text/plain"));
    ]

let tool_contracts =
  group "Tool"
    [
      test "declaration accessors and jsont" (fun () ->
          (match Tool.no_input_schema with
          | Jsont.Object _ -> ()
          | _ -> failf "no-input schema must be an object");
          let declaration = tool () in
          equal string ~msg:"name" "read_file" (Tool.name declaration);
          equal (option string) ~msg:"description" (Some "Read a file.")
            (Tool.description declaration);
          is_true ~msg:"schema retained"
            (Json.equal schema (Tool.input_schema declaration));
          roundtrip "tool" (opaque "tool") Tool.jsont declaration);
      test "accepts valid names" (fun () ->
          List.iter
            (fun name ->
              equal string ~msg:name name (Tool.name (tool ~name ())))
            [
              "a";
              "_private";
              "read_file";
              "read-file";
              "read2";
              String.make 64 'a';
            ]);
      test "rejects invalid names" (fun () ->
          List.iter
            (fun name ->
              expect_invalid_arg (String.escaped name) (fun () -> tool ~name ()))
            [
              ""; "2read"; "-read"; "read.file"; "read file"; String.make 65 'a';
            ]);
      test "rejects bad description and schema" (fun () ->
          expect_invalid_arg "empty description" (fun () ->
              Tool.make ~name:"bad" ~description:"" ~input_schema:schema ());
          expect_invalid_arg "non-object schema" (fun () ->
              Tool.make ~name:"bad" ~input_schema:(Json.string "schema") ()));
      test "call accessors and jsont" (fun () ->
          let c = call () in
          equal string ~msg:"id" "call_1" (Tool.Call.id c);
          equal string ~msg:"name" "read_file" (Tool.Call.name c);
          roundtrip "call" call_t Tool.Call.jsont c;
          expect_invalid_arg "empty id" (fun () ->
              Tool.Call.make ~id:"" ~name:"read_file" ~input:empty_object ());
          expect_invalid_arg "bad name" (fun () ->
              Tool.Call.make ~id:"id" ~name:"bad name" ~input:empty_object ());
          expect_invalid_arg "empty signature" (fun () ->
              Tool.Call.make ~id:"id" ~name:"read_file" ~input:empty_object
                ~signature:"" ()));
      test "result accessors and jsont" (fun () ->
          let c = call () in
          let empty_result = Tool.Result.empty c in
          equal (list string) ~msg:"empty texts" []
            (Tool.Result.texts empty_result);
          equal bool ~msg:"empty not error" false
            (Tool.Result.is_error empty_result);
          let text_result = Tool.Result.text ~error:true c "contents" in
          equal (list string) ~msg:"texts" [ "contents" ]
            (Tool.Result.texts text_result);
          equal bool ~msg:"error" true (Tool.Result.is_error text_result);
          roundtrip "result" result_t Tool.Result.jsont text_result;
          expect_invalid_arg "empty text" (fun () -> Tool.Result.text c ""));
      test "call equality is metadata-insensitive across a text round-trip"
        (fun () ->
          (* A [~locs] text decode stamps source locations onto the input JSON;
             [Tool.Call.equal] must compare the JSON value, not its parse
             metadata, so a constructed call equals its text-decoded twin. *)
          let c =
            Tool.Call.make ~id:"call_1" ~name:"read_file"
              ~input:
                (json_object
                   [ ("path", Json.string "a.ml"); ("n", Json.int 2) ])
              ()
          in
          let decoded =
            decode_text_locs Tool.Call.jsont (encode_text Tool.Call.jsont c)
          in
          is_true ~msg:"constructed equals text-decoded"
            (Tool.Call.equal c decoded);
          is_false ~msg:"a distinct input is still distinguished"
            (Tool.Call.equal c
               (Tool.Call.make ~id:"call_1" ~name:"read_file"
                  ~input:(json_object [ ("path", Json.string "b.ml") ])
                  ())));
      test "declaration equality is semantic over the schema" (fun () ->
          let make ?(name = "read_file") ?(description = "Read a file.")
              ?(input_schema = schema) () =
            Tool.make ~name ~description ~input_schema ()
          in
          let declaration = make () in
          is_true ~msg:"identical declarations are equal"
            (Tool.equal declaration (make ()));
          let reordered_schema =
            match schema with
            | Jsont.Object (members, meta) ->
                Jsont.Object (List.rev members, meta)
            | _ -> failf "schema must be an object"
          in
          is_true ~msg:"schema member order is irrelevant"
            (Tool.equal declaration (make ~input_schema:reordered_schema ()));
          is_true ~msg:"constructed equals text-decoded"
            (Tool.equal declaration
               (decode_text_locs Tool.jsont
                  (encode_text Tool.jsont declaration)));
          is_false ~msg:"name participates"
            (Tool.equal declaration (make ~name:"read_line" ()));
          is_false ~msg:"description participates"
            (Tool.equal declaration (make ~description:"Read lines." ()));
          is_false ~msg:"missing description differs"
            (Tool.equal declaration
               (Tool.make ~name:"read_file" ~input_schema:schema ()));
          is_false ~msg:"schema participates"
            (Tool.equal declaration
               (make ~input_schema:Tool.no_input_schema ())));
      prop "call jsont round-trips (property)" call_gen (fun c ->
          roundtrip "call" call_t Tool.Call.jsont c);
      prop "declaration jsont round-trips (property)" tool_gen (fun t ->
          roundtrip "tool" (opaque "tool") Tool.jsont t);
      prop "result jsont round-trips (property)" result_gen (fun r ->
          roundtrip "result" result_t Tool.Result.jsont r);
    ]

(* Usage lane laws *)

let usage_contracts =
  group "Usage"
    [
      test "lane-wise add and totals" (fun () ->
          let a =
            Usage.make ~input:1 ~output:2 ~reasoning:3 ~cache_read:4
              ~cache_write:5 ()
          in
          let b =
            Usage.make ~input:10 ~output:20 ~reasoning:30 ~cache_read:40
              ~cache_write:50 ()
          in
          let sum = Usage.add a b in
          equal int ~msg:"input" 11 sum.Usage.input;
          equal int ~msg:"output" 22 sum.Usage.output;
          equal int ~msg:"reasoning" 33 sum.Usage.reasoning;
          equal int ~msg:"cache_read" 44 sum.Usage.cache_read;
          equal int ~msg:"cache_write" 55 sum.Usage.cache_write;
          equal int ~msg:"input_total" 10 (Usage.input_total a);
          equal int ~msg:"output_total" 5 (Usage.output_total a);
          equal int ~msg:"sum_lanes" 15 (Usage.sum_lanes a);
          roundtrip "usage" usage_t Usage.jsont a);
      test "rejects negative lanes and add overflow" (fun () ->
          List.iter
            (fun f -> expect_invalid_arg "negative lane" f)
            [
              (fun () -> Usage.make ~input:(-1) ~output:0 ());
              (fun () -> Usage.make ~input:0 ~output:(-1) ());
              (fun () -> Usage.make ~input:0 ~output:0 ~reasoning:(-1) ());
              (fun () -> Usage.make ~input:0 ~output:0 ~cache_read:(-1) ());
              (fun () -> Usage.make ~input:0 ~output:0 ~cache_write:(-1) ());
            ];
          let large = Usage.make ~input:max_int ~output:0 () in
          expect_invalid_arg "add overflow" (fun () ->
              Usage.add large (Usage.make ~input:1 ~output:0 ())));
      prop "totals identity: sum_lanes = input_total + output_total" usage_gen
        (fun u ->
          equal int (Usage.sum_lanes u)
            (Usage.input_total u + Usage.output_total u));
      prop "input_total is the input lanes" usage_gen (fun u ->
          equal int (Usage.input_total u)
            (u.Usage.input + u.Usage.cache_read + u.Usage.cache_write));
      prop "output_total is the output lanes" usage_gen (fun u ->
          equal int (Usage.output_total u) (u.Usage.output + u.Usage.reasoning));
      prop "add has identity zero" usage_gen (fun u ->
          equal usage_gen_t u (Usage.add u Usage.zero);
          equal usage_gen_t u (Usage.add Usage.zero u));
      prop "add is commutative" (Gen.pair usage_gen usage_gen) (fun (a, b) ->
          equal usage_gen_t (Usage.add a b) (Usage.add b a));
      prop "add is associative" (Gen.triple usage_gen usage_gen usage_gen)
        (fun (a, b, c) ->
          equal usage_gen_t
            (Usage.add a (Usage.add b c))
            (Usage.add (Usage.add a b) c));
      prop "jsont round-trips (property)" usage_gen (fun u ->
          equal usage_gen_t u (decode Usage.jsont (encode Usage.jsont u)));
    ]

(* Stop forward-compatibility *)

let stop_labels =
  [
    (Stop.end_turn, "end_turn");
    (Stop.tool_call, "tool_call");
    (Stop.length, "length");
    (Stop.content_filter, "content_filter");
    (Stop.refusal, "refusal");
    (Stop.other "vendor_stop", "vendor_stop");
  ]

let stop_contracts =
  group "Response.Stop"
    [
      test "label of every constructor" (fun () ->
          List.iter
            (fun (stop, label) ->
              equal string ~msg:label label (Stop.label stop))
            stop_labels);
      test "every constructor round-trips through jsont" (fun () ->
          List.iter
            (fun (stop, _) -> roundtrip "stop" stop_t Stop.jsont stop)
            stop_labels);
      test "unknown valid label decodes to Other and re-encodes identically"
        (fun () ->
          equal stop_t ~msg:"decodes to Other" (Stop.other "vendor_stop")
            (decode Stop.jsont (Json.string "vendor_stop"));
          equal_json "re-encodes to the label"
            (Json.string "vendor_stop")
            (encode Stop.jsont (Stop.other "vendor_stop")));
      test "a known label decodes to its canonical value" (fun () ->
          equal stop_t ~msg:"end_turn" Stop.end_turn
            (decode Stop.jsont (Json.string "end_turn"));
          equal (option stop_t) ~msg:"of_label" (Some Stop.end_turn)
            (Stop.of_label "end_turn"));
      test "rejects an invalid label" (fun () ->
          expect_decode_error "hyphen" Stop.jsont (Json.string "bad-label");
          expect_decode_error "uppercase" Stop.jsont (Json.string "Vendor");
          expect_decode_error "empty" Stop.jsont (Json.string "");
          expect_decode_error "non-string" Stop.jsont (Json.int 1));
      test "other rejects invalid and dedicated labels" (fun () ->
          expect_invalid_arg "space label" (fun () -> Stop.other "bad label");
          expect_invalid_arg "uppercase label" (fun () -> Stop.other "Vendor");
          expect_invalid_arg "dedicated label" (fun () -> Stop.other "end_turn"));
      prop "label after jsont decode is preserved" stop_gen (fun stop ->
          equal string (Stop.label stop)
            (Stop.label (decode Stop.jsont (encode Stop.jsont stop))));
    ]

let error_contracts =
  group "Error"
    [
      test "accessors and jsont" (fun () ->
          let error =
            Error.make ~kind:Error.Transport ~phase:Error.Stream
              ~provider:openai ~status:503 ~request_id:"req_1"
              ~redacted_body:"unavailable" "provider unavailable"
          in
          equal string ~msg:"label" "transport" (Error.label (Error.kind error));
          equal phase_t ~msg:"phase" Error.Stream (Error.phase error);
          equal (option int) ~msg:"status" (Some 503) (Error.status error);
          equal (option string) ~msg:"request id" (Some "req_1")
            (Error.request_id error);
          roundtrip "error" error_t Error.jsont error);
      test "rejects invalid construction" (fun () ->
          expect_invalid_arg "empty message" (fun () ->
              Error.make ~kind:Error.Provider "");
          expect_invalid_arg "low status" (fun () ->
              Error.make ~kind:Error.Provider ~status:99 "bad");
          expect_invalid_arg "high status" (fun () ->
              Error.make ~kind:Error.Provider ~status:600 "bad");
          expect_invalid_arg "reserved other" (fun () ->
              Error.make ~kind:(Error.Other "auth") "bad");
          expect_invalid_arg "invalid other" (fun () ->
              Error.make ~kind:(Error.Other "Bad") "bad");
          expect_invalid_arg "invalid other label" (fun () ->
              Error.label (Error.Other "Bad")));
      prop "jsont round-trips (property)" error_gen (fun e ->
          roundtrip "error" error_t Error.jsont e);
    ]

(* Reasoning round-trip per opaque field *)

let message_contracts =
  group "Message"
    [
      test "assistant parts, tool calls, and reasoning accessors" (fun () ->
          let c = call () in
          let reasoning =
            Message.Assistant.Reasoning.make ~id:"rs_1" ~text:"thinking"
              ~encrypted:"ciphertext" ~signature:"sig_1" ()
          in
          let assistant =
            Message.Assistant.make
              [
                Message.Assistant.reasoning_part reasoning;
                Message.Assistant.text_part "I will use a tool.";
                Message.Assistant.tool_call c;
              ]
          in
          equal (list string) ~msg:"texts" [ "I will use a tool." ]
            (Message.Assistant.texts assistant);
          equal (list call_t) ~msg:"tool calls" [ c ]
            (Message.Assistant.tool_calls assistant);
          equal
            (list (opaque "reasoning"))
            ~msg:"reasonings" [ reasoning ]
            (Message.Assistant.reasonings assistant);
          roundtrip "assistant" (opaque "assistant") Message.Assistant.jsont
            assistant;
          roundtrip "message" message_t Message.jsont
            (Message.assistant assistant));
      test "empty assistant" (fun () ->
          let e = Message.Assistant.empty in
          equal (list string) ~msg:"texts" [] (Message.Assistant.texts e);
          equal (list call_t) ~msg:"tool calls" []
            (Message.Assistant.tool_calls e);
          equal
            (list (opaque "reasoning"))
            ~msg:"reasonings" []
            (Message.Assistant.reasonings e);
          roundtrip "empty assistant" (opaque "assistant")
            Message.Assistant.jsont e);
      test "reasoning: each opaque field survives jsont round-trip" (fun () ->
          let field name make project =
            let r = make () in
            let r' =
              decode Message.Assistant.Reasoning.jsont
                (encode Message.Assistant.Reasoning.jsont r)
            in
            equal (option string) ~msg:name (project r) (project r')
          in
          field "id"
            (fun () -> Message.Assistant.Reasoning.make ~id:"rs_1" ())
            Message.Assistant.Reasoning.id;
          field "encrypted"
            (fun () -> Message.Assistant.Reasoning.make ~encrypted:"ct" ())
            Message.Assistant.Reasoning.encrypted;
          field "signature"
            (fun () -> Message.Assistant.Reasoning.make ~signature:"sig" ())
            Message.Assistant.Reasoning.signature;
          field "text"
            (fun () -> Message.Assistant.Reasoning.make ~text:"t" ())
            Message.Assistant.Reasoning.text;
          field "summary"
            (fun () -> Message.Assistant.Reasoning.make ~summary:"s" ())
            Message.Assistant.Reasoning.summary);
      test "rejects invalid construction" (fun () ->
          expect_invalid_arg "no reasoning field" (fun () ->
              Message.Assistant.Reasoning.make ());
          expect_invalid_arg "empty reasoning text" (fun () ->
              Message.Assistant.Reasoning.make ~text:"" ());
          expect_invalid_arg "empty assistant parts" (fun () ->
              Message.Assistant.make []);
          expect_invalid_arg "empty assistant text" (fun () ->
              Message.Assistant.text "");
          expect_invalid_arg "empty system" (fun () -> Message.system "");
          expect_invalid_arg "empty developer" (fun () -> Message.developer "");
          expect_invalid_arg "empty user" (fun () -> Message.user []);
          expect_invalid_arg "empty user text" (fun () -> Message.user_text ""));
      prop "reasoning jsont round-trips (property)" reasoning_gen (fun r ->
          let r' =
            decode Message.Assistant.Reasoning.jsont
              (encode Message.Assistant.Reasoning.jsont r)
          in
          is_true
            (Message.Assistant.Reasoning.id r
             = Message.Assistant.Reasoning.id r'
            && Message.Assistant.Reasoning.summary r
               = Message.Assistant.Reasoning.summary r'
            && Message.Assistant.Reasoning.text r
               = Message.Assistant.Reasoning.text r'
            && Message.Assistant.Reasoning.encrypted r
               = Message.Assistant.Reasoning.encrypted r'
            && Message.Assistant.Reasoning.signature r
               = Message.Assistant.Reasoning.signature r'));
      test "equality of a tool-call assistant survives a text round-trip"
        (fun () ->
          (* [Message.equal] must be semantic over the embedded tool-call JSON;
             a text decode would otherwise defeat it with source metadata. *)
          let m =
            Message.assistant
              (Message.Assistant.make
                 [
                   Message.Assistant.text_part "using a tool";
                   Message.Assistant.tool_call
                     (Tool.Call.make ~id:"c1" ~name:"read_file"
                        ~input:(json_object [ ("path", Json.string "x") ])
                        ());
                 ])
          in
          is_true ~msg:"constructed equals text-decoded"
            (Message.equal m
               (decode_text_locs Message.jsont (encode_text Message.jsont m))));
      prop "message jsont round-trips (property)" message_gen (fun m ->
          roundtrip "message" message_t Message.jsont m);
    ]

(* Transcript grammar and [last_assistant_text] *)

let transcript_contracts =
  group "Transcript"
    [
      test "accepts ordinary messages" (fun () ->
          let t = ready_transcript () in
          is_true ~msg:"ready" (Transcript.is_ready t);
          equal int ~msg:"count" 2 (List.length (Transcript.messages t));
          roundtrip "transcript" (opaque "transcript") Transcript.jsont t);
      test "tool loop: calls become pending, results clear them" (fun () ->
          let first = call ~id:"call_1" () in
          let second = call ~id:"call_2" () in
          let t =
            Transcript.add_exn
              (Message.assistant (assistant_with_calls [ first; second ]))
              (ready_transcript ())
          in
          is_true ~msg:"awaiting" (not (Transcript.is_ready t));
          equal (list call_t) ~msg:"pending in output order" [ first; second ]
            (Transcript.pending t);
          let t =
            match
              Transcript.add
                (Message.tool_result (Tool.Result.text second "second"))
                t
            with
            | Ok t -> t
            | Error e -> failf "answer second: %a" Transcript.Error.pp e
          in
          equal (list call_t) ~msg:"remaining" [ first ] (Transcript.pending t);
          let t =
            match
              Transcript.add (Message.tool_result (Tool.Result.empty first)) t
            with
            | Ok t -> t
            | Error e -> failf "answer first: %a" Transcript.Error.pp e
          in
          is_true ~msg:"ready after all results" (Transcript.is_ready t);
          equal int ~msg:"message count" 5 (List.length (Transcript.messages t)));
      test "each grammar error is producible via add/of_list" (fun () ->
          let first = call ~id:"call_1" () in
          let second = call ~id:"call_2" () in
          let pending =
            Transcript.add_exn
              (Message.assistant (assistant_with_calls [ first ]))
              (ready_transcript ())
          in
          (* Ordinary message while pending. *)
          expect_error "ordinary while pending"
            (Transcript.add (Message.user_text "continue") pending)
            (fun e ->
              equal transcript_error_t ~msg:"pending"
                (Transcript.Error.Pending_tool_results [ first ]) e);
          (* Unknown tool result. *)
          expect_error "unknown result"
            (Transcript.add
               (Message.tool_result (Tool.Result.text second "x"))
               pending)
            (fun e ->
              equal transcript_error_t ~msg:"unknown"
                (Transcript.Error.Unknown_tool_result { call_id = "call_2" })
                e);
          (* Name mismatch. *)
          expect_error "name mismatch"
            (Transcript.add
               (Message.tool_result
                  (Tool.Result.empty
                     (Tool.Call.make ~id:"call_1" ~name:"other_tool"
                        ~input:empty_object ())))
               pending)
            (fun e ->
              equal transcript_error_t ~msg:"mismatch"
                (Transcript.Error.Tool_result_name_mismatch
                   {
                     call_id = "call_1";
                     expected = "read_file";
                     actual = "other_tool";
                   })
                e);
          (* Duplicate tool call id within one assistant message. *)
          expect_error "duplicate call id"
            (Transcript.add
               (Message.assistant
                  (assistant_with_calls [ first; call ~id:"call_1" () ]))
               (ready_transcript ()))
            (fun e ->
              equal transcript_error_t ~msg:"duplicate call"
                (Transcript.Error.Duplicate_tool_call { call_id = "call_1" })
                e);
          (* Tool result without a preceding call. *)
          expect_error "result without call"
            (Transcript.add
               (Message.tool_result (Tool.Result.empty first))
               (ready_transcript ()))
            (fun e ->
              match e with
              | Transcript.Error.Tool_result_without_call r ->
                  equal string ~msg:"orphan id" "call_1" (Tool.Result.call_id r)
              | _ -> failf "unexpected error"));
      test "duplicate tool result is rejected" (fun () ->
          let first = call ~id:"call_1" () in
          let second = call ~id:"call_2" () in
          let t =
            Transcript.add_exn
              (Message.assistant (assistant_with_calls [ first; second ]))
              (ready_transcript ())
          in
          let t =
            match
              Transcript.add (Message.tool_result (Tool.Result.empty first)) t
            with
            | Ok t -> t
            | Error e -> failf "first: %a" Transcript.Error.pp e
          in
          expect_error "duplicate result"
            (Transcript.add
               (Message.tool_result (Tool.Result.text first "again"))
               t)
            (fun e ->
              equal transcript_error_t ~msg:"duplicate"
                (Transcript.Error.Duplicate_tool_result { call_id = "call_1" })
                e));
      test "add_response of a well-formed response never errors" (fun () ->
          let t = ready_transcript () in
          (match
             Transcript.add_response
               (Response.make ~model:gpt (Message.Assistant.text "Done."))
               t
           with
          | Ok t' -> is_true ~msg:"still ready" (Transcript.is_ready t')
          | Error e -> failf "add_response: %a" Transcript.Error.pp e);
          (* A tool-call response leaves the transcript pending, still no error. *)
          match
            Transcript.add_response
              (Response.make ~model:gpt (assistant_with_calls [ call () ]))
              t
          with
          | Ok t' -> is_true ~msg:"pending" (not (Transcript.is_ready t'))
          | Error e -> failf "add_response tool: %a" Transcript.Error.pp e);
      test "of_list agrees with folding add" (fun () ->
          let first = call ~id:"call_1" () in
          let messages =
            [
              Message.developer "You are Mentat.";
              Message.user_text "Use a tool.";
              Message.assistant (assistant_with_calls [ first ]);
              Message.tool_result (Tool.Result.text first "contents");
              Message.assistant_text "Done.";
            ]
          in
          let from_list =
            match Transcript.of_list messages with
            | Ok t -> t
            | Error e -> failf "of_list: %a" Transcript.Error.pp e
          in
          let from_add =
            List.fold_left
              (fun t m -> Transcript.add_exn m t)
              Transcript.empty messages
          in
          equal (opaque "transcript") ~msg:"agree" from_add from_list;
          is_true ~msg:"reversed order rejected"
            (Result.is_error (Transcript.of_list (List.rev messages))));
      test "last_assistant returns the raw most recent assistant" (fun () ->
          equal (option pass) ~msg:"none yet" None
            (Transcript.last_assistant (ready_transcript ()));
          let two_turns =
            Transcript.of_list_exn
              [
                Message.user_text "First.";
                Message.assistant_text "First answer.";
                Message.user_text "Second.";
                Message.assistant_text "Second answer.";
              ]
          in
          (match Transcript.last_assistant two_turns with
          | Some a ->
              equal (list string) ~msg:"most recent" [ "Second answer." ]
                (Message.Assistant.texts a)
          | None -> failf "expected an assistant");
          (* An empty assistant turn is returned unfiltered. *)
          let empty_turn =
            Transcript.of_list_exn
              [
                Message.user_text "hi";
                Message.assistant Message.Assistant.empty;
              ]
          in
          match Transcript.last_assistant empty_turn with
          | Some a ->
              equal (list string) ~msg:"empty returned" []
                (Message.Assistant.texts a)
          | None -> failf "expected the empty assistant");
      test "last_assistant_text skips tool-call-only and empty turns" (fun () ->
          (* Most recent visible text is "First answer."; the later turns are a
             tool-call-only assistant then an empty assistant. *)
          let first = call ~id:"call_9" () in
          let t =
            Transcript.of_list_exn
              [
                Message.user_text "q1";
                Message.assistant_text "First answer.";
                Message.user_text "q2";
                Message.assistant Message.Assistant.empty;
              ]
          in
          equal (option string) ~msg:"skips empty" (Some "First answer.")
            (Transcript.last_assistant_text t);
          let t2 =
            Transcript.add_exn
              (Message.assistant
                 (Message.Assistant.make [ Message.Assistant.tool_call first ]))
              t
          in
          equal (option string) ~msg:"skips tool-call-only"
            (Some "First answer.")
            (Transcript.last_assistant_text t2);
          (* [last_assistant] returns the raw latest (the tool-call turn). *)
          (match Transcript.last_assistant t2 with
          | Some a ->
              equal int ~msg:"latest is the tool-call turn" 1
                (List.length (Message.Assistant.tool_calls a))
          | None -> failf "expected the tool-call assistant");
          (* Joined text is untrimmed and joined with sep. *)
          let joined =
            Transcript.of_list_exn
              [
                Message.user_text "q";
                Message.assistant
                  (Message.Assistant.make
                     [
                       Message.Assistant.text_part " a ";
                       Message.Assistant.text_part " b ";
                     ]);
              ]
          in
          equal (option string) ~msg:"untrimmed join" (Some " a | b ")
            (Transcript.last_assistant_text ~sep:"|" joined);
          equal (option pass) ~msg:"no visible text yields None" None
            (Transcript.last_assistant_text (ready_transcript ())));
      prop "of_list (messages t) = t for valid transcripts" transcript_gen
        (fun t -> is_true (Transcript.of_list (Transcript.messages t) = Ok t));
      prop "jsont round-trips (property)" transcript_gen (fun t ->
          roundtrip "transcript" (opaque "transcript") Transcript.jsont t);
    ]

let request_contracts =
  group "Request"
    [
      test "construction preserves model, tools, prelude, and message order"
        (fun () ->
          let transcript = ready_transcript () in
          let declared = tool () in
          let options = Request.Options.make ~max_output_tokens:123 () in
          let prelude_messages =
            [
              Message.system "host system";
              Message.developer "host developer";
              Message.user_text "host user";
            ]
          in
          let prelude =
            match Request.Prelude.make prelude_messages with
            | Ok p -> p
            | Error e -> failf "prelude: %a" Request.Error.pp e
          in
          let request =
            Request.make_exn ~model:gpt ~prelude ~tools:[ declared ] ~options
              ~cache_key:"session-1" transcript
          in
          equal model_t ~msg:"model" gpt (Request.model request);
          equal
            (list (opaque "tool"))
            ~msg:"tools" [ declared ] (Request.tools request);
          equal (list message_t) ~msg:"prelude" prelude_messages
            (Request.Prelude.messages (Request.prelude request));
          equal (list message_t) ~msg:"messages are prelude then transcript"
            (prelude_messages @ Transcript.messages transcript)
            (Request.messages request);
          equal (option string) ~msg:"cache key" (Some "session-1")
            (Request.cache_key request));
      test "append_prelude preserves everything else" (fun () ->
          let transcript = ready_transcript () in
          let declared = tool () in
          let options = Request.Options.make ~max_output_tokens:123 () in
          let prelude =
            match Request.Prelude.make [ Message.system "host" ] with
            | Ok p -> p
            | Error e -> failf "prelude: %a" Request.Error.pp e
          in
          let request =
            Request.make_exn ~model:gpt ~prelude ~tools:[ declared ] ~options
              ~cache_key:"session-1" transcript
          in
          let appended = Message.user_text "appended" in
          match Request.append_prelude request [ appended ] with
          | Error e -> failf "append: %a" Request.Error.pp e
          | Ok r ->
              equal model_t ~msg:"model" gpt (Request.model r);
              equal
                (list (opaque "tool"))
                ~msg:"tools" [ declared ] (Request.tools r);
              equal (option string) ~msg:"cache key" (Some "session-1")
                (Request.cache_key r);
              equal (list message_t) ~msg:"message order"
                ([ Message.system "host"; appended ]
                @ Transcript.messages transcript)
                (Request.messages r));
      test "prelude rejects assistant and tool-result messages" (fun () ->
          expect_error "assistant in prelude"
            (Request.Prelude.make [ Message.assistant_text "no" ])
            (fun e ->
              match e with
              | Request.Error.Invalid_prelude_message (Message.Assistant _) ->
                  ()
              | _ -> failf "unexpected error");
          expect_error "assistant on append"
            (Request.Prelude.append Request.Prelude.empty
               [ Message.assistant_text "no" ])
            (fun e ->
              match e with
              | Request.Error.Invalid_prelude_message (Message.Assistant _) ->
                  ()
              | _ -> failf "unexpected error"));
      test "construction errors" (fun () ->
          let transcript = ready_transcript () in
          expect_error "empty transcript"
            (Request.make ~model:gpt Transcript.empty) (fun e ->
              equal request_error_t ~msg:"empty" Request.Error.Empty_transcript
                e);
          let pending =
            Transcript.add_exn
              (Message.assistant (assistant_with_calls [ call () ]))
              transcript
          in
          expect_error "awaiting transcript" (Request.make ~model:gpt pending)
            (fun e ->
              match e with
              | Request.Error.Pending_tool_results calls ->
                  equal int ~msg:"count" 1 (List.length calls)
              | _ -> failf "unexpected error");
          expect_error "duplicate tools"
            (Request.make ~model:gpt ~tools:[ tool (); tool () ] transcript)
            (fun e ->
              equal request_error_t ~msg:"duplicate"
                (Request.Error.Duplicate_tool "read_file") e);
          expect_error "required without tools"
            (Request.make ~model:gpt
               ~options:
                 (Request.Options.make ~tool_choice:Request.Options.Required ())
               transcript)
            (fun e ->
              equal request_error_t ~msg:"required"
                Request.Error.Tool_choice_without_tools e);
          expect_error "named tool undeclared"
            (Request.make ~model:gpt
               ~tools:[ tool () ]
               ~options:
                 (Request.Options.make
                    ~tool_choice:(Request.Options.Tool "write_file") ())
               transcript)
            (fun e ->
              equal request_error_t ~msg:"unknown choice"
                (Request.Error.Unknown_tool_choice "write_file") e);
          expect_invalid_arg "empty cache key" (fun () ->
              Request.make ~model:gpt ~cache_key:"" transcript));
      test "options reject invalid values" (fun () ->
          expect_invalid_arg "bad named tool" (fun () ->
              Request.Options.make
                ~tool_choice:(Request.Options.Tool "bad name") ());
          expect_invalid_arg "non-positive max tokens" (fun () ->
              Request.Options.make ~max_output_tokens:0 ());
          expect_invalid_arg "negative temperature" (fun () ->
              Request.Options.make ~temperature:(-0.1) ());
          expect_invalid_arg "schema needs name" (fun () ->
              Request.Options.make
                ~response_format:
                  (Request.Options.Json_schema
                     { name = ""; schema; strict = true })
                ());
          expect_invalid_arg "schema needs object" (fun () ->
              Request.Options.make
                ~response_format:
                  (Request.Options.Json_schema
                     { name = "a"; schema = Json.string "x"; strict = true })
                ()));
      test "reasoning-effort spellings round-trip" (fun () ->
          List.iter
            (fun effort ->
              equal
                (option (opaque "effort"))
                ~msg:"of_string . to_string" (Some effort)
                (Request.Options.Reasoning_effort.of_string
                   (Request.Options.Reasoning_effort.to_string effort)))
            Request.Options.Reasoning_effort.all;
          equal (option pass) ~msg:"unknown spelling" None
            (Request.Options.Reasoning_effort.of_string "enormous"));
      test "jsont round-trips a request without embedded schema" (fun () ->
          (* No tools, so no arbitrary JSON whose decode metadata would defeat
             structural equality; the tool-bearing and text cases are checked
             via [digest] in the Request.digest group. *)
          let request =
            Request.make_exn ~model:gpt
              ~options:
                (Request.Options.make ~max_output_tokens:64 ~temperature:0.2 ())
              ~cache_key:"k" (ready_transcript ())
          in
          roundtrip "request" request_gen_t Request.jsont request);
      prop "options jsont round-trips (property)" options_gen (fun o ->
          roundtrip "options" options_gen_t Request.Options.jsont o);
      prop "jsont round-trips the message list (property)" request_gen (fun r ->
          equal (list message_t) ~msg:"messages" (Request.messages r)
            (Request.messages (decode Request.jsont (encode Request.jsont r))));
    ]

(* Request-digest contracts *)

let digest_contracts =
  group "Request.digest"
    [
      test "digest of a fixed request is a pinned hex (frozen wire golden)"
        (fun () ->
          (* A hardcoded expected digest, not a self-comparison: it pins the
             exact canonical bytes and the "mentat.llm.request.v1" tag, so any
             change to the scheme — even one mirrored into the oracle above —
             breaks here and must be promoted deliberately. *)
          let request =
            Request.make_exn
              ~model:
                (Model.make ~provider:(Provider.make "openai")
                   ~api:(Model.Api.make "responses")
                   ~id:"gpt-5")
              (Transcript.of_list_exn [ Message.user_text "hi" ])
          in
          equal string ~msg:"pinned digest"
            "93499eae1e63bee6e46de098eea484f3b5f21c070213d0603fdcc24bfcf7ff6a"
            (Mentat_digest.to_hex (Request.digest request)));
      test "matches the canonical version-tagged encoding (golden)" (fun () ->
          (* Exercises object-sort, arrays, string escaping, numbers, and bool
             through the independent oracle, pinning the canonical scheme and the
             "mentat.llm.request.v1" tag. *)
          let request =
            Request.make_exn ~model:gpt
              ~tools:[ tool () ]
              ~options:
                (Request.Options.make ~temperature:0.2
                   ~reasoning_effort:Request.Options.Reasoning_effort.High ())
              (Transcript.of_list_exn
                 [ Message.user_text "he\tsaid \"hi\"\nok" ])
          in
          equal digest_t ~msg:"oracle" (oracle_digest request)
            (Request.digest request));
      test "same request built twice digests equal" (fun () ->
          equal digest_t
            (Request.digest (user_request "hello"))
            (Request.digest (user_request "hello")));
      test "digest is stable across a jsont text round-trip" (fun () ->
          let request =
            Request.make_exn ~model:gpt
              ~tools:[ tool () ]
              ~options:(Request.Options.make ~max_output_tokens:64 ())
              ~cache_key:"ignored" (ready_transcript ())
          in
          equal digest_t ~msg:"text round-trip" (Request.digest request)
            (Request.digest
               (decode_text Request.jsont (encode_text Request.jsont request))));
      test
        "digest is stable across a text round-trip with duplicate schema \
         members" (fun () ->
          (* jsont accumulates object members into a list and never dedupes, so
             duplicate members survive a text round-trip and the stable-sorted
             canonical writer yields the same bytes before and after
             persistence: property 1 holds even for pathological schemas. *)
          let dup_schema =
            json_object
              [ ("type", Json.string "object"); ("type", Json.string "object") ]
          in
          let request =
            Request.make_exn ~model:gpt
              ~tools:[ Tool.make ~name:"dup" ~input_schema:dup_schema () ]
              (ready_transcript ())
          in
          equal digest_t ~msg:"dup members stable" (Request.digest request)
            (Request.digest
               (decode_text Request.jsont (encode_text Request.jsont request))));
      test "digest is invariant to construction order" (fun () ->
          let first = call ~id:"call_1" () in
          let messages =
            [
              Message.user_text "Use a tool.";
              Message.assistant (assistant_with_calls [ first ]);
              Message.tool_result (Tool.Result.text first "contents");
              Message.assistant_text "Done.";
            ]
          in
          let of_list = Transcript.of_list_exn messages in
          let of_add =
            List.fold_left
              (fun t m -> Transcript.add_exn m t)
              Transcript.empty messages
          in
          equal digest_t ~msg:"order-independent"
            (Request.digest (Request.make_exn ~model:gpt of_list))
            (Request.digest (Request.make_exn ~model:gpt of_add)));
      test "digest ignores cache_key" (fun () ->
          let make ?cache_key () =
            Request.make_exn ~model:gpt ?cache_key (ready_transcript ())
          in
          let d0 = Request.digest (make ()) in
          equal digest_t ~msg:"absent vs present" d0
            (Request.digest (make ~cache_key:"a" ()));
          equal digest_t ~msg:"different keys" d0
            (Request.digest (make ~cache_key:"b" ())));
      test "digest needs no attachment bytes" (fun () ->
          let ref_content = Mentat_digest.Content_ref.of_contents "big bytes" in
          let with_source source =
            Request.make_exn ~model:gpt
              (Transcript.of_list_exn
                 [
                   Message.user [ Content.media ~media_type:"image/png" source ];
                 ])
          in
          let ref_request = with_source (`Ref ref_content) in
          (* Computable with only a [`Ref], no store. *)
          is_true ~msg:"64 hex"
            (String.length (Mentat_digest.to_hex (Request.digest ref_request))
            = 64);
          equal digest_t ~msg:"ref digest is stable"
            (Request.digest ref_request)
            (Request.digest ref_request);
          (* Resolving [`Ref] to [`Base64] is a DIFFERENT request (property 4
             separation), even for the same underlying bytes. *)
          is_false ~msg:"ref differs from resolved base64"
            (Mentat_digest.equal
               (Request.digest ref_request)
               (Request.digest (with_source (`Base64 "big bytes")))));
      test "digest separates every billable input" (fun () ->
          let base = Request.make_exn ~model:gpt (ready_transcript ()) in
          let d = Request.digest base in
          let differs ~msg other =
            is_false ~msg (Mentat_digest.equal d (Request.digest other))
          in
          differs ~msg:"model"
            (Request.make_exn ~model:(model "gpt-4") (ready_transcript ()));
          differs ~msg:"transcript message"
            (Request.make_exn ~model:gpt
               (Transcript.add_exn (Message.user_text "more")
                  (ready_transcript ())));
          differs ~msg:"prelude message"
            (Request.make_exn ~model:gpt
               ~prelude:
                 (match Request.Prelude.make [ Message.system "p" ] with
                 | Ok p -> p
                 | Error _ -> Request.Prelude.empty)
               (ready_transcript ()));
          differs ~msg:"tool declaration"
            (Request.make_exn ~model:gpt
               ~tools:[ tool () ]
               (ready_transcript ()));
          differs ~msg:"option"
            (Request.make_exn ~model:gpt
               ~options:(Request.Options.make ~temperature:0.5 ())
               (ready_transcript ())));
      test "byte-sensitive over NUL and high bytes" (fun () ->
          let d s = Request.digest (user_request s) in
          is_false ~msg:"NUL matters"
            (Mentat_digest.equal (d "ab") (d "a\000b"));
          is_false ~msg:"high byte matters"
            (Mentat_digest.equal (d "a") (d "a\255"));
          is_false ~msg:"content structure matters"
            (Mentat_digest.equal
               (Request.digest
                  (Request.make_exn ~model:gpt
                     (Transcript.of_list_exn
                        [ Message.user [ Content.text "ab" ] ])))
               (Request.digest
                  (Request.make_exn ~model:gpt
                     (Transcript.of_list_exn
                        [ Message.user [ Content.text "a"; Content.text "b" ] ])))));
      prop "digest matches the canonical encoding (property)" request_gen
        (fun r -> equal digest_t (oracle_digest r) (Request.digest r));
      prop "digest is stable across a jsont tree round-trip" request_gen
        (fun r ->
          equal digest_t (Request.digest r)
            (Request.digest (decode Request.jsont (encode Request.jsont r))));
      prop "digest is byte-sensitive over NUL-bearing content"
        (Gen.pair nul_text nul_text) (fun (a, b) ->
          cover "a contains NUL" (String.contains a '\000');
          let da = Request.digest (user_request a) in
          let db = Request.digest (user_request b) in
          if String.equal a b then equal digest_t da db
          else
            is_false ~msg:"distinct content, distinct digest"
              (Mentat_digest.equal da db));
    ]

(* Client rejects unaccepted models without running. Setup versus output
   consumption phase is observable through a fake run. *)

let client_contracts =
  group "Client"
    [
      test "provider, apis, and derived acceptance" (fun () ->
          let client =
            Client.make ~provider:openai ~apis:[ responses ]
              ~run:(fun ~cancelled:_ ~on_event:_ _ -> Ok (response ()))
          in
          equal provider_t ~msg:"provider" openai (Client.provider client);
          equal (list api_t) ~msg:"apis" [ responses ] (Client.apis client);
          is_true ~msg:"accepts a served provider and api"
            (Client.accepts client gpt);
          is_false ~msg:"rejects other provider"
            (Client.accepts client (model ~provider:anthropic "claude"));
          is_false ~msg:"rejects an unserved api"
            (Client.accepts client
               (model ~api:(Model.Api.make "chat") "gpt-5")));
      test "dispatch passes cancellation, streams events, returns terminal"
        (fun () ->
          let terminal = response () in
          let seen_cancelled = ref false in
          let events =
            [
              Event.text_delta "he";
              Event.reasoning_summary_delta "why";
              Event.text_delta "llo";
            ]
          in
          let client =
            Client.make ~provider:openai ~apis:[ responses ]
              ~run:(fun ~cancelled ~on_event request ->
                seen_cancelled := cancelled ();
                equal model_t ~msg:"run receives request" gpt
                  (Request.model request);
                List.iter on_event events;
                Ok terminal)
          in
          let observed = ref [] in
          let outcome =
            Client.response
              ~cancelled:(fun () -> true)
              ~on_event:(fun e -> observed := e :: !observed)
              client
              (Request.make_exn ~model:gpt (ready_transcript ()))
          in
          equal
            (result response_t error_t)
            ~msg:"terminal" (Ok terminal) outcome;
          is_true ~msg:"cancellation forwarded" !seen_cancelled;
          equal (list string) ~msg:"events observed in order"
            [ "text:he"; "reason:why"; "text:llo" ]
            (List.rev_map event_desc !observed));
      test "rejects an unaccepted model with Invalid_request, never running"
        (fun () ->
          let called = ref false in
          let client =
            Client.make ~provider:openai ~apis:[ responses ]
              ~run:(fun ~cancelled:_ ~on_event:_ _ ->
                called := true;
                Ok (response ()))
          in
          let wrong =
            Request.make_exn
              ~model:(model ~provider:anthropic "claude")
              (ready_transcript ())
          in
          expect_error "wrong provider" (Client.response client wrong) (fun e ->
              equal string ~msg:"kind" "invalid_request"
                (Error.label (Error.kind e));
              equal (option provider_t) ~msg:"provider" (Some openai)
                (Error.provider e));
          is_false ~msg:"run was never invoked" !called);
      test "rejects a model whose API the client does not serve" (fun () ->
          let client =
            Client.make ~provider:openai ~apis:[ responses ]
              ~run:(fun ~cancelled:_ ~on_event:_ _ -> Ok (response ()))
          in
          let wrong_api =
            Request.make_exn
              ~model:(model ~api:(Model.Api.make "chat") "gpt-5")
              (ready_transcript ())
          in
          expect_error "wrong api" (Client.response client wrong_api) (fun e ->
              equal string ~msg:"kind" "invalid_request"
                (Error.label (Error.kind e))));
      test "phase distinguishes setup from provider-output consumption"
        (fun () ->
          let request = Request.make_exn ~model:gpt (ready_transcript ()) in
          let startup =
            Client.make ~provider:openai ~apis:[ responses ]
              ~run:(fun ~cancelled:_ ~on_event:_ _ ->
                Error
                  (Error.make ~kind:Error.Auth ~phase:Error.Startup "no key"))
          in
          expect_error "startup" (Client.response startup request) (fun e ->
              equal phase_t ~msg:"phase" Error.Startup (Error.phase e);
              equal string ~msg:"kind" "auth" (Error.label (Error.kind e)));
          let observed = ref [] in
          let streaming =
            Client.make ~provider:openai ~apis:[ responses ]
              ~run:(fun ~cancelled:_ ~on_event _ ->
                on_event (Event.text_delta "partial");
                Error
                  (Error.make ~kind:Error.Provider ~phase:Error.Stream
                     "mid-stream"))
          in
          expect_error "stream"
            (Client.response
               ~on_event:(fun e -> observed := e :: !observed)
               streaming request)
            (fun e -> equal phase_t ~msg:"phase" Error.Stream (Error.phase e));
          equal (list string) ~msg:"event delivered before the failure"
            [ "text:partial" ]
            (List.rev_map event_desc !observed));
      (* The "no event after the terminal" rule is enforced by the [run] return
         type: an adapter that returns then emits does not typecheck, so it has
         no runtime test. *)
    ]

let event_contracts =
  group "Event"
    [
      test "constructors build the expected variants" (fun () ->
          equal string ~msg:"text" "text:hi"
            (event_desc (Event.text_delta "hi"));
          equal string ~msg:"reasoning" "reason:why"
            (event_desc (Event.reasoning_summary_delta "why"));
          equal string ~msg:"tool call" "tool_call:call_1"
            (event_desc (Event.tool_call (call ())));
          equal string ~msg:"usage" "usage:3"
            (event_desc (Event.usage (Usage.make ~input:3 ~output:0 ())));
          let delta =
            Event.Tool_input.make ~key:"0" ~call_id:"call_1" ~name:"read_file"
              ~input_delta:"{" ()
          in
          equal string ~msg:"tool input" "tool_input:0"
            (event_desc (Event.tool_input_delta delta));
          equal (option string) ~msg:"delta call id" (Some "call_1")
            (Event.Tool_input.call_id delta);
          equal string ~msg:"delta text" "{"
            (Event.Tool_input.input_delta delta));
      test "rejects empty deltas" (fun () ->
          expect_invalid_arg "empty text" (fun () -> Event.text_delta "");
          expect_invalid_arg "empty reasoning" (fun () ->
              Event.reasoning_summary_delta "");
          expect_invalid_arg "empty key" (fun () ->
              Event.Tool_input.make ~key:"" ~input_delta:"{" ());
          expect_invalid_arg "empty input delta" (fun () ->
              Event.Tool_input.make ~key:"0" ~input_delta:"" ());
          expect_invalid_arg "empty call id" (fun () ->
              Event.Tool_input.make ~key:"0" ~call_id:"" ~input_delta:"{" ()));
    ]

let response_contracts =
  group "Response"
    [
      test "accessors and jsont" (fun () ->
          let assistant = Message.Assistant.text "Done." in
          let r =
            Response.make ~model:gpt ~response_model:"gpt-5-2026-05-01"
              ~response_id:"resp_1" ~provider_stop:"stop" ~stop:Stop.end_turn
              ~usage:(Usage.make ~input:1 ~output:2 ())
              ~reasoning_summary:[ "summary" ] assistant
          in
          equal message_t ~msg:"message"
            (Message.assistant assistant)
            (Response.message r);
          equal (list string) ~msg:"texts" [ "Done." ] (Response.texts r);
          equal string ~msg:"text" "Done." (Response.text r);
          is_false ~msg:"no tools" (Response.has_tool_calls r);
          equal (option string) ~msg:"id" (Some "resp_1")
            (Response.response_id r);
          equal
            (option (opaque "stop"))
            ~msg:"stop" (Some Stop.end_turn) (Response.stop r);
          equal (list string) ~msg:"reasoning summary" [ "summary" ]
            (Response.reasoning_summary r);
          roundtrip "response" response_t Response.jsont r);
      test "rejects empty string fields" (fun () ->
          let a = Message.Assistant.text "Done." in
          expect_invalid_arg "empty response model" (fun () ->
              Response.make ~model:gpt ~response_model:"" a);
          expect_invalid_arg "empty response id" (fun () ->
              Response.make ~model:gpt ~response_id:"" a);
          expect_invalid_arg "empty provider stop" (fun () ->
              Response.make ~model:gpt ~provider_stop:"" a);
          expect_invalid_arg "empty reasoning summary line" (fun () ->
              Response.make ~model:gpt ~reasoning_summary:[ "" ] a));
      test "equality of a tool-call response survives a text round-trip"
        (fun () ->
          (* [Response.equal] defers the assistant message to [Message.equal],
             so it inherits the metadata-insensitive tool-call comparison. *)
          let r =
            Response.make ~model:gpt ~stop:Stop.tool_call
              (assistant_with_calls
                 [
                   Tool.Call.make ~id:"c1" ~name:"read_file"
                     ~input:(json_object [ ("path", Json.string "x") ])
                     ();
                 ])
          in
          is_true ~msg:"constructed equals text-decoded"
            (Response.equal r
               (decode_text_locs Response.jsont (encode_text Response.jsont r))));
    ]

(* Stable wire shapes ([Json.equal] sorts object members, so these pin field
   names and value shapes, not member order). *)

let codec_shapes =
  group "Codec shapes"
    [
      test "stop is a bare label string" (fun () ->
          equal_json "stop" (Json.string "end_turn")
            (encode Stop.jsont Stop.end_turn));
      test "content ref encodes as a tagged token" (fun () ->
          let r = Mentat_digest.Content_ref.of_contents "abc" in
          equal_json "ref content"
            (json_object
               [
                 ("type", Json.string "media");
                 ("media_type", Json.string "image/png");
                 ( "source",
                   json_object
                     [
                       ("type", Json.string "ref");
                       ( "ref",
                         Json.string (Mentat_digest.Content_ref.to_token r) );
                     ] );
               ])
            (encode Content.jsont
               (Content.media ~media_type:"image/png" (`Ref r))));
      test "model encodes provider, api, and id" (fun () ->
          equal_json "model"
            (json_object
               [
                 ("provider", Json.string "openai");
                 ("api", Json.string "responses");
                 ("id", Json.string "gpt-5");
               ])
            (encode Model.jsont gpt));
      test "options shape" (fun () ->
          equal_json "options"
            (json_object
               [
                 ( "tool_choice",
                   json_object
                     [
                       ("type", Json.string "tool");
                       ("name", Json.string "read_file");
                     ] );
                 ("max_output_tokens", Json.int 100);
                 ("temperature", Json.number 0.2);
                 ("reasoning_effort", Json.string "high");
                 ( "response_format",
                   json_object
                     [
                       ("type", Json.string "json_schema");
                       ("name", Json.string "answer");
                       ("schema", schema);
                       ("strict", Json.bool true);
                     ] );
               ])
            (encode Request.Options.jsont
               (Request.Options.make
                  ~tool_choice:(Request.Options.Tool "read_file")
                  ~max_output_tokens:100 ~temperature:0.2
                  ~reasoning_effort:Request.Options.Reasoning_effort.High
                  ~response_format:
                    (Request.Options.Json_schema
                       { name = "answer"; schema; strict = true })
                  ())));
      test "response shape" (fun () ->
          equal_json "response"
            (json_object
               [
                 ( "model",
                   json_object
                     [
                       ("provider", Json.string "openai");
                       ("api", Json.string "responses");
                       ("id", Json.string "gpt-5");
                     ] );
                 ("response_id", Json.string "resp_1");
                 ("stop", Json.string "end_turn");
                 ( "usage",
                   json_object
                     [
                       ("input", Json.int 1);
                       ("output", Json.int 2);
                       ("reasoning", Json.int 0);
                       ("cache_read", Json.int 0);
                       ("cache_write", Json.int 0);
                     ] );
                 ("reasoning_summary", json_array [ Json.string "s" ]);
                 ( "assistant",
                   json_object
                     [
                       ( "parts",
                         json_array
                           [
                             json_object
                               [
                                 ("type", Json.string "text");
                                 ("text", Json.string "Done.");
                               ];
                           ] );
                     ] );
               ])
            (encode Response.jsont
               (Response.make ~model:gpt ~response_id:"resp_1"
                  ~stop:Stop.end_turn
                  ~usage:(Usage.make ~input:1 ~output:2 ())
                  ~reasoning_summary:[ "s" ]
                  (Message.Assistant.text "Done."))));
    ]

let codec_rejections =
  group "Codec rejections"
    [
      test "rejects invalid transcript grammar" (fun () ->
          let bad =
            json_object
              [
                ( "messages",
                  json_array
                    [
                      encode Message.jsont (Message.user_text "hi");
                      encode Message.jsont
                        (Message.tool_result (Tool.Result.empty (call ())));
                    ] );
              ]
          in
          expect_decode_error "bad grammar" Transcript.jsont bad);
      test "rejects an invalid tool name" (fun () ->
          expect_decode_error "tool" Tool.jsont
            (json_object
               [ ("name", Json.string "bad name"); ("input_schema", schema) ]));
      test "rejects an invalid tool-result identity" (fun () ->
          let result ~call_id ~name =
            json_object
              [
                ("call_id", Json.string call_id);
                ("name", Json.string name);
                ("error", Json.bool false);
                ("content", json_array []);
              ]
          in
          expect_decode_error "empty call id" Tool.Result.jsont
            (result ~call_id:"" ~name:"read_file");
          expect_decode_error "invalid tool name" Tool.Result.jsont
            (result ~call_id:"call_1" ~name:"bad name"));
      test "rejects an empty error message" (fun () ->
          expect_decode_error "error" Error.jsont
            (json_object
               [ ("kind", Json.string "auth"); ("message", Json.string "") ]));
      test "rejects a malformed content ref token" (fun () ->
          expect_decode_error "content ref" Content.jsont
            (json_object
               [
                 ("type", Json.string "media");
                 ("media_type", Json.string "image/png");
                 ( "source",
                   json_object
                     [
                       ("type", Json.string "ref");
                       ("ref", Json.string "not-a-token");
                     ] );
               ]));
      test "rejects a negative usage lane" (fun () ->
          expect_decode_error "usage" Usage.jsont
            (json_object [ ("input", Json.int (-1)); ("output", Json.int 0) ]));
    ]

(* Ported end-to-end workflows *)

let workflows =
  group "Workflows"
    [
      test "no-tool request lifecycle" (fun () ->
          let transcript = ready_transcript () in
          let _ = Request.make_exn ~model:gpt transcript in
          let response =
            Response.make ~model:gpt (Message.Assistant.text "Done.")
          in
          let transcript =
            match Transcript.add_response response transcript with
            | Ok t -> t
            | Error e -> failf "add_response: %a" Transcript.Error.pp e
          in
          is_true ~msg:"still ready" (Transcript.is_ready transcript);
          ignore (Request.make_exn ~model:gpt transcript));
      test "tool request lifecycle" (fun () ->
          let c = call () in
          let transcript =
            Transcript.add_exn
              (Message.assistant (assistant_with_calls [ c ]))
              (ready_transcript ())
          in
          is_true ~msg:"awaiting" (not (Transcript.is_ready transcript));
          let transcript =
            match
              Transcript.add
                (Message.tool_result (Tool.Result.text c "contents"))
                transcript
            with
            | Ok t -> t
            | Error e -> failf "answer: %a" Transcript.Error.pp e
          in
          is_true ~msg:"ready" (Transcript.is_ready transcript);
          ignore (Request.make_exn ~model:gpt ~tools:[ tool () ] transcript));
      test
        "client-driven turn: only the terminal response enters the transcript"
        (fun () ->
          let terminal =
            response ~assistant:(assistant_with_calls [ call () ]) ()
          in
          (* The run emits live events, but only [Response.message] is durable. *)
          let client =
            Client.make ~provider:openai ~apis:[ responses ]
              ~run:(fun ~cancelled:_ ~on_event _ ->
                on_event (Event.text_delta "I will use a tool.");
                on_event (Event.tool_call (call ()));
                Ok terminal)
          in
          let request = Request.make_exn ~model:gpt (ready_transcript ()) in
          match Client.response client request with
          | Error e -> failf "response: %a" Error.pp e
          | Ok response ->
              let transcript =
                match
                  Transcript.add_response response (ready_transcript ())
                with
                | Ok t -> t
                | Error e -> failf "add_response: %a" Transcript.Error.pp e
              in
              equal int ~msg:"one assistant message appended" 3
                (List.length (Transcript.messages transcript));
              is_true ~msg:"terminal tool call leaves it pending"
                (not (Transcript.is_ready transcript)));
    ]

let () =
  run "mentat.llm"
    [
      provider_contracts;
      model_contracts;
      content_contracts;
      image_contracts;
      tool_contracts;
      usage_contracts;
      stop_contracts;
      error_contracts;
      message_contracts;
      transcript_contracts;
      request_contracts;
      digest_contracts;
      client_contracts;
      event_contracts;
      response_contracts;
      codec_shapes;
      codec_rejections;
      workflows;
    ]
