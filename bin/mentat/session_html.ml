(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Escape-by-construction HTML. [txt] and every attribute value pass through the
   one [escape] path (ampersand, angle brackets, and both quote forms); [raw] is
   the single trusted sink, reserved for static chrome and
   [Cmarkit_html.of_doc ~safe:true] output — it never receives a bare fact
   payload. A rendering-law miss therefore cannot inject markup, and the
   hash-pinned CSP is the backstop for the residual. *)
module Html : sig
  type t
  (** Rendered HTML. Abstract, so within this module a value reaches the output
      only through {!txt} (escaped), an escaped attribute, or the trusted {!raw}
      — a bare string can never masquerade as HTML. *)

  val escape : string -> string
  val txt : string -> t
  val raw : string -> t
  val empty : t
  val seq : t list -> t
  val node : string -> ?attrs:(string * string) list -> t list -> t
  val void : string -> attrs:(string * string) list -> t
  val to_string : t -> string
end = struct
  type t = string

  let escape s =
    let b = Buffer.create (String.length s + 8) in
    String.iter
      (function
        | '&' -> Buffer.add_string b "&amp;"
        | '<' -> Buffer.add_string b "&lt;"
        | '>' -> Buffer.add_string b "&gt;"
        | '"' -> Buffer.add_string b "&quot;"
        | '\'' -> Buffer.add_string b "&#39;"
        | c -> Buffer.add_char b c)
      s;
    Buffer.contents b

  let txt s = escape s
  let raw s = s
  let empty = ""
  let seq ts = String.concat "" ts

  let attrs_string attrs =
    List.map (fun (k, v) -> Printf.sprintf " %s=\"%s\"" k (escape v)) attrs
    |> String.concat ""

  let node tag ?(attrs = []) children =
    Printf.sprintf "<%s%s>%s</%s>" tag (attrs_string attrs) (seq children) tag

  let void tag ~attrs = Printf.sprintf "<%s%s>" tag (attrs_string attrs)
  let to_string t = t
end

(* Markdown prose. [~safe:true] drops raw HTML blocks and unsafe URIs by
   construction; its output is the only value the trusted [Html.raw] sink
   receives from a fact payload. *)
let markdown s =
  Html.raw (Cmarkit_html.of_doc ~safe:true (Cmarkit.Doc.of_string s))

(* The one interactive control: expand/collapse every [<details>]. No inline
   handler (which would defeat the CSP), no external asset. The page degrades to
   per-card toggles without it. Its exact bytes are hashed into [script_hash]
   below, so the emitted [<script>] always matches [script-src 'sha256-…']. *)
let script_js =
  "(function(){function all(v){var \
   ds=document.querySelectorAll('details');for(var \
   i=0;i<ds.length;i++){ds[i].open=v;}}var \
   e=document.getElementById('expand-all'),c=document.getElementById('collapse-all');if(e){e.addEventListener('click',function(){all(true);});}if(c){c.addEventListener('click',function(){all(false);});}})();"

let script_hash =
  Base64.encode_string
    (Mentat_digest.to_raw_string (Mentat_digest.string script_js))

(* The CSP the [<meta>] carries. Only the fetch-directive family binds in meta:
   [default-src 'none'] blocks every unlisted source class, and the
   hash-pinned [script-src] admits exactly the control above — an injected
   [<script>] fails the hash and cannot run. The single quotes are CSP syntax
   and must reach the attribute literally, so this is emitted as raw chrome, not
   through the escaping attribute path; every token here is producer-controlled
   and free of HTML-special bytes. *)
let csp =
  Printf.sprintf
    "default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src \
     'sha256-%s'; base-uri 'none'"
    script_hash

(* Palette ported from [www/style.css] — desert-sand-at-dusk accent, the
   dark-sand variable set, JetBrains Mono. *)
let root_dark_vars =
  "--bg:#0a0908;--panel:#0d0b08;--panel-alt:#0b0a08;--code:#100d09;--text:#dcd5c5;--bright:#f2ede2;--prose:#a89f8a;--muted:#92876f;--faint:#5c5442;--accent:#e0873c;--accent-bright:#f0a05a;--border:#262116;--border-strong:#38301f;--ok:#8aa86a;--err:#d16a4a"

let root_light_vars =
  "--bg:#f6f5f4;--panel:#ffffff;--panel-alt:#faf9f8;--code:#f2f0ee;--text:#2b2620;--bright:#161310;--prose:#4a4437;--muted:#6f6656;--faint:#a89f8a;--accent:#c96a1f;--accent-bright:#b45c14;--border:#e4e0da;--border-strong:#d3cdc3;--ok:#5f7a42;--err:#b34a2e"

