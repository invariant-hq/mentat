(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let stdout_printf fmt = Printf.printf (fmt ^^ "%!")
let stderr_printf fmt = Printf.eprintf (fmt ^^ "%!")

(* Strip C0 control bytes except tab and newline, and DEL, from untrusted text
   before it reaches the human path: an OSC/CSI sequence in model output
   is a terminal-injection attack on a TTY and noise in a file. *)
let sanitize_c0 text =
  let buffer = Buffer.create (String.length text) in
  String.iter
    (fun char ->
      let code = Char.code char in
      if code = 0x09 || code = 0x0A then Buffer.add_char buffer char
      else if code < 0x20 || code = 0x7F then ()
      else Buffer.add_char buffer char)
    text;
  Buffer.contents buffer

let model_text text = stdout_printf "%s\n" (sanitize_c0 text)
let model_delta text = stdout_printf "%s" (sanitize_c0 text)

(* Remove ANSI escape sequences (CSI [ESC \[ … final] and single [ESC x]
   forms) from a rendered string. cmdliner 2.x fixes its styler at module init
   from [NO_COLOR]/[TERM] and exposes no runtime toggle, so third-party
   styling is stripped here on the way out. *)
let strip_ansi text =
  let length = String.length text in
  let buffer = Buffer.create length in
  let i = ref 0 in
  while !i < length do
    if Char.equal text.[!i] '\x1b' then
      if !i + 1 < length && Char.equal text.[!i + 1] '[' then (
        i := !i + 2;
        while
          !i < length
          &&
          let code = Char.code text.[!i] in
          not (code >= 0x40 && code <= 0x7E)
        do
          incr i
        done;
        if !i < length then incr i)
      else i := !i + 2
    else (
      Buffer.add_char buffer text.[!i];
      incr i)
  done;
  Buffer.contents buffer

(* A formatter that accumulates cmdliner's styled output and, on flush, strips
   ANSI before writing it to [channel]. cmdliner renders each message whole then
   flushes once, so a split escape sequence is not a concern in practice. *)
let stripping_formatter channel =
  let buffer = Buffer.create 256 in
  let out string pos len = Buffer.add_substring buffer string pos len in
  let flush () =
    output_string channel (strip_ansi (Buffer.contents buffer));
    Buffer.clear buffer;
    flush channel
  in
  Format.make_formatter out flush

let help_ppf = stripping_formatter stdout
let err_ppf = stripping_formatter stderr

let flush_cmdliner () =
  Format.pp_print_flush help_ppf ();
  Format.pp_print_flush err_ppf ()

let init () = Jsont.Error.disable_ansi_styler ()

let print_table ~header rows =
  (* Column width in codepoints, not bytes, so multibyte cell content does not
     skew padding. *)
  let cell_width cell =
    String.fold_left
      (fun count char ->
        if Char.code char land 0xC0 <> 0x80 then count + 1 else count)
      0 cell
  in
  let widths =
    List.fold_left
      (fun widths row ->
        let rec loop widths cells =
          match (widths, cells) with
          | _, [] -> widths
          | [], cell :: cells -> cell_width cell :: loop [] cells
          | width :: widths, cell :: cells ->
              max width (cell_width cell) :: loop widths cells
        in
        loop widths row)
      [] (header :: rows)
  in
  let pad width cell =
    cell ^ String.make (max 0 (width - cell_width cell)) ' '
  in
  let trim_right line =
    let length = ref (String.length line) in
    while !length > 0 && Char.equal line.[!length - 1] ' ' do
      decr length
    done;
    String.sub line 0 !length
  in
  let print_row row =
    let rec cells widths row =
      match (widths, row) with
      | _, [] -> []
      | _, [ last ] -> [ last ]
      | width :: widths, cell :: row -> pad width cell :: cells widths row
      | [], cell :: row -> cell :: cells [] row
    in
    stdout_printf "%s\n" (trim_right (String.concat "  " (cells widths row)))
  in
  print_row header;
  List.iter print_row rows

module Json = struct
  let to_string json =
    match Jsont_bytesrw.encode_string Jsont.json json with
    | Ok text -> text
    | Error message -> failwith message

  let obj fields =
    Jsont.Json.object'
      (List.map
         (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
         fields)

  let string s = Jsont.Json.string s
  let int n = Jsont.Json.int n
  let bool b = Jsont.Json.bool b
  let null = Jsont.Json.null ()
  let list values = Jsont.Json.list values
  let string_or_null = function None -> null | Some value -> string value
  let int_or_null = function None -> null | Some value -> int value

  let envelope ~type_ fields =
    obj (("schema_version", int 1) :: ("type", string type_) :: fields)
end

let json_error ~type_ message =
  stdout_printf "%s\n"
    (Json.to_string (Json.envelope ~type_ [ ("error", Json.string message) ]))
