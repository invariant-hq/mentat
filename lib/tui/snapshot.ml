(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  version : string;
  model : string;
  effort : string option;
  cwd : Lpath.Abs.t;
  home : Lpath.Abs.t option;
  context_window : int option;
  sandbox : string option;
  trusted : bool;
}

let is_white_space uchar =
  match Uchar.to_int uchar with
  | 0x09 | 0x0A | 0x0B | 0x0C | 0x0D | 0x20 | 0x85 | 0xA0 | 0x1680 | 0x2028
  | 0x2029 | 0x202F | 0x205F | 0x3000 ->
      true
  | code -> code >= 0x2000 && code <= 0x200A

let visibly_nonblank value =
  let rec loop offset =
    if offset >= String.length value then false
    else
      let decoded = String.get_utf_8_uchar value offset in
      let uchar = Uchar.utf_decode_uchar decoded in
      if is_white_space uchar then
        loop (offset + Uchar.utf_decode_length decoded)
      else true
  in
  loop 0

let label ~fallback value =
  let value = Prims.normalize_inline value in
  if visibly_nonblank value then value else fallback

let optional_label = function
  | None -> None
  | Some value ->
      let value = Prims.normalize_inline value in
      if visibly_nonblank value then Some value else None

let positive = function Some value when value > 0 -> Some value | _ -> None

let make ~version ~model ~effort ~cwd ~home ~context_window ~sandbox
    ~trusted =
  {
    version = label ~fallback:"[version unavailable]" version;
    model = label ~fallback:"[model unavailable]" model;
    effort = optional_label effort;
    cwd;
    home;
    context_window = positive context_window;
    sandbox = optional_label sandbox;
    trusted;
  }

let version t = t.version
let model t = t.model
let effort t = t.effort
let cwd t = t.cwd
let home t = t.home
let context_window t = t.context_window
let sandbox t = t.sandbox
let trusted t = t.trusted

let with_model ~model ~effort ?context_window t =
  let model = label ~fallback:"[model unavailable]" model in
  let context_window =
    if String.equal model t.model then t.context_window
    else positive context_window
  in
  { t with model; effort = optional_label effort; context_window }

let model_line t =
  match t.effort with Some effort -> t.model ^ " " ^ effort | None -> t.model

let equal a b =
  String.equal a.version b.version
  && String.equal a.model b.model
  && Option.equal String.equal a.effort b.effort
  && Lpath.Abs.equal a.cwd b.cwd
  && Option.equal Lpath.Abs.equal a.home b.home
  && Option.equal Int.equal a.context_window b.context_window
  && Option.equal String.equal a.sandbox b.sandbox
  && Bool.equal a.trusted b.trusted