let base_css =
  "*{margin:0;padding:0;box-sizing:border-box}body{background:var(--bg);color:var(--text);font-family:var(--mono);font-size:14px;line-height:1.65;-webkit-font-smoothing:antialiased;padding:0}:root{--mono:\"JetBrains \
   Mono\",ui-monospace,\"SF \
   Mono\",Menlo,Monaco,monospace}.wrap{max-width:960px;margin:0 auto;padding:0 \
   20px \
   80px}a{color:var(--accent);text-decoration:none}a:hover{color:var(--accent-bright)}.hd{border-bottom:1px \
   solid var(--border);padding:28px 0 \
   20px;margin-bottom:8px}.brand{color:var(--accent);white-space:pre;font-size:14px;line-height:1;margin:0 \
   0 \
   8px}.wordmark{color:var(--faint);letter-spacing:0.34em;font-size:12px;margin-bottom:18px}.htitle{color:var(--bright);font-size:18px;font-weight:600;margin:0 \
   0 \
   10px;word-break:break-word}.meta{color:var(--muted);font-size:12.5px;display:grid;grid-template-columns:auto \
   1fr;gap:2px 14px}.meta dt{color:var(--faint)}.meta \
   dd{color:var(--prose);word-break:break-word}.totals{margin-top:12px;color:var(--muted);font-size:12.5px}.totals \
   b{color:var(--text);font-weight:600}.controls{display:flex;gap:8px;margin:16px \
   0 24px}.controls \
   button{font-family:inherit;font-size:12px;color:var(--muted);background:none;border:1px \
   solid var(--border-strong);padding:4px 12px;cursor:pointer}.controls \
   button:hover{color:var(--accent);border-color:var(--accent)}.fact{margin:14px \
   0;padding-left:22px;position:relative}.gutter{position:absolute;left:0;top:2px;color:var(--accent);font-size:12px}.role{color:var(--faint);font-size:11px;letter-spacing:0.08em;text-transform:uppercase;margin-bottom:4px}.prose{color:var(--text)}.prose \
   p{margin:0 0 10px}.prose ul,.prose ol{margin:0 0 10px 22px}.prose \
   code{background:var(--code);padding:1px 5px;font-size:12.5px}.prose \
   pre{background:var(--code);border:1px solid var(--border);padding:12px \
   14px;overflow-x:auto;margin:0 0 10px}.prose pre \
   code{background:none;padding:0}.prose h1,.prose h2,.prose h3,.prose \
   h4{color:var(--bright);margin:14px 0 \
   8px;font-size:15px}.msg{border-left:2px solid \
   var(--border-strong);padding-left:12px;color:var(--prose)}details{border:1px \
   solid var(--border);background:var(--panel-alt);margin:6px \
   0}details>summary{cursor:pointer;padding:8px \
   12px;color:var(--muted);font-size:12.5px;list-style:none}details>summary::-webkit-details-marker{display:none}details>summary:hover{color:var(--accent)}details[open]>summary{border-bottom:1px \
   solid var(--border);color:var(--text)}.body{padding:10px 12px}.tool \
   .tname{color:var(--accent-bright);font-weight:600}pre.out{background:var(--code);border:1px \
   solid var(--border);padding:10px \
   12px;overflow-x:auto;font-size:12.5px;white-space:pre-wrap;word-break:break-word;color:var(--prose);margin:0}.chip{display:inline-block;font-size:11px;padding:1px \
   8px;border:1px solid \
   var(--border-strong);color:var(--muted);margin-right:6px}.chip.ok{color:var(--ok);border-color:var(--ok)}.chip.err{color:var(--err);border-color:var(--err)}.chip.warn{color:var(--accent);border-color:var(--accent)}.badge{color:var(--muted);font-size:12px;margin-top:6px}.badge \
   .add{color:var(--ok)}.badge .del{color:var(--err)}.banner{border:1px solid \
   var(--err);color:var(--err);padding:10px \
   12px;font-size:12.5px}.divider{border-top:1px dashed \
   var(--border-strong);margin:26px 0 \
   14px;padding-top:10px;color:var(--faint);font-size:12px;letter-spacing:0.06em}.queue,.deleg{color:var(--muted);font-size:12.5px}.todo{list-style:none;font-size:12.5px}.todo \
   li{padding:2px 0;color:var(--prose)}.todo \
   .g{color:var(--accent);margin-right:8px}.todo \
   .prio{color:var(--faint);font-size:11px;margin-left:8px}.elided{color:var(--faint);font-size:11.5px;font-style:italic;margin:4px \
   0}.placeholder{display:inline-block;border:1px dashed \
   var(--border-strong);color:var(--faint);padding:6px \
   10px;font-size:12px}img.inline{max-width:100%;border:1px solid \
   var(--border);margin:6px 0;display:block}@media \
   print{details{display:block}details>summary{list-style:none}}"

