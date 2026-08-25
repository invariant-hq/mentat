(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = struct
  type t = { context : string; reason : string }

  let make ~context reason = { context; reason }

  let message e =
    if String.equal e.context "" then e.reason
    else Printf.sprintf "%s: %s" e.context e.reason

  let pp ppf e = Format.pp_print_string ppf (message e)
end

(* [Jsont.Number] carries a float; accept only values that are an integer
   round-trip so an out-of-range magnitude cannot alias a valid value. *)
let positive_int ~context = function
  | Jsont.Number (v, _)
    when Float.compare v 1.0 >= 0
         && Float.equal (float_of_int (int_of_float v)) v ->
      Ok (int_of_float v)
  | _ -> Error (Error.make ~context "must be a positive integer")
