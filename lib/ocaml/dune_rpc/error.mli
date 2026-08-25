(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Structured failures of a Dune RPC exchange.

    Every caller inside this library collapses a failed exchange into the
    attach loop's detached state, so no accessor or renderer is declared here:
    the constructors carry their detail for the debugger and for the day a
    surface reports why Dune could not be reached. Adding a reader is the moment
    to decide which surface shows it. *)

type t =
  | Connection_failed of { endpoint : string; message : string }
      (** Registry discovery, socket setup, or connection failed. A missing
          running Dune RPC instance uses the endpoint ["dune rpc registry"]. *)
  | Protocol_error of { message : string; payload : string option }
      (** A Dune RPC request, response, or version negotiation failed. *)