let stylesheet theme =
  match theme with
  | `Dark -> Printf.sprintf ":root{%s}%s" root_dark_vars base_css
  | `Light -> Printf.sprintf ":root{%s}%s" root_light_vars base_css
  | `Auto ->
      Printf.sprintf ":root{%s}@media (prefers-color-scheme:light){:root{%s}}%s"
        root_dark_vars root_light_vars base_css

module Options = struct
  type t = {
    theme : [ `Auto | `Light | `Dark ];
    max_tool_bytes : int;
    max_image_bytes : int;
    max_total_bytes : int;
    timestamp : Mentat_session.Time.t option;
    quiet : bool;
  }

  let make ?(theme = `Auto) ?(max_tool_bytes = 100_000)
      ?(max_image_bytes = 2_000_000) ?(max_total_bytes = 50_000_000) ?timestamp
      ?(quiet = false) () =
    {
      theme;
      max_tool_bytes;
      max_image_bytes;
      max_total_bytes;
      timestamp;
      quiet;
    }

  let default = make ()
end

type head = {
  id : Mentat_session.Id.t;
  title : string option;
  metadata : Mentat_session.Metadata.t;
  metrics : Mentat_session.Metrics.t option;
}

(* Common fragments. *)

let brand_mark = "\xe2\x96\x82\xe2\x96\x84\xe2\x96\x86\xe2\x96\x84\xe2\x96\x82"
(* ▂▄▆▄▂ *)

let chip ?(cls = "") text =
  Html.node "span" ~attrs:[ ("class", "chip " ^ cls) ] [ Html.txt text ]

(* Truncate to a byte cap, returning the kept prefix and the elided-byte count,
   so truncation is always shown, never silent. The cut is backed off so it
   never splits a UTF-8 sequence (a split lead byte would render as a broken
   codepoint). *)
let clamp ~max s =
  let n = String.length s in
  if n <= max then (s, 0)
  else begin
    let is_continuation c = c >= 0x80 && c < 0xc0 in
    let cut = ref max in
    while !cut > 0 && is_continuation (Char.code s.[!cut - 1]) do
      decr cut
    done;
    let keep =
      if !cut = 0 then max
      else
        let lead = Char.code s.[!cut - 1] in
        let need =
          if lead < 0x80 then 1
          else if lead < 0xe0 then 2
          else if lead < 0xf0 then 3
          else 4
        in
        if max - (!cut - 1) >= need then max else !cut - 1
    in
    (String.sub s 0 keep, n - keep)
  end

let elided_note = function
  | 0 -> Html.empty
  | n ->
      Html.node "div"
        ~attrs:[ ("class", "elided") ]
        [ Html.txt (Printf.sprintf "… truncated (%d bytes elided) …" n) ]

let pretty_json j =
  match Jsont_bytesrw.encode_string ~format:Jsont.Indent Jsont.json j with
  | Ok s -> s
  | Error _ -> "<unrenderable input>"

let format_time t =
  let ms = Mentat_session.Time.to_unix_ms t in
  let tm = Unix.gmtime (Int64.to_float ms /. 1000.) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

(* An inlined base64 image, or a placeholder when it exceeds the cap. [media_type]
   and [data] reach the [src]/[alt] attribute sinks, which [Html.void] escapes. *)
let inline_image (opts : Options.t) ~media_type ~data =
  if String.length data <= opts.Options.max_image_bytes then
    Html.void "img"
      ~attrs:
        [
          ("class", "inline");
          ("alt", "inline image");
          ("src", Printf.sprintf "data:%s;base64,%s" media_type data);
        ]
  else
    Html.node "span"
      ~attrs:[ ("class", "placeholder") ]
      [
        Html.txt
          (Printf.sprintf "image omitted (%s, %d bytes over cap)" media_type
             (String.length data - opts.Options.max_image_bytes));
      ]

(* One model-visible content block: prose, an inlined base64 image (capped), or a
   self-contained placeholder for URI/reference media — the export never
   references an external host. [resolve_media] loads a [`Ref]'s attachment bytes
   (supplied by the CLI, which holds the store); a resolved reference embeds the
   real image, an unresolved one keeps the placeholder. *)
