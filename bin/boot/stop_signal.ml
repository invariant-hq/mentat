(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = bool Atomic.t

let create () = Atomic.make false
let requested t = Atomic.get t
let request t = Atomic.set t true

let with_signals t f =
  let escalate _ = if Atomic.exchange t true then Stdlib.exit 130 in
  let previous_term = Sys.signal Sys.sigterm (Sys.Signal_handle escalate) in
  let previous_int = Sys.signal Sys.sigint (Sys.Signal_handle escalate) in
  Fun.protect
    ~finally:(fun () ->
      Sys.set_signal Sys.sigterm previous_term;
      Sys.set_signal Sys.sigint previous_int)
    f

let wait ~clock t =
  let rec loop () =
    if Atomic.get t then ()
    else begin
      Eio.Time.sleep clock 0.1;
      loop ()
    end
  in
  loop ()
