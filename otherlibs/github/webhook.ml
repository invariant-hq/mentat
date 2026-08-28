(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Hand-rolled on purpose: Digestif's [consistent_of_hex] accepts whitespace
   separators inside and after the hex, and this authentication surface wants
   the byte-strict grammar — exactly 2n hex digits, nothing else. *)
let hex_digit = function
  | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
  | 'a' .. 'f' as c -> Some (Char.code c - Char.code 'a' + 10)
  | 'A' .. 'F' as c -> Some (Char.code c - Char.code 'A' + 10)
  | _ -> None

let hex_decode s =
  let len = String.length s in
  if len = 0 || len mod 2 <> 0 then None
  else
    let buffer = Bytes.create (len / 2) in
    let rec go i =
      if i >= len then Some (Bytes.to_string buffer)
      else
        match (hex_digit s.[i], hex_digit s.[i + 1]) with
        | Some hi, Some lo ->
            Bytes.set buffer (i / 2) (Char.chr ((hi lsl 4) lor lo));
            go (i + 2)
        | _, _ -> None
    in
    go 0

let prefix = "sha256="

let presented signature =
  let plen = String.length prefix in
  if
    String.length signature > plen
    && String.equal (String.sub signature 0 plen) prefix
  then hex_decode (String.sub signature plen (String.length signature - plen))
  else None

let verify ~secret ~signature ~body =
  match presented signature with
  | None -> false
  | Some presented ->
      String.length presented = 32
      && Eqaf.equal presented
           (Digestif.SHA256.to_raw_string
              (Digestif.SHA256.hmac_string ~key:secret body))