let render_content ~resolve_media (opts : Options.t) content =
  match (content : Mentat_llm.Content.t) with
  | Mentat_llm.Content.Text s ->
      Html.node "div" ~attrs:[ ("class", "prose") ] [ markdown s ]
  | Mentat_llm.Content.Media { media_type; source } -> (
      match source with
      | `Base64 data -> inline_image opts ~media_type ~data
      | `Uri uri ->
          Html.node "span"
            ~attrs:[ ("class", "placeholder") ]
            [ Html.txt (Printf.sprintf "linked media (%s): %s" media_type uri) ]
      | `Ref reference -> (
          match resolve_media reference with
          | Some bytes ->
              inline_image opts ~media_type ~data:(Base64.encode_string bytes)
          | None ->
              Html.node "span"
                ~attrs:[ ("class", "placeholder") ]
                [
                  Html.txt
                    (Printf.sprintf "content-referenced media (%s)" media_type);
                ]))

let render_contents ~resolve_media opts contents =
  Html.seq (List.map (render_content ~resolve_media opts) contents)

(* A collapsible card, collapsed by default unless [open_]. [claim]/[decision]
   carry the correlation id so a settlement and its opener read as one card. *)
let card ~fact ?claim ?decision ?(open_ = false) ~seq ~summary body =
  let attrs =
    [ ("class", "fact"); ("data-fact", fact); ("id", Printf.sprintf "f%d" seq) ]
    @ (match claim with Some c -> [ ("data-claim", c) ] | None -> [])
    @ match decision with Some d -> [ ("data-decision", d) ] | None -> []
  in
  let details_attrs = if open_ then [ ("open", "") ] else [] in
  Html.node "div" ~attrs
    [
      Html.node "details" ~attrs:details_attrs
        [
          Html.node "summary" [ summary ];
          Html.node "div" ~attrs:[ ("class", "body") ] [ body ];
        ];
    ]

(* A non-collapsible block with a gutter marker. *)
let block ~fact ~seq ?(gutter = "") ?(cls = "") children =
  Html.node "div"
    ~attrs:
      [
        ("class", "fact " ^ cls);
        ("data-fact", fact);
        ("id", Printf.sprintf "f%d" seq);
      ]
    ((if gutter = "" then Html.empty
      else Html.node "span" ~attrs:[ ("class", "gutter") ] [ Html.txt gutter ])
    :: children)

let permission_requests_list requests =
  match requests with
  | [] -> Html.empty
  | _ ->
      let item r =
        let label =
          match Mentat_permission.Request.display r with
          | Some d -> d
          | None -> (
              match Mentat_permission.Request.source r with
              | Some s -> s
              | None -> "access request")
        in
        Html.node "li" [ Html.txt label ]
      in
      Html.node "div"
        [
          Html.node "div" ~attrs:[ ("class", "role") ] [ Html.txt "permission" ];
          Html.node "ul" ~attrs:[ ("class", "todo") ] (List.map item requests);
        ]

let evidence_badge (ev : Mentat_protocol.Fact.evidence) =
  let stats = ev.Mentat_protocol.Fact.totals in
  let files = stats.Textdiff.files in
  let add = stats.Textdiff.additions in
  let del = stats.Textdiff.deletions in
  let revert =
    match ev.Mentat_protocol.Fact.revertability with
    | Mentat_mutation.Revertability.Available -> Html.empty
    | other ->
        Html.node "span"
          [ Html.txt (" · " ^ Mentat_mutation.Revertability.message other) ]
  in
  let observed =
    match ev.Mentat_protocol.Fact.observed with
    | [] -> Html.empty
    | paths ->
        Html.node "span"
          [
            Html.txt
              (Printf.sprintf " · %d observed path(s)" (List.length paths));
          ]
  in
  Html.node "div"
    ~attrs:[ ("class", "badge") ]
    [
      Html.txt (Printf.sprintf "%d file(s) " files);
      Html.node "span"
        ~attrs:[ ("class", "add") ]
        [ Html.txt (Printf.sprintf "+%d" add) ];
      Html.txt " ";
      Html.node "span"
        ~attrs:[ ("class", "del") ]
        [ Html.txt (Printf.sprintf "\xe2\x88\x92%d" del) ];
      revert;
      observed;
    ]

let tool_status_chip result =
  match Mentat_tool.Result.status result with
  | Mentat_tool.Result.Completed -> chip ~cls:"ok" "completed"
  | Mentat_tool.Result.Failed { kind = _; _ } -> chip ~cls:"err" "failed"
  | Mentat_tool.Result.Interrupted _ -> chip ~cls:"warn" "interrupted"

let tool_result_body (opts : Options.t) result mutation =
  let status = tool_status_chip result in
  let failure_message =
    match Mentat_tool.Result.status result with
    | Mentat_tool.Result.Failed { message; _ } ->
        Html.node "div" ~attrs:[ ("class", "prose") ] [ Html.txt message ]
    | Mentat_tool.Result.Interrupted { reason; _ } ->
        Html.node "div" ~attrs:[ ("class", "prose") ] [ Html.txt reason ]
    | Mentat_tool.Result.Completed -> Html.empty
  in
  let output_block =
    match Mentat_tool.Result.output result with
    | None -> Html.empty
    | Some out ->
        let text = Mentat_tool.Output.text out in
        let kept, elided = clamp ~max:opts.Options.max_tool_bytes text in
        let trunc_chip =
          if Mentat_tool.Output.truncated out then
            chip "output truncated by tool"
          else Html.empty
        in
        Html.seq
          [
            trunc_chip;
            Html.node "pre" ~attrs:[ ("class", "out") ] [ Html.txt kept ];
            elided_note elided;
          ]
  in
  let evidence =
    match mutation with Some ev -> evidence_badge ev | None -> Html.empty
  in
  Html.seq [ status; failure_message; output_block; evidence ]

let decision_request_body req =
  match (req : Mentat_session.Decision.Request.t) with
  | Mentat_session.Decision.Request.Permission review ->
      let action =
        match
          Mentat_permission.Request.display
            (Mentat_permission.Policy.Review.request review)
        with
        | Some d -> d
        | None -> "permission review"
      in
      let n = List.length (Mentat_permission.Policy.Review.accesses review) in
      Html.node "div"
        [
          Html.node "div"
            ~attrs:[ ("class", "role") ]
            [ Html.txt "permission review" ];
          Html.node "div" ~attrs:[ ("class", "prose") ] [ Html.txt action ];
          Html.node "div"
            ~attrs:[ ("class", "badge") ]
            [ Html.txt (Printf.sprintf "%d access(es)" n) ];
        ]
  | Mentat_session.Decision.Request.Question q ->
      let choices =
        match Mentat_session.Question.choices q with
        | None | Some [] -> Html.empty
        | Some cs ->
            Html.node "ul"
              ~attrs:[ ("class", "todo") ]
              (List.map (fun c -> Html.node "li" [ Html.txt c ]) cs)
      in
      Html.node "div"
        [
          Html.node "div" ~attrs:[ ("class", "role") ] [ Html.txt "question" ];
          Html.node "div"
            ~attrs:[ ("class", "prose") ]
            [ markdown (Mentat_session.Question.prompt q) ];
          choices;
        ]
  | Mentat_session.Decision.Request.Plan p ->
      let title =
        match Mentat_session.Plan.title p with
        | Some t -> Html.node "div" ~attrs:[ ("class", "role") ] [ Html.txt t ]
        | None ->
            Html.node "div" ~attrs:[ ("class", "role") ] [ Html.txt "plan" ]
      in
      Html.node "div"
        [
          title;
          Html.node "div"
            ~attrs:[ ("class", "prose") ]
            [ markdown (Mentat_session.Plan.body p) ];
        ]

let principal_label p =
  match (p : Mentat_session.Principal.t) with
  | Mentat_session.Principal.Local_user -> "local user"
  | Mentat_session.Principal.Unattended_policy -> "unattended policy"

let decision_answer_text answer =
  match (answer : Mentat_session.Decision.Answer.t) with
  | Mentat_session.Decision.Answer.Permission { answer = a; message } -> (
      let base = Format.asprintf "%a" Mentat_permission.Answer.pp a in
      match message with Some m -> base ^ " — \"" ^ m ^ "\"" | None -> base)
  | Mentat_session.Decision.Answer.Question a -> (
      match (a : Mentat_session.Question.Answer.t) with
      | Mentat_session.Question.Answer.Free s -> "answered: " ^ s
      | Mentat_session.Question.Answer.Choice i ->
          Printf.sprintf "chose option #%d" (i + 1))
  | Mentat_session.Decision.Answer.Plan a -> (
      match (a : Mentat_session.Plan.Answer.t) with
      | Mentat_session.Plan.Answer.Keep_planning -> "keep planning"
      | Mentat_session.Plan.Answer.Revise feedback -> "revise: " ^ feedback
      | Mentat_session.Plan.Answer.Approve _ -> "plan approved")

let task_glyph = function
  | Mentat_session.Task.Status.Pending -> "\xe2\x97\x8b" (* ○ *)
  | Mentat_session.Task.Status.In_progress -> "\xe2\x97\x90" (* ◐ *)
  | Mentat_session.Task.Status.Completed -> "\xe2\x9c\x93" (* ✓ *)
  | Mentat_session.Task.Status.Cancelled -> "\xe2\x9c\x97" (* ✗ *)

let queue_line update =
  match (update : Mentat_session.Queue.Update.t) with
  | Mentat_session.Queue.Update.Enqueued _ -> "Queued a follow-up input"
  | Mentat_session.Queue.Update.Replaced _ -> "Queue replaced"
  | Mentat_session.Queue.Update.Cleared -> "Queue cleared"

let task_board_card ~seq ?(expanded = false) board =
  let items = Mentat_session.Task.Board.items board in
  let render_item item =
    Html.node "li"
      [
        Html.node "span"
          ~attrs:[ ("class", "g") ]
          [ Html.txt (task_glyph item.Mentat_session.Task.Item.status) ];
        Html.txt item.Mentat_session.Task.Item.content;
        Html.node "span"
          ~attrs:[ ("class", "prio") ]
          [
            Html.txt
              (Mentat_session.Task.Priority.to_string
                 item.Mentat_session.Task.Item.priority);
          ];
      ]
  in
  card ~fact:"journal.task_board" ~seq ~open_:expanded
    ~summary:
      (Html.txt (Printf.sprintf "todos updated (%d)" (List.length items)))
    (Html.node "ul" ~attrs:[ ("class", "todo") ] (List.map render_item items))

let decision_resolution_block resolved =
  let by =
    principal_label (Mentat_session.Decision.Resolved.answered_by resolved)
  in
  let answer =
    decision_answer_text (Mentat_session.Decision.Resolved.answer resolved)
  in
  Html.node "div"
    ~attrs:[ ("class", "msg") ]
    [
      Html.node "div"
        ~attrs:[ ("class", "role") ]
        [ Html.txt ("resolved · " ^ by) ];
      Html.node "div" ~attrs:[ ("class", "prose") ] [ Html.txt answer ];
    ]

(* One decision card keyed by decision id; [resolution], when present, folds the
   answer and its principal into the same card. *)
let decision_card ~seq ?resolution requested =
  let name = Mentat_session.Decision.Requested.name requested in
  let did =
    Mentat_session.Decision.Id.to_string
      (Mentat_session.Decision.Requested.id requested)
  in
  let resolved_chip, resolution_block =
    match resolution with
    | Some r ->
        ( chip ~cls:"ok" "resolved",
          Html.node "div"
            ~attrs:[ ("data-fact", "decision.resolved") ]
            [ decision_resolution_block r ] )
    | None -> (Html.empty, Html.empty)
  in
  card ~fact:"decision.requested" ~decision:did ~seq
    ~summary:
      (Html.seq
         [
           Html.txt (Printf.sprintf "decision (%s)" name);
           Html.txt " ";
           resolved_chip;
         ])
    (Html.seq
       [
         decision_request_body
           (Mentat_session.Decision.Requested.request requested);
         resolution_block;
       ])

(* One fact fragment. The match is exhaustive over all of [Fact.t]'s arms; the
   projector never mints the three recovery-only facts, so they cannot reach
   here. Task-board and decision arms render their standalone default; the
   document pass ({!render_facts}) overrides them with the cross-fact rules —
   board dedup-and-last-expanded and decision request/resolution folding. *)
let fragment ~resolve_media (opts : Options.t) position fact =
  let open Mentat_protocol.Fact in
  let seq = Mentat_protocol.Position.seq position in
  match (fact : Mentat_protocol.Fact.t) with
  | Turn_started turn ->
      let contract = Mentat_session.Turn.contract turn in
      let model = Mentat_session.Contract.model contract in
      let model_label =
        Printf.sprintf "%s/%s"
          (Mentat_llm.Provider.id (Mentat_llm.Model.provider model))
          (Mentat_llm.Model.id model)
      in
      let mode_label =
        match Mentat_session.Contract.mode contract with
        | Mentat_session.Contract.Mode.Build -> "build"
        | Mentat_session.Contract.Mode.Plan -> "plan"
        | Mentat_session.Contract.Mode.Review -> "review"
      in
      let badges = Html.node "div" [ chip mode_label; chip model_label ] in
      let body =
        match Mentat_session.Turn.input turn with
        | Mentat_session.Turn.Input.User contents ->
            Html.seq
              [
                Html.node "div" ~attrs:[ ("class", "role") ] [ Html.txt "user" ];
                render_contents ~resolve_media opts contents;
              ]
        | Mentat_session.Turn.Input.Continue ->
            Html.node "div" ~attrs:[ ("class", "msg") ] [ Html.txt "continued" ]
        | Mentat_session.Turn.Input.Plan_build _ ->
            Html.node "div"
              ~attrs:[ ("class", "msg") ]
              [ Html.txt "plan approved \xe2\x86\x92 build" ]
      in
      block ~fact:"turn.started" ~seq ~gutter:"\xe2\x9d\xaf" ~cls:"turn"
        [ badges; body ]
  | Turn_assistant response ->
      let prose =
        match Mentat_llm.Response.texts response with
        | [] -> Html.empty
        | texts ->
            Html.node "div"
              ~attrs:[ ("class", "prose") ]
              (List.map markdown texts)
      in
      let reasoning_summary =
        match Mentat_llm.Response.reasoning_summary response with
        | [] -> Html.empty
        | lines ->
            Html.node "details"
              [
                Html.node "summary" [ Html.txt "reasoning summary" ];
                Html.node "div"
                  ~attrs:[ ("class", "body prose") ]
                  (List.map (fun l -> Html.node "p" [ Html.txt l ]) lines);
              ]
      in
      let reasoning_parts =
        let parts =
          Mentat_llm.Message.Assistant.reasonings
            (Mentat_llm.Response.assistant response)
        in
        let texts =
          List.filter_map
            (fun r ->
              match Mentat_llm.Message.Assistant.Reasoning.text r with
              | Some t -> Some t
              | None -> Mentat_llm.Message.Assistant.Reasoning.summary r)
            parts
        in
        match texts with
        | [] -> Html.empty
        | _ ->
            Html.node "details"
              [
                Html.node "summary" [ Html.txt "reasoning" ];
                Html.node "div"
                  ~attrs:[ ("class", "body prose") ]
                  (List.map (fun t -> Html.node "p" [ Html.txt t ]) texts);
              ]
      in
      block ~fact:"turn.assistant" ~seq ~gutter:"\xe2\x8f\xba" ~cls:"assistant"
        [ prose; reasoning_summary; reasoning_parts ]
  | Turn_assistant_interrupted { text } ->
      block ~fact:"turn.assistant_interrupted" ~seq ~gutter:"\xe2\x8f\xba"
        ~cls:"assistant"
        [
          chip ~cls:"warn" "interrupted";
          Html.node "div" ~attrs:[ ("class", "prose") ] [ markdown text ];
        ]
  | Turn_provider_failed { claim = _; error } ->
      block ~fact:"turn.provider_failed" ~seq
        [
          Html.node "div"
            ~attrs:[ ("class", "banner") ]
            [
              Html.txt
                (Printf.sprintf "provider error (%s): %s"
                   (Mentat_llm.Error.label (Mentat_llm.Error.kind error))
                   (Mentat_llm.Error.message error));
            ];
        ]
  | Turn_message message ->
      let role, body =
        match (message : Mentat_llm.Message.t) with
        | Mentat_llm.Message.System s ->
            ( "system",
              Html.node "div" ~attrs:[ ("class", "prose") ] [ markdown s ] )
        | Mentat_llm.Message.Developer s ->
            ( "developer",
              Html.node "div" ~attrs:[ ("class", "prose") ] [ markdown s ] )
        | Mentat_llm.Message.User contents ->
            ("user", render_contents ~resolve_media opts contents)
        | Mentat_llm.Message.Assistant a ->
            ( "assistant",
              Html.node "div"
                ~attrs:[ ("class", "prose") ]
                (List.map markdown (Mentat_llm.Message.Assistant.texts a)) )
        | Mentat_llm.Message.Tool_result r ->
            ( "tool result",
              Html.node "pre"
                ~attrs:[ ("class", "out") ]
                [
                  Html.txt (String.concat "\n" (Mentat_llm.Tool.Result.texts r));
                ] )
      in
      block ~fact:"turn.message" ~seq
        [
          Html.node "div"
            ~attrs:[ ("class", "msg") ]
            [
              Html.node "div" ~attrs:[ ("class", "role") ] [ Html.txt role ];
              body;
            ];
        ]
  | Turn_settled { turn = _; outcome } -> (
      match (outcome : Mentat_session.Turn.Outcome.t) with
      | Mentat_session.Turn.Outcome.Completed -> Html.empty
      | Mentat_session.Turn.Outcome.Step_limit ->
          block ~fact:"turn.settled" ~seq [ chip "step limit reached" ]
      | Mentat_session.Turn.Outcome.Interrupted { reason; _ } ->
          let text =
            match reason with
            | Some r -> "interrupted: " ^ r
            | None -> "interrupted"
          in
          block ~fact:"turn.settled" ~seq [ chip ~cls:"warn" text ]
      | Mentat_session.Turn.Outcome.Failed { message } ->
          block ~fact:"turn.settled" ~seq
            [ chip ~cls:"err" ("failed: " ^ message) ])
  | Tool_started started ->
      let name =
        Mentat_llm.Tool.Call.name
          (Mentat_session.Tool_claim.Started.call started)
      in
      let claim =
        Mentat_session.Tool_claim.Id.to_string
          (Mentat_session.Tool_claim.Started.id started)
      in
      let input =
        pretty_json (Mentat_session.Tool_claim.Started.input started)
      in
      let kept, elided = clamp ~max:opts.Options.max_tool_bytes input in
      let requests = Mentat_session.Tool_claim.Started.requests started in
      card ~fact:"tool.started" ~claim ~seq
        ~summary:
          (Html.seq
             [
               Html.node "span" ~attrs:[ ("class", "tname") ] [ Html.txt name ];
               Html.txt "  ·  tool call";
             ])
        (Html.seq
           [
             Html.node "pre" ~attrs:[ ("class", "out") ] [ Html.txt kept ];
             elided_note elided;
             permission_requests_list requests;
           ])
  | Tool_prepared { claim; description; requests } ->
      let claim = Mentat_session.Tool_claim.Id.to_string claim in
      card ~fact:"tool.prepared" ~claim ~seq
        ~summary:(Html.txt "awaiting final approval")
        (Html.seq
           [
             chip "awaiting approval";
             Html.node "div"
               ~attrs:[ ("class", "prose") ]
               [ Html.txt description ];
             permission_requests_list requests;
           ])
  | Tool_returned { claim; result; mutation } ->
      let claim = Mentat_session.Tool_claim.Id.to_string claim in
      card ~fact:"tool.returned" ~claim ~seq ~summary:(Html.txt "tool result")
        (tool_result_body opts result mutation)
  | Tool_ambiguous { claim; mutation } ->
      let claim = Mentat_session.Tool_claim.Id.to_string claim in
      card ~fact:"tool.ambiguous" ~claim ~seq
        ~summary:(Html.txt "ambiguous tool settlement")
        (Html.seq
           [
             chip ~cls:"warn" "ambiguous after crash recovery";
             (match mutation with
             | Some ev -> evidence_badge ev
             | None -> Html.empty);
           ])
  | Decision_requested requested -> decision_card ~seq requested
  | Decision_resolved resolved ->
      block ~fact:"decision.resolved" ~seq
        [ decision_resolution_block resolved ]
  | Journal_task_board board -> task_board_card ~seq board
  | Journal_delegation delegation ->
      let label =
        match Mentat_session.Delegation.description delegation with
        | Some d -> d
        | None -> Mentat_session.Delegation.source_call delegation
      in
      let child =
        Mentat_session.Id.to_string (Mentat_session.Delegation.child delegation)
      in
      block ~fact:"journal.delegation" ~seq
        [
          Html.node "div"
            ~attrs:[ ("class", "deleg") ]
            [
              Html.txt (Printf.sprintf "delegated to subagent: %s " label);
              chip child;
            ];
        ]
  | Journal_queue update ->
      if opts.Options.quiet then Html.empty
      else
        block ~fact:"journal.queue" ~seq
          [
            Html.node "div"
              ~attrs:[ ("class", "queue") ]
              [ Html.txt (queue_line update) ];
          ]
  | Undo { update; dropped_turns; _ } -> (
      match Mentat_session.Undo.Update.anchor update with
      | None -> Html.empty
      | Some _ ->
          block ~fact:"undo.updated" ~seq
            [
              Html.node "div"
                ~attrs:[ ("class", "divider") ]
                [
                  Html.txt
                    (Printf.sprintf "%d turn%s undone" dropped_turns
                       (if dropped_turns = 1 then "" else "s"));
                ];
            ])
  | Workspace_notice notice ->
      let severity =
        match Mentat_session.Notice.severity notice with
        | Mentat_session.Notice.Severity.Error -> "error"
        | Mentat_session.Notice.Severity.Warning -> "warning"
        | Mentat_session.Notice.Severity.Info -> "info"
      in
      let head =
        Mentat_session.Notice.source notice
        ^ " \u{2014} "
        ^ Mentat_session.Notice.title notice
      in
      let body =
        match Mentat_session.Notice.body notice with
        | Some body -> [ Html.node "pre" [ Html.txt body ] ]
        | None -> []
      in
      block ~fact:"workspace.notice" ~seq
        (Html.node "div"
           ~attrs:[ ("class", "notice " ^ severity) ]
           [ Html.txt head ]
        :: body)
  | Compaction compaction ->
      let reason =
        Mentat_session.Compaction.Reason.to_string
          (Mentat_session.Compaction.reason compaction)
      in
      let summary_texts =
        List.filter_map
          (fun m ->
            match (m : Mentat_llm.Message.t) with
            | Mentat_llm.Message.System s | Mentat_llm.Message.Developer s ->
                Some s
            | Mentat_llm.Message.Assistant a ->
                Some (String.concat "\n" (Mentat_llm.Message.Assistant.texts a))
            | Mentat_llm.Message.User contents ->
                Some
                  (String.concat "\n"
                     (List.filter_map
                        (fun c ->
                          match (c : Mentat_llm.Content.t) with
                          | Mentat_llm.Content.Text s -> Some s
                          | Mentat_llm.Content.Media _ -> None)
                        contents))
            | Mentat_llm.Message.Tool_result _ -> None)
          (Mentat_session.Compaction.summary_messages compaction)
      in
      let summary_details =
        Html.node "details"
          [
            Html.node "summary" [ Html.txt "compaction summary" ];
            Html.node "div"
              ~attrs:[ ("class", "body prose") ]
              (List.map markdown summary_texts);
          ]
      in
      block ~fact:"compaction" ~seq
        [
          Html.node "div"
            ~attrs:[ ("class", "divider") ]
            [ Html.txt (Printf.sprintf "context compacted (%s)" reason) ];
          summary_details;
        ]

(* Render the fact stream, applying the two cross-fact rules the per-fact
   {!fragment} cannot see: a task board identical to the previous board is a
   redundant snapshot and is dropped, and the last surviving board renders
   expanded; a decision resolution folds into its request's card, keyed by
   decision id, so only an orphan resolution renders on its own. *)
let render_facts ~resolve_media opts facts =
  let resolutions = Hashtbl.create 16 in
  let requested_ids = Hashtbl.create 16 in
  List.iter
    (fun (_, fact) ->
      match (fact : Mentat_protocol.Fact.t) with
      | Mentat_protocol.Fact.Decision_resolved r ->
          Hashtbl.replace resolutions (Mentat_session.Decision.Resolved.id r) r
      | Mentat_protocol.Fact.Decision_requested q ->
          Hashtbl.replace requested_ids
            (Mentat_session.Decision.Requested.id q)
            ()
      | _ -> ())
    facts;
  let expanded_board =
    let prev = ref None in
    List.fold_left
      (fun acc (pos, fact) ->
        match (fact : Mentat_protocol.Fact.t) with
        | Mentat_protocol.Fact.Journal_task_board b -> (
            match !prev with
            | Some pb when Mentat_session.Task.Board.equal pb b -> acc
            | _ ->
                prev := Some b;
                Mentat_protocol.Position.seq pos)
        | _ -> acc)
      (-1) facts
  in
  let prev_board = ref None in
  List.filter_map
    (fun (pos, fact) ->
      let seq = Mentat_protocol.Position.seq pos in
      match (fact : Mentat_protocol.Fact.t) with
      | Mentat_protocol.Fact.Journal_task_board board -> (
          match !prev_board with
          | Some b when Mentat_session.Task.Board.equal b board -> None
          | _ ->
              prev_board := Some board;
              Some (task_board_card ~seq ~expanded:(seq = expanded_board) board)
          )
      | Mentat_protocol.Fact.Decision_requested requested ->
          let resolution =
            Hashtbl.find_opt resolutions
              (Mentat_session.Decision.Requested.id requested)
          in
          Some (decision_card ~seq ?resolution requested)
      | Mentat_protocol.Fact.Decision_resolved r ->
          if Hashtbl.mem requested_ids (Mentat_session.Decision.Resolved.id r)
          then None
          else Some (fragment ~resolve_media opts pos fact)
      | _ -> Some (fragment ~resolve_media opts pos fact))
    facts

(* The run header above the transcript. *)
let render_head (opts : Options.t) head =
  let m = head.metadata in
  let dl label value =
    Html.seq
      [ Html.node "dt" [ Html.txt label ]; Html.node "dd" [ Html.txt value ] ]
  in
  let title_row =
    match head.title with
    | Some t -> Html.node "div" ~attrs:[ ("class", "htitle") ] [ Html.txt t ]
    | None ->
        Html.node "div"
          ~attrs:[ ("class", "htitle") ]
          [ Html.txt (Mentat_session.Id.to_string head.id) ]
  in
  let stamp =
    match opts.Options.timestamp with
    | Some t -> dl "generated" (format_time t)
    | None -> Html.empty
  in
  let totals =
    match head.metrics with
    | None -> Html.empty
    | Some metrics ->
        let tokens =
          try
            let u = metrics.Mentat_session.Metrics.usage in
            Some
              (Mentat_llm.Usage.input_total u, Mentat_llm.Usage.output_total u)
          with Invalid_argument _ -> None
        in
        let token_text =
          match tokens with
          | Some (i, o) -> Printf.sprintf " · %d in / %d out tokens" i o
          | None -> ""
        in
        Html.node "div"
          ~attrs:[ ("class", "totals") ]
          [
            Html.txt "runs ";
            Html.node "b"
              [ Html.txt (string_of_int metrics.Mentat_session.Metrics.turns) ];
            Html.txt " turn(s), ";
            Html.node "b"
              [
                Html.txt
                  (string_of_int metrics.Mentat_session.Metrics.tool_calls);
              ];
            Html.txt " tool call(s)";
            Html.txt token_text;
          ]
  in
  Html.node "header"
    ~attrs:[ ("class", "hd") ]
    [
      Html.node "div" ~attrs:[ ("class", "brand") ] [ Html.txt brand_mark ];
      Html.node "div" ~attrs:[ ("class", "wordmark") ] [ Html.txt "mentat" ];
      title_row;
      Html.node "dl"
        ~attrs:[ ("class", "meta") ]
        [
          dl "session" (Mentat_session.Id.to_string head.id);
          dl "cwd" (Lpath.Abs.to_string (Mentat_session.Metadata.cwd m));
          dl "lifecycle"
            (Mentat_session.Metadata.Status.to_string
               (Mentat_session.Metadata.status m));
          dl "created" (format_time (Mentat_session.Metadata.created_at m));
          dl "updated" (format_time (Mentat_session.Metadata.updated_at m));
          stamp;
        ];
      totals;
    ]

let controls =
  Html.node "div"
    ~attrs:[ ("class", "controls") ]
    [
      Html.node "button"
        ~attrs:[ ("id", "expand-all"); ("type", "button") ]
        [ Html.txt "expand all" ];
      Html.node "button"
        ~attrs:[ ("id", "collapse-all"); ("type", "button") ]
        [ Html.txt "collapse all" ];
    ]

let render ?(options = Options.default) ?(resolve_media = fun _ -> None) head
    facts =
  let title =
    match head.title with
    | Some t -> t
    | None -> "session " ^ Mentat_session.Id.to_string head.id
  in
  let body =
    Html.seq
      [
        render_head options head;
        controls;
        Html.node "main"
          ~attrs:[ ("class", "transcript") ]
          (render_facts ~resolve_media options facts);
      ]
  in
  let doc =
    String.concat ""
      [
        "<!doctype html>\n<html lang=\"en\">\n<head>\n";
        "<meta charset=\"utf-8\">\n";
        "<meta name=\"viewport\" content=\"width=device-width, \
         initial-scale=1\">\n";
        Printf.sprintf
          "<meta http-equiv=\"Content-Security-Policy\" content=\"%s\">\n" csp;
        Printf.sprintf "<title>%s</title>\n" (Html.escape title);
        Printf.sprintf "<style>%s</style>\n" (stylesheet options.Options.theme);
        "</head>\n<body>\n<div class=\"wrap\">\n";
        Html.to_string body;
        "\n</div>\n";
        Printf.sprintf "<script>%s</script>\n" script_js;
        "</body>\n</html>\n";
      ]
  in
  let len = String.length doc in
  if len > options.Options.max_total_bytes then Error (`Too_large len)
  else Ok doc
